//go:build integration

package graph_test

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestReadBudget_Regression_HappyPathsWithBudgetEnabledAtDefaults (T3 acceptance "no legitimate call is
// rejected" + "every graph and identity RPC still passes its existing budget assertions"): every identity and
// graph RPC's happy path runs over HTTP through ratelimit.Interceptor with the ADR-0010 D5 read budget ENABLED at
// the shipped defaults (2,000 reads/uid/day, 500/IP/day on profile-exempt procedures, 100 CheckHandle
// calls/day). No call may be rejected, each call's Firestore ops must stay within the documented budget, and the
// per-uid budget charged must equal the sum of the reads the counter recorded.
func TestReadBudget_Regression_HappyPathsWithBudgetEnabledAtDefaults(t *testing.T) {
	w := newWired(t)
	uidCap := ratelimit.NewDailyCap(2000)
	ipCap := ratelimit.NewDailyCap(500)
	r := newRigWithMutationCap(t, w, 0, 0, func(c *ratelimit.Config) {
		c.ReadBudget = uidCap
		c.ReadBudgetIP = ipCap
		c.ReadBudgetIPEnforce = map[string]struct{}{identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {}}
		c.ReadBudgetIPChargeOnly = map[string]struct{}{identityv1connect.IdentityServiceCreateProfileProcedure: {}}
		c.DailyCaps = map[string]ratelimit.NamedDailyCap{
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {Name: "check_handle_daily", Cap: ratelimit.NewDailyCap(100)},
		}
	})
	const a, b = "uid-rbA", "uid-rbB"
	ctx := context.Background()
	ca, cb := r.as(a), r.as(b)

	var chargedTotal, countedTotal int64
	// step runs one RPC as uid, asserts it was not rejected and stayed within budget bud, and tracks charging.
	step := func(name, uid string, bud budgettest.Budget, fn func() error) {
		t.Helper()
		before := uidCap.Spent(uid)
		if err := fn(); err != nil {
			t.Fatalf("%s rejected or failed with the read budget enabled: %v", name, err)
		}
		ops := r.lastOps()
		budgettest.Assert(t, name, ops, bud)
		chargedTotal += uidCap.Spent(uid) - before
		countedTotal += ops.Reads()
	}

	step("IdentityService.CheckHandleAvailability", a, budgettest.Budget{Reads: 1}, func() error {
		resp, err := ca.id.CheckHandleAvailability(ctx, connect.NewRequest(&identityv1.CheckHandleAvailabilityRequest{Handle: "regress_a"}))
		if err == nil && !resp.Msg.GetAvailable() {
			t.Fatal("regress_a should be available")
		}
		return err
	})
	step("IdentityService.CreateProfile (A)", a, budgettest.Budget{Reads: 2, Writes: 3}, func() error {
		_, err := ca.id.CreateProfile(ctx, connect.NewRequest(&identityv1.CreateProfileRequest{IdempotencyKey: key1, Handle: "regress_a", DisplayName: "A"}))
		return err
	})
	step("IdentityService.CreateProfile (B)", b, budgettest.Budget{Reads: 2, Writes: 3}, func() error {
		_, err := cb.id.CreateProfile(ctx, connect.NewRequest(&identityv1.CreateProfileRequest{IdempotencyKey: key2, Handle: "regress_b", DisplayName: "B"}))
		return err
	})
	step("IdentityService.GetMe", a, budgettest.Budget{Reads: 2}, func() error {
		_, err := ca.id.GetMe(ctx, connect.NewRequest(&identityv1.GetMeRequest{}))
		return err
	})
	step("IdentityService.GetProfile (by handle)", a, budgettest.Budget{Reads: 3}, func() error {
		_, err := ca.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: "regress_b"}}))
		return err
	})
	step("IdentityService.GetProfile (by user_id)", a, budgettest.Budget{Reads: 3}, func() error {
		_, err := ca.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: b}}))
		return err
	})
	dn := "A renamed"
	step("IdentityService.UpdateProfile", a, budgettest.Budget{Reads: 2, Writes: 1}, func() error {
		_, err := ca.id.UpdateProfile(ctx, connect.NewRequest(&identityv1.UpdateProfileRequest{IdempotencyKey: key3, DisplayName: &dn}))
		return err
	})
	step("IdentityService.ChangeHandle", a, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1}, func() error {
		_, err := ca.id.ChangeHandle(ctx, connect.NewRequest(&identityv1.ChangeHandleRequest{IdempotencyKey: "0123456789abcde1", NewHandle: "regress_a2"}))
		return err
	})

	step("GraphService.Follow", a, budFollowWorstCold, func() error {
		_, err := ca.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key1, UserId: b}))
		return err
	})
	step("GraphService.GetRelationships", a, budgettest.Budget{Reads: 1}, func() error {
		_, err := ca.graph.GetRelationships(ctx, connect.NewRequest(&graphv1.GetRelationshipsRequest{UserIds: []string{b}}))
		return err
	})
	step("GraphService.ListFollowers", a, budgettest.Budget{Reads: 2 + 20 + 20}, func() error {
		_, err := ca.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: b}))
		return err
	})
	step("GraphService.ListFollowing", a, budgettest.Budget{Reads: 2 + 20 + 20}, func() error {
		_, err := ca.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: a}))
		return err
	})
	// ListFollowRequests/RespondToFollowRequest are FAILED_PRECONDITION stubs until private accounts ship (ADR-0008 D1).
	step("GraphService.Mute", a, budMute, func() error {
		_, err := ca.graph.Mute(ctx, connect.NewRequest(&graphv1.MuteRequest{IdempotencyKey: key2, UserId: b}))
		return err
	})
	step("GraphService.ListMutedUsers", a, budgettest.Budget{Reads: 1 + 20}, func() error {
		_, err := ca.graph.ListMutedUsers(ctx, connect.NewRequest(&graphv1.ListMutedUsersRequest{}))
		return err
	})
	step("GraphService.Unmute", a, budUnmute, func() error {
		_, err := ca.graph.Unmute(ctx, connect.NewRequest(&graphv1.UnmuteRequest{IdempotencyKey: key3, UserId: b}))
		return err
	})
	step("GraphService.Block", a, budBlockWorst, func() error {
		_, err := ca.graph.Block(ctx, connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: "0123456789abcde2", UserId: b}))
		return err
	})
	step("GraphService.ListBlockedUsers", a, budgettest.Budget{Reads: 1 + 20}, func() error {
		_, err := ca.graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{}))
		return err
	})
	step("GraphService.Unblock", a, budUnblock, func() error {
		_, err := ca.graph.Unblock(ctx, connect.NewRequest(&graphv1.UnblockRequest{IdempotencyKey: "0123456789abcde3", UserId: b}))
		return err
	})
	step("GraphService.Unfollow (no-op after Block)", a, budUnfollow, func() error {
		_, err := ca.graph.Unfollow(ctx, connect.NewRequest(&graphv1.UnfollowRequest{IdempotencyKey: "0123456789abcde4", UserId: b}))
		return err
	})

	if chargedTotal != countedTotal {
		t.Errorf("read budget charged %d reads in total, budget.Counter recorded %d", chargedTotal, countedTotal)
	}
	if spent := uidCap.Spent(a); spent >= 2000 {
		t.Errorf("uid A spent %d of 2000 reads on one happy-path pass: defaults would reject typical use", spent)
	}
}
