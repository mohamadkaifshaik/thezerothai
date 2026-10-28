//go:build integration

// follow_requests_respond_integration_test.go exercises W3-28a against the Firestore emulator (ADR-0025 D7, D9, D5):
// ListFollowRequests paging and hydration, RespondToFollowRequest accept, decline, replay, inactive requester and the
// 5,000 cap, each with a budget assertion, the accept-vs-withdraw and accept-vs-block races, the pending-request count,
// and PROTECTED_ACCOUNT on the follower and following lists. The full chain through apiserver.Build is
// apiserver/follow_requests_chain_integration_test.go.
package graph_test

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// Budgets of the W3-28a RPCs at the graph layer (the interceptor's profile read is added by the chain test). The
// requester's status (Directory) and the caller snapshot are warm, as they are after a List.
var (
	budRespondAccept  = budgettest.Budget{Reads: 2, Writes: 4, Deletes: 1} // request + requester graph; edge, requester graph, 2 counters; request delete
	budRespondDecline = budgettest.Budget{Reads: 2, Writes: 1, Deletes: 1}
	budRespondReplay  = budgettest.Budget{Reads: 1, Writes: 0}
	// A requester the instance has not seen: the Directory lookup of the requester (a non-ACTIVE account is never cached) and the
	// caller snapshot are cold, so +2 over the warm budgets above.
	budRespondColdExtras = budgettest.Budget{Reads: 4, Writes: 1, Deletes: 1}
	budRespondCap        = budgettest.Budget{Reads: 2, Writes: 0}
)

type acceptRecorder struct {
	graph.FollowEvents
	mu       sync.Mutex
	accepted [][2]string
	followed int
}

func (r *acceptRecorder) Followed(context.Context, string, string, time.Time)        { r.followed++ }
func (r *acceptRecorder) FollowRequested(context.Context, string, string, time.Time) {}
func (r *acceptRecorder) FollowRequestAccepted(_ context.Context, target, requester string, _ time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.accepted = append(r.accepted, [2]string{target, requester})
}

// protectedSet is a fixed identity.ProtectedAuthors for the graph-layer PROTECTED_ACCOUNT matrix; the apiserver chain
// test protects through the real UpdateProfile and the real loader.
type protectedSet map[string]bool

func (s protectedSet) Has(uid string) bool { return s[uid] }
func (s protectedSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s[author] || following
}
func (s protectedSet) Current(context.Context) (identity.ProtectedSet, error) { return s, nil }

// request makes uid-from request uid-p through the real Follow path.
func request(t *testing.T, w wired, from, to string) {
	t.Helper()
	rel, err := w.graph.Follow(context.Background(), from, key1, to)
	must(t, "Follow(request) "+from, err)
	if rel.FollowState != graph.FollowStateRequested {
		t.Fatalf("Follow %s -> %s = %v, want REQUESTED", from, to, rel.FollowState)
	}
}

