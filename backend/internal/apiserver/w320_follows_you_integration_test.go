//go:build integration

package apiserver

// W3-20: GraphService.GetProfileRelationship, "Follows you" (ADR-0024 D7), over the real Build chain on the emulators.
// The graph package has the module-level matrix (TestW311_*); this file proves the same rules through the production
// chain (interceptors, flag gate, rate-limit config, error mapping, request log): the full relationship matrix with real
// Follow / Block / Mute calls, the budget in the order a profile header uses it (GetProfile, then the relationship call),
// the pair-cache eviction on the TARGET's Follow and Unfollow and on a Block in both directions, and the staleness
// bound across two instances (the other instance converges within CACHE_TTL; a short TTL here makes that checkable).
// NOT_FOUND byte identity for missing, SUSPENDED, DELETING and blocking targets is asserted in
// TestW320_TabNotFoundBytesMatchGetProfile together with the tabs.

import (
	"context"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

func (e *bmChain) w320Rel(u bmUser, target string) (*graphv1.GetProfileRelationshipResponse, error) {
	r, err := e.graph.GetProfileRelationship(context.Background(), authed(u.token, &graphv1.GetProfileRelationshipRequest{UserId: target}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *bmChain) w320Follow(t *testing.T, who bmUser, target string) {
	t.Helper()
	if _, err := e.graph.Follow(context.Background(), authed(who.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("w320-f"), UserId: target})); err != nil {
		t.Fatalf("Follow: %v", err)
	}
}

func (e *bmChain) w320Unfollow(t *testing.T, who bmUser, target string) {
	t.Helper()
	if _, err := e.graph.Unfollow(context.Background(), authed(who.token, &graphv1.UnfollowRequest{IdempotencyKey: contractKey("w320-uf"), UserId: target})); err != nil {
		t.Fatalf("Unfollow: %v", err)
	}
}

func (e *bmChain) w320Block(t *testing.T, who bmUser, target string) {
	t.Helper()
	if _, err := e.graph.Block(context.Background(), authed(who.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b"), UserId: target})); err != nil {
		t.Fatalf("Block: %v", err)
	}
}

// TestW320_FollowsYouMatrix: eleven relationship states, each built with the real RPCs on a writer chain and read on a
// cold reader through the header sequence (GetProfile of the target, then GetProfileRelationship). Cold cost: 3 reads
// after the header's GetProfile warmed the target (ADR-0024 D7: interceptor, caller graph, edge doc), +1 on overflow, 1
// when the answer is the blocked-by refusal (the caller graph; no edge, no Directory read), 0 for the caller's own id.
func TestW320_FollowsYouMatrix(t *testing.T) {
	ctx := context.Background()
	type want struct {
		follow     graphv1.FollowState
		blocking   bool
		muting     bool
		followedBy bool
	}
	none, following := graphv1.FollowState_FOLLOW_STATE_NONE, graphv1.FollowState_FOLLOW_STATE_FOLLOWING
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, w *w320Chain, v, tg bmUser)
		want  want
		reads int64
	}{
		{"no relation", func(t *testing.T, w *w320Chain, v, tg bmUser) {}, want{none, false, false, false}, 3},
		{"the target follows the caller", func(t *testing.T, w *w320Chain, v, tg bmUser) { w.w320Follow(t, tg, v.uid) }, want{none, false, false, true}, 3},
		{"the caller follows the target only", func(t *testing.T, w *w320Chain, v, tg bmUser) { w.w320Follow(t, v, tg.uid) }, want{following, false, false, false}, 3},
		{"mutual follow", func(t *testing.T, w *w320Chain, v, tg bmUser) { w.w320Follow(t, v, tg.uid); w.w320Follow(t, tg, v.uid) }, want{following, false, false, true}, 3},
		{"the caller mutes the target, who follows the caller", func(t *testing.T, w *w320Chain, v, tg bmUser) {
			w.w320Follow(t, tg, v.uid)
			if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m"), UserId: tg.uid})); err != nil {
				t.Fatal(err)
			}
		}, want{none, false, true, true}, 3},
		{"the caller blocks a target who had followed them: Block removed the edge, no edge read", func(t *testing.T, w *w320Chain, v, tg bmUser) {
			w.w320Follow(t, tg, v.uid)
			w.w320Block(t, v, tg.uid)
		}, want{none, true, false, false}, 2},
		{"block then unblock: the edge does not come back", func(t *testing.T, w *w320Chain, v, tg bmUser) {
			w.w320Follow(t, tg, v.uid)
			w.w320Block(t, v, tg.uid)
			if _, err := w.graph.Unblock(ctx, authed(v.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("w320-ub"), UserId: tg.uid})); err != nil {
				t.Fatal(err)
			}
		}, want{none, false, false, false}, 3},
		{"unfollow removes the edge", func(t *testing.T, w *w320Chain, v, tg bmUser) {
			w.w320Follow(t, tg, v.uid)
			w.w320Unfollow(t, tg, v.uid)
		}, want{none, false, false, false}, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := newW320Chain(t, nil)
			v, tg := w.user(t), w.user(t)
			tc.setup(t, w, v, tg)
			r := newW320Chain(t, nil) // cold reader
			// The header's sequence: GetProfile of the target warms the Directory, then the relationship call.
			r.w320Profile(t, v, tg.uid)
			got, err := r.w320Rel(v, tg.uid)
			if err != nil {
				t.Fatalf("GetProfileRelationship: %v", err)
			}
			rel := got.GetRelationship()
			if rel.GetUserId() != tg.uid || rel.GetFollowState() != tc.want.follow || rel.GetBlocking() != tc.want.blocking ||
				rel.GetMuting() != tc.want.muting || got.GetFollowedBy() != tc.want.followedBy {
				t.Errorf("answer = %v, want %+v", got, tc.want)
			}
			budgettest.Assert(t, "GetProfileRelationship cold ("+tc.name+")", r.lineBudget(t, w320RPCGetProfileRel), budgettest.Budget{Reads: tc.reads})
			if c := r.lineBudget(t, w320RPCGetProfileRel); c.Writes() != 0 || c.Deletes() != 0 {
				t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
			}
			// A repeat is free: the snapshot and the pair are cached, the interceptor is warm.
			if _, err := r.w320Rel(v, tg.uid); err != nil {
				t.Fatal(err)
			}
			budgettest.Assert(t, "GetProfileRelationship warm ("+tc.name+")", r.lineBudget(t, w320RPCGetProfileRel), budgettest.Budget{})
		})
	}

	t.Run("the caller's own id: NONE, false, nothing read past the interceptor", func(t *testing.T) {
		w := newW320Chain(t, nil)
		v := w.user(t)
		w.w320Warm(t, v)
		got, err := w.w320Rel(v, v.uid)
		if err != nil || got.GetFollowedBy() || got.GetRelationship().GetFollowState() != none || got.GetRelationship().GetUserId() != v.uid {
			t.Fatalf("self = %v, %v", got, err)
		}
		w.w320AssertNothing(t, "GetProfileRelationship on self", w320RPCGetProfileRel)
	})
	t.Run("a malformed user_id is VALIDATION field=user_id at 0 reads", func(t *testing.T) {
		w := newW320Chain(t, nil)
		v := w.user(t)
		w.w320Warm(t, v)
		for _, bad := range []string{"", "has_underscore", "has space", "../x", "a/b", fmt.Sprintf("%0130d", 1)} {
			_, err := w.w320Rel(v, bad)
			w320Reason(t, fmt.Sprintf("user_id=%q", bad), err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "user_id")
			w.w320AssertNothing(t, "GetProfileRelationship bad id", w320RPCGetProfileRel)
		}
	})
	t.Run("the target blocked the caller: NOT_FOUND after the caller graph only, with and without overflow", func(t *testing.T) {
		w := newW320Chain(t, nil)
		v, blocker, ovBlocker := w.user(t), w.user(t), w.user(t)
		v2 := w.user(t)
		w.w320Block(t, blocker, v.uid)
		w.w320Block(t, ovBlocker, v2.uid)
		if _, err := w.fs.Doc("graph/"+v2.uid).Update(ctx, []firestore.Update{{Path: "blockedBy", Value: firestore.ArrayRemove(ovBlocker.uid)}, {Path: "blockedByOverflow", Value: true}}); err != nil {
			t.Fatal(err)
		}
		r := newW320Chain(t, nil)
		_, err := r.w320Rel(v, blocker.uid)
		wireError(t, err, connect.CodeNotFound)
		// interceptor 1 + caller graph 1; no Directory call, no edge read.
		budgettest.Assert(t, "blocked-by refusal", r.lineBudget(t, w320RPCGetProfileRel), budgettest.Budget{Reads: 2})
		_, err = r.w320Rel(v2, ovBlocker.uid)
		wireError(t, err, connect.CodeNotFound)
		// overflow: interceptor 1 + caller graph 1 + the target's own graph 1.
		budgettest.Assert(t, "blocked-by refusal, overflowed set", r.lineBudget(t, w320RPCGetProfileRel), budgettest.Budget{Reads: 3})
	})
}

