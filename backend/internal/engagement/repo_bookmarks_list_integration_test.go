//go:build integration

package engagement

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// seedBookmarks writes n bookmark docs directly (post n is the newest, one second apart) and returns their ids
// newest first.
func (e *repoEnv) seedBookmarks(t *testing.T, uid string, n int) []string {
	t.Helper()
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	var out []string
	for i := n; i >= 1; i-- {
		id := fmt.Sprintf("%019d", i)
		if _, err := e.client.Doc("users/"+uid+"/bookmarks/"+id).Set(context.Background(), map[string]any{"createdAt": base.Add(time.Duration(i) * time.Second)}); err != nil {
			t.Fatal(err)
		}
		out = append(out, id)
	}
	return out
}

// ListPage is the one list query: newest first by (createdAt, id), Limit always set, resumed by StartAfter on the last
// row, reads = rows (an empty page bills 1), and it only ever sees the named user's subcollection.
func TestBookmarkRepo_ListPagePagesAndBills(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	want := e.seedBookmarks(t, bmUID, 25)
	e.seedBookmarks(t, "someone-else", 3)

	var p1, p2, p3 []ExportedBookmark
	measured(t, "ListPage 20", budgettest.Budget{Reads: 20}, func(ctx context.Context) {
		var err error
		if p1, err = e.repo.ListPage(ctx, bmUID, nil, 20); err != nil {
			t.Fatal(err)
		}
	})
	last := p1[len(p1)-1]
	measured(t, "ListPage 20 (second)", budgettest.Budget{Reads: 5}, func(ctx context.Context) {
		var err error
		if p2, err = e.repo.ListPage(ctx, bmUID, &posts.Position{CreatedAt: last.BookmarkedAt, ID: last.PostID}, 20); err != nil {
			t.Fatal(err)
		}
	})
	if len(p1) != 20 || len(p2) != 5 {
		t.Fatalf("pages = %d + %d rows, want 20 + 5", len(p1), len(p2))
	}
	var got []string
	for _, r := range append(append([]ExportedBookmark{}, p1...), p2...) {
		got = append(got, r.PostID)
	}
	if !slices.Equal(got, want) {
		t.Fatalf("order = %v, want newest first %v", got, want)
	}
	// An empty page bills one read (Firestore bills an empty query as one).
	tail := p2[len(p2)-1]
	measured(t, "ListPage empty", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		var err error
		if p3, err = e.repo.ListPage(ctx, bmUID, &posts.Position{CreatedAt: tail.BookmarkedAt, ID: tail.PostID}, 20); err != nil {
			t.Fatal(err)
		}
	})
	if len(p3) != 0 {
		t.Errorf("past the end = %v", p3)
	}
	// The limit is clamped to 1..50, whatever the caller asks for.
	big, err := e.repo.ListPage(ctx, bmUID, nil, 5000)
	if err != nil || len(big) != 25 {
		t.Errorf("big limit: %d rows, %v", len(big), err)
	}
	e.seedBookmarks(t, "many", 60)
	if capped, err := e.repo.ListPage(ctx, "many", nil, 5000); err != nil || len(capped) != MaxListPage {
		t.Errorf("limit 5000 returned %d rows, want %d: %v", len(capped), MaxListPage, err)
	}
	if one, err := e.repo.ListPage(ctx, bmUID, nil, 0); err != nil || len(one) != 1 {
		t.Errorf("limit 0 returned %d rows, want the floor of 1: %v", len(one), err)
	}
}

// Rows with the same createdAt are ordered by id descending and never skipped or repeated across a page boundary.
func TestBookmarkRepo_ListPageTieBreak(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	at := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	ids := []string{"0000000000000000005", "0000000000000000004", "0000000000000000003", "0000000000000000002", "0000000000000000001"}
	for _, id := range ids {
		if _, err := e.client.Doc("users/"+bmUID+"/bookmarks/"+id).Set(ctx, map[string]any{"createdAt": at}); err != nil {
			t.Fatal(err)
		}
	}
	var got []string
	var after *posts.Position
	for range 5 {
		rows, err := e.repo.ListPage(ctx, bmUID, after, 2)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) == 0 {
			break
		}
		for _, r := range rows {
			got = append(got, r.PostID)
		}
		l := rows[len(rows)-1]
		after = &posts.Position{CreatedAt: l.BookmarkedAt, ID: l.PostID}
	}
	if !slices.Equal(got, ids) {
		t.Errorf("paged %v, want %v", got, ids)
	}
}