func TestRespond_Integration_AcceptDeclineReplay(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	request(t, w, "uid-b", "uid-p")
	ctx := context.Background()

	page, err := w.graph.ListFollowRequests(ctx, "uid-p", 20, "")
	must(t, "ListFollowRequests", err)
	if len(page.Items) != 2 || page.NextPageToken != "" {
		t.Fatalf("page = %+v, want the 2 pending requests and no token", page)
	}
	if page.Items[0].User.UserID != "uid-b" || page.Items[1].User.UserID != "uid-a" {
		t.Errorf("order = %s, %s, want newest first (uid-b, uid-a)", page.Items[0].User.UserID, page.Items[1].User.UserID)
	}
	if n, err := w.graph.counter.PendingFollowRequests(ctx, "uid-p"); err != nil || n != 2 {
		t.Errorf("PendingFollowRequests = %d, %v, want 2", n, err)
	}

	// Accept: edge, requester graph, both counters, request delete. 2 reads here (+1 interceptor in the chain).
	measured(t, "RespondToFollowRequest (accept, warm)", budRespondAccept, func(ctx context.Context) {
		rel, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true)
		must(t, "accept", err)
		if rel.UserID != "uid-a" || rel.FollowState != graph.FollowStateNone {
			t.Errorf("relationship = %+v, want the caller's NONE toward uid-a", rel)
		}
	})
	if !docExists(t, w.client, "follows/uid-a_uid-p") {
		t.Error("the edge uid-a -> uid-p was not created")
	}
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
	if following, _ := counts(t, w, "uid-a"); following != 1 {
		t.Errorf("a.followingCount = %d, want 1", following)
	}
	if _, followers := counts(t, w, "uid-p"); followers != 1 {
		t.Errorf("p.followersCount = %d, want 1", followers)
	}
	if len(ev.accepted) != 1 || ev.accepted[0] != [2]string{"uid-p", "uid-a"} || ev.followed != 0 {
		t.Errorf("events: accepted=%v followed=%d, want one FollowRequestAccepted(target uid-p, requester uid-a) and no Followed", ev.accepted, ev.followed)
	}
	rels, err := w.graph.GetRelationships(ctx, "uid-a", []string{"uid-p"})
	must(t, "GetRelationships", err)
	if rels[0].FollowState != graph.FollowStateFollowing {
		t.Errorf("a's view of p = %v, want FOLLOWING (this instance dropped a's cached snapshot)", rels[0].FollowState)
	}

	// Replay: the request is gone; 1 read, 0 writes, no second event, counters untouched.
	measured(t, "RespondToFollowRequest (replay)", budRespondReplay, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key2, "uid-a", true); err != nil {
			t.Fatal(err)
		}
	})
	if _, followers := counts(t, w, "uid-p"); followers != 1 || len(ev.accepted) != 1 {
		t.Errorf("replay moved state: followers=%d accepted=%d", followers, len(ev.accepted))
	}

	// Decline: 1 write + 1 delete, no edge, no event; the requester may ask again.
	measured(t, "RespondToFollowRequest (decline)", budRespondDecline, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-b", false); err != nil {
			t.Fatal(err)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-b", "uid-p"})
	if docExists(t, w.client, "follows/uid-b_uid-p") || len(ev.accepted) != 1 {
		t.Error("a decline created an edge or notified")
	}
	request(t, w, "uid-b", "uid-p")
	assertRequestInvariants(t, w, true, [2]string{"uid-b", "uid-p"})
	// A decline replay after a decline of a different request is still 0 writes for a requester who never asked.
	measured(t, "RespondToFollowRequest (never asked)", budRespondReplay, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-p-ghost", false); err != nil {
			t.Fatal(err)
		}
	})
}

// A requester who is no longer ACTIVE: the request is deleted and `requested` cleaned, no edge, no counter, no event.
func TestRespond_Integration_RequesterInactive(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	seedUserField(t, w, "uid-a", "status", "SUSPENDED")

	measured(t, "RespondToFollowRequest (requester not ACTIVE)", budRespondColdExtras, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true); err != nil {
			t.Fatal(err)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
	if docExists(t, w.client, "follows/uid-a_uid-p") || len(ev.accepted) != 0 {
		t.Error("an inactive requester got an edge or a notification")
	}
	if _, followers := counts(t, w, "uid-p"); followers != 0 {
		t.Errorf("p.followersCount = %d, want 0", followers)
	}
}

// A requester at the 5,000 following cap: LIMIT_REACHED requester_following with nothing written; decline still works.
func TestRespond_Integration_RequesterAtCap(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"following": padUIDs(5000), "requested": []string{"uid-p"}})

	measured(t, "RespondToFollowRequest (requester cap)", budRespondCap, func(ctx context.Context) {
		_, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true)
		requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "requester_following")
	})
	assertRequestInvariants(t, w, true, [2]string{"uid-a", "uid-p"})
	measured(t, "RespondToFollowRequest (decline at cap)", budRespondColdExtras, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", false); err != nil {
			t.Fatal(err)
		}
	})
	assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
}

