// Package communities is the Communities module (ADR-0031): public places where people who need not follow each other post about
// one interest, under rules that the community's own owner and moderators enforce inside the community view only. It owns the
// communities/{cid} collection, its communityMembers subcollection and communityMemberships/{uid}, and
// dzeroth.communities.v1.CommunityService. Other modules reach it through the interfaces in model.go and this file (ADR-0031 D1):
// communities.Reader for reads (Get, Role, Memberships); posts never imports this module (posts.CommunityGate and
// posts.CommunityModerator are seams declared in posts).
//
// What exists: the flag gate (FEATURE_COMMUNITIES, D10), the error and limit names fixed by the proto (errors.go, limits.go);
// the write path CreateCommunity, UpdateCommunity and GetCommunity (model.go, service.go, repo_firestore.go, cache.go,
// server_rpcs.go); and the lifecycle (purge.go, the `communities` eraser step and export section, registered in
// apiserver/lifecycle_communities.go, with the rows). The guard (internal/apiserver/lifecycle_collections_guard_test.go)
// fails the build for a collection constant without an erasure row, which is why ship in one PR; join, leave
// and ListMyCommunities (service_membership.go, repo_membership.go, the member-doc cache and Reader). The directory
// and member list (service_directory.go, repo_directory.go, server_directory.go, the Directory seam) and the posting gate
// (gate.go, repo_gate.go, PostGate implements posts.CommunityGate: Admit, CheckMember, AllowPost, CanReply, IsMember) are built.
// The feed (timeline.Server.GetCommunityTimeline, in the timeline module, reading through Reader) and moderation (service_moderation.go, repo_moderation.go, server_moderation.go, consumer-side PostModerator, ADR-0031 N9: communities never imports posts) are built.
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

// Reader is the read seam other modules and the handlers use (ADR-0031 D1): everything cached on this instance for at most 60 s (D12), so
// a write elsewhere reaches a caller within that bound and this instance's own writes refresh the entries at once. timeline,
// posts' CommunityGate (its member lookups use the cached MemberState) and moderation reach communities through it; *service implements it, next to Service.
type Reader interface {
	// Get is the cache-first community document: 0 reads warm, 1 cold (charged when the document is missing too, and a missing one is
	// remembered for 60 s). ErrNotFound for a missing document. It does not apply the SUSPENDED rule: a caller that answers NOT_FOUND for
	// everyone checks Status itself (the owner alone may see a SUSPENDED community in GetCommunity and ListMyCommunities).
	Get(ctx context.Context, communityID string) (Community, error)
	// Role is the viewer's D4 role: OWNER and MODERATOR from the community document, MEMBER and BANNED from the member document, which is
	// cached for 60 s with absence cached too. 0 extra reads warm, 1 cold.
	Role(ctx context.Context, communityID, uid string) (Role, error)
	// Memberships is uid's communityMemberships document, never cached: 1 read (charged when missing too).
	Memberships(ctx context.Context, uid string) (Memberships, error)
}
