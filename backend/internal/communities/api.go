// Package communities is the Communities module (ADR-0031): public places where people who need not follow each other post about
// one interest, under rules that the community's own owner and moderators enforce inside the community view only. It will own
// the communities/{cid} collection, its communityMembers subcollection and communityMemberships/{uid}, and
// dzeroth.communities.v1.CommunityService. Other modules reach it through the interfaces in this file only (ADR-0031 D1):
// communities.Reader for reads, added by the tickets that need it; posts never imports this module (posts.CommunityGate and
// posts.CommunityModerator are seams declared in posts).
//
// W5-22 ships the skeleton only: the flag name and its gate (FEATURE_COMMUNITIES, D10), the Service seam, the error and limit names
// fixed by the proto (errors.go, limits.go) and a handler that mounts every CommunityService route behind the gate. It names no
// collection constant on purpose: the T11 guard (internal/apiserver/lifecycle_collections_guard_test.go) fails the build for a
// collection constant without an erasure row, so the constants, the eraser step and the guard rows arrive together in
// W5-23 + W5-24. Later tickets add the write path (W5-23), the lifecycle (W5-24), join and the directory (W5-25), posting and
// the post fields (W5-26), the feed (W5-27, in the timeline module) and moderation (W5-28).
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

// Service is the module's seam (ADR-0031 D1): the business rules behind CommunityService, depending on interfaces only. It has no
// methods yet; W5-23 adds Create, Update and Get, W5-25 Join, Leave and the lists, W5-28 the moderation calls, and the handler
// then stops answering Unimplemented past the gate.
type Service interface{}

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
