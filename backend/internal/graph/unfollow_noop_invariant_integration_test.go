//go:build integration

// unfollow_noop_invariant_integration_test.go is ticket T32 (ADR-0009, closes review item N4): emulator tests
// that pin the invariant "for any account that can call graph RPCs, follows/{a}_{b} exists <=> b in
// graph/{a}.following <=> users/{a} and users/{b} exist", which is what makes Unfollow's blind-batch no-op
// (repo_firestore.go Unfollow: failed precondition => (false, nil) => NONE) correct.
//
//  1. Every no-op cause the code can produce ends with the target NOT in following, no edge doc, 0 reads /
//     0 writes / 0 deletes, and the identical NONE answer (nothing that could tell "deleted" from "blocked").
//  2. The one ops-only stuck state (S2: edge + following entry exist, users/{target} is gone) is seeded
//     directly: Unfollow is still the same 0-cost NONE, the invariant checker flags it, and running PurgeUser
//     to completion (the documented repair) restores every invariant.
package graph_test

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// wantNoopRel is the only answer Unfollow may give for any no-op cause (ADR-0009 privacy/oracle check).
func wantNoopRel(target string) graph.Relationship {
	return graph.Relationship{UserID: target, FollowState: graph.FollowStateNone}
}

// assertNotFollowing checks the post-condition shared by every no-op cause: a's following array does not hold
// b and follows/a_b does not exist.
func assertNotFollowing(t *testing.T, w wired, a, b string) {
	t.Helper()
	if g := graphArrays(t, w.client, a); contains(g["following"], b) {
		t.Errorf("graph/%s.following = %v still contains %s after a no-op Unfollow", a, g["following"], b)
	}
	if docExists(t, w.client, "follows/"+a+"_"+b) {
		t.Errorf("follows/%s_%s still exists after a no-op Unfollow", a, b)
	}
}

// noopUnfollow calls Unfollow under the documented no-op budget (0R/0W/0D) and requires the NONE answer.
func noopUnfollow(t *testing.T, w wired, label, caller, key, target string) graph.Relationship {
	t.Helper()
	var rel graph.Relationship
	measured(t, label, budUnfollowNoop, func(ctx context.Context) {
		var err error
		rel, err = w.graph.Unfollow(ctx, caller, key, target)
		must(t, label, err)
	})
	if !reflect.DeepEqual(rel, wantNoopRel(target)) {
		t.Errorf("%s: rel = %+v, want %+v", label, rel, wantNoopRel(target))
	}
	return rel
}

// TestT32_Unfollow_NoopCauses_LeaveInvariantAndCostNothing covers each cause of a no-op Unfollow that API paths
// can produce (ADR-0009 reachability table): never followed (incl. a target that never existed), replay,
// blocked either way, edge removed by Block, and edge removed by the target's purge (step 2). Self-unfollow is
// the service-level no-op that never reaches Firestore.
func TestT32_Unfollow_NoopCauses_LeaveInvariantAndCostNothing(t *testing.T) {
	const a, b = "uid-a", "uid-b"
	ctx := context.Background()
	causes := []struct {
		name   string
		target string
		setup  func(t *testing.T, w wired)
	}{
		{"never followed", b, func(t *testing.T, w wired) {}},
		{"target never existed", "uid-ghost", func(t *testing.T, w wired) {}},
		{"replay after a successful unfollow", b, func(t *testing.T, w wired) {
			_, err := w.graph.Follow(ctx, a, key1, b)
			must(t, "Follow", err)
			_, err = w.graph.Unfollow(ctx, a, key2, b)
			must(t, "Unfollow", err)
		}},
		{"caller blocked target", b, func(t *testing.T, w wired) {
			_, err := w.graph.Block(ctx, a, key1, b)
			must(t, "Block a->b", err)
		}},
		{"target blocked caller (blocked-by)", b, func(t *testing.T, w wired) {
			_, err := w.graph.Block(ctx, b, key1, a)
			must(t, "Block b->a", err)
		}},
		{"edge removed by Block (caller followed, then target blocked caller)", b, func(t *testing.T, w wired) {
			_, err := w.graph.Follow(ctx, a, key1, b)
			must(t, "Follow", err)
			_, err = w.graph.Block(ctx, b, key2, a)
			must(t, "Block b->a", err)
		}},
		{"edge removed by Block (caller followed, then caller blocked target)", b, func(t *testing.T, w wired) {
			_, err := w.graph.Follow(ctx, a, key1, b)
			must(t, "Follow", err)
			_, err = w.graph.Block(ctx, a, key2, b)
			must(t, "Block a->b", err)
		}},
		{"edge removed by purge step 2 of the target", b, func(t *testing.T, w wired) {
			_, err := w.graph.Follow(ctx, a, key1, b)
			must(t, "Follow", err)
			purgeToCompletion(t, w.graph.repo, b, graph.Checkpoint{})
		}},
	}

	answers := map[string]graph.Relationship{}
	for _, tc := range causes {
		t.Run(tc.name, func(t *testing.T) {
			w := newWired(t)
			mustCreateProfile(t, w.identity, a, "usera")
			mustCreateProfile(t, w.identity, b, "userb")
			tc.setup(t, w)

			rel := noopUnfollow(t, w, "Unfollow no-op ("+tc.name+")", a, key3, tc.target)
			assertNotFollowing(t, w, a, tc.target)
			answers[tc.name] = rel
			// The end-of-test sweep (newWired) proves I1-I4 still hold: a no-op must not disturb counters.
		})
	}
	t.Run("self unfollow", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, a, "usera")
		answers["self"] = noopUnfollow(t, w, "Unfollow no-op (self)", a, key3, a)
	})

	// Oracle check: every cause produced the same NONE answer, so nothing distinguishes deleted from blocked.
	// (UserID is echoed from the request, so compare with it normalized.)
	var first graph.Relationship
	for name, rel := range answers {
		rel.UserID = ""
		if first == (graph.Relationship{}) {
			first = rel
		}
		if rel != first {
			t.Errorf("no-op answer for %q = %+v differs from the others (%+v): distinct answers could reveal the cause", name, rel, first)
		}
	}
	if len(answers) != len(causes)+1 {
		t.Errorf("collected %d answers, want %d (a subtest did not run)", len(answers), len(causes)+1)
	}
}