// Drift (the requester already follows the target while a request exists; never produced by the code): the request is
// dropped, no second edge, no counter moves.
func TestRespond_Integration_DriftIsDropped(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	seedFollow(t, w, "uid-a", "uid-p", time.Now()) // an edge next to the request: I-X drift
	w.SkipInvariantSweep("seeds an edge next to a pending request (I-X drift) on purpose")

	measured(t, "RespondToFollowRequest (drift)", budRespondColdExtras, func(ctx context.Context) {
		if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true); err != nil {
			t.Fatal(err)
		}
	})
	if docExists(t, w.client, "followRequests/uid-a_uid-p") || contains(requestedOf(t, w.client, "uid-a"), "uid-p") {
		t.Error("the drifted request was not cleaned")
	}
	if len(ev.accepted) != 0 {
		t.Error("a drift reported an accept")
	}
	if _, followers := counts(t, w, "uid-p"); followers != 1 {
		t.Errorf("p.followersCount = %d, want the seeded 1", followers)
	}
}

// Paging: 25 pending requests are 20 + 5 rows (token then ""), newest first, within 1 + 2 x page reads.
func TestListFollowRequests_Integration_PagesAndBudget(t *testing.T) {
	w := newWired(t, withNewAccountWindow(time.Nanosecond))
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	reqs := mustCreateUsers(t, w.identity, "q", 25)
	for _, u := range reqs {
		request(t, w, u, "uid-p")
	}

	var seen []string
	token := ""
	for i, want := range []int{20, 5} {
		var p graph.Page
		bud := budgettest.Budget{Reads: 1 + 20 + 20}
		if i == 1 {
			bud = budgettest.Budget{Reads: 5 + 5}
		}
		measured(t, fmt.Sprintf("ListFollowRequests (page %d)", i+1), bud, func(ctx context.Context) {
			var err error
			p, err = w.graph.ListFollowRequests(ctx, "uid-p", 20, token)
			must(t, "ListFollowRequests", err)
		})
		if len(p.Items) != want {
			t.Fatalf("page %d rows = %d, want %d", i+1, len(p.Items), want)
		}
		for _, it := range p.Items {
			seen = append(seen, it.User.UserID)
		}
		token = p.NextPageToken
		if (i == 0) != (token != "") {
			t.Fatalf("page %d token = %q", i+1, token)
		}
	}
	if len(seen) != 25 || seen[0] != reqs[24] || seen[24] != reqs[0] {
		t.Errorf("rows = %d, first %s last %s, want 25 newest first (%s ... %s)", len(seen), seen[0], seen[len(seen)-1], reqs[24], reqs[0])
	}
	if n, err := w.graph.counter.PendingFollowRequests(context.Background(), "uid-p"); err != nil || n != 25 {
		t.Errorf("PendingFollowRequests = %d, %v, want 25", n, err)
	}
	measured(t, "PendingFollowRequests", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		if _, err := w.graph.counter.PendingFollowRequests(ctx, "uid-p"); err != nil {
			t.Fatal(err)
		}
	})

	// A token from the caller's list is useless to anyone else, and a followers token is useless here.
	mustCreateProfile(t, w.identity, "uid-x", "userx")
	p1, err := w.graph.ListFollowRequests(context.Background(), "uid-p", 20, "")
	must(t, "first page", err)
	_, err = w.graph.ListFollowRequests(context.Background(), "uid-x", 20, p1.NextPageToken)
	requireAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "page_token")
}

// Hydration drops: a requester who deleted the account is dropped from the page and the page stays short.
func TestListFollowRequests_Integration_DropsInactive(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	request(t, w, "uid-b", "uid-p")
	seedUserField(t, w, "uid-a", "status", "SUSPENDED")
	page, err := w.graph.ListFollowRequests(context.Background(), "uid-p", 20, "")
	must(t, "ListFollowRequests", err)
	if len(page.Items) != 1 || page.Items[0].User.UserID != "uid-b" {
		t.Errorf("rows = %+v, want only uid-b", page.Items)
	}
}

