//go:build integration

// block_integration_test.go exercises Block/Unblock/Mute/Unmute against the Firestore emulator (ADR-0008
// T8 acceptance criteria and budgets).
package graph_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestBlock_Integration_MutualFollow_Budget(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx0 := context.Background()
	if _, err := w.graph.Follow(ctx0, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Follow(ctx0, "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	ctx, counter := budget.WithCounter(context.Background())
	rel, err := w.graph.Block(ctx, "uid-a", key2, "uid-b")
	if err != nil {
		t.Fatalf("Block: %v", err)
	}
	if !rel.Blocking || rel.FollowState != graph.FollowStateNone {
		t.Errorf("rel = %+v", rel)
	}
	budgettest.Assert(t, "GraphService.Block (mutual follow)", counter, budgettest.Budget{Reads: 3, Writes: 5, Deletes: 2})

	if docExists(t, w.client, "follows/uid-a_uid-b") || docExists(t, w.client, "follows/uid-b_uid-a") {
		t.Error("follows docs must both be deleted")
	}
	a, b := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b")
	if !contains(a["blocked"], "uid-b") || len(a["following"]) != 0 {
		t.Errorf("a = %v", a)
	}
	if !contains(b["blockedBy"], "uid-a") || len(b["following"]) != 0 || len(b["blocked"]) != 0 {
		t.Errorf("b = %v", b)
	}
	for _, uid := range []string{"uid-a", "uid-b"} {
		if fg, fr := counts(t, w, uid); fg != 0 || fr != 0 {
			t.Errorf("%s counters = %d/%d, want 0/0 (each decremented exactly once)", uid, fg, fr)
		}
	}

	// Replay: 0 writes, blocking=true.
	ctx2, c2 := budget.WithCounter(context.Background())
	rel, err = w.graph.Block(ctx2, "uid-a", key3, "uid-b")
	if err != nil || !rel.Blocking {
		t.Fatalf("replay = %+v, %v", rel, err)
	}
	budgettest.Assert(t, "GraphService.Block (replay)", c2, budgettest.Budget{Reads: 3, Writes: 0})
}

func TestBlock_Integration_TypicalBudget(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx, counter := budget.WithCounter(context.Background())
	if _, err := w.graph.Block(ctx, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.Block (typical)", counter, budgettest.Budget{Reads: 3, Writes: 3, Deletes: 0})
}

func TestBlock_Integration_UnknownTargetAndSelf(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	_, err := w.graph.Block(context.Background(), "uid-a", key1, "ghost")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code.String() != "not_found" {
		t.Fatalf("err = %v, want not_found", err)
	}
	_, err = w.graph.Block(context.Background(), "uid-a", key1, "uid-a")
	if !errors.As(err, &ae) || ae.Code.String() != "invalid_argument" {
		t.Fatalf("err = %v, want invalid_argument", err)
	}
}

func TestUnblock_Integration_NoRestoreAndNoop(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx0 := context.Background()
	if _, err := w.graph.Follow(ctx0, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx0, "uid-a", key2, "uid-b"); err != nil {
		t.Fatal(err)
	}

	ctx, counter := budget.WithCounter(context.Background())
	rel, err := w.graph.Unblock(ctx, "uid-a", key3, "uid-b")
	if err != nil || rel.Blocking || rel.FollowState != graph.FollowStateNone {
		t.Fatalf("Unblock = %+v, %v", rel, err)
	}
	budgettest.Assert(t, "GraphService.Unblock", counter, budgettest.Budget{Reads: 1, Writes: 2})
	a, b := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b")
	if contains(a["blocked"], "uid-b") || contains(b["blockedBy"], "uid-a") || len(a["following"]) != 0 {
		t.Errorf("a=%v b=%v", a, b)
	}

	ctx2, c2 := budget.WithCounter(context.Background())
	if _, err := w.graph.Unblock(ctx2, "uid-a", "aaaaaaaaaaaaaaaa", "uid-b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.Unblock (noop)", c2, budgettest.Budget{Reads: 1, Writes: 0})
}

func TestMute_Integration_OnlyCallerGraphChanges(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	ctx, counter := budget.WithCounter(context.Background())
	rel, err := w.graph.Mute(ctx, "uid-a", key1, "uid-b")
	if err != nil || !rel.Muting {
		t.Fatalf("Mute = %+v, %v", rel, err)
	}
	budgettest.Assert(t, "GraphService.Mute", counter, budgettest.Budget{Reads: 3, Writes: 2})
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["muted"], "uid-b") {
		t.Errorf("a = %v", a)
	}
	if b := graphArrays(t, w.client, "uid-b"); len(b["muted"])+len(b["blockedBy"])+len(b["blocked"]) != 0 {
		t.Errorf("target graph changed: %v", b)
	}

	// Replay: 0 writes.
	ctx2, c2 := budget.WithCounter(context.Background())
	if _, err := w.graph.Mute(ctx2, "uid-a", key2, "uid-b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.Mute (replay)", c2, budgettest.Budget{Reads: 3, Writes: 0})

	ctx3, c3 := budget.WithCounter(context.Background())
	rel, err = w.graph.Unmute(ctx3, "uid-a", key3, "uid-b")
	if err != nil || rel.Muting {
		t.Fatalf("Unmute = %+v, %v", rel, err)
	}
	budgettest.Assert(t, "GraphService.Unmute", c3, budgettest.Budget{Reads: 1, Writes: 1})
	ctx4, c4 := budget.WithCounter(context.Background())
	if _, err := w.graph.Unmute(ctx4, "uid-a", "aaaaaaaaaaaaaaaa", "uid-b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.Unmute (noop)", c4, budgettest.Budget{Reads: 1, Writes: 0})
}

func TestBlockMute_Integration_QuotaExhausted_UnblockStillWorks(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	ist := time.FixedZone("IST", 5*3600+30*60)
	if _, err := w.client.Collection("quotas").Doc("uid-a").Set(context.Background(), map[string]interface{}{
		"day": time.Now().In(ist).Format("2006-01-02"), "blocks": 200,
	}); err != nil {
		t.Fatal(err)
	}
	for name, call := range map[string]func() error{
		"Block": func() error { _, err := w.graph.Block(context.Background(), "uid-a", key2, "uid-c"); return err },
		"Mute":  func() error { _, err := w.graph.Mute(context.Background(), "uid-a", key2, "uid-b"); return err },
	} {
		var ae *apierr.Error
		if err := call(); !errors.As(err, &ae) || ae.Metadata["quota"] != "blocks" {
			t.Errorf("%s err = %v, want QUOTA_EXCEEDED blocks", name, err)
		}
	}
	if _, err := w.graph.Unblock(context.Background(), "uid-a", key3, "uid-b"); err != nil {
		t.Errorf("Unblock must never be quota-gated: %v", err)
	}
}

func TestBlock_Integration_CapsAndOverflow(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	pad := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "pad-" + time.Duration(i).String()
		}
		return out
	}
	// Target at the blockedBy cap: caller's block still lands, blockedBy is skipped, overflow flag is set.
	seedGraphArrays(t, w.client, "uid-b", map[string]interface{}{"blockedBy": pad(10000)})
	if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
		t.Fatalf("Block at blockedBy cap: %v", err)
	}
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["blocked"], "uid-b") {
		t.Errorf("a = %v", a)
	}
	if b := graphArrays(t, w.client, "uid-b"); contains(b["blockedBy"], "uid-a") || len(b["blockedBy"]) != 10000 {
		t.Error("blockedBy must not grow past its cap")
	}
	snap, err := w.client.Collection("graph").Doc("uid-b").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := snap.DataAt("blockedByOverflow"); v != true {
		t.Errorf("blockedByOverflow = %v, want true", v)
	}

	// Caller at the blocked cap: LIMIT_REACHED.
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	seedGraphArrays(t, w.client, "uid-c", map[string]interface{}{"blocked": pad(2000)})
	_, err = w.graph.Block(context.Background(), "uid-c", key1, "uid-b")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["limit"] != "blocked" {
		t.Errorf("err = %v, want LIMIT_REACHED blocked", err)
	}
}