// TestW320_FollowsYouPairCache: the pair cache of ADR-0024 D7 on ONE instance. The answer is cached both ways; the
// TARGET's Follow and Unfollow evict it at once (no wait for the TTL), a Block in either direction evicts it, and the
// caller's own Follow and Unfollow never change this edge, so they cost the cache nothing.
func TestW320_FollowsYouPairCache(t *testing.T) {
	w := newW320Chain(t, nil)
	v, tg := w.user(t), w.user(t)
	w.w320Warm(t, v)
	w.w320Profile(t, v, tg.uid) // the header's GetProfile warms the target
	// maxReads is the ADR-0024 D7 ceiling for the step: 0 when nothing was invalidated; after a write on this instance the caller's
	// snapshot and the target's profile may be re-read too (3 = snapshot, profile, edge; 4 with the interceptor), the pair is
	// what the hit flag proves.
	rel := func(want bool, what string, maxReads int64, hit bool) {
		t.Helper()
		got, err := w.w320Rel(v, tg.uid)
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		if got.GetFollowedBy() != want {
			t.Errorf("%s: followed_by = %v, want %v", what, got.GetFollowedBy(), want)
		}
		budgettest.Assert(t, what, w.lineBudget(t, w320RPCGetProfileRel), budgettest.Budget{Reads: maxReads})
		if l := w.line(t, w320RPCGetProfileRel); l["followed_by_cache_hit"] != hit {
			t.Errorf("%s: followed_by_cache_hit = %v, want %v", what, l["followed_by_cache_hit"], hit)
		}
	}
	rel(false, "first look (snapshot + edge, 2 reads past the warm interceptor)", 2, false)
	rel(false, "repeat: false is cached too", 0, true)

	w.w320Follow(t, tg, v.uid) // the TARGET follows the caller: this instance evicts the pair
	rel(true, "after the target's Follow the pair is re-read (cache miss)", 4, false)
	rel(true, "and cached again", 0, true)

	w.w320Follow(t, v, tg.uid) // the caller's own Follow does not touch this edge
	rel(true, "the caller's own Follow keeps the cached pair", 4, true)
	w.w320Unfollow(t, v, tg.uid)
	rel(true, "the caller's own Unfollow keeps the cached pair", 4, true)

	w.w320Unfollow(t, tg, v.uid) // the target unfollows: evicted
	rel(false, "after the target's Unfollow the pair is re-read", 4, false)
	w.w320Follow(t, tg, v.uid)
	rel(true, "target follows again", 4, false)

	w.w320Block(t, v, tg.uid) // the caller blocks the target: Block removed both edges; the pair is evicted
	got, err := w.w320Rel(v, tg.uid)
	if err != nil || !got.GetRelationship().GetBlocking() || got.GetFollowedBy() {
		t.Fatalf("after the caller's Block: %v, %v; want blocking and not followed_by", got, err)
	}
	if _, err := w.graph.Unblock(context.Background(), authed(v.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("w320-ub"), UserId: tg.uid})); err != nil {
		t.Fatal(err)
	}
	rel(false, "after Unblock the old edge is gone (Block removed it) and the stale 'true' is not served", 4, false)

	w.w320Follow(t, tg, v.uid)
	rel(true, "target follows once more", 4, false)
	w.w320Block(t, tg, v.uid) // the TARGET blocks the caller: the pair is evicted and the caller now gets NOT_FOUND
	_, err = w.w320Rel(v, tg.uid)
	wireError(t, err, connect.CodeNotFound)
}

