package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// CommunityGate is the posting gate, declared here by its consumer and implemented by the communities module:
// posts never imports communities. Every method returns an already-shaped *apierr.Error for a refusal, which Create passes through.
//
// Create runs it in this order: the protected-caller check (Create itself, 0 reads), Admit (before the transaction), then inside
// CreatePost's transaction CheckMember, the quota write (posts + communityPosts in one Set) and AllowPost.
type CommunityGate interface {
	// Admit checks the community's status from the 60 s instance cache (1 read cold, 0 warm; staleness bound 60 s, so a suspension
	// or archive on another instance reaches this path within a minute) and returns the community's name for the label snapshot. A
	// missing or SUSPENDED community is the one byte-identical NOT_FOUND; ARCHIVED is FAILED_PRECONDITION COMMUNITY_STATE
	// community_archived.
	Admit(ctx context.Context, cid string) (name string, err error)
	// CheckMember reads uid's member doc FRESH inside tx (1 read, never cached: a ban on another instance stops the next post at
	// once). JOINED returns nil; BANNED is FORBIDDEN banned; no doc is FORBIDDEN not_member. A missing doc is never an error of
	// the transaction (CreatePost would read a NotFound as a vanished parent).
	CheckMember(ctx context.Context, tx *firestore.Transaction, cid, uid string) error
	// AllowPost draws one unit of the per (uid, community) daily cap (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, per instance, IST
	// day): RATE_LIMITED limit=community_posts_per_community_daily when spent. Memory only, 0 reads.
	AllowPost(ctx context.Context, uid, cid string) error

	// CanReply is the members-only reply rule, run by Create for a reply whose parent carries a
	// conversationCommunityId. It checks the community status from the 60 s cache (SUSPENDED or missing is the one NOT_FOUND, ARCHIVED is
	// community_archived) and then the caller's member doc from the 60 s cache: not JOINED, and BANNED, is FORBIDDEN reason=not_member.
	// +2 reads cold, +0 warm; staleness bound 60 s, so a ban or leave on another instance reaches this path within a minute. 0 writes.
	CanReply(ctx context.Context, uid, cid string) error
	// IsMember reports whether uid is JOINED in cid, from the same 60 s member cache and without loading the community document (+1 read
	// cold, +0 warm): the viewer_reply_permission hint of GetPost and GetThread (A7). An error is not a refusal; the caller reports UNKNOWN.
	IsMember(ctx context.Context, uid, cid string) (bool, error)
}

// Gate outcomes on the request line (`community_gate`): enums only.
const (
	gateAdmitted  = "admitted"
	gateProtected = "rejected:protected"
	gateRefused   = "rejected" // refused by the gate before the transaction (not found, archived)
	gateNotMember = "rejected:forbidden"
	gateQuota     = "rejected:quota"
	gateCap       = "rejected:cap"

	// Reply-gate outcomes (`community_reply_gate`): enums only.
	replyGateAdmitted  = "admitted"
	replyGateNotMember = "rejected:not_member"
	replyGateState     = "rejected:state" // missing, suspended or archived community
	replyGateError     = "error"
)

// zeroPostID is the all-zero sentinel id: the timeline's settle watermark is a position (W, zeroID).
const zeroPostID = "0000000000000000000"

// communityBounds are the id bounds a Window puts on `communityId == C ORDER BY __name__ DESC`. Ids are fixed-width
// 19-digit decimals, so id order equals (createdAt, id) order. Zero values mean "no bound".
type communityBounds struct {
	// startAfter resumes strictly older than this id (Window.Before).
	startAfter string
	// endBefore stops strictly newer than this id, exclusive (Window.After with a real id).
	endBefore string
	// endAt stops at this id inclusive (Window.After with the zero sentinel: everything created at or after that millisecond).
	endAt string
}

// communityBoundsOf converts a Window to id bounds. It is pure so the sentinel rule is unit-tested without a database.
func communityBoundsOf(w Window) communityBounds {
	var b communityBounds
	if w.Before != nil {
		b.startAfter = w.Before.ID
	}
	if w.After != nil {
		if w.After.ID == zeroPostID {
			b.endAt = snowflake.MinID(w.After.CreatedAt)
		} else {
			b.endBefore = w.After.ID
		}
	}
	return b
}

// SetCommunityGate wires the gate of CreatePost into a community. Like SetRepostLinks it is set once at startup, before
// ListenAndServe, because communities is built after posts. Without it a set community_id stays FEATURE_DISABLED feature=communities
// (fail closed: never an ordinary post).
func (s *service) SetCommunityGate(g CommunityGate) { s.community = g }

// ByCommunity implements Reader. Reads: len(result), minimum 1.
func (s *service) ByCommunity(ctx context.Context, cid string, w Window, limit int) ([]*Post, error) {
	if cid == "" {
		return nil, fmt.Errorf("posts: ByCommunity needs a community id")
	}
	if err := w.validate(); err != nil {
		return nil, err
	}
	readAt := s.now()
	out, err := s.repo.ByCommunity(ctx, cid, w, clampLimit(limit))
	if err != nil {
		return nil, err
	}
	s.fill(out, readAt)
	return out, nil
}

