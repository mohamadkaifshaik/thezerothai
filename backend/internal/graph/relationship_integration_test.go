//go:build integration

package graph_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// On the emulators: GetProfileRelationship's answers on cold and warm instances, the block matrix, and
// the eviction of the cached follow edge by the writes that change it. Edges are seeded with seedFollow or created by
// the real RPCs, never seedEdge, so the end-of-test invariant sweep holds.

// rel runs GetProfileRelationship as caller on inst and returns the answer and the error.
func rel(t *testing.T, inst wired, caller, target string) (graph.ProfileRelationship, error) {
	t.Helper()
	return inst.graph.GetProfileRelationship(context.Background(), caller, target)
}

func mustRel(t *testing.T, inst wired, caller, target string) graph.ProfileRelationship {
	t.Helper()
	got, err := rel(t, inst, caller, target)
	if err != nil {
		t.Fatalf("GetProfileRelationship(%s -> %s): %v", caller, target, err)
	}
	return got
}

// warmDirectory loads uid's profile into inst's identity cache and nothing else (no graph read), the state the
// header's own GetProfile leaves for the target one request earlier.
func warmDirectory(t *testing.T, inst wired, uids ...string) {
	t.Helper()
	if _, err := inst.identity.(identity.Directory).GetProfiles(context.Background(), uids); err != nil {
		t.Fatalf("warm directory: %v", err)
	}
}

// freshInstance is a second identity+graph pair on the same database with empty caches: a freshly started Cloud Run
// instance.
func freshInstance(w wired) wired { return newInstance(w.client) }

// TestW311_GetProfileRelationship_ColdAndWarm: the answer is the same on an instance with nothing cached, with only the
// target profile warm, after the header's GetProfile, and on the repeat. That the repeat and the blocked pair read no
// edge is checked against the fake repo's call tallies in relationship_test.go.
func TestW311_GetProfileRelationship_ColdAndWarm(t *testing.T) {
	w := newWired(t)
	a, b, c := "uid-w311a", "uid-w311b", "uid-w311c"
	mustCreateProfile(t, w.identity, a, "w311a")
	mustCreateProfile(t, w.identity, b, "w311b")
	mustCreateProfile(t, w.identity, c, "w311c")
	seedFollow(t, w, b, a, time.Now().Add(-time.Hour)) // b follows a

	check := func(inst wired, name string, caller, target string, wantFollowedBy bool) {
		t.Helper()
		got, err := inst.graph.GetProfileRelationship(context.Background(), caller, target)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got.FollowedBy != wantFollowedBy || got.Relationship.UserID != target {
			t.Fatalf("%s: got %+v, want followed_by=%v for %s", name, got, wantFollowedBy, target)
		}
	}

	// Nothing cached at all: caller graph + target users doc + edge.
	cold := freshInstance(w)
	check(cold, "GetProfileRelationship (nothing cached)", a, b, true)
	check(cold, "GetProfileRelationship (warm)", a, b, true)

	// The Directory warm (the header's GetProfile loaded the target), the caller graph and the edge cold.
	cold2 := freshInstance(w)
	warmDirectory(t, cold2, b, c)
	check(cold2, "GetProfileRelationship (cold, profile warm)", a, b, true)
	check(cold2, "GetProfileRelationship (warm)", a, b, true)
	// A non-follower is cached too: the repeat gives the false answer as well.
	check(cold2, "GetProfileRelationship (non-follower, cold edge)", a, c, false)
	check(cold2, "GetProfileRelationship (non-follower, warm)", a, c, false)

	// The header flow: GetProfile has just loaded the caller graph (the block check) and the target profile.
	cold3 := freshInstance(w)
	if _, err := cold3.identity.GetProfile(context.Background(), a, identity.ProfileTarget{UserID: b}); err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	check(cold3, "GetProfileRelationship (after the header's GetProfile)", a, b, true)

	// The caller's own id.
	check(cold, "GetProfileRelationship (own id)", a, a, false)
}

