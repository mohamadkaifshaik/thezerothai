//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// snowID is a post id of millisecond t with sequence seq, so id order is createdAt order as in production.
func snowID(t *testing.T, at time.Time, seq int64) string {
	t.Helper()
	v, err := strconv.ParseInt(snowflake.MinID(at), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%019d", v+seq)
}

// seedChild writes one posts doc: kind, createdAt from the id, the two stored counters and an optional reply / quote target.
func seedChild(t *testing.T, client *firestore.Client, id string, kind Kind, replies, quotes int64, replyTo, quoteOf string) {
	t.Helper()
	at, err := snowflake.Time(id)
	if err != nil {
		t.Fatal(err)
	}
	d := map[string]any{"authorId": "uid-bulk", "kind": string(kind), "createdAt": at, "replyCount": replies, "quoteCount": quotes}
	if replyTo != "" {
		d["replyToId"], d["isReply"] = replyTo, true
	}
	if quoteOf != "" {
		d["quoteOfId"] = quoteOf
	}
	if _, err := client.Collection(postsCollection).Doc(id).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

// TestScanChildParents_Integration: the scan returns only posts created before the bound, in id order, resumes exactly
// after a post id, and projects kind and the two counters.
func TestScanChildParents_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	cut := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	old1, old2, old3 := snowID(t, cut.Add(-3*time.Hour), 0), snowID(t, cut.Add(-2*time.Hour), 0), snowID(t, cut.Add(-time.Millisecond), 5)
	atCut, newer := snowID(t, cut, 0), snowID(t, cut.Add(time.Hour), 0)
	seedChild(t, client, old1, KindPost, 4, 1, "", "")
	seedChild(t, client, old2, KindRepost, 0, 0, "", "")
	seedChild(t, client, old3, KindQuote, 0, 0, "", "")
	seedChild(t, client, atCut, KindPost, 0, 0, "", "")
	seedChild(t, client, newer, KindPost, 0, 0, "", "")

	got, err := repo.ScanChildParents(ctx, cut, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	want := []ChildParent{{ID: old1, Kind: KindPost, Replies: 4, Quotes: 1}, {ID: old2, Kind: KindRepost}, {ID: old3, Kind: KindQuote}}
	if len(got) != len(want) {
		t.Fatalf("scan = %+v, want %+v (createdAt >= before excluded)", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("scan[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
	page, err := repo.ScanChildParents(ctx, cut, "", 2)
	if err != nil || len(page) != 2 || page[1].ID != old2 {
		t.Fatalf("page of 2 = %+v, %v", page, err)
	}
	rest, err := repo.ScanChildParents(ctx, cut, page[1].ID, 2)
	if err != nil || len(rest) != 1 || rest[0].ID != old3 {
		t.Fatalf("resumed page = %+v, %v; want exactly [%s]", rest, err, old3)
	}
	if _, err := repo.ScanChildParents(ctx, time.Time{}, "", 0); err == nil {
		t.Fatal("a zero before bound was accepted")
	}
	if _, err := repo.ScanChildParents(ctx, cut, "../x", 0); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("bad after = %v, want ErrInvalidID", err)
	}
}

// TestRepairChildCounts_Integration: the count compares without writing; the repair writes only the stale counter, never a
// REPOST, and reports a missing post as ErrNotFound without creating it.
func TestRepairChildCounts_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	target, repost, inStep := snowID(t, base, 0), snowID(t, base, 1), snowID(t, base, 2)
	seedChild(t, client, target, KindPost, 9, 1, "", "")
	seedChild(t, client, repost, KindRepost, 0, 0, "", "")
	seedChild(t, client, inStep, KindPost, 1, 0, "", "")
	seedChild(t, client, snowID(t, base, 10), KindReply, 0, 0, target, "")
	seedChild(t, client, snowID(t, base, 11), KindReply, 0, 0, target, "")
	seedChild(t, client, snowID(t, base, 12), KindQuote, 0, 0, "", target)
	seedChild(t, client, snowID(t, base, 13), KindReply, 0, 0, inStep, "")

	c, err := repo.CountChildParent(ctx, ChildParent{ID: target, Kind: KindPost, Replies: 9, Quotes: 1})
	if err != nil || c.Replies != (ChildRecount{Stored: 9, Counted: 2}) || c.Quotes != (ChildRecount{Stored: 1, Counted: 1}) || !c.Stale() || c.Reads != 2 {
		t.Fatalf("count = %+v, %v", c, err)
	}
	if r, _ := counts(t, client, target); r != 9 {
		t.Fatalf("the count wrote replyCount = %d", r)
	}
	if c, err := repo.CountChildParent(ctx, ChildParent{ID: repost, Kind: KindRepost}); err != nil || !c.Repost || c.Reads != 0 {
		t.Fatalf("repost count = %+v, %v; want skipped", c, err)
	}

	got, err := repo.RepairChildCounts(ctx, target)
	if err != nil || !got.Replies.Written || got.Quotes.Written || got.Replies.Counted != 2 || got.Reads != 3 {
		t.Fatalf("repair = %+v, %v; want replyCount written only, 3 reads", got, err)
	}
	if r, q := counts(t, client, target); r != 2 || q != 1 {
		t.Fatalf("after repair counts = %d, %d; want 2, 1", r, q)
	}
	before := updateTime(t, client, inStep)
	if got, err := repo.RepairChildCounts(ctx, inStep); err != nil || got.Wrote() || got.Stale() {
		t.Fatalf("in-step repair = %+v, %v; want no write", got, err)
	}
	if !updateTime(t, client, inStep).Equal(before) {
		t.Fatal("an in-step repair wrote the post")
	}
	if got, err := repo.RepairChildCounts(ctx, repost); err != nil || !got.Repost || got.Wrote() {
		t.Fatalf("repost repair = %+v, %v", got, err)
	}
	missing := snowID(t, base, 99)
	if _, err := repo.RepairChildCounts(ctx, missing); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing = %v, want ErrNotFound", err)
	}
	if !postGone(t, client, missing) {
		t.Fatal("the repair created the missing post")
	}
}

func updateTime(t *testing.T, client *firestore.Client, id string) time.Time {
	t.Helper()
	snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return snap.UpdateTime
}
