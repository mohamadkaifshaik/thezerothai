//go:build integration

package apiserver

// W3-28a (ADR-0025 D5, D7, D9, D12) through the real Build chain on the emulators, with the real protected-set loader and
// the real UpdateProfile(is_private) toggle (FEATURE_PRIVATE_ACCOUNTS on):
//   - Follow of a protected P is REQUESTED; ListFollowRequests shows the requests newest first at the documented reads;
//   - an unapproved viewer (a stranger, or a mere requester) gets PROTECTED_ACCOUNT on P's followers and following at 3
//     cold reads and no page read;
//   - Accept creates the edge, moves both counters, keeps I-R and I-X, notifies the requester (follow_accepted_{P}, no
//     follow_{requester} row for P) and makes the requester see P's posts; a replay costs 0 writes; Decline writes
//     nothing else and notifies nobody;
//   - the D12 flag matrix: with FEATURE_PRIVATE_ACCOUNTS off, allowlisted without the caller, percent 0 or on, a
//     protected P can still list and answer (undo is never gated), and only a public caller is refused, and only in off.

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	rpcListFollowRequests = graphv1connect.GraphServiceListFollowRequestsProcedure
	rpcRespondToFollowReq = graphv1connect.GraphServiceRespondToFollowRequestProcedure
	rpcListFollowers      = graphv1connect.GraphServiceListFollowersProcedure
	rpcListFollowing      = graphv1connect.GraphServiceListFollowingProcedure
)

func w328On(c *config.Config) {
	c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
	c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
}

func (e *bmChain) w328Request(t *testing.T, from bmUser, to string) {
	t.Helper()
	r, err := e.graph.Follow(context.Background(), authed(from.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("w328-f"), UserId: to}))
	if err != nil {
		t.Fatalf("Follow: %v", err)
	}
	if got := r.Msg.GetRelationship().GetFollowState(); got != graphv1.FollowState_FOLLOW_STATE_REQUESTED {
		t.Fatalf("Follow of a protected account = %v, want REQUESTED", got)
	}
}