// TestW320_FollowsYouConvergesAcrossInstances: instance A caches "false"; the target follows on instance B. A keeps
// answering false until its entry expires (the documented staleness, at most CACHE_TTL = 60 s in production), then true.
// The TTL is set to 1 s on A so the bound can be observed; the wait is the TTL itself, not synchronisation.
func TestW320_FollowsYouConvergesAcrossInstances(t *testing.T) {
	a := newW320Chain(t, func(c *config.Config) { c.CacheTTL = time.Second })
	b := newW320Chain(t, nil)
	v, tg := a.user(t), a.user(t)
	if got, err := a.w320Rel(v, tg.uid); err != nil || got.GetFollowedBy() {
		t.Fatalf("first look on A: %v, %v", got, err)
	}
	b.w320Follow(t, tg, v.uid)
	if got, err := a.w320Rel(v, tg.uid); err != nil {
		t.Fatal(err)
	} else if got.GetFollowedBy() {
		t.Log("A already converged (its entry had expired before the second look)")
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		got, err := a.w320Rel(v, tg.uid)
		if err != nil {
			t.Fatal(err)
		}
		if got.GetFollowedBy() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("instance A never converged within 10 s of a 1 s TTL")
		}
		time.Sleep(200 * time.Millisecond) // waiting for the cache TTL to pass, not for a goroutine
	}
}
