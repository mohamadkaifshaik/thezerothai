//go:build integration

package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

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
	budgettest.Assert(t, "Takedown", c, budgettest.Budget{Reads: 1, Writes: 2})
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
	budgettest.Assert(t, "Restore", c, budgettest.Budget{Reads: 1, Writes: 2})
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
	budgettest.Assert(t, "HideAuthor", c, budgettest.Budget{Reads: 4, Writes: 6})

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
	budgettest.Assert(t, "RestoreAuthor", c, budgettest.Budget{Reads: 3, Writes: 6})
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

// TestModerator_HideAuthorSince: the settle pass (ADR-0016 D4) pages only posts with createdAt >= Since, so a post
// created after the first pass read its page is hidden at the cost of the recent window, not the whole history.
func TestModerator_HideAuthorSince(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	base := int64(1_700_000_000_000)
	for i := 1; i <= 3; i++ {
		seedPost(t, client, pid(i), "u-bad", false, base+int64(i)*1000)
	}
	now := time.Unix(1_800_000_100, 0)
	if _, done, err := repo.HideAuthor(context.Background(), "u-bad", ModerationCheckpoint{}, now); err != nil || !done {
		t.Fatalf("first pass: done=%v err=%v", done, err)
	}
	// A post an instance with a stale ACTIVE cache accepted after the first pass read its page.
	seedPost(t, client, pid(4), "u-bad", false, base+4000)

	ctx, c := budget.WithCounter(context.Background())
	since := time.UnixMilli(base + 3500).UTC()
	next, done, err := repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{Since: since}, now)
	if err != nil || !done || next.Changed != 1 {
		t.Fatalf("settle pass: next=%+v done=%v err=%v", next, done, err)
	}
	budgettest.Assert(t, "HideAuthor since", c, budgettest.Budget{Reads: 1, Writes: 2})
	if got := storedModeration(t, repo, pid(4)); got != ModerationSuspendedAuthor {
		t.Errorf("late post moderation = %q", got)
	}
}

// TestModerator_BatchFailsWhenAPostChangedAfterTheRead: a post a moderator took down between HideAuthor's read and
// its commit must not be overwritten with SUSPENDED_AUTHOR. The LastUpdateTime precondition fails the whole batch
// (nothing is written, TAKEN_DOWN survives) and the re-run, which re-reads, succeeds. Same for RestoreAuthor.
func TestModerator_BatchFailsWhenAPostChangedAfterTheRead(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	base := int64(1_700_000_000_000)
	seedPost(t, client, pid(1), "u-bad", false, base+1000)
	seedPost(t, client, pid(2), "u-bad", false, base+2000)
	now := time.Unix(1_800_000_100, 0)

	repo.moderationReadHook = func() {
		repo.moderationReadHook = nil
		if _, err := repo.Takedown(context.Background(), pid(1), now); err != nil {
			t.Error(err)
		}
	}
	if _, _, err := repo.HideAuthor(context.Background(), "u-bad", ModerationCheckpoint{}, now); err == nil {
		t.Fatal("HideAuthor committed over a post changed after its read")
	}
	if got := storedModeration(t, repo, pid(1)); got != ModerationTakenDown {
		t.Errorf("post 1 = %q, want TAKEN_DOWN to survive", got)
	}
	if got := storedModeration(t, repo, pid(2)); got != ModerationNone {
		t.Errorf("post 2 = %q: the failed batch must write nothing", got)
	}
	// The re-run re-reads and finishes: only post 2 is changed, post 1 stays taken down.
	next, done, err := repo.HideAuthor(context.Background(), "u-bad", ModerationCheckpoint{}, now)
	if err != nil || !done || next.Changed != 1 {
		t.Fatalf("re-run: next=%+v done=%v err=%v", next, done, err)
	}

	// RestoreAuthor: a post re-taken-down between its read and commit is not cleared.
	repo.moderationReadHook = func() {
		repo.moderationReadHook = nil
		if _, err := repo.Takedown(context.Background(), pid(2), now); err != nil {
			t.Error(err)
		}
	}
	if _, _, err := repo.RestoreAuthor(context.Background(), "u-bad", ModerationCheckpoint{}); err == nil {
		t.Fatal("RestoreAuthor committed over a post changed after its read")
	}
	if got := storedModeration(t, repo, pid(2)); got != ModerationTakenDown {
		t.Errorf("post 2 after failed restore = %q, want TAKEN_DOWN", got)
	}
}

