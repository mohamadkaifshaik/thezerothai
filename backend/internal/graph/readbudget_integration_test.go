//go:build integration

package graph_test

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestReadBudget_Integration_ChargesRealCounterReads (ADR-0010 D5 / T3): against the Firestore emulator the
// per-uid read budget is charged with the reads budget.Counter actually recorded (a cold GetProfile charges
// 1-3), for identity and graph RPCs alike, and an exhausted uid is rejected with 0 Firestore reads.
func TestReadBudget_Integration_ChargesRealCounterReads(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, uidV, "budgetv")
	mustCreateProfile(t, w.identity, uidH, "budgeth")
	uidCap := ratelimit.NewDailyCap(2000)
	r := newRigWithMutationCap(t, w, 0, 0, func(c *ratelimit.Config) { c.ReadBudget = uidCap })
	v := r.as(uidV)
	ctx := context.Background()

	// Cold GetProfile: evict the cached profile so the read hits Firestore.
	w.identity.(identity.Directory).Forget(uidH)
	before := uidCap.Spent(uidV)
	if _, err := v.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uidH},
	})); err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	charged := uidCap.Spent(uidV) - before
	if got := r.lastOps().Reads(); charged != got || charged < 1 || charged > 3 {
		t.Fatalf("cold GetProfile charged %d, counter recorded %d reads; want equal and within 1-3", charged, got)
	}

	before = uidCap.Spent(uidV)
	if _, err := v.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH})); err != nil {
		t.Fatalf("ListFollowers: %v", err)
	}
	if charged, got := uidCap.Spent(uidV)-before, r.lastOps().Reads(); charged != got {
		t.Fatalf("ListFollowers charged %d, counter recorded %d reads", charged, got)
	}

	// Exhausted uid: rejected with 0 Firestore reads, whichever RPC it calls; another uid is unaffected.
	uidCap.Charge(uidV, 2000)
	_, err := v.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uidH},
	}))
	info := decodeErr(t, err)
	if info.Code != connect.CodeResourceExhausted || info.Meta["limit"] != "read_budget_daily" {
		t.Fatalf("exhausted uid: code=%v limit=%q, want ResourceExhausted/read_budget_daily", info.Code, info.Meta["limit"])
	}
	if got := r.lastOps().Reads(); got != 0 {
		t.Fatalf("rejected call performed %d Firestore reads, want 0", got)
	}
	if _, err := r.as(uidH).id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uidH},
	})); err != nil {
		t.Fatalf("another uid must be unaffected: %v", err)
	}
}
