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
}

// NewPostGate builds the gate. cap is the per (uid, community) daily cap (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY); nil means no cap.
func NewPostGate(r Reader, m TxMemberReader, cap *ratelimit.DailyCap) *PostGate {
	return &PostGate{communities: r, members: m, cap: cap}
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
