//go:build integration

package apiserver

// W3-28c (ADR-0025 implementation note, W3-25c): AuthorSnapshot.is_private on every graph user-list row, through the real
// Build chain with FEATURE_PRIVATE_ACCOUNTS on and the real UpdateProfile(is_private) toggle:
//   - ListFollowing, ListFollowers, ListFollowRequests, ListSuggestedUsers, ListBlockedUsers and ListMutedUsers show
//     user.is_private=true on a protected user's row and false on a public user's row, on a cold instance each;
//   - turning is_private off flips the row back to false;
//   - the frozen copies (Post.author on a profile timeline, Notification.actor) stay false for the same protected user;
//   - every list stays at its read ceiling: the value comes from the profile the list already hydrated.

import (
	"context"
	"net/http"
	"testing"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func w328cOn(c *config.Config) {
	w328On(c)
	c.FeatureFollowSuggestions = flags.Spec{Name: "follow_suggestions", Mode: flags.On}
}

// w328cWant asserts rows holds exactly the wanted uids with the wanted is_private values.
func w328cWant(t *testing.T, what string, rows []*graphv1.UserListItem, want map[string]bool) {
	t.Helper()
	got := map[string]bool{}
	for _, r := range rows {
		if _, dup := got[r.GetUser().GetUserId()]; dup {
			t.Fatalf("%s: duplicate row %s", what, r.GetUser().GetUserId())
		}
		got[r.GetUser().GetUserId()] = r.GetUser().GetIsPrivate()
	}
	if len(got) != len(want) {
		t.Errorf("%s: rows = %v, want %v", what, got, want)
		return
	}
	for uid, priv := range want {
		if g, ok := got[uid]; !ok || g != priv {
			t.Errorf("%s: rows = %v, want %v", what, got, want)
			return
		}
	}
}

func TestW328c_IsPrivateOnEveryUserListRow(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w328cOn)
	// v is the viewer. p (protected, approved follower v), a and b2 (public) are followed by v. a follows x (protected), y and z
	// (public): v's suggestions. q (protected) and r (public) request p. pb/ab are blocked and pm/am muted by v.
	v, p, a, x, y := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)
	b2, z := w.user(t), w.user(t) // b2: a third followee of v (suggestions need 3); z: a second public suggestion (3 usable candidates)
	q, r := w.user(t), w.user(t)
	pb, ab, pm, am := w.user(t), w.user(t), w.user(t), w.user(t)

	prot := true
	for _, u := range []bmUser{p, q, pb, pm} {
		if _, err := w.w320Update(u, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
			t.Fatalf("protect %s: %v", u.uid, err)
		}
	}
	pid := w.post(t, p, "protected author's post")

	w.w328Request(t, v, p.uid)
	if _, err := w.w328Respond(p, v.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}
	w.w320Follow(t, v, a.uid)
	w.w320Follow(t, v, b2.uid)
	w.w320Follow(t, p, a.uid) // a protected follower of a public account, for ListFollowers(a)
	// a follows x and y while both are public (a follow of a protected x would only be a request); x protects afterwards.
	w.w320Follow(t, a, x.uid)
	w.w320Follow(t, a, y.uid)
	w.w320Follow(t, a, z.uid)
	if _, err := w.w320Update(x, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect x: %v", err)
	}
	w.w328Request(t, q, p.uid)
	w.w328Request(t, r, p.uid)
	for _, u := range []bmUser{pb, ab} {
		w.w320Block(t, v, u.uid)
	}
	for _, u := range []bmUser{pm, am} {
		if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w328c-m"), UserId: u.uid})); err != nil {
			t.Fatalf("Mute: %v", err)
		}
	}

	// Each read runs on its own cold instance (no Directory cache), so the value is what the list hydrated from Firestore.
	cold := func() *w320Chain { return newW320Chain(t, w328cOn) }
	cases := []struct {
		name    string
		rpc     string
		ceiling budgettest.Budget
		call    func(c *w320Chain) ([]*graphv1.UserListItem, error)
		want    map[string]bool
	}{
		{"ListFollowing", rpcListFollowing, budgettest.Budget{Reads: 3 + 2*20}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.graph.ListFollowing(ctx, authed(v.token, &graphv1.ListFollowingRequest{UserId: v.uid, PageSize: 20}))
			if err != nil {
				return nil, err
			}
			return resp.Msg.GetUsers(), nil
		}, map[string]bool{p.uid: true, a.uid: false, b2.uid: false}},
		{"ListFollowers", rpcListFollowers, budgettest.Budget{Reads: 3 + 2*20}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.graph.ListFollowers(ctx, authed(v.token, &graphv1.ListFollowersRequest{UserId: a.uid, PageSize: 20}))
			if err != nil {
				return nil, err
			}
			return resp.Msg.GetUsers(), nil
		}, map[string]bool{p.uid: true, v.uid: false}},
		{"ListFollowRequests", rpcListFollowRequests, budgettest.Budget{Reads: 42}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.w328List(p)
			if err != nil {
				return nil, err
			}
			return resp.GetRequests(), nil
		}, map[string]bool{q.uid: true, r.uid: false}},
		{"ListSuggestedUsers", graphv1connect.GraphServiceListSuggestedUsersProcedure, budgettest.Budget{Reads: 32}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.w320Suggest(v, 10)
			if err != nil {
				return nil, err
			}
			return resp.GetUsers(), nil
		}, map[string]bool{x.uid: true, y.uid: false, z.uid: false}},
		{"ListBlockedUsers", graphv1connect.GraphServiceListBlockedUsersProcedure, budgettest.Budget{Reads: 1 + 1 + 20}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.graph.ListBlockedUsers(ctx, authed(v.token, &graphv1.ListBlockedUsersRequest{PageSize: 20}))
			if err != nil {
				return nil, err
			}
			return resp.Msg.GetUsers(), nil
		}, map[string]bool{pb.uid: true, ab.uid: false}},
		{"ListMutedUsers", graphv1connect.GraphServiceListMutedUsersProcedure, budgettest.Budget{Reads: 1 + 1 + 20}, func(c *w320Chain) ([]*graphv1.UserListItem, error) {
			resp, err := c.graph.ListMutedUsers(ctx, authed(v.token, &graphv1.ListMutedUsersRequest{PageSize: 20}))
			if err != nil {
				return nil, err
			}
			return resp.Msg.GetUsers(), nil
		}, map[string]bool{pm.uid: true, am.uid: false}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := cold()
			rows, err := tc.call(c)
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			w328cWant(t, tc.name, rows, tc.want)
			// +0: the badge is copied from the hydrated profile, so the list stays inside the ceiling it had before the field.
			budgettest.Assert(t, tc.name+" (cold) with is_private", c.lineBudget(t, tc.rpc), tc.ceiling)
		})
	}

	t.Run("frozen copies stay false for the same protected user", func(t *testing.T) {
		c := cold()
		resp, err := c.tabCall(v, p.uid, tabPostsPB, 20, "", "")
		if err != nil || len(tabPostIDs(resp)) != 1 || tabPostIDs(resp)[0] != pid {
			t.Fatalf("Posts tab of the protected author as an approved follower: %v err=%v, want the post", resp, err)
		}
		if resp.GetPosts()[0].GetPost().GetAuthor().GetUserId() != p.uid || resp.GetPosts()[0].GetPost().GetAuthor().GetIsPrivate() {
			t.Errorf("Post.author = %v, want the protected author with is_private unset", resp.GetPosts()[0].GetPost().GetAuthor())
		}
		// p followed a above: a's follow_{p} notification names p as the actor.
		w328WaitNotif(t, c.chainEnv, a.uid, "follow_"+p.uid)
		nc := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, c.url)
		nr, err := nc.ListNotifications(ctx, authed(a.token, &notificationsv1.ListNotificationsRequest{PageSize: 20}))
		if err != nil {
			t.Fatalf("ListNotifications: %v", err)
		}
		seen := false
		for _, n := range nr.Msg.GetNotifications() {
			if n.GetActor().GetUserId() == p.uid {
				seen = true
				if n.GetActor().GetIsPrivate() {
					t.Errorf("Notification.actor = %v, want is_private unset", n.GetActor())
				}
			}
		}
		if !seen {
			t.Errorf("no notification from the protected actor in %v", nr.Msg.GetNotifications())
		}
	})

	t.Run("turning is_private off flips the row to false", func(t *testing.T) {
		off := false
		if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &off}); err != nil {
			t.Fatalf("unprotect: %v", err)
		}
		resp, err := cold().graph.ListFollowing(ctx, authed(v.token, &graphv1.ListFollowingRequest{UserId: v.uid, PageSize: 20}))
		if err != nil {
			t.Fatalf("ListFollowing: %v", err)
		}
		w328cWant(t, "ListFollowing after unprotect", resp.Msg.GetUsers(), map[string]bool{p.uid: false, a.uid: false, b2.uid: false})
	})
}
