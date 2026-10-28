//go:build integration

// follow_requests_integration_test.go exercises the W3-27 request path against the Firestore emulator (ADR-0025 D6,
// D7, AQ4): Follow to a protected account, replay, the 500 cap, withdraw, Block clean-up in both directions, and the
// REQUESTED relationship state on every read path, each with a budget assertion. The follow-vs-protect race is
// follow_race_integration_test.go (it needs the transaction hook).
package graph_test

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// assertRequestInvariants checks I-R (a followRequests doc exists exactly when the followee is in the follower's
// `requested`) and I-X (never together with a follows edge) for the listed pairs [follower, followee].
func assertRequestInvariants(t *testing.T, w wired, wantRequested bool, pairs ...[2]string) {
	t.Helper()
	for _, p := range pairs {
		docThere := docExists(t, w.client, "followRequests/"+p[0]+"_"+p[1])
		inArray := contains(requestedOf(t, w.client, p[0]), p[1])
		if docThere != inArray {
			t.Errorf("I-R broken for %s -> %s: doc=%v requested entry=%v", p[0], p[1], docThere, inArray)
		}
		if docThere != wantRequested {
			t.Errorf("request %s -> %s exists = %v, want %v", p[0], p[1], docThere, wantRequested)
		}
		if docThere && docExists(t, w.client, "follows/"+p[0]+"_"+p[1]) {
			t.Errorf("I-X broken for %s -> %s: request and edge together", p[0], p[1])
		}
	}
}

func protect(t *testing.T, w wired, uid string) {
	t.Helper()
	seedUserField(t, w, uid, "isPrivate", true)
}

func TestFollowRequest_Integration_CreateReplayWithdraw(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")

	// Request: 4 reads cold (caller profile + target users in the txn + caller graph + quotas), 3 writes.
	measured(t, "Follow (request, cold)", budFollowRequest, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key1, "uid-p")
		must(t, "Follow", err)
		if rel.FollowState != graph.FollowStateRequested || rel.Blocking {
			t.Errorf("rel = %+v, want REQUESTED", rel)
		}
	})
	assertRequestInvariants(t, w, true, [2]string{"uid-a", "uid-p"})
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 1 {
		t.Errorf("quotas.follows = %d, want 1 (a request counts as a follow)", got)
	}
	if following, _ := counts(t, w, "uid-a"); following != 0 {
		t.Errorf("a.followingCount = %d, want 0", following)
	}
	if _, followers := counts(t, w, "uid-p"); followers != 0 {
		t.Errorf("p.followersCount = %d, want 0 (a request is not a follower)", followers)
	}
	snap, err := w.client.Doc("followRequests/uid-a_uid-p").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if d := snap.Data(); d["followerId"] != "uid-a" || d["followeeId"] != "uid-p" || d["createdAt"] == nil {
		t.Errorf("request doc = %v, want {followerId, followeeId, createdAt}", d)
	}

	// Every read path reports REQUESTED from the caller's own snapshot (0 extra reads).
	rels, err := w.graph.GetRelationships(context.Background(), "uid-a", []string{"uid-p"})
	must(t, "GetRelationships", err)
	if rels[0].FollowState != graph.FollowStateRequested {
		t.Errorf("GetRelationships = %v, want REQUESTED", rels[0].FollowState)
	}
	pr, err := w.graph.GetProfileRelationship(context.Background(), "uid-a", "uid-p")
	must(t, "GetProfileRelationship", err)
	if pr.Relationship.FollowState != graph.FollowStateRequested {
		t.Errorf("GetProfileRelationship = %v, want REQUESTED", pr.Relationship.FollowState)
	}

	// Replay with a new key: REQUESTED, 0 writes, no second quota unit, 3 reads warm.
	warmProfiles(t, w, "uid-a")
	measured(t, "Follow (request replay, warm)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key2, "uid-p")
		must(t, "Follow replay", err)
		if rel.FollowState != graph.FollowStateRequested {
			t.Errorf("replay = %v, want REQUESTED", rel.FollowState)
		}
	})
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 1 {
		t.Errorf("quotas.follows = %d after a replay, want 1", got)
	}

	// Withdraw = Unfollow: 0 reads in the batches, 1 write (requested ArrayRemove), 1 delete (the request).
	measured(t, "Unfollow (withdraw)", budWithdraw, func(ctx context.Context) {
		rel, err := w.graph.Unfollow(ctx, "uid-a", key3, "uid-p")
		must(t, "Unfollow", err)
		if rel.FollowState != graph.FollowStateNone {
			t.Errorf("withdraw = %v, want NONE", rel.FollowState)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
	rels, _ = w.graph.GetRelationships(context.Background(), "uid-a", []string{"uid-p"})
	if rels[0].FollowState != graph.FollowStateNone {
		t.Errorf("after withdraw GetRelationships = %v, want NONE", rels[0].FollowState)
	}

	// Nothing left to withdraw: NONE, 0 writes, 0 deletes.
	measured(t, "Unfollow (nothing to withdraw)", budgettest.Budget{}, func(ctx context.Context) {
		if _, err := w.graph.Unfollow(ctx, "uid-a", key3, "uid-p"); err != nil {
			t.Fatal(err)
		}
	})

	// The quota is spent, not refunded; a fresh request after the withdraw works and is charged again.
	if _, err := w.graph.Follow(context.Background(), "uid-a", "0123456789abcde1", "uid-p"); err != nil {
		t.Fatal(err)
	}
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 2 {
		t.Errorf("quotas.follows = %d after request, withdraw, request, want 2", got)
	}
	assertRequestInvariants(t, w, true, [2]string{"uid-a", "uid-p"})
}

// Withdraw is undo: it needs no private_accounts flag. The fixture's FlagChecker enables everything, so this pins the
// other half: a caller whose graph flag is on and who holds a request can always withdraw, and with the target
// unprotected afterwards (the account went public) the withdraw still removes the pending request.
func TestFollowRequest_Integration_WithdrawAfterTargetWentPublic(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-p"); err != nil {
		t.Fatal(err)
	}
	seedUserField(t, w, "uid-p", "isPrivate", false)
	measured(t, "Unfollow (withdraw, target now public)", budWithdraw, func(ctx context.Context) {
		if _, err := w.graph.Unfollow(ctx, "uid-a", key2, "uid-p"); err != nil {
			t.Fatal(err)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
}

func TestFollowRequest_Integration_RequestedCapIs500(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	w.SkipInvariantSweep("seeded 500 synthetic requested entries without request docs")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"requested": padUIDs(500)})

	measured(t, "Follow (requested cap)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
		_, err := w.graph.Follow(ctx, "uid-a", key1, "uid-p")
		requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "follow_requests")
	})
	if docExists(t, w.client, "followRequests/uid-a_uid-p") {
		t.Error("a request was written past the cap")
	}
	// At 499 the 500th is allowed.
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"requested": padUIDs(499)})
	if _, err := w.graph.Follow(context.Background(), "uid-a", key2, "uid-p"); err != nil {
		t.Fatalf("500th request: %v", err)
	}
}

