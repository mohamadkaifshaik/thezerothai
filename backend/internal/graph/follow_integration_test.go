//go:build integration

// follow_integration_test.go exercises Follow/Unfollow against the Firestore emulator, wiring
// identity+graph together the same way apiserver.Build does (T16a will build a fuller invariant-checker
// suite; this focuses on T7's own acceptance criteria and budget assertions).
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestFollow_Integration_HappyPath_Budget(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	ctx, counter := budget.WithCounter(context.Background())
	rel, err := w.graph.Follow(ctx, "uid-a", "0123456789abcdef", "uid-b")
	if err != nil {
		t.Fatalf("Follow() error = %v", err)
	}
	if rel.FollowState != graph.FollowStateFollowing {
		t.Fatalf("FollowState = %v, want FOLLOWING", rel.FollowState)
	}
	budgettest.Assert(t, "GraphService.Follow (cold)", counter, budgettest.Budget{Reads: 4, Writes: 5})

	meA, err := w.identity.GetMe(context.Background(), "uid-a")
	if err != nil {
		t.Fatalf("GetMe(a): %v", err)
	}
	if meA.Profile.FollowingCount != 1 {
		t.Errorf("a.FollowingCount = %d, want 1", meA.Profile.FollowingCount)
	}
	meB, err := w.identity.GetMe(context.Background(), "uid-b")
	if err != nil {
		t.Fatalf("GetMe(b): %v", err)
	}
	if meB.Profile.FollowersCount != 1 {
		t.Errorf("b.FollowersCount = %d, want 1", meB.Profile.FollowersCount)
	}
}

func TestFollow_Integration_Replay(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	if _, err := w.graph.Follow(context.Background(), "uid-a", "0123456789abcdef", "uid-b"); err != nil {
		t.Fatalf("Follow() #1 error = %v", err)
	}

	ctx, counter := budget.WithCounter(context.Background())
	rel, err := w.graph.Follow(ctx, "uid-a", "fedcba9876543210", "uid-b")
	if err != nil {
		t.Fatalf("Follow() #2 (replay) error = %v", err)
	}
	if rel.FollowState != graph.FollowStateFollowing {
		t.Fatalf("FollowState = %v, want FOLLOWING", rel.FollowState)
	}
	budgettest.Assert(t, "GraphService.Follow (replay)", counter, budgettest.Budget{Reads: 4, Writes: 0})

	me, err := w.identity.GetMe(context.Background(), "uid-a")
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if me.Profile.FollowingCount != 1 {
		t.Errorf("FollowingCount = %d, want 1 (replay must not double-count)", me.Profile.FollowingCount)
	}
}

// A double-click or a client retry is 2-3 identical Follow calls on one pair of docs. Racing them on the emulator can
// legitimately make a call answer with the retryable UNAVAILABLE (ADR-0008 D1: retries exhausted after losing lock
// races; nothing was written), so that is an accepted outcome, as in TestT16a_Race_ConcurrentDuplicateBlocksAndMutes.
// What must hold is the invariant: at least one call commits, every other answer is success or UNAVAILABLE, and the
// edge exists exactly once (FollowingCount == 1). A phase where every call was UNAVAILABLE proves nothing about
// concurrency, so it is retried once on a fresh pair; a second such phase fails the test (issue #284).
func TestFollow_Integration_ConcurrentDuplicateFollows_ExactlyOneEdge(t *testing.T) {
	w := newWired(t)
	const n = 3
	const maxPhases = 2
	for phase := 0; phase < maxPhases; phase++ {
		a, b := fmt.Sprintf("uid-a%d", phase), fmt.Sprintf("uid-b%d", phase)
		mustCreateProfile(t, w.identity, a, fmt.Sprintf("usera%d", phase))
		mustCreateProfile(t, w.identity, b, fmt.Sprintf("userb%d", phase))

		errs := runConcurrently(n, func(int) error {
			_, err := w.graph.Follow(context.Background(), a, "0123456789abcdef", b)
			return err
		})
		succeeded := 0
		for i, err := range errs {
			if err == nil {
				succeeded++
				continue
			}
			var ae *apierr.Error
			if errors.As(err, &ae) && ae.Code == connect.CodeUnavailable {
				t.Logf("phase %d goroutine %d: retryable UNAVAILABLE after exhausted retries: %v", phase, i, err)
				continue
			}
			t.Errorf("phase %d: Follow() goroutine %d error = %v (only success or UNAVAILABLE is acceptable)", phase, i, err)
		}
		if succeeded == 0 {
			if phase+1 < maxPhases {
				continue
			}
			t.Fatalf("every Follow call was UNAVAILABLE in %d phases, so concurrent duplicates were never exercised", maxPhases)
		}

		me, err := w.identity.GetMe(context.Background(), a)
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if me.Profile.FollowingCount != 1 {
			t.Errorf("FollowingCount = %d, want exactly 1 after %d concurrent Follow calls", me.Profile.FollowingCount, n)
		}
		return
	}
}