// validateCommunityShape is the 0-read VALIDATION part of a set community_id (proto CreatePost comment): 19 digits, not
// with a reply. (reply_policy is checked where the policy is parsed.)
func validateCommunityShape(in CreateInput) error {
	if in.CommunityID == "" {
		return nil
	}
	if !ids.ValidPostID(in.CommunityID) {
		return apierr.Validation("community_id", "community_id must be a 19-digit community id")
	}
	if in.ReplyToPostID != "" {
		return apierr.Validation("community_id", "a reply belongs to its root post's conversation: leave community_id empty")
	}
	return nil
}

// admitCommunity is steps 1 and 2 of the gate, before the transaction: a protected caller is refused first (F6; the profile is already
// held, 0 reads), then the gate's Admit (community status from the 60 s cache: 1 read cold, 0 warm). It returns the label snapshot.
func (s *service) admitCommunity(ctx context.Context, author identity.Profile, cid string) (*CommunityLabel, error) {
	if author.IsPrivate {
		logger.SetRequestField(ctx, fieldCommunityGate, gateProtected)
		return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT,
			"a protected account cannot post in a community")
	}
	name, err := s.community.Admit(ctx, cid)
	if err != nil {
		logger.SetRequestField(ctx, fieldCommunityGate, gateRefused)
		return nil, err
	}
	logger.SetRequestField(ctx, fieldCommunityGate, gateAdmitted)
	return &CommunityLabel{ID: cid, Name: name}, nil
}

// applyCommunity turns a root-post or quote draft into a community post: the feed key, the label snapshot and the conversation's
// community (the root's own), and the in-transaction gate with the caller's quota tier.
func (s *service) applyCommunity(p *CreateParams, label *CommunityLabel, author identity.Profile) {
	p.Draft.CommunityID = label.ID
	p.Draft.Community = label
	p.Draft.ConversationCommunityID = label.ID
	limit := s.communityPostsPerDay
	if s.isNewAccount(author, s.now()) {
		limit = s.newAccountCommunityPostsPerDay
	}
	p.Community = &CommunityPost{Gate: s.community, QuotaLimit: limit}
}

// noteCommunityGateError records which gate step refused inside the transaction (`community_gate`, enums only).
func noteCommunityGateError(ctx context.Context, err error) {
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		return
	}
	switch ae.Reason {
	case commonv1.ErrorReason_ERROR_REASON_FORBIDDEN:
		logger.SetRequestField(ctx, fieldCommunityGate, gateNotMember)
	case commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
		logger.SetRequestField(ctx, fieldCommunityGate, gateQuota)
	case commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED:
		logger.SetRequestField(ctx, fieldCommunityGate, gateCap)
	}
}

// gateReply is the members-only reply check for a reply whose parent is in a community conversation. It keys on the
// parent's conversationCommunityId, which every reply inherits, so a reply to a reply never loads the root and a hidden root (no
// communityId) stays members-only. It runs after the reply-policy rules, so blocks refusals answer first. Reads: +2 cold
// (community status, member doc, both 60 s caches), +0 warm; a conversation outside a community, communities globally off and an
// unwired gate skip it with 0 reads. A refusal writes nothing.
func (s *service) gateReply(ctx context.Context, uid string, parent *Post, off bool) error {
	cid := parent.ConversationCommunityID
	if cid == "" || off || s.community == nil {
		return nil
	}
	err := s.community.CanReply(ctx, uid, cid)
	switch {
	case err == nil:
		logger.SetRequestField(ctx, fieldCommunityReplyGate, replyGateAdmitted)
		return nil
	case isForbiddenReason(err):
		logger.SetRequestField(ctx, fieldCommunityReplyGate, replyGateNotMember)
		return err
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		logger.SetRequestField(ctx, fieldCommunityReplyGate, replyGateState)
		return err
	}
	logger.SetRequestField(ctx, fieldCommunityReplyGate, replyGateError)
	return logger.RedactErr(fmt.Errorf("posts: community reply gate: %w", err), uid)
}

func isForbiddenReason(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FORBIDDEN
}

// CommunityReplyPermission is the viewer hint for a post whose conversation carries a conversationCommunityId (no new enum value):
// NOT_ALLOWED for a viewer who is not a JOINED member, ALLOWED for a member. known is false (nothing to say) for a post outside a
// community conversation or when the lookup fails, and the caller keeps the answer it had. +1 read cold (the member doc), +0 warm. A
// hidden root keeps its conversation members-only. Implements CommunityReplyHinter; the caller never asks while communities is globally off.
func (s *service) CommunityReplyPermission(ctx context.Context, viewer string, p *Post) (perm postsv1.ReplyPermission, known bool) {
	cid := p.ConversationCommunityID
	if cid == "" || s.community == nil || viewer == "" {
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNSPECIFIED, false
	}
	ok, err := s.community.IsMember(ctx, viewer, cid)
	if err != nil {
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN, true
	}
	if ok {
		return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, true
	}
	return postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, true
}
