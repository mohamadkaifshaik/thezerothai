// Package graph owns follows, blocks and mutes (ADR-0003: graph/{uid}, follows/{a}_{b}; ADR-0008 social
// graph slice). It exposes Service (consumed by server.go, the Connect handler), Reader (consumed by other
// modules — timeline, posts, notifications — for filtering on the caller's social context), FollowEvents
// (a no-op post-commit hook until the notifications plan) and Eraser (the delete-cascade building block used
// by opsctl and, later, the account-lifecycle job). graph depends on identity's api.go interfaces
// (Directory, Counters) directly; identity depends on graph only through the consumer-side BlockChecker
// interface identity itself declares (identity/api.go) — graph is never imported by identity, so there is
// no import cycle (ADR-0008 "Import cycle to avoid").
package graph

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// FollowState mirrors graphv1.FollowState as a plain Go type (no proto import at the domain-model layer;
// server.go converts at the boundary).
type FollowState int

const (
	FollowStateUnspecified FollowState = iota
	FollowStateNone
	FollowStateFollowing
	// FollowStateRequested is unreachable until private accounts ship (ADR-0008 D1).
	FollowStateRequested
)

// Relationship is the caller's relationship to one user (graphv1.Relationship).
type Relationship struct {
	UserID      string
	FollowState FollowState
	Blocking    bool
	Muting      bool
}

// Snapshot is the caller's whole social context (ADR-0003/ADR-0008 D2), read from graph/{uid} and cached
// 60s (ADR-0008 D8). Set membership is presence-in-map; a nil map is a valid, empty set.
type Snapshot struct {
	Following map[string]bool
	Blocked   map[string]bool
	Muted     map[string]bool
	Requested map[string]bool
	// BlockedBy is never serialized to any client and never exported (ADR-0008 D2/D12).
	BlockedBy map[string]bool
	// BlockedByOverflow is true once this account has been blocked by so many users that blockedBy stopped
	// growing at its 10,000 cap (ADR-0008 D2). Fail-closed paths (Follow, GetProfile, list target checks)
	// then also consult the other party's own graph doc directly instead of trusting BlockedBy alone.
	BlockedByOverflow bool
}

func (s Snapshot) isFollowing(uid string) bool { return s.Following[uid] }
func (s Snapshot) isBlocked(uid string) bool   { return s.Blocked[uid] }
func (s Snapshot) isMuted(uid string) bool     { return s.Muted[uid] }
func (s Snapshot) isBlockedBy(uid string) bool { return s.BlockedBy[uid] }

// relationshipFor computes a Relationship from a caller's own Snapshot only (ADR-0008 D4): never reports
// followed_by, never reflects BlockedBy (a user who blocked the caller looks like a stranger).
func relationshipFor(callerSnap Snapshot, targetUID string) Relationship {
	rel := Relationship{UserID: targetUID}
	if callerSnap.isFollowing(targetUID) {
		rel.FollowState = FollowStateFollowing
	} else {
		rel.FollowState = FollowStateNone
	}
	rel.Blocking = callerSnap.isBlocked(targetUID)
	rel.Muting = callerSnap.isMuted(targetUID)
	return rel
}

// ListItem is one row of a followers/following/blocked/muted page (graphv1.UserListItem).
type ListItem struct {
	User identity.Profile
	// Since is the follow edge's createdAt; zero for blocked/muted rows (unordered-by-time arrays).
	Since        time.Time
	Relationship Relationship
}

// Page is one page of list results, with an opaque next_page_token ("" => no more).
type Page struct {
	Items         []ListItem
	NextPageToken string
}

// Checkpoint resumes Eraser.PurgeUser across calls (ADR-0008 D10). Zero value starts from the beginning.
type Checkpoint struct {
	// Step is 1-5 (see purge.go); 0 means "start".
	Step int
	// Offset is the number of blocked/blockedBy entries already processed in steps 3-4.
	Offset int
}

// Service is the Connect handler's dependency (server.go) and also implements Reader, FollowEvents,
// Eraser and identity.BlockChecker (all on the same concrete type — see service.go) so apiserver.Build
// wires one object into every seam.
type Service interface {
	Follow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	Unfollow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	Block(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	Unblock(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	Mute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	Unmute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error)
	GetRelationships(ctx context.Context, callerUID string, targetUIDs []string) ([]Relationship, error)
	ListFollowers(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error)
	ListFollowing(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error)
	ListBlockedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error)
	ListMutedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error)
}

// Reader is graph's read-only seam other modules use for filtering (ADR-0008: "the timeline, posts and
// notifications plans must use them" — never by reading graph/* directly).
type Reader interface {
	// Snapshot returns uid's whole social context, cached 60s (0 reads on a cache hit).
	Snapshot(ctx context.Context, uid string) (Snapshot, error)
}

// FollowEvents is a post-commit hook, a no-op until the notifications plan (ADR-0008 D11): "graph calls a
// no-op FollowEvents.Followed(ctx, follower, followee, at) after a commit that created an edge; replays and
// no-ops don't call it." Never called synchronously inside the mutation's own transaction/budget.
type FollowEvents interface {
	Followed(ctx context.Context, followerUID, followeeUID string, at time.Time)
}

// Eraser is the delete-cascade building block (ADR-0008 D10), used by opsctl purge-graph now and later the
// account-lifecycle job. PurgeUser is resumable: call again with the returned checkpoint until done is true.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint Checkpoint) (next Checkpoint, done bool, err error)
}
