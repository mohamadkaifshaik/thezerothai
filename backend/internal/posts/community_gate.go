package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// CommunityGate is the posting gate of ADR-0031 D5 (A2), declared here by its consumer and implemented by the communities module:
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
}

// Gate outcomes on the request line (`community_gate`, ADR-0031 D13): enums only.
const (
	gateAdmitted  = "admitted"
	gateProtected = "rejected:protected"
	gateRefused   = "rejected" // refused by the gate before the transaction (not found, archived)
	gateNotMember = "rejected:forbidden"
	gateQuota     = "rejected:quota"
	gateCap       = "rejected:cap"
)

// zeroPostID is the all-zero sentinel id (ADR-0010 D13): the timeline's settle watermark is a position (W, zeroID).
const zeroPostID = "0000000000000000000"

// communityBounds are the id bounds a Window puts on `communityId == C ORDER BY __name__ DESC` (ADR-0031 D3). Ids are fixed-width
// 19-digit decimals (ADR-0010 D18), so id order equals (createdAt, id) order. Zero values mean "no bound".
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

// SetCommunityGate wires the gate of CreatePost into a community (ADR-0031 D5). Like SetRepostLinks it is set once at startup, before
// ListenAndServe, because communities is built after posts. Without it a set community_id stays FEATURE_DISABLED feature=communities
// (fail closed: never an ordinary post).
func (s *service) SetCommunityGate(g CommunityGate) { s.community = g }

// ByCommunity implements Reader (ADR-0031 D3). Reads: len(result), minimum 1.
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

// validateCommunityShape is the 0-read VALIDATION part of a set community_id (ADR-0031 D5; proto CreatePost comment): 19 digits, not
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