func (e *bmChain) w328Respond(u bmUser, requester string, accept bool) (*graphv1.RespondToFollowRequestResponse, error) {
	r, err := e.graph.RespondToFollowRequest(context.Background(), authed(u.token, &graphv1.RespondToFollowRequestRequest{
		IdempotencyKey: contractKey("w328-r"), RequesterUserId: requester, Accept: accept,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *bmChain) w328List(u bmUser) (*graphv1.ListFollowRequestsResponse, error) {
	r, err := e.graph.ListFollowRequests(context.Background(), authed(u.token, &graphv1.ListFollowRequestsRequest{PageSize: 20}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// w328Invariants checks I-R and I-X for follower -> followee: the request doc exists exactly when the followee is in the
// follower's `requested`, and never together with an edge. It returns whether the request exists.
func w328Invariants(t *testing.T, fs *firestore.Client, follower, followee string) (requested, edge bool) {
	t.Helper()
	requested = fsDocExists(t, fs, "followRequests/"+follower+"_"+followee)
	edge = fsDocExists(t, fs, "follows/"+follower+"_"+followee)
	snap, err := fs.Doc("graph/" + follower).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d struct {
		Requested []string `firestore:"requested"`
		Following []string `firestore:"following"`
	}
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	inRequested, inFollowing := false, false
	for _, u := range d.Requested {
		inRequested = inRequested || u == followee
	}
	for _, u := range d.Following {
		inFollowing = inFollowing || u == followee
	}
	if requested != inRequested {
		t.Errorf("I-R broken for %s -> %s: doc=%v requested entry=%v", follower, followee, requested, inRequested)
	}
	if edge != inFollowing {
		t.Errorf("edge invariant broken for %s -> %s: edge doc=%v following entry=%v", follower, followee, edge, inFollowing)
	}
	if requested && edge {
		t.Errorf("I-X broken for %s -> %s: request and edge together", follower, followee)
	}
	return requested, edge
}

// w328WaitNotif waits for the inline fan-out to write users/{uid}/notifications/{id}.
func w328WaitNotif(t *testing.T, e *chainEnv, uid, id string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !fsDocExists(t, e.fs, "users/"+uid+"/notifications/"+id) {
		if time.Now().After(deadline) {
			t.Fatalf("no notification %s for the recipient; rows = %v", id, notifIDs(t, e.fs, uid))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestW328a_FollowRequestsThroughTheChain(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w328On)
	p, a, b, stranger := w.user(t), w.user(t), w.user(t), w.user(t)

	pid := w.post(t, p, "protected author's post")
	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}
	w.w328Request(t, a, p.uid)
	time.Sleep(5 * time.Millisecond) // distinct createdAt: b is the newer request
	w.w328Request(t, b, p.uid)

	t.Run("before the accept an unapproved viewer sees neither the posts nor the lists", func(t *testing.T) {
		r := newW320Chain(t, w328On)
		resp, err := r.tabCall(a, p.uid, tabPostsPB, 20, "", "")
		if err != nil || !resp.GetAuthorProtected() {
			t.Fatalf("requester's Posts tab: %v err=%v, want author_protected", resp, err)
		}
		for _, who := range []struct {
			name string
			u    bmUser
		}{{"stranger", stranger}, {"requester", a}} {
			cold := newW320Chain(t, w328On)
			_, err := cold.graph.ListFollowers(ctx, authed(who.u.token, &graphv1.ListFollowersRequest{UserId: p.uid, PageSize: 20}))
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
			budgettest.Assert(t, "ListFollowers of a protected account ("+who.name+", cold)", cold.lineBudget(t, rpcListFollowers), budgettest.Budget{Reads: 3})
			cold = newW320Chain(t, w328On)
			_, err = cold.graph.ListFollowing(ctx, authed(who.u.token, &graphv1.ListFollowingRequest{UserId: p.uid, PageSize: 20}))
			assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
			budgettest.Assert(t, "ListFollowing of a protected account ("+who.name+", cold)", cold.lineBudget(t, rpcListFollowing), budgettest.Budget{Reads: 3})
		}
	})

	// One instance for P's whole session: List warms what Respond reuses.
	c := newW320Chain(t, w328On)
	page, err := c.w328List(p)
	if err != nil {
		t.Fatalf("ListFollowRequests: %v", err)
	}
	if len(page.GetRequests()) != 2 || page.GetNextPageToken() != "" {
		t.Fatalf("requests = %v, want 2 rows and no token", page)
	}
	if page.GetRequests()[0].GetUser().GetUserId() != b.uid || page.GetRequests()[1].GetUser().GetUserId() != a.uid {
		t.Errorf("order = %s, %s, want newest first (b, a)", page.GetRequests()[0].GetUser().GetUserId(), page.GetRequests()[1].GetUser().GetUserId())
	}
	if page.GetRequests()[0].GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_NONE || page.GetRequests()[0].GetSince() == nil {
		t.Errorf("row = %v, want relationship NONE and a since", page.GetRequests()[0])
	}
	// Cold page of 2: interceptor 1, caller graph 1, query 2, hydration 2 (the ceilings 42 / 102 are at 20 / 50).
	budgettest.Assert(t, "ListFollowRequests (cold, 2 rows)", c.lineBudget(t, rpcListFollowRequests), budgettest.Budget{Reads: 6})

	// Accept a: edge, requester graph, both counters, request delete.
	acc, err := c.w328Respond(p, a.uid, true)
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	if acc.GetRelationship().GetUserId() != a.uid || acc.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_NONE {
		t.Errorf("accept relationship = %v, want the caller's NONE toward a (offer Follow back)", acc.GetRelationship())
	}
	budgettest.Assert(t, "RespondToFollowRequest (accept, after List)", c.lineBudget(t, rpcRespondToFollowReq), budgettest.Budget{Reads: 3, Writes: 4, Deletes: 1})
	if got := c.line(t, rpcRespondToFollowReq)["respond"]; got != "accept" {
		t.Errorf("respond log = %v, want accept", got)
	}
	if req, edge := w328Invariants(t, w.fs, a.uid, p.uid); req || !edge {
		t.Errorf("after accept: request=%v edge=%v, want the edge only", req, edge)
	}
	if got := w.w320Field(t, "users/"+a.uid, "followingCount"); got != int64(1) {
		t.Errorf("a.followingCount = %v, want 1", got)
	}
	if got := w.w320Field(t, "users/"+p.uid, "followersCount"); got != int64(1) {
		t.Errorf("p.followersCount = %v, want 1", got)
	}
	// The requester is told (follow_accepted_{P}); P gets no FOLLOW row for an edge P approved.
	w328WaitNotif(t, w.chainEnv, a.uid, "follow_accepted_"+p.uid)
	time.Sleep(200 * time.Millisecond)
	for _, id := range notifIDs(t, w.fs, p.uid) {
		if id == "follow_"+a.uid {
			t.Error("P got a plain follow notification for an accepted request")
		}
	}

	// Replay: the request is gone; 0 writes, no second row.
	if _, err := c.w328Respond(p, a.uid, true); err != nil {
		t.Fatalf("accept replay: %v", err)
	}
	budgettest.Assert(t, "RespondToFollowRequest (replay, warm)", c.lineBudget(t, rpcRespondToFollowReq), budgettest.Budget{Reads: 2})
	if got := c.line(t, rpcRespondToFollowReq)["respond"]; got != "replay" {
		t.Errorf("respond log = %v, want replay", got)
	}
	cold := newW320Chain(t, w328On)
	if _, err := cold.w328Respond(p, a.uid, true); err != nil {
		t.Fatalf("accept replay (cold): %v", err)
	}
	budgettest.Assert(t, "RespondToFollowRequest (replay, cold)", cold.lineBudget(t, rpcRespondToFollowReq), budgettest.Budget{Reads: 3}) // interceptor, request, caller snapshot
	if got := w.w320Field(t, "users/"+p.uid, "followersCount"); got != int64(1) {
		t.Errorf("replay moved p.followersCount to %v", got)
	}

	// The accepted follower sees P's posts and lists, on a cold instance too.
	r := newW320Chain(t, w328On)
	resp, err := r.tabCall(a, p.uid, tabPostsPB, 20, "", "")
	if err != nil || resp.GetAuthorProtected() || len(tabPostIDs(resp)) != 1 || tabPostIDs(resp)[0] != pid {
		t.Fatalf("approved follower's Posts tab: %v err=%v, want P's post", resp, err)
	}
	fl, err := r.graph.ListFollowers(ctx, authed(a.token, &graphv1.ListFollowersRequest{UserId: p.uid, PageSize: 20}))
	if err != nil || len(fl.Msg.GetUsers()) != 1 || fl.Msg.GetUsers()[0].GetUser().GetUserId() != a.uid {
		t.Fatalf("approved follower's ListFollowers: %v err=%v, want [a]", fl, err)
	}
	// b is still only a requester.
	if resp, err := newW320Chain(t, w328On).tabCall(b, p.uid, tabPostsPB, 20, "", ""); err != nil || !resp.GetAuthorProtected() {
		t.Errorf("pending requester's Posts tab: %v err=%v, want author_protected", resp, err)
	}

	// Decline b: 1 write + 1 delete (the requester's `requested`), nobody notified, no edge; b may ask again.
	if _, err := c.w328Respond(p, b.uid, false); err != nil {
		t.Fatalf("decline: %v", err)
	}
	budgettest.Assert(t, "RespondToFollowRequest (decline)", c.lineBudget(t, rpcRespondToFollowReq), budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1})
	if req, edge := w328Invariants(t, w.fs, b.uid, p.uid); req || edge {
		t.Errorf("after decline: request=%v edge=%v, want neither", req, edge)
	}
	time.Sleep(200 * time.Millisecond)
	if ids := notifIDs(t, w.fs, b.uid); len(ids) != 0 {
		t.Errorf("a decline notified the requester: %v", ids)
	}
	w.w328Request(t, b, p.uid)
	if req, _ := w328Invariants(t, w.fs, b.uid, p.uid); !req {
		t.Error("b could not ask again after a decline")
	}
	if n := w.w320Field(t, "users/"+p.uid, "followersCount"); n != int64(1) {
		t.Errorf("p.followersCount = %v after the decline, want 1", n)
	}
	if got := c.w328Count(t, p); got != 1 {
		t.Errorf("pending requests after accept, decline and a new request = %d, want 1", got)
	}
}

// w328Count is the pending count the graph service reports for u; the GetMe badge wiring is W3-26b, so it is read from the
// request list here.
func (e *bmChain) w328Count(t *testing.T, u bmUser) int {
	t.Helper()
	page, err := e.w328List(u)
	if err != nil {
		t.Fatalf("ListFollowRequests: %v", err)
	}
	return len(page.GetRequests())
}

// The D12 matrix: a protected P answers its requests whatever FEATURE_PRIVATE_ACCOUNTS says (undo is never gated), and
// only a public caller is refused, and only while the flag is off for everyone.
func TestW328a_FlagModesNeverStrandAProtectedAccount(t *testing.T) {
	w := newW320Chain(t, w328On)
	p, stranger := w.user(t), w.user(t)
	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}
	other := w.user(t)
	modes := []struct {
		name        string
		spec        flags.Spec
		publicWorks bool
		accept      bool
	}{
		{"off", flags.Spec{Name: "private_accounts", Mode: flags.Off}, false, true},
		{"allowlist without the caller", flags.Spec{Name: "private_accounts", Mode: flags.Allowlist, Allowlist: map[string]struct{}{other.uid: {}}}, true, false},
		{"percent 0", flags.Spec{Name: "private_accounts", Mode: flags.Percent, Percent: 0}, true, true},
		{"on", flags.Spec{Name: "private_accounts", Mode: flags.On}, true, false},
	}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			q := w.user(t)
			w.w328Request(t, q, p.uid)
			c := newW320Chain(t, func(cfg *config.Config) {
				cfg.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
				cfg.FeaturePrivateAccounts = m.spec
			})
			page, err := c.w328List(p)
			if err != nil {
				t.Fatalf("protected P ListFollowRequests: %v", err)
			}
			found := false
			for _, it := range page.GetRequests() {
				found = found || it.GetUser().GetUserId() == q.uid
			}
			if !found {
				t.Errorf("P's list lacks the pending request: %v", page)
			}
			if _, err := c.w328Respond(p, q.uid, m.accept); err != nil {
				t.Fatalf("protected P respond (accept=%v): %v", m.accept, err)
			}
			req, edge := w328Invariants(t, w.fs, q.uid, p.uid)
			if req || edge != m.accept {
				t.Errorf("after respond(accept=%v): request=%v edge=%v", m.accept, req, edge)
			}

			_, err = c.w328List(stranger)
			if m.publicWorks {
				if err != nil {
					t.Errorf("public caller ListFollowRequests: %v, want an empty page", err)
				}
				return
			}
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if d.GetMetadata()["feature"] != "private_accounts" {
				t.Errorf("metadata = %v, want feature=private_accounts", d.GetMetadata())
			}
			// The refusal costs the interceptor read and at most the gate's cached profile lookup, and writes nothing.
			budgettest.Assert(t, "ListFollowRequests refused by the gate", c.lineBudget(t, rpcListFollowRequests), budgettest.Budget{Reads: 2})
			_, err = c.w328Respond(stranger, q.uid, true)
			assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			budgettest.Assert(t, "RespondToFollowRequest refused by the gate", c.lineBudget(t, rpcRespondToFollowReq), budgettest.Budget{Reads: 2})
		})
	}
}