// ADR-0025 D7: a Block deletes the requests in both directions and their `requested` entries, with +0 reads and +0
// writes over a plain Block and at most 2 more deletes.
func TestFollowRequest_Integration_BlockClearsRequestsBothWays(t *testing.T) {
	for _, tc := range []struct {
		name        string
		blocker     string
		requestsAB  bool
		requestsBA  bool
		wantDeletes int64
	}{
		{"caller had requested the target", "uid-a", true, false, 1},
		{"target had requested the caller", "uid-a", false, true, 1},
		{"requests in both directions", "uid-a", true, true, 2},
		{"requests in both directions, the other side blocks", "uid-b", true, true, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := newWired(t)
			mustCreateProfile(t, w.identity, "uid-a", "usera")
			mustCreateProfile(t, w.identity, "uid-b", "userb")
			protect(t, w, "uid-a")
			protect(t, w, "uid-b")
			if tc.requestsAB {
				if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
					t.Fatal(err)
				}
			}
			if tc.requestsBA {
				if _, err := w.graph.Follow(context.Background(), "uid-b", key1, "uid-a"); err != nil {
					t.Fatal(err)
				}
			}
			other := "uid-a"
			if tc.blocker == "uid-a" {
				other = "uid-b"
			}
			// A plain Block is 3 reads, 3 writes; the clean-up adds deletes only.
			measured(t, "Block (with pending requests)", budgettest.Budget{Reads: 3, Writes: 3, Deletes: tc.wantDeletes}, func(ctx context.Context) {
				rel, err := w.graph.Block(ctx, tc.blocker, key2, other)
				must(t, "Block", err)
				if rel.FollowState != graph.FollowStateNone || !rel.Blocking {
					t.Errorf("rel = %+v, want NONE + blocking", rel)
				}
			})
			assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-b"}, [2]string{"uid-b", "uid-a"})
			if r := requestedOf(t, w.client, "uid-a"); len(r) != 0 {
				t.Errorf("a.requested = %v, want empty", r)
			}
			if r := requestedOf(t, w.client, "uid-b"); len(r) != 0 {
				t.Errorf("b.requested = %v, want empty", r)
			}
		})
	}
}

