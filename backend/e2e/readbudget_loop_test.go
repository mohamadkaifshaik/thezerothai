//go:build integration

package e2e

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// errorDetailOf returns the dzeroth.common.v1.ErrorDetail carried by a Connect error (nil if none).
func errorDetailOf(err error) *commonv1.ErrorDetail {
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		return nil
	}
	for _, d := range cerr.Details() {
		if msg, derr := d.Value(); derr == nil {
			if detail, ok := msg.(*commonv1.ErrorDetail); ok {
				return detail
			}
		}
	}
	return nil
}

// TestE2E_ReadBudgetLoop_RandomHandlesStopAtTheBudget (audit item 2, T20 AC3, P0): a verified uid with a profile
// loops CheckHandleAvailability and GetProfile-by-handle on random (never-existing) handles through the real
// Build chain with a small READ_BUDGET_PER_UID_PER_DAY. Real Firestore reads are charged to the budget; the sum
// of the logged fs_reads stops at the budget (overshoot is at most the one call that crossed it), the first
// rejection is RATE_LIMITED read_budget_daily, and every later call is rejected with fs_reads == 0.
func TestE2E_ReadBudgetLoop_RandomHandlesStopAtTheBudget(t *testing.T) {
	skipIfNoEmulators(t)
	const budget = 40
	ctx := context.Background()
	idToken, _ := newAnonymousIDToken(t) // passes the identity gate against the emulator (config.AuthEmulator)

	// Setup on a separate handler (own limiter state), so creating the profile does not spend the loop's budget.
	setup, _ := newTestServerCfg(t, nil)
	if _, err := setup.CreateProfile(ctx, authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-readbudget-loop-create-profile",
		Handle:         uniqueHandle("rbl"),
		DisplayName:    "Budget Loop",
	})); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	log, logs := captureLogger()
	client, _ := newTestServerCfgLog(t, func(cfg *config.Config) {
		cfg.RateLimit.ReadBudgetPerUIDPerDay = budget
		// Take every other limiter out of the way so only the read budget can reject.
		cfg.RateLimit.PerUserPerMinute = 1_000_000
		cfg.RateLimit.CheckHandlePerUserPerMinute = 1_000_000
		cfg.RateLimit.CheckHandleCallsPerDay = 1_000_000
		cfg.RateLimit.PerIPPerMinute = 1_000_000
		cfg.RateLimit.PreAuthIPPerMinute = 1_000_000
	}, log)

	call := func(i int) (rpc string, err error) {
		if i%2 == 0 {
			rpc = identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure
			_, err = client.CheckHandleAvailability(ctx, authedRequest(idToken, &identityv1.CheckHandleAvailabilityRequest{Handle: uniqueHandle("rb")}))
			return rpc, err
		}
		rpc = identityv1connect.IdentityServiceGetProfileProcedure
		_, err = client.GetProfile(ctx, authedRequest(idToken, &identityv1.GetProfileRequest{
			Target: &identityv1.GetProfileRequest_Handle{Handle: uniqueHandle("rb")},
		}))
		return rpc, err
	}
	// lastReads is the fs_reads of the request line the call just logged.
	lastReads := func(rpc string) int64 {
		t.Helper()
		lines := logs.requestLines(t, rpc)
		if len(lines) == 0 {
			t.Fatalf("no request line for %s", rpc)
		}
		reads, _ := lines[len(lines)-1]["fs_reads"].(float64)
		return int64(reads)
	}

	const maxCalls = 200
	var total, maxCall int64
	firstRejection := -1
	for i := 0; i < maxCalls; i++ {
		rpc, err := call(i)
		reads := lastReads(rpc)
		if err != nil && connect.CodeOf(err) == connect.CodeResourceExhausted {
			d := errorDetailOf(err)
			if d == nil || d.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED || d.GetMetadata()["limit"] != "read_budget_daily" {
				t.Fatalf("call %d: first rejection = %v, want RATE_LIMITED limit=read_budget_daily", i, err)
			}
			if reads != 0 {
				t.Errorf("call %d: the rejected call logged fs_reads = %d, want 0", i, reads)
			}
			firstRejection = i
			break
		}
		if err != nil && connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("call %d (%s): unexpected error %v", i, rpc, err) // GetProfile of a random handle is NOT_FOUND
		}
		total += reads
		maxCall = max(maxCall, reads)
	}
	if firstRejection < 0 {
		t.Fatalf("no call was rejected in %d calls (spent %d reads): the budget %d never stopped the loop", maxCalls, total, budget)
	}
	if maxCall == 0 {
		t.Fatal("no call logged any fs_reads: the loop did not exercise real Firestore reads")
	}
	// The budget is charged after the call, so the call that crosses it is the last one admitted: total reads are
	// at least the budget and exceed it by less than one call's reads.
	if total < budget || total-maxCall >= budget {
		t.Errorf("admitted reads = %d (largest call %d), want in [%d, %d)", total, maxCall, budget, budget+maxCall)
	}

	// Further calls stay rejected and cost nothing: the sum of fs_reads has stopped growing.
	for i := firstRejection + 1; i < firstRejection+11; i++ {
		rpc, err := call(i)
		d := errorDetailOf(err)
		if connect.CodeOf(err) != connect.CodeResourceExhausted || d == nil || d.GetMetadata()["limit"] != "read_budget_daily" {
			t.Fatalf("call %d after the budget: err = %v, want RATE_LIMITED read_budget_daily", i, err)
		}
		if reads := lastReads(rpc); reads != 0 {
			t.Errorf("call %d after the budget: fs_reads = %d, want 0", i, reads)
		}
	}
}
