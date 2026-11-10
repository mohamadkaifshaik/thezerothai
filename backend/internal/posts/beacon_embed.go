package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// PostBeaconFlagName is the wire name of FEATURE_POST_BEACON_EMBED. A set CreatePostRequest.beacon_id needs it on for the
// caller; the read side only needs it not globally off (the kill switch strips Post.beacon).
const PostBeaconFlagName = "post_beacon_embed"

// BeaconSnapshot is the frozen summary of the plan a post shares, taken at create time. It is stored on the post doc and
// exported with it, but never put on the wire: PostView carries only what BeaconPlans.Previews decides for the viewer.
type BeaconSnapshot struct {
	Title    string
	Activity beaconsv1.BeaconActivity
	StartAt  time.Time
	// CommunityID is "" for a public plan.
	CommunityID string
}

// BeaconLive is a plan's live, per-viewer state: what the card shows.
type BeaconLive struct {
	BeaconID    string
	Title       string
	Activity    beaconsv1.BeaconActivity
	StartAt     time.Time
	Status      beaconsv1.BeaconStatus
	CommunityID string
}

// Errors of BeaconPlans.EmbedTarget, mapped by Create (any other error, an *apierr.Error included, passes through).
var (
	// ErrBeaconNotFound is one answer for a plan that is missing, hidden or not the caller's.
	ErrBeaconNotFound = errors.New("posts: beacon not found")
	// ErrBeaconEnded and ErrBeaconCancelled: the plan can no longer be shared.
	ErrBeaconEnded     = errors.New("posts: beacon ended")
	ErrBeaconCancelled = errors.New("posts: beacon cancelled")
)

// BeaconPlans is the seam to the beacons module (internal/apiserver adapts beacons.Service to it; posts imports no other
// module). A nil BeaconPlans fails closed: Create refuses a beacon_id with FEATURE_DISABLED and every read renders
// "unavailable".
type BeaconPlans interface {
	// EmbedTarget is the caller's own live OPEN or FULL plan (ErrBeaconNotFound, ErrBeaconEnded, ErrBeaconCancelled).
	EmbedTarget(ctx context.Context, uid, beaconID string) (BeaconLive, error)
	// Previews answers the live state of each plan viewer may see in one batch; an absent id is unavailable.
	Previews(ctx context.Context, viewer string, beaconIDs []string) (map[string]BeaconLive, error)
}

// beaconSnapshotOf is the frozen summary of a live plan.
func beaconSnapshotOf(l BeaconLive) *BeaconSnapshot {
	return &BeaconSnapshot{Title: l.Title, Activity: l.Activity, StartAt: l.StartAt.UTC(), CommunityID: l.CommunityID}
}

// beaconRequestHash appends the plan to the idempotency hash only when one is set, so a request without one hashes
// byte for byte as before.
func beaconRequestHash(base, beaconID string) string {
	if beaconID == "" {
		return base
	}
	return idempotency.HashRequest(base + "|beacon=" + beaconID)
}

// WithBeacons returns v plus the live plans hydrated for this response (read-only afterwards). v itself is not changed.
func (v ViewerSet) WithBeacons(live map[string]BeaconLive) ViewerSet {
	v.beacons = live
	return v
}

// WithBeaconsGloballyOff returns v marked so that ToView carries no Post.beacon (FEATURE_POST_BEACON_EMBED is off for
// everyone: the kill switch).
func (v ViewerSet) WithBeaconsGloballyOff() ViewerSet {
	v.beaconsOff = true
	return v
}

// beaconToProto is the one place a Post.beacon is built. The audience-leak guard: live fields are put on the wire only
// from this response's Previews batch; any other case (never hydrated, hidden, deleted, a community plan the viewer left,
// a failed read) is the bare unavailable form, and the frozen snapshot never leaves the server. A REPOST or QUOTE row
// carries none (the card is on the original), and the kill switch strips it.
func beaconToProto(p *Post, vs ViewerSet) *postsv1.BeaconPreview {
	if p.BeaconID == "" || vs.beaconsOff || p.Kind != KindPost {
		return nil
	}
	l, ok := vs.beacons[p.BeaconID]
	if !ok {
		return &postsv1.BeaconPreview{BeaconId: p.BeaconID, Unavailable: true}
	}
	return &postsv1.BeaconPreview{
		BeaconId: p.BeaconID, Title: l.Title, Activity: l.Activity, StartAt: timestamppb.New(l.StartAt), Status: l.Status,
		CommunityId: l.CommunityID,
	}
}