// TestT32_Unfollow_RaceWithTargetPurge races Unfollow(a->b) against the full purge of b (step 2 deletes the
// same edge with the same Exists precondition). Whichever wins, the target must end up out of following, the
// counters must be exact (sweep), and a follow-up Unfollow must be a 0-cost NONE.
func TestT32_Unfollow_RaceWithTargetPurge(t *testing.T) {
	const iterations = 4
	w := newWired(t)
	users := mustCreateUsers(t, w.identity, "p", 2*iterations)
	ctx := context.Background()
	for it := 0; it < iterations; it++ {
		a, b := users[2*it], users[2*it+1]
		_, err := w.graph.Follow(ctx, a, key1, b)
		must(t, "setup Follow", err)

		errs := runConcurrently(2, func(i int) error {
			if i == 0 {
				_, err := w.graph.Unfollow(ctx, a, key2, b)
				return err
			}
			purgeToCompletion(t, w.graph.repo, b, graph.Checkpoint{})
			return nil
		})
		for i, err := range errs {
			if err != nil {
				t.Errorf("iteration %d call %d: %v", it, i, err)
			}
		}
		assertNotFollowing(t, w, a, b)
		noopUnfollow(t, w, fmt.Sprintf("Unfollow after race #%d", it), a, key3, b)
		assertGraphInvariants(t, w.client)
		if t.Failed() {
			return
		}
	}
}

// TestT32_Unfollow_StuckS2_IsFlaggedAndPurgeRepairs pins the ops-only failure and its documented repair
// (ADR-0009 S2, runbook: `opsctl purge-graph --skip-start-gate --uid <deleted uid>`): the edge and following
// entry exist but users/{b} is gone, so the counter Update in Unfollow's batch fails NotFound.
func TestT32_Unfollow_StuckS2_IsFlaggedAndPurgeRepairs(t *testing.T) {
	const a, b = "uid-a", "uid-b"
	w := newWired(t)
	w.SkipInvariantSweep("T32 seeds ADR-0009 state S2 (users/uid-b deleted while an edge to it exists); the test asserts the invariants itself before and after the repair")
	mustCreateProfile(t, w.identity, a, "usera")
	mustCreateProfile(t, w.identity, b, "userb")
	ctx := context.Background()
	_, err := w.graph.Follow(ctx, a, key1, b)
	must(t, "Follow", err)
	assertGraphInvariants(t, w.client) // consistent before the deviation

	// The ops deviation: users/{b} deleted before the graph purge finished (runbook Step 2 out of order).
	if _, err := w.client.Collection("users").Doc(b).Delete(ctx); err != nil {
		t.Fatalf("seed S2: delete users/%s: %v", b, err)
	}

	// The user is stuck: Unfollow answers the same 0-cost NONE as every other no-op and changes nothing.
	noopUnfollow(t, w, "Unfollow (S2 stuck)", a, key2, b)
	if g := graphArrays(t, w.client, a); !contains(g["following"], b) {
		t.Fatalf("graph/%s.following = %v; S2 seed lost the following entry", a, g["following"])
	}
	if !docExists(t, w.client, "follows/"+a+"_"+b) {
		t.Fatalf("follows/%s_%s vanished; S2 seed is not the stuck state", a, b)
	}

	// The checker flags it (I2: edges exist but users/b does not).
	st, err := loadGraphState(ctx, w.client)
	must(t, "loadGraphState", err)
	wantMsg := fmt.Sprintf("I2: follows/*_%s edges exist but users/%s does not", b, b)
	violations := graphInvariantViolations(st)
	found := false
	for _, v := range violations {
		if strings.Contains(v, wantMsg) {
			found = true
		}
	}
	if !found {
		t.Fatalf("checker did not flag S2; want %q in %v", wantMsg, violations)
	}

	// The documented repair: PurgeUser(b) to completion (steps 1-5, resuming by query).
	purgeToCompletion(t, w.graph.repo, b, graph.Checkpoint{})
	assertGraphInvariants(t, w.client)
	assertNotFollowing(t, w, a, b)
	after, err := loadGraphState(ctx, w.client)
	must(t, "loadGraphState after repair", err)
	if got := after.Users[a]; got.Following != 0 || got.Followers != 0 {
		t.Errorf("users/%s counters after repair = %+v, want 0/0 (followingCount decremented exactly once)", a, got)
	}
	if _, ok := after.Graphs[b]; ok {
		t.Errorf("graph/%s must be deleted by the purge", b)
	}
	if docExists(t, w.client, "users/"+b) {
		t.Errorf("users/%s was resurrected by the repair", b)
	}
	// Idempotent: the user is no longer stuck and a replayed Unfollow stays a 0-cost NONE.
	noopUnfollow(t, w, "Unfollow (after S2 repair)", a, key3, b)
}