func TestFollow_Integration_BlockedByTarget_NotFound(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	// b blocked a: a's own blockedBy contains b (ADR-0008 D2).
	seedBlock(t, w.client, "uid-b", "uid-a")

	_, err := w.graph.Follow(context.Background(), "uid-a", "fedcba9876543210", "uid-b")
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code.String() != "not_found" {
		t.Errorf("Code = %v, want NotFound", ae.Code)
	}
}

func TestFollow_Integration_CallerBlocksTarget_TargetBlocked(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	seedBlock(t, w.client, "uid-a", "uid-b")

	_, err := w.graph.Follow(context.Background(), "uid-a", "fedcba9876543210", "uid-b")
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code.String() != "failed_precondition" {
		t.Errorf("Code = %v, want FailedPrecondition", ae.Code)
	}
}

// TestIsBlockedBy_Integration_OverflowFallback (ADR-0008 D2): a caller with BlockedByOverflow=true still
// gets NOT_FOUND on Follow when the target's own .blocked array (not the caller's incomplete blockedBy)
// contains the caller — the fail-closed path, +1 read.
func TestFollow_Integration_BlockedByOverflowFallback(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"blockedByOverflow": true})
	seedGraphArrays(t, w.client, "uid-b", map[string]interface{}{"blocked": []string{"uid-a"}})

	ctx, counter := budget.WithCounter(context.Background())
	_, err := w.graph.Follow(ctx, "uid-a", "fedcba9876543210", "uid-b")
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code.String() != "not_found" {
		t.Errorf("Code = %v, want NotFound", ae.Code)
	}
	// Worst-case budget (proto): reads 4/2 (+1 if the caller's blockedBy overflowed) => 5 here.
	budgettest.Assert(t, "GraphService.Follow (overflow fallback)", counter, budgettest.Budget{Reads: 5})
}

func TestUnfollow_Integration_HappyPathAndNoop(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	if _, err := w.graph.Follow(context.Background(), "uid-a", "0123456789abcdef", "uid-b"); err != nil {
		t.Fatalf("Follow: %v", err)
	}

	ctx, counter := budget.WithCounter(context.Background())
	if _, err := w.graph.Unfollow(ctx, "uid-a", "fedcba9876543210", "uid-b"); err != nil {
		t.Fatalf("Unfollow() error = %v", err)
	}
	budgettest.Assert(t, "GraphService.Unfollow", counter, budgettest.Budget{Reads: 0, Writes: 3, Deletes: 1})

	me, err := w.identity.GetMe(context.Background(), "uid-a")
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if me.Profile.FollowingCount != 0 {
		t.Errorf("FollowingCount = %d, want 0", me.Profile.FollowingCount)
	}

	// Second Unfollow: not following any more -> 0 writes.
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, err := w.graph.Unfollow(ctx2, "uid-a", "0123456789fedcba", "uid-b"); err != nil {
		t.Fatalf("Unfollow() #2 error = %v", err)
	}
	budgettest.Assert(t, "GraphService.Unfollow (no-op)", counter2, budgettest.Budget{Writes: 0, Deletes: 0})
}

// The following-cap and quota scenarios (boundary, rollover, new-account tiers) live in
// mutations_integration_test.go (T16a).