// HydrateBeacons adds the live plan state of ps to vs: nothing when FEATURE_POST_BEACON_EMBED is globally off (the marker
// strips the field), no read when no post of the page carries a plan, else one batch Previews call (deduplicated, bounded
// by the page). A nil plans or a failed read leaves every card unavailable (fail closed, logged without ids).
func HydrateBeacons(ctx context.Context, fc FlagChecker, plans BeaconPlans, vs ViewerSet, viewer string, ps ...*Post) ViewerSet {
	if g, ok := fc.(GloballyOffChecker); ok && g.GloballyOff(PostBeaconFlagName) {
		return vs.WithBeaconsGloballyOff()
	}
	if fc == nil {
		return vs.WithBeaconsGloballyOff()
	}
	var ids []string
	seen := map[string]bool{}
	for _, p := range ps {
		if p != nil && p.BeaconID != "" && p.Kind == KindPost && !seen[p.BeaconID] {
			seen[p.BeaconID] = true
			ids = append(ids, p.BeaconID)
		}
	}
	if len(ids) == 0 {
		return vs
	}
	if plans == nil {
		return vs.WithBeacons(nil)
	}
	live, err := plans.Previews(ctx, viewer, ids)
	if err != nil { // never fatal: the cards render unavailable
		logger.SetRequestField(ctx, "beacon_previews_failed", true)
		return vs.WithBeacons(nil)
	}
	return vs.WithBeacons(live)
}

// validateBeaconShape is the pure part of the beacon_id rules (0 reads): 19 digits, and a root post only, so no reply, no
// quote and no poll alongside (VALIDATION field "beacon_id"). Images and text are fine.
func validateBeaconShape(in CreateInput, hasPoll bool) error {
	if in.BeaconID == "" {
		return nil
	}
	switch {
	case !ids.ValidBeaconID(in.BeaconID):
		return apierr.Validation("beacon_id", "beacon_id must be a 19-digit plan id")
	case in.ReplyToPostID != "":
		return apierr.Validation("beacon_id", "a reply cannot share a plan")
	case in.QuoteOfPostID != "":
		return apierr.Validation("beacon_id", "a quote cannot share a plan")
	case hasPoll:
		return apierr.Validation("beacon_id", "a post cannot carry both a poll and a plan")
	}
	return nil
}

// beaconTarget runs the plan rules that need a read: the caller's own live plan (BeaconPlans.EmbedTarget, which also checks
// FEATURE_BEACONS for the caller), then the community match. A plan scoped to a community goes only in a post to that
// community; a public plan may go in any post.
func (s *service) beaconTarget(ctx context.Context, uid string, in CreateInput) (BeaconLive, error) {
	live, err := s.beacons.EmbedTarget(ctx, uid, in.BeaconID)
	switch {
	case err == nil:
	case errors.Is(err, ErrBeaconNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return BeaconLive{}, apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "beacon not found")
	case errors.Is(err, ErrBeaconEnded):
		return BeaconLive{}, beaconState("ended")
	case errors.Is(err, ErrBeaconCancelled):
		return BeaconLive{}, beaconState("cancelled")
	default:
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return BeaconLive{}, err
		}
		return BeaconLive{}, logger.RedactErr(fmt.Errorf("posts: plan lookup: %w", err), uid, in.BeaconID)
	}
	if live.CommunityID != "" && live.CommunityID != in.CommunityID {
		return BeaconLive{}, apierr.Validation("beacon_id", "a community plan can only be shared in a post to that community")
	}
	return live, nil
}

func beaconState(reason string) error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "the plan can no longer be shared").
		WithMeta("reason", reason)
}

// beaconSnapshotIf is the snapshot to store: nil without a plan.
func beaconSnapshotIf(beaconID string, l BeaconLive) *BeaconSnapshot {
	if beaconID == "" {
		return nil
	}
	return beaconSnapshotOf(l)
}