// The races of ADR-0025 D9: an accept against a withdraw, and an accept against a Block, end in a consistent state
// whichever wins: no request left, I-R and I-X hold (the end-of-test sweep checks the edge, counter and array invariants).
func TestRespond_Integration_Races(t *testing.T) {
	for round := 0; round < 4; round++ {
		t.Run(fmt.Sprintf("accept vs withdraw %d", round), func(t *testing.T) {
			w := newWired(t)
			mustCreateProfile(t, w.identity, "uid-p", "userp")
			mustCreateProfile(t, w.identity, "uid-a", "usera")
			protect(t, w, "uid-p")
			request(t, w, "uid-a", "uid-p")
			errs := runConcurrently(2, func(i int) error {
				ctx := context.Background()
				if i == 0 {
					_, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true)
					return err
				}
				_, err := w.graph.Unfollow(ctx, "uid-a", key1, "uid-p")
				return err
			})
			for i, err := range errs {
				if err != nil {
					t.Errorf("racer %d: %v", i, err)
				}
			}
			assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
		})
		t.Run(fmt.Sprintf("accept vs block %d", round), func(t *testing.T) {
			w := newWired(t)
			mustCreateProfile(t, w.identity, "uid-p", "userp")
			mustCreateProfile(t, w.identity, "uid-a", "usera")
			protect(t, w, "uid-p")
			request(t, w, "uid-a", "uid-p")
			errs := runConcurrently(2, func(i int) error {
				ctx := context.Background()
				if i == 0 {
					_, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", true)
					return err
				}
				_, err := w.graph.Block(ctx, "uid-p", key1, "uid-a")
				return err
			})
			for i, err := range errs {
				if err != nil {
					t.Errorf("racer %d: %v", i, err)
				}
			}
			assertRequestInvariants(t, w, false, [2]string{"uid-a", "uid-p"})
			if docExists(t, w.client, "follows/uid-a_uid-p") {
				t.Error("the blocked requester still follows the blocker")
			}
		})
	}
}

// PROTECTED_ACCOUNT (ADR-0025 D5): the followers and following of a protected account are for the account and its
// followers; a stranger and a mere requester are refused after 2 reads here (3 in the chain, with the interceptor) and no
// page read; an accepted requester then sees the page.
func TestListFollowLists_Integration_ProtectedAccount(t *testing.T) {
	w := newWired(t, withProtected(protectedSet{"uid-p": true}))
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-s", "users")
	mustCreateProfile(t, w.identity, "uid-pub", "userpub")
	protect(t, w, "uid-p")
	request(t, w, "uid-a", "uid-p")
	_, err := w.graph.Follow(context.Background(), "uid-pub", key1, "uid-s") // a public account with a follower
	must(t, "Follow public", err)

	refused := budgettest.Budget{Reads: 2} // caller graph + target profile; no edge query, no hydration
	for _, who := range []string{"uid-s", "uid-a"} {
		measured(t, "ListFollowers (protected, "+who+")", refused, func(ctx context.Context) {
			_, err := w.graph.ListFollowers(ctx, who, "uid-p", 20, "")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "", "")
		})
		measured(t, "ListFollowing (protected, "+who+")", refused, func(ctx context.Context) {
			_, err := w.graph.ListFollowing(ctx, who, "uid-p", 20, "")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "", "")
		})
	}
	// The owner and an approved follower see the lists; a public target is unaffected.
	if _, err := w.graph.ListFollowers(context.Background(), "uid-p", "uid-p", 20, ""); err != nil {
		t.Errorf("owner ListFollowers: %v", err)
	}
	if _, err := w.graph.ListFollowers(context.Background(), "uid-a", "uid-s", 20, ""); err != nil {
		t.Errorf("ListFollowers of a public account: %v", err)
	}
	_, err = w.graph.RespondToFollowRequest(context.Background(), "uid-p", key1, "uid-a", true)
	must(t, "accept", err)
	page, err := w.graph.ListFollowers(context.Background(), "uid-a", "uid-p", 20, "")
	must(t, "approved ListFollowers", err)
	if len(page.Items) != 1 || page.Items[0].User.UserID != "uid-a" {
		t.Errorf("approved follower sees %+v, want [uid-a]", page.Items)
	}
}
