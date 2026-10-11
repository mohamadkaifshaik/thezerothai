//go:build integration

package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func storedModeration(t *testing.T, repo *FirestoreRepo, id string) Moderation {
	t.Helper()
	snap, err := repo.ref(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	return Moderation(d.Moderation)
}

// TestModerator_TakedownRestoreBudgets covers ADR-0016 D3/D4 for one post: 1 read + 1 write, no-ops are 0 writes,
// a suspension-hidden post is upgraded to TAKEN_DOWN and is not restored by restore-post's SUSPENDED rule.
func TestModerator_TakedownRestoreBudgets(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedPost(t, client, pid(1), "u-a", false, 1_700_000_000_000)
	now := time.Unix(1_800_000_000, 0)

	ctx, c := budget.WithCounter(context.Background())
	res, err := repo.Takedown(ctx, pid(1), now)
	if err != nil || res.Before != ModerationNone || res.After != ModerationTakenDown || res.AuthorID != "u-a" {
		t.Fatalf("takedown = %+v err=%v", res, err)
	}
	budgettest.Assert(t, "Takedown", c, budgettest.Budget{Reads: 1, Writes: 1})
	if got := storedModeration(t, repo, pid(1)); got != ModerationTakenDown {
		t.Fatalf("stored = %q", got)
	}

	ctx, c = budget.WithCounter(context.Background())
	if res, err = repo.Takedown(ctx, pid(1), now); err != nil || res.Before != ModerationTakenDown {
		t.Fatalf("second takedown = %+v err=%v", res, err)
	}
	budgettest.Assert(t, "Takedown again", c, budgettest.Budget{Reads: 1})

	ctx, c = budget.WithCounter(context.Background())
	if res, err = repo.Restore(ctx, pid(1)); err != nil || res.After != ModerationNone {
		t.Fatalf("restore = %+v err=%v", res, err)
	}
	budgettest.Assert(t, "Restore", c, budgettest.Budget{Reads: 1, Writes: 1})
	if got := storedModeration(t, repo, pid(1)); got != ModerationNone {
		t.Fatalf("stored after restore = %q", got)
	}
	// Exact restore: every other field is untouched.
	snap, _ := repo.ref(pid(1)).Get(context.Background())
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.Text != "text "+pid(1) || d.LikeCount != 1 || d.ModeratedAt != nil {
		t.Fatalf("doc changed beyond moderation: %+v", d)
	}

	if _, err := repo.Takedown(context.Background(), pid(404), now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing post: %v", err)
	}
	if _, err := repo.Takedown(context.Background(), "", now); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("empty id: %v", err)
	}
}

// TestModerator_HideAndRestoreAuthor: suspension hides every visible post of the author (TAKEN_DOWN stays
// TAKEN_DOWN), other authors are untouched, a re-run is 0 writes, and unsuspend restores only SUSPENDED_AUTHOR.
func TestModerator_HideAndRestoreAuthor(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	base := int64(1_700_000_000_000)
	for i := 1; i <= 4; i++ {
		seedPost(t, client, pid(i), "u-bad", false, base+int64(i)*1000)
	}
	seedPost(t, client, pid(9), "u-good", false, base+9000)
	if _, err := repo.Takedown(context.Background(), pid(2), time.Unix(1_800_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_100, 0)

	ctx, c := budget.WithCounter(context.Background())
	next, done, err := repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{}, now)
	if err != nil || !done || next.Changed != 3 {
		t.Fatalf("hide: next=%+v done=%v err=%v", next, done, err)
	}
	// 4 posts paged, 3 changed (the TAKEN_DOWN one is skipped).
	budgettest.Assert(t, "HideAuthor", c, budgettest.Budget{Reads: 4, Writes: 3})

	want := map[string]Moderation{pid(1): ModerationSuspendedAuthor, pid(2): ModerationTakenDown,
		pid(3): ModerationSuspendedAuthor, pid(4): ModerationSuspendedAuthor, pid(9): ModerationNone}
	for id, m := range want {
		if got := storedModeration(t, repo, id); got != m {
			t.Errorf("post %s moderation = %q, want %q", id, got, m)
		}
	}

	// Re-run is idempotent: 4 reads, 0 writes.
	ctx, c = budget.WithCounter(context.Background())
	next, done, err = repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{}, now)
	if err != nil || !done || next.Changed != 0 {
		t.Fatalf("re-run: next=%+v done=%v err=%v", next, done, err)
	}
	budgettest.Assert(t, "HideAuthor rerun", c, budgettest.Budget{Reads: 4})

	// Resuming from a checkpoint pages only the older posts.
	ctx, c = budget.WithCounter(context.Background())
	after := &Position{CreatedAt: time.UnixMilli(base + 3000).UTC(), ID: pid(3)}
	if _, _, err = repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{After: after}, now); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "HideAuthor resume", c, budgettest.Budget{Reads: 2})

	// restore-post must not undo a suspension; unsuspend restores exactly the suspension-hidden posts.
	if res, err := repo.Restore(context.Background(), pid(1)); err != nil || res.After != ModerationSuspendedAuthor {
		t.Fatalf("restore of a suspended-author post = %+v err=%v", res, err)
	}
	ctx, c = budget.WithCounter(context.Background())
	rn, done, err := repo.RestoreAuthor(ctx, "u-bad", ModerationCheckpoint{})
	if err != nil || !done || rn.Changed != 3 {
		t.Fatalf("restore author: next=%+v done=%v err=%v", rn, done, err)
	}
	budgettest.Assert(t, "RestoreAuthor", c, budgettest.Budget{Reads: 3, Writes: 3})
	if got := storedModeration(t, repo, pid(2)); got != ModerationTakenDown {
		t.Errorf("TAKEN_DOWN post after unsuspend = %q, want it still taken down", got)
	}
	for _, i := range []int{1, 3, 4} {
		if got := storedModeration(t, repo, pid(i)); got != ModerationNone {
			t.Errorf("post %d after unsuspend = %q", i, got)
		}
	}
}

// TestGetForViewer_HiddenPostIsNotFoundForEveryone: a taken-down post answers exactly like an unknown id, for the
// author too, and comes back after restore. The hidden check costs no extra read.
func TestGetForViewer_HiddenPostIsNotFoundForEveryone(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	p, _, err := in.create(t, "uid-bob", key(1), "hide me")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := in.repo.Takedown(context.Background(), p.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	cold := newCreateInstance(t, client, time.Nanosecond)
	_, _, unknownErr := cold.get("uid-alice", pid(31337))
	for _, viewer := range []string{"uid-alice", "uid-bob"} {
		in2 := newCreateInstance(t, client, time.Nanosecond)
		c, got, err := in2.get(viewer, p.ID)
		if got != nil || err == nil || err.Error() != unknownErr.Error() {
			t.Fatalf("viewer %s: post=%v err=%v, want the unknown-id error %v", viewer, got, err, unknownErr)
		}
		budgettest.Assert(t, "GetPost hidden", c, budgettest.Budget{Reads: 1})
	}
	if _, err := in.repo.Restore(context.Background(), p.ID); err != nil {
		t.Fatal(err)
	}
	in3 := newCreateInstance(t, client, time.Nanosecond)
	if _, got, err := in3.get("uid-alice", p.ID); err != nil || got == nil || got.Moderation != ModerationNone {
		t.Fatalf("after restore: post=%v err=%v", got, err)
	}
}