func storedRemoval(t *testing.T, repo *FirestoreRepo, id string) (RemovalState, time.Time, bool) {
	t.Helper()
	snap, err := repo.removalRef(id).Get(context.Background())
	if status.Code(err) == codes.NotFound {
		return "", time.Time{}, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var d removalDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if !d.ExpireAt.After(d.CreatedAt) || d.ExpireAt.Sub(d.CreatedAt) < RemovalRetention-time.Hour {
		t.Errorf("removal %s: expireAt %v is not about RemovalRetention after createdAt %v", id, d.ExpireAt, d.CreatedAt)
	}
	return RemovalState(d.State), d.CreatedAt, true
}

// TestModerator_RemovalLogFollowsEveryHideAndRestore (ADR-0016 D10): every hide and every un-hide writes the post's
// postRemovals entry in the same transaction or batch as the moderation field; no-ops write nothing; a re-run of
// suspend-user's hide writes nothing new; a restore overwrites with RESTORED and a later createdAt (a warm
// instance's incremental query would never see a delete).
func TestModerator_RemovalLogFollowsEveryHideAndRestore(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	base := int64(1_700_000_000_000)
	now := time.Now()
	seedPost(t, client, pid(1), "u-a", false, base+1000)

	if st, _, ok := storedRemoval(t, repo, pid(1)); ok {
		t.Fatalf("entry before any action: %q", st)
	}
	if _, err := repo.Takedown(context.Background(), pid(1), now); err != nil {
		t.Fatal(err)
	}
	st, at1, ok := storedRemoval(t, repo, pid(1))
	if !ok || st != RemovalRemoved || at1.IsZero() {
		t.Fatalf("after takedown: state=%q at=%v ok=%v", st, at1, ok)
	}
	// A repeated takedown is a no-op: 0 writes, the entry is untouched.
	ctx, c := budget.WithCounter(context.Background())
	if _, err := repo.Takedown(ctx, pid(1), now); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "Takedown again", c, budgettest.Budget{Reads: 1})
	if _, at, _ := storedRemoval(t, repo, pid(1)); !at.Equal(at1) {
		t.Fatalf("a no-op takedown moved createdAt %v -> %v", at1, at)
	}

	time.Sleep(20 * time.Millisecond)
	if _, err := repo.Restore(context.Background(), pid(1)); err != nil {
		t.Fatal(err)
	}
	st, at2, _ := storedRemoval(t, repo, pid(1))
	if st != RemovalRestored || !at2.After(at1) {
		t.Fatalf("after restore: state=%q at=%v (was %v), want RESTORED and later", st, at2, at1)
	}
	time.Sleep(20 * time.Millisecond)
	if _, err := repo.Takedown(context.Background(), pid(1), now); err != nil {
		t.Fatal(err)
	}
	if st, at3, _ := storedRemoval(t, repo, pid(1)); st != RemovalRemoved || !at3.After(at2) {
		t.Fatalf("re-takedown: state=%q at=%v (was %v)", st, at3, at2)
	}
}

// TestModerator_HideAuthorLogsEveryPostInOneBatchAndIsIdempotent: 300 posts need two pages (hidePage = 250: two
// operations per post stay inside the 500-operation batch), cost 2 writes per post, and a re-run writes nothing.
func TestModerator_HideAuthorLogsEveryPostInOneBatchAndIsIdempotent(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	const n = 300
	base := int64(1_700_000_000_000)
	for i := 1; i <= n; i++ {
		seedPost(t, client, pid(i), "u-bad", false, base+int64(i)*1000)
	}
	now := time.Now()

	ctx, c := budget.WithCounter(context.Background())
	cp := ModerationCheckpoint{}
	pages := 0
	for {
		var done bool
		var err error
		if cp, done, err = repo.HideAuthor(ctx, "u-bad", cp, now); err != nil {
			t.Fatalf("page %d: %v", pages, err)
		}
		pages++
		if done {
			break
		}
	}
	if pages != 2 || cp.Changed != n {
		t.Fatalf("pages=%d changed=%d, want 2 pages and %d changed", pages, cp.Changed, n)
	}
	budgettest.Assert(t, "HideAuthor 300", c, budgettest.Budget{Reads: n, Writes: 2 * n})
	for _, i := range []int{1, 250, 251, n} {
		if st, _, ok := storedRemoval(t, repo, pid(i)); !ok || st != RemovalRemoved {
			t.Errorf("post %d entry = %q ok=%v", i, st, ok)
		}
	}

	// Re-run from the start: every post is already hidden and already logged.
	ctx, c = budget.WithCounter(context.Background())
	cp = ModerationCheckpoint{}
	for {
		var done bool
		var err error
		if cp, done, err = repo.HideAuthor(ctx, "u-bad", cp, now); err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
	}
	if cp.Changed != 0 || c.Writes() != 0 {
		t.Fatalf("re-run changed=%d writes=%d, want 0/0", cp.Changed, c.Writes())
	}

	// The reader sees the newest 50 of them, and unsuspend writes RESTORED over every entry.
	ents, err := repo.Newest(context.Background(), time.Now().Add(-time.Hour), RemovalMaxIDs)
	if err != nil || len(ents) != RemovalMaxIDs {
		t.Fatalf("Newest: %d entries err=%v", len(ents), err)
	}
	cp = ModerationCheckpoint{}
	for {
		var done bool
		if cp, done, err = repo.RestoreAuthor(context.Background(), "u-bad", cp); err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
	}
	if st, _, _ := storedRemoval(t, repo, pid(n)); st != RemovalRestored {
		t.Fatalf("after unsuspend entry = %q, want RESTORED", st)
	}
}
