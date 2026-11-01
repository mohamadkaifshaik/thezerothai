// Package communities is the Communities module (ADR-0031): public places where people who need not follow each other post about
// one interest, under rules that the community's own owner and moderators enforce inside the community view only. It owns the
// communities/{cid} collection, its communityMembers subcollection and communityMemberships/{uid}, and
// dzeroth.communities.v1.CommunityService. Other modules reach it through the interfaces in model.go and this file (ADR-0031 D1):
// communities.Reader for reads, added by the tickets that need it; posts never imports this module (posts.CommunityGate and
// posts.CommunityModerator are seams declared in posts).
//
// What exists: the flag gate (W5-22, FEATURE_COMMUNITIES, D10), the error and limit names fixed by the proto (errors.go, limits.go);
// the write path CreateCommunity, UpdateCommunity and GetCommunity (W5-23: model.go, service.go, repo_firestore.go, cache.go,
// server_rpcs.go); and the lifecycle (W5-24: purge.go, the `communities` eraser step and export section, registered in
// apiserver/lifecycle_communities.go, with the T11 rows). The T11 guard (internal/apiserver/lifecycle_collections_guard_test.go)
// fails the build for a collection constant without an erasure row, which is why W5-23 and W5-24 ship in one PR. Still to come: join,
// leave and the lists (W5-25), posting and the post fields (W5-26), the feed (W5-27, in the timeline module) and moderation (W5-28).
package communities

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name of FEATURE_COMMUNITIES (ADR-0031 D10), the `feature` metadata of FEATURE_DISABLED and the string in
// GetMe.enabled_features. timeline.GetCommunityTimeline and posts.CreatePost (community_id) gate on the same name.
const FlagName = "communities"

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the flag gate every CommunityService method (and timeline's GetCommunityTimeline) runs before any Firestore access
// (ADR-0031 D10: one class, the flag must be on for the caller). Disabled is FAILED_PRECONDITION + FEATURE_DISABLED with
// metadata feature=communities and 0 reads. A nil checker is off for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	err := flags.Guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid, FlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", FlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", FlagName)
	}
	return err
}
