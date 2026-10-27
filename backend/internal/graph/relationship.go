// relationship.go is GetProfileRelationship (ADR-0024 D7, ticket W3-11): the profile header's one graph call. It is
// the caller's Relationship to ONE user, computed from the cached caller snapshot exactly as GetRelationships does,
// plus followed_by ("Follows you"): whether follows/{target}_{caller} exists. That edge is the only extra read, and
// it is cached per pair in graph.Cache (see Cache.Edge for the staleness bound).
package graph

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fieldFollowedByCacheHit is the request-log field for the edge lookup: true when the followed_by answer came from
// the pair cache, false when it cost the one edge read. It is absent when no edge lookup ran (the caller's own id,
// a refused target, a target the caller blocks). Enums and bools only, never a uid (security review L4).
const fieldFollowedByCacheHit = "followed_by_cache_hit"

// ProfileRelationship is the GetProfileRelationship answer (ADR-0024 D7): the caller's Relationship to one user, plus
// whether that user follows the caller.
type ProfileRelationship struct {
	Relationship Relationship
	// FollowedBy is true when follows/{target}_{caller} exists ("Follows you").
	FollowedBy bool
}

// GetProfileRelationship is the ADR-0024 D7 header RPC for exactly one target; it is never computed for list rows
// (1 read each). It needs only FEATURE_GRAPH on for the caller, like every GraphService RPC; D9 gives it no flag
// of its own. It replaces the header's GetRelationships([uid]), which is unchanged.
//
// Order, and what each step costs in Firestore reads:
//  1. flag, then target id format (VALIDATION), 0 reads.
//  2. the caller's own id: NONE and false, 0 reads.
//  3. the target blocked the caller (the caller's snapshot blockedBy, +1 read of the target's graph on a
//     blockedByOverflow caller): NOT_FOUND byte-identical to GetProfile (identity.ProfileNotFoundError), no
//     Directory call, no edge read.
//  4. the target missing, SUSPENDED or DELETING (identity.Directory, cache-first): the same NOT_FOUND.
//  5. the caller blocks the target: Blocking true, followed_by false without reading, because Block deleted both
//     edges and a blocked pair cannot follow (ADR-0008 D9).
//  6. otherwise the edge follows/{target}_{caller}, from the pair cache or one point read.
//
// Reads: cold = caller graph 1 + edge 1 = 2 when the target's profile is warm in the Directory (the header's
// GetProfile has just loaded it), +1 if that profile is cold, +1 on blockedByOverflow; the account-status
// interceptor adds its own 1 on the request line (ADR-0024: "3 cold"). Warm: 0. Refused as blocked-by: 1 cold
// (the caller graph), 0 warm. The caller blocks the target: 1 + Directory, no edge read. Writes: 0.
func (s *service) GetProfileRelationship(ctx context.Context, callerUID, targetUID string) (_ ProfileRelationship, err error) {
	defer begin(ctx, "profile_relationship")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return ProfileRelationship{}, err
	}
	if targetUserIDIssue(targetUID) {
		return ProfileRelationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return ProfileRelationship{Relationship: Relationship{UserID: targetUID, FollowState: FollowStateNone}}, nil
	}

	blockedBy, err := s.IsBlockedBy(ctx, callerUID, targetUID)
	if err != nil {
		return ProfileRelationship{}, s.internalErr("profile relationship", err, callerUID, targetUID)
	}
	if blockedBy {
		return ProfileRelationship{}, identity.ProfileNotFoundError()
	}
	snap, err := s.Snapshot(ctx, callerUID) // a cache hit: IsBlockedBy just loaded it
	if err != nil {
		return ProfileRelationship{}, s.internalErr("profile relationship", err, callerUID)
	}
	profiles, err := s.directory.GetProfiles(ctx, []string{targetUID})
	if err != nil {
		return ProfileRelationship{}, s.internalErr("profile relationship", err, callerUID, targetUID)
	}
	if _, ok := profiles[targetUID]; !ok {
		return ProfileRelationship{}, identity.ProfileNotFoundError()
	}

	out := ProfileRelationship{Relationship: relationshipFor(snap, targetUID)}
	if out.Relationship.Blocking {
		return out, nil
	}
	out.FollowedBy, err = s.followedBy(ctx, targetUID, callerUID)
	if err != nil {
		return ProfileRelationship{}, s.internalErr("profile relationship", err, callerUID, targetUID)
	}
	return out, nil
}

// followedBy answers "does follower follow followee" for one pair: the pair cache first (true and false both
// cached, so a non-follower's repeat view is 0 reads), else one point read of the edge, cached from what it
// returned. The cache's staleness bound is documented at Cache.Edge; a Follow or Unfollow that lands between the
// read and the Set can leave one stale answer for at most that bound.
func (s *service) followedBy(ctx context.Context, follower, followee string) (bool, error) {
	if exists, ok := s.cache.Edge(follower, followee); ok {
		logger.SetRequestField(ctx, fieldFollowedByCacheHit, true)
		return exists, nil
	}
	logger.SetRequestField(ctx, fieldFollowedByCacheHit, false)
	exists, err := s.repo.FollowEdgeExists(ctx, follower, followee)
	if err != nil {
		return false, err
	}
	s.cache.SetEdge(follower, followee, exists)
	return exists, nil
}