// TestW311_GetProfileRelationship_BlockMatrix: the target blocked the caller is NOT_FOUND byte-identical to GetProfile and
// the caller blocking the target is Blocking with followed_by=false; the missing and non-ACTIVE targets
// answer the same NOT_FOUND.
func TestW311_GetProfileRelationship_BlockMatrix(t *testing.T) {
	w := newWired(t)
	a, b, blocker, ghost, suspended := "uid-w311ma", "uid-w311mb", "uid-w311mblocker", "uid-w311ghost", "uid-w311msusp"
	mustCreateProfile(t, w.identity, a, "w311ma")
	mustCreateProfile(t, w.identity, b, "w311mb")
	mustCreateProfile(t, w.identity, blocker, "w311mblk")
	mustCreateProfile(t, w.identity, suspended, "w311msusp")
	seedFollow(t, w, b, a, time.Now().Add(-time.Hour))
	seedBlock(t, w.client, blocker, a)                    // blocker blocked a
	seedUserField(t, w, suspended, "status", "SUSPENDED") // not ACTIVE

	notFoundLike := func(name string, target string) {
		t.Helper()
		inst := freshInstance(w)
		_, err := rel(t, inst, a, target)
		var got, want *apierr.Error
		if !errors.As(err, &got) {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
		// The reference: what GetProfile answers for the same caller and target on a fresh instance.
		_, wantErr := freshInstance(w).identity.GetProfile(context.Background(), a, identity.ProfileTarget{UserID: target})
		if !errors.As(wantErr, &want) {
			t.Fatalf("%s: GetProfile err = %v, want NOT_FOUND", name, wantErr)
		}
		if got.Code != connect.CodeNotFound || got.Code != want.Code || got.Reason != want.Reason || got.Message != want.Message ||
			!reflect.DeepEqual(got.Metadata, want.Metadata) || got.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED {
			t.Errorf("%s: GetProfileRelationship = %#v, GetProfile = %#v; want identical NOT_FOUND", name, got, want)
		}
	}
	notFoundLike("target blocked the caller", blocker)
	notFoundLike("target missing", ghost)
	notFoundLike("target suspended", suspended)

	// The caller blocks the target (a real Block, which deletes b -> a): Blocking, followed_by=false.
	inst := freshInstance(w)
	if _, err := inst.graph.Block(context.Background(), a, key1, b); err != nil {
		t.Fatalf("Block: %v", err)
	}
	warmDirectory(t, inst, b)
	got, err := rel(t, inst, a, b)
	if err != nil {
		t.Fatalf("GetProfileRelationship after Block: %v", err)
	}
	if !got.Relationship.Blocking || got.FollowedBy || got.Relationship.FollowState != graph.FollowStateNone {
		t.Errorf("after Block: %+v, want blocking, not following, followed_by=false", got)
	}
}

// TestW311_GetProfileRelationship_Overflow: a caller whose blockedBy overflowed also checks the target's own graph:
// a target that blocked it is NOT_FOUND, a target that did not is answered normally.
func TestW311_GetProfileRelationship_Overflow(t *testing.T) {
	w := newWired(t)
	a, b, blocker := "uid-w311oa", "uid-w311ob", "uid-w311oblk"
	mustCreateProfile(t, w.identity, a, "w311oa")
	mustCreateProfile(t, w.identity, b, "w311ob")
	mustCreateProfile(t, w.identity, blocker, "w311oblk")
	seedFollow(t, w, b, a, time.Now().Add(-time.Hour))
	seedGraphArrays(t, w.client, a, map[string]interface{}{"blockedByOverflow": true})
	// blocker's own blocked[] names a, but a's blockedBy does not (the overflowed set dropped it).
	if _, err := w.client.Collection("graph").Doc(blocker).Update(context.Background(), []firestore.Update{{Path: "blocked", Value: firestore.ArrayUnion(a)}}); err != nil {
		t.Fatalf("seed blocker.blocked: %v", err)
	}

	inst := freshInstance(w)
	warmDirectory(t, inst, b)
	got, err := rel(t, inst, a, b)
	if err != nil || !got.FollowedBy {
		t.Fatalf("overflow caller, target b: %+v, %v", got, err)
	}

	_, err = rel(t, freshInstance(w), a, blocker)
	if !isNotFound(err) {
		t.Fatalf("overflow caller, blocker: err = %v, want NOT_FOUND", err)
	}
}

func isNotFound(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Code == connect.CodeNotFound
}

// TestW311_GetProfileRelationship_EvictionAfterTheTargetsFollow: with the answer cached as "does not follow you", the
// target's Follow (a real RPC on this instance) evicts the pair so the next view says "Follows you"; the caller's own
// Follow never touches that edge, so it changes nothing; another instance's write is only seen when the entry expires.
func TestW311_GetProfileRelationship_EvictionAfterTheTargetsFollow(t *testing.T) {
	w := newWired(t)
	a, b, c := "uid-w311ea", "uid-w311eb", "uid-w311ec"
	mustCreateProfile(t, w.identity, a, "w311ea")
	mustCreateProfile(t, w.identity, b, "w311eb")
	mustCreateProfile(t, w.identity, c, "w311ec")
	ctx := context.Background()

	if got := mustRel(t, w, a, b); got.FollowedBy {
		t.Fatalf("before any follow: %+v", got)
	}
	// a's own Follow of b: b -> a is untouched, so the cached false stands.
	if _, err := w.graph.Follow(ctx, a, key1, b); err != nil {
		t.Fatalf("a follows b: %v", err)
	}
	warmDirectory(t, w, b) // the Follow forgot the target's cached profile; the header's GetProfile would reload it
	got, err := rel(t, w, a, b)
	if err != nil || got.FollowedBy || got.Relationship.FollowState != graph.FollowStateFollowing {
		t.Fatalf("after the caller's own Follow: %+v, %v, want FOLLOWING and followed_by=false", got, err)
	}

	// Another instance writes c -> a: this instance keeps the cached false until the entry expires (<= the cache TTL).
	if got := mustRel(t, w, a, c); got.FollowedBy {
		t.Fatalf("c before: %+v", got)
	}
	other := freshInstance(w)
	if _, err := other.graph.Follow(ctx, c, key1, a); err != nil {
		t.Fatalf("c follows a (other instance): %v", err)
	}
	if got := mustRel(t, w, a, c); got.FollowedBy {
		t.Errorf("another instance's Follow was visible at once on this one: %+v (the bound is the cache TTL)", got)
	}
	if got := mustRel(t, other, a, c); !got.FollowedBy {
		t.Errorf("the writing instance does not see its own Follow: %+v", got)
	}

	// The target's Follow on THIS instance evicts the pair: the next view re-reads and sees true.
	if _, err := w.graph.Follow(ctx, b, key2, a); err != nil {
		t.Fatalf("b follows a: %v", err)
	}
	warmDirectory(t, w, b)
	got, err = rel(t, w, a, b)
	if err != nil || !got.FollowedBy || got.Relationship.FollowState != graph.FollowStateFollowing {
		t.Fatalf("after the target's Follow: %+v, %v, want followed_by", got, err)
	}
	if got := mustRel(t, w, a, b); !got.FollowedBy {
		t.Errorf("repeat view lost followed_by: %+v", got)
	}

	// The target's Unfollow evicts it again.
	if _, err := w.graph.Unfollow(ctx, b, key3, a); err != nil {
		t.Fatalf("b unfollows a: %v", err)
	}
	if got := mustRel(t, w, a, b); got.FollowedBy {
		t.Errorf("after the target's Unfollow: %+v, want followed_by=false", got)
	}
}

// TestW311_GetProfileRelationship_EvictionAfterBlock: a Block deletes both edges; the pair cached as "Follows you" in
// either direction is evicted by it, so after the Unblock neither side keeps a stale "Follows you".
func TestW311_GetProfileRelationship_EvictionAfterBlock(t *testing.T) {
	w := newWired(t)
	a, b := "uid-w311ba", "uid-w311bb"
	mustCreateProfile(t, w.identity, a, "w311ba")
	mustCreateProfile(t, w.identity, b, "w311bb")
	seedFollow(t, w, a, b, time.Now().Add(-2*time.Hour))
	seedFollow(t, w, b, a, time.Now().Add(-time.Hour))
	ctx := context.Background()

	if !mustRel(t, w, a, b).FollowedBy || !mustRel(t, w, b, a).FollowedBy {
		t.Fatal("a mutual follow must read as followed_by in both directions")
	}
	if _, err := w.graph.Block(ctx, a, key1, b); err != nil {
		t.Fatalf("a blocks b: %v", err)
	}
	// While blocked: a sees Blocking + false, b sees NOT_FOUND (a looks absent).
	if got := mustRel(t, w, a, b); !got.Relationship.Blocking || got.FollowedBy {
		t.Errorf("blocker's view: %+v", got)
	}
	if _, err := rel(t, w, b, a); !isNotFound(err) {
		t.Errorf("blocked user's view: err = %v, want NOT_FOUND", err)
	}
	if _, err := w.graph.Unblock(ctx, a, key2, b); err != nil {
		t.Fatalf("a unblocks b: %v", err)
	}
	// Both edges are gone for good: a stale cached true on either side would be a lie.
	if got := mustRel(t, w, a, b); got.FollowedBy || got.Relationship.Blocking {
		t.Errorf("a's view after Unblock: %+v, want followed_by=false", got)
	}
	if got := mustRel(t, w, b, a); got.FollowedBy {
		t.Errorf("b's view after Unblock: %+v, want followed_by=false", got)
	}

}

// TestW311_FollowEdgeExists_Repo: the point read answers false for a missing document, and its direction is follower
// then followee.
func TestW311_FollowEdgeExists_Repo(t *testing.T) {
	w := newWired(t)
	a, b := "uid-w311ra", "uid-w311rb"
	mustCreateProfile(t, w.identity, a, "w311ra")
	mustCreateProfile(t, w.identity, b, "w311rb")
	seedFollow(t, w, a, b, time.Now())

	for _, tt := range []struct {
		name               string
		follower, followee string
		want               bool
	}{
		{"existing edge", a, b, true},
		{"the opposite direction", b, a, false},
		{"unknown users", "uid-w311nobody", "uid-w311nobody2", false},
	} {
		ctx := context.Background()
		got, err := w.graph.repo.FollowEdgeExists(ctx, tt.follower, tt.followee)
		if err != nil || got != tt.want {
			t.Errorf("%s: FollowEdgeExists = %v, %v, want %v", tt.name, got, err, tt.want)
		}
	}
	if _, err := w.graph.repo.FollowEdgeExists(context.Background(), "a_b", b); err == nil {
		t.Error("a uid containing the reserved '_' must be refused, not read")
	}
}
