package communities

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TxMemberReader reads a member doc inside a transaction (FirestoreRepo.MemberInTx).
type TxMemberReader interface {
	MemberInTx(ctx context.Context, tx *firestore.Transaction, communityID, uid string) (MemberState, error)
}

// PostGate implements posts.CommunityGate (ADR-0031 D5, A2): posts declares the seam and never imports this package, so the methods
// use primitives and *firestore.Transaction only. Built by apiserver and handed to posts late (communities is constructed after posts).
type PostGate struct {
	communities Reader
	members     TxMemberReader
	cap         *ratelimit.DailyCap
	cached      CachedMembers // the Reader itself when it can answer a member lookup alone; nil = use Reader.Role
}

// NewPostGate builds the gate. cap is the per (uid, community) daily cap (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY); nil means no cap.
func NewPostGate(r Reader, m TxMemberReader, cap *ratelimit.DailyCap) *PostGate {
	g := &PostGate{communities: r, members: m, cap: cap}
	if c, ok := r.(CachedMembers); ok {
		g.cached = c
	}
	return g
}

// Admit is step 2: the community from the 60 s cache (1 read cold, 0 warm; staleness bound 60 s, D12). Missing or SUSPENDED is the one
// byte-identical NOT_FOUND; ARCHIVED is COMMUNITY_STATE community_archived. It returns the name for the label snapshot.
func (g *PostGate) Admit(ctx context.Context, cid string) (string, error) {
	c, err := g.communities.Get(ctx, cid)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", NotFoundError()
		}
		return "", logger.RedactErr(fmt.Errorf("communities: gate: load community: %w", err), cid)
	}
	switch c.Status {
	case StatusSuspended:
		return "", NotFoundError()
	case StatusArchived:
		return "", StateConflict(StateArchived)
	}
	return c.Name, nil
}

// CheckMember is step 3: the caller's member doc read fresh inside tx. JOINED passes; BANNED is FORBIDDEN banned; no doc is FORBIDDEN
// not_member.
func (g *PostGate) CheckMember(ctx context.Context, tx *firestore.Transaction, cid, uid string) error {
	st, err := g.members.MemberInTx(ctx, tx, cid, uid)
	if err != nil {
		return err
	}
	switch st {
	case MemberJoined:
		return nil
	case MemberBanned:
		return Forbidden(ReasonBanned)
	}
	return Forbidden(ReasonNotMember)
}

// AllowPost is the end of step 4: one unit of the (uid, community) cap, keyed "uid|cid", per instance and IST day. RATE_LIMITED
// limit=community_posts_per_community_daily when spent.
func (g *PostGate) AllowPost(ctx context.Context, uid, cid string) error {
	if g.cap == nil || g.cap.Allow(uid+"|"+cid) {
		return nil
	}
	return g.cap.ExceededError(ctx, LimitPostsPerCommunityDaily)
}

// CachedMembers is the cached member-doc lookup the reply paths use (*service implements it): 1 read cold, 0 warm, staleness bound 60 s.
// NewPostGate takes it from the Reader when the Reader provides it, else it falls back to Reader.Role.
type CachedMembers interface {
	MemberState(ctx context.Context, communityID, uid string) (MemberState, error)
}

// CanReply is the members-only reply rule (ADR-0031 D5, F8): the community status from the 60 s cache (missing or SUSPENDED is the one
// NOT_FOUND, ARCHIVED is community_archived), then the caller's member doc from the 60 s cache. Not JOINED, and BANNED, is FORBIDDEN
// not_member (a banned caller learns nothing more than a non-member). +2 reads cold, +0 warm; 0 writes.
func (g *PostGate) CanReply(ctx context.Context, uid, cid string) error {
	if _, err := g.Admit(ctx, cid); err != nil {
		return err
	}
	ok, err := g.IsMember(ctx, uid, cid)
	if err != nil {
		return err
	}
	if !ok {
		return Forbidden(ReasonNotMember)
	}
	return nil
}

// IsMember reports whether uid is JOINED in cid from the cached member doc, without loading the community (+1 read cold, +0 warm).
// The owner and every moderator hold a JOINED member doc (D4), so they pass.
func (g *PostGate) IsMember(ctx context.Context, uid, cid string) (bool, error) {
	if g.cached != nil {
		st, err := g.cached.MemberState(ctx, cid, uid)
		if err != nil {
			return false, logger.RedactErr(fmt.Errorf("communities: gate: member state: %w", err), cid, uid)
		}
		return st == MemberJoined, nil
	}
	role, err := g.communities.Role(ctx, cid, uid)
	if err != nil {
		return false, logger.RedactErr(fmt.Errorf("communities: gate: role: %w", err), cid, uid)
	}
	return role != RoleNone && role != RoleBanned, nil
}