// Prune: one batch, 0 reads, 1 write (userLikes) and 1 delete per id; the liked and reposted sets and the bookmarks
// that are not pruned survive (field-level update), a second prune of the same ids is harmless, and a user with no
// userLikes doc gets one holding only the empty set.
func TestBookmarkRepo_PruneIsOneFieldLevelBatch(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	ids := e.seedBookmarks(t, bmUID, 5)
	if _, err := e.client.Doc("userLikes/"+bmUID).Set(ctx, map[string]any{
		"recent": []string{"9"}, "recentReposts": []string{"8"}, "bookmarks": ids,
	}); err != nil {
		t.Fatal(err)
	}
	gone := []string{ids[1], ids[3]}

	c := measured(t, "Prune", budgettest.Budget{Writes: 1, Deletes: 2}, func(ctx context.Context) {
		if err := e.repo.Prune(ctx, bmUID, gone); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 0 || c.Writes() != 1 || c.Deletes() != 2 {
		t.Errorf("Prune reads/writes/deletes = %d/%d/%d, want 0/1/2", c.Reads(), c.Writes(), c.Deletes())
	}
	for _, id := range gone {
		if e.bookmarkExists(t, bmUID, id) {
			t.Errorf("bookmark %s survived the prune", id)
		}
	}
	for _, id := range []string{ids[0], ids[2], ids[4]} {
		if !e.bookmarkExists(t, bmUID, id) {
			t.Errorf("bookmark %s was pruned but its post was not gone", id)
		}
	}
	if got, want := e.bookmarks(t, bmUID), []string{ids[0], ids[2], ids[4]}; !slices.Equal(got, want) {
		t.Errorf("userLikes.bookmarks = %v, want %v", got, want)
	}
	snap, _ := e.client.Doc("userLikes/" + bmUID).Get(ctx)
	if v, _ := snap.DataAt("recent"); fmt.Sprint(v) != "[9]" {
		t.Errorf("userLikes.recent = %v: a prune must not touch it", v)
	}
	if v, _ := snap.DataAt("recentReposts"); fmt.Sprint(v) != "[8]" {
		t.Errorf("userLikes.recentReposts = %v: a prune must not touch it", v)
	}
	// Repeating it (a concurrent prune of the same rows) is harmless.
	if err := e.repo.Prune(ctx, bmUID, gone); err != nil {
		t.Errorf("second prune: %v", err)
	}
	if got := e.bookmarks(t, bmUID); len(got) != 3 {
		t.Errorf("userLikes.bookmarks = %v after a repeated prune", got)
	}
	// No ids: nothing at all.
	measured(t, "Prune none", budgettest.Budget{}, func(ctx context.Context) {
		if err := e.repo.Prune(ctx, bmUID, nil); err != nil {
			t.Fatal(err)
		}
	})
	// A user with no userLikes doc: the batch creates it holding only the (empty) set.
	e.seedBookmarks(t, "fresh", 1)
	if err := e.repo.Prune(ctx, "fresh", []string{"0000000000000000001"}); err != nil {
		t.Fatalf("prune without userLikes: %v", err)
	}
	if e.bookmarkExists(t, "fresh", "0000000000000000001") || len(e.bookmarks(t, "fresh")) != 0 {
		t.Error("prune without userLikes left residue")
	}
	// More than a page of ids is refused before any write.
	over := make([]string, MaxListPage+1)
	for i := range over {
		over[i] = fmt.Sprintf("%019d", i+1)
	}
	if err := e.repo.Prune(ctx, bmUID, over); err == nil {
		t.Error("prune of more than MaxListPage ids was accepted")
	}
}