// ADR-0025 AQ4: the target went public while the request is still pending (the privacy_public job has not run). Follow
// becomes the edge, and in the same transaction deletes the request and its `requested` entry.
func TestFollowRequest_Integration_PublicTargetWithLeftoverRequestBecomesEdge(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-p"); err != nil {
		t.Fatal(err)
	}
	seedUserField(t, w, "uid-p", "isPrivate", false) // went public; the job has not accepted anything

	measured(t, "Follow (AQ4: edge over a leftover request)", budgettest.Budget{Reads: 4, Writes: 5, Deletes: 1}, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key2, "uid-p")
		must(t, "Follow", err)
		if rel.FollowState != graph.FollowStateFollowing {
			t.Errorf("rel = %+v, want FOLLOWING", rel)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
	if !docExists(t, w.client, "follows/uid-a_uid-p") {
		t.Error("the edge was not created")
	}
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["following"], "uid-p") {
		t.Errorf("a.following = %v, want uid-p", a["following"])
	}
	if following, _ := counts(t, w, "uid-a"); following != 1 {
		t.Errorf("a.followingCount = %d, want 1", following)
	}
	if _, followers := counts(t, w, "uid-p"); followers != 1 {
		t.Errorf("p.followersCount = %d, want 1", followers)
	}
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 2 {
		t.Errorf("quotas.follows = %d, want 2 (the request and the edge are ordinary follows)", got)
	}
}

// I-X: an existing edge wins. The follower stays FOLLOWING (0 writes, no request) when the followee is protected later.
func TestFollowRequest_Integration_ExistingEdgeWinsOverProtect(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-p"); err != nil {
		t.Fatal(err)
	}
	protect(t, w, "uid-p")
	warmProfiles(t, w, "uid-a")
	measured(t, "Follow (edge replay, protected target)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key2, "uid-p")
		must(t, "Follow", err)
		if rel.FollowState != graph.FollowStateFollowing {
			t.Errorf("rel = %v, want FOLLOWING", rel.FollowState)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
}

// The target's users doc decides existence inside the transaction: a missing, SUSPENDED or DELETING target is the same
// NOT_FOUND a missing user gets, byte for byte, and writes nothing.
func TestFollowRequest_Integration_InactiveTargetIsNotFound(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-susp", "usersusp")
	mustCreateProfile(t, w.identity, "uid-del", "userdel")
	protect(t, w, "uid-susp")
	seedUserField(t, w, "uid-susp", "status", "SUSPENDED")
	seedUserField(t, w, "uid-del", "status", "DELETING")

	_, ghostErr := w.graph.Follow(context.Background(), "uid-a", key1, "uid-ghost")
	requireAPIError(t, ghostErr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	for _, target := range []string{"uid-susp", "uid-del"} {
		measured(t, "Follow ("+target+")", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-a", key2, target)
			requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
			if err.Error() != ghostErr.Error() {
				t.Errorf("error for %s = %q, differs from the missing-user error %q", target, err, ghostErr)
			}
		})
	}
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-susp"}, [2]string{"uid-a", "uid-del"})
}

// A caller who blocked the protected account gets TARGET_BLOCKED and no request; one blocked by it gets NOT_FOUND.
func TestFollowRequest_Integration_BlockRulesComeFirst(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-p"); err != nil {
		t.Fatal(err)
	}
	_, err := w.graph.Follow(context.Background(), "uid-a", key2, "uid-p")
	requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED, "", "")
	if _, err := w.graph.Unblock(context.Background(), "uid-a", key3, "uid-p"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(context.Background(), "uid-p", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}
	_, err = w.graph.Follow(context.Background(), "uid-a", "0123456789abcde1", "uid-p")
	requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
}

// A request whose doc exists although the caller's `requested` lacks the entry (drift) answers as a replay: the commit
// fails with AlreadyExists, nothing is written, and the Follow does not become an error.
func TestFollowRequest_Integration_DriftedRequestDocIsAReplay(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	w.SkipInvariantSweep("seeded a request doc without its requested entry")
	if _, err := w.client.Doc("followRequests/uid-a_uid-p").Set(context.Background(), map[string]interface{}{
		"followerId": "uid-a", "followeeId": "uid-p", "createdAt": time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	measured(t, "Follow (drifted request doc)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key1, "uid-p")
		must(t, "Follow", err)
		if rel.FollowState != graph.FollowStateRequested {
			t.Errorf("rel = %v, want REQUESTED", rel.FollowState)
		}
	})
}
