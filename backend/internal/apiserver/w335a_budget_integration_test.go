//go:build integration

package apiserver

// W3-35a: the Part B budget table, in two parts, every figure measured on a cold instance (a fresh Build chain per call, the
// account-status interceptor's read included) and asserted at the ADR-0025 Cost impact ceilings:
//   - TestW335a_BudgetTableWithPartBOn runs the whole W3-20 table again with FEATURE_PRIVATE_ACCOUNTS on and a protected
//     account in the set: every existing read path keeps its W3-20 ceiling ("+0", the predicate costs no read);
//   - TestW335a_PartBBudgetTable measures each Part B RPC and each modified read path against its own row.
// Every case logs a W320BUDGET line (rpc, case, reads, writes, deletes and the ceiling); the report's table is those lines.

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestW335a_BudgetTableWithPartBOn(t *testing.T) { w320BudgetTable(t, w335aOn) }

func TestW335a_PartBBudgetTable(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	ch := w.w
	follower, stranger, pub := ch.user(t), ch.user(t), ch.user(t)
	ch.w320Follow(t, follower, w.p.uid)
	ch.w320Follow(t, follower, w.x.uid)
	for _, u := range []bmUser{follower, stranger} {
		if _, err := ch.add(u, contractKey("w335a-bt-bm"), w.pid); err != nil {
			t.Fatal(err)
		}
		ch.like(t, u, w.pid)
	}
	const (
		rpcGet    = postsv1connect.PostServiceGetPostProcedure
		rpcThread = postsv1connect.PostServiceGetThreadProcedure
	)
	// meas runs call on a fresh chain (cold) and asserts the last request line of rpc against ceil.
	meas := func(rpc, label string, ceil budgettest.Budget, call func(r *w320Chain)) *w320Chain {
		t.Helper()
		r := newW320Chain(t, w335aOn)
		call(r)
		r.w320Measure(t, rpc, label, ceil)
		return r
	}
	home := func(u bmUser) func(r *w320Chain) { return func(r *w320Chain) { r.w330Home(t, u) } }
	toggle := func(v bool) func(r *w320Chain) {
		return func(r *w320Chain) {
			if _, err := r.w320Update(w.p, &identityv1.UpdateProfileRequest{IsPrivate: &v}); err != nil {
				t.Fatalf("is_private=%v: %v", v, err)
			}
		}
	}

	// Home before P protects: the baseline the protected world must not exceed.
	hBefore := meas(rpcGetHomeTimeline, "Home page 20, P public (baseline)", budgettest.Budget{Reads: 60}, home(follower)).lineBudget(t, rpcGetHomeTimeline).Reads()

	meas(graphv1connect.GraphServiceFollowProcedure, "Follow a public account (edge), cold", budgettest.Budget{Reads: 4, Writes: 5}, func(r *w320Chain) {
		r.w320Follow(t, pub, w.x.uid)
	})
	meas(rpcUpdateProfile, "UpdateProfile toggle: protect, cold", budgettest.Budget{Reads: 4, Writes: 3}, toggle(true))

	// 20 pending requests; the first two are answered below.
	reqs := make([]bmUser, 20)
	for i := range reqs {
		reqs[i] = ch.user(t)
	}
	meas(graphv1connect.GraphServiceFollowProcedure, "Follow a protected account (request), cold", budgettest.Budget{Reads: 4, Writes: 3}, func(r *w320Chain) {
		r.w328Request(t, reqs[0], w.p.uid)
	})
	for _, u := range reqs[1:] {
		ch.w328Request(t, u, w.p.uid)
	}
	meas(graphv1connect.GraphServiceUnfollowProcedure, "Withdraw (Unfollow of a REQUESTED target), cold", budgettest.Budget{Reads: 1, Writes: 1, Deletes: 1}, func(r *w320Chain) {
		if _, err := r.graph.Unfollow(ctx, authed(reqs[19].token, &graphv1.UnfollowRequest{IdempotencyKey: contractKey("w335a-bt-wd"), UserId: w.p.uid})); err != nil {
			t.Fatal(err)
		}
	})
	ch.w328Request(t, reqs[19], w.p.uid) // the 20th request is back

	meas(rpcListFollowRequests, "ListFollowRequests page 20 (20 pending), cold", budgettest.Budget{Reads: 42}, func(r *w320Chain) {
		page, err := r.w328List(w.p)
		if err != nil || len(page.GetRequests()) != 20 {
			t.Fatalf("ListFollowRequests = %v err=%v, want 20 rows", page, err)
		}
	})

	// Respond: after a List on the same instance (the client flow), then standalone cold.
	rc := newW320Chain(t, w335aOn)
	if _, err := rc.w328List(w.p); err != nil {
		t.Fatal(err)
	}
	respond := func(r *w320Chain, who bmUser, accept bool) {
		if _, err := r.w328Respond(w.p, who.uid, accept); err != nil {
			t.Fatalf("Respond(%v): %v", accept, err)
		}
	}
	respond(rc, reqs[0], true)
	rc.w320Measure(t, rpcRespondToFollowReq, "Respond accept, after List (3 / 4 writes / 1 delete)", budgettest.Budget{Reads: 3, Writes: 4, Deletes: 1})
	respond(rc, reqs[1], false)
	rc.w320Measure(t, rpcRespondToFollowReq, "Respond decline, after List", budgettest.Budget{Reads: 2, Writes: 1, Deletes: 1})
	respond(rc, reqs[0], true)
	rc.w320Measure(t, rpcRespondToFollowReq, "Respond replay of an accept", budgettest.Budget{Reads: 2})
	// A fully cold standalone Respond reads up to 5 (ADR-0025 W3-28a implementation note); writes unchanged.
	meas(rpcRespondToFollowReq, "Respond accept, standalone cold (W3-28a note: up to 5)", budgettest.Budget{Reads: 5, Writes: 4, Deletes: 1}, func(r *w320Chain) {
		respond(r, reqs[2], true)
	})

	// GetMe: +1 read (one count()) for a protected caller, nothing for a public one.
	meas(rpcGetMe, "GetMe, public caller, cold", budgettest.Budget{Reads: 2}, func(r *w320Chain) { r.w326bGetMe(t, follower) })
	meas(rpcGetMe, "GetMe, protected caller, cold (+1 count)", budgettest.Budget{Reads: 3}, func(r *w320Chain) { r.w326bGetMe(t, w.p) })

	// An unapproved viewer of P: 3 cold reads and no page read, on the profile tab and both graph lists.
	meas(w320RPCGetUserTimeline, "GetUserTimeline of P, unapproved, cold", budgettest.Budget{Reads: 3}, func(r *w320Chain) {
		if resp, err := r.tabCall(stranger, w.p.uid, tabPostsPB, 20, "", ""); err != nil || !resp.GetAuthorProtected() {
			t.Fatalf("tab: %v err=%v", resp, err)
		}
	})
	for _, c := range []struct {
		rpc  string
		call func(r *w320Chain) error
	}{
		{rpcListFollowers, func(r *w320Chain) error {
			_, err := r.graph.ListFollowers(ctx, authed(stranger.token, &graphv1.ListFollowersRequest{UserId: w.p.uid, PageSize: 20}))
			return err
		}},
		{rpcListFollowing, func(r *w320Chain) error {
			_, err := r.graph.ListFollowing(ctx, authed(stranger.token, &graphv1.ListFollowingRequest{UserId: w.p.uid, PageSize: 20}))
			return err
		}},
	} {
		meas(c.rpc, "unapproved viewer of P, cold", budgettest.Budget{Reads: 3}, func(r *w320Chain) {
			wireError(t, c.call(r), connect.CodeFailedPrecondition)
		})
	}

	// Modified read paths at their own ceilings.
	meas(rpcGet, "GetPost of P's post, unapproved (refusal), cold", budgettest.Budget{Reads: 4}, func(r *w320Chain) {
		if _, err := r.posts.GetPost(ctx, authed(stranger.token, &postsv1.GetPostRequest{PostId: w.pid})); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("GetPost = %v", err)
		}
	})
	meas(rpcGet, "GetPost of P's post, approved follower, cold (4 + userLikes)", budgettest.Budget{Reads: 5}, func(r *w320Chain) {
		if _, err := r.posts.GetPost(ctx, authed(follower.token, &postsv1.GetPostRequest{PostId: w.pid})); err != nil {
			t.Fatal(err)
		}
	})
	meas(rpcThread, "GetThread of X's root (P replied), unapproved, cold", budgettest.Budget{Reads: 38}, func(r *w320Chain) {
		if _, err := r.w329bThread(stranger, w.xroot); err != nil {
			t.Fatal(err)
		}
	})
	meas(rpcListBookmarks, "ListBookmarks page 20, unapproved owner, cold", budgettest.Budget{Reads: 43}, func(r *w320Chain) {
		if _, err := r.list(stranger, 20, ""); err != nil {
			t.Fatal(err)
		}
	})
	meas(rpcListLikedPosts, "ListLikedPosts page 20, unapproved owner, cold", budgettest.Budget{Reads: 23}, func(r *w320Chain) {
		if _, err := r.listLiked(stranger, 20, ""); err != nil {
			t.Fatal(err)
		}
	})
	hAfter := meas(rpcGetHomeTimeline, "Home page 20, P protected", budgettest.Budget{Reads: hBefore}, home(follower)).lineBudget(t, rpcGetHomeTimeline).Reads()
	t.Logf("W335A Home reads before/after P protects: %d / %d", hBefore, hAfter)

	meas(rpcUpdateProfile, "UpdateProfile toggle: unprotect with 20 pending (job published), cold", budgettest.Budget{Reads: 4, Writes: 3}, toggle(false))
}
