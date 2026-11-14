package main

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TestPendingNote: a hot post's stored counter prints its plain and pending parts; a cold one prints as before.
func TestPendingNote(t *testing.T) {
	if got := pendingNote(posts.ChildRecount{Stored: 4, Counted: 4}); got != "" {
		t.Fatalf("cold = %q, want nothing", got)
	}
	if got := pendingNote(posts.ChildRecount{Stored: 7, Pending: 2}); got != " (plain 5 + pending 2)" {
		t.Fatalf("hot = %q", got)
	}
}

// pendingBulk is a ChildBulkRecounter whose one post is hot: the posts layer reports Stored = plain + pending.
type pendingBulk struct{ pre, fix posts.ChildRepair }

func (pendingBulk) ScanChildParents(context.Context, time.Time, string, int) ([]posts.ChildParent, error) {
	return nil, nil
}
func (b pendingBulk) CountChildParent(context.Context, posts.ChildParent) (posts.ChildRepair, error) {
	return b.pre, nil
}
func (b pendingBulk) RepairChildCounts(context.Context, string) (posts.ChildRepair, error) {
	return b.fix, nil
}

// TestDecidePost_ComparesPlainPlusPending: the bulk run decides on Stored (plain + pending, computed by the posts layer):
// an in-step hot post whose plain field lags its pending deltas prints nothing and writes nothing; a stale hot post's
// line carries pending=D, and a cold line is unchanged.
func TestDecidePost_ComparesPlainPlusPending(t *testing.T) {
	const pid = "0000000000000000009"
	inStep := pendingBulk{pre: posts.ChildRepair{Replies: posts.ChildRecount{Stored: 5, Pending: 2, Counted: 5}}}
	res, err := decidePost(context.Background(), inStep, bulkRecountArgs{write: true, maxWrites: 10}, posts.ChildParent{ID: pid, Replies: 3}, 0)
	if err != nil || len(res.lines) != 0 || res.stats.Mismatched != 0 || res.stats.Written != 0 {
		t.Fatalf("in-step hot post: %+v, %v", res, err)
	}
	stale := pendingBulk{
		pre: posts.ChildRepair{Replies: posts.ChildRecount{Stored: 7, Pending: 2, Counted: 5}},
		fix: posts.ChildRepair{Replies: posts.ChildRecount{Stored: 7, Pending: 2, Counted: 5, Written: true}},
	}
	res, err = decidePost(context.Background(), stale, bulkRecountArgs{write: true, maxWrites: 10}, posts.ChildParent{ID: pid, Replies: 5}, 0)
	want := "post=" + pid + " field=reply_count stored=7 recounted=5 action=written pending=2"
	if err != nil || len(res.lines) != 1 || res.lines[0] != want || res.stats.Written != 1 {
		t.Fatalf("stale hot post: %+v, %v; want %q", res, err, want)
	}
	cold := pendingBulk{pre: posts.ChildRepair{Quotes: posts.ChildRecount{Stored: 3, Counted: 1}}}
	res, _ = decidePost(context.Background(), cold, bulkRecountArgs{}, posts.ChildParent{ID: pid, Quotes: 3}, 0)
	if want := "post=" + pid + " field=quote_count stored=3 recounted=1 action=dry-run"; len(res.lines) != 1 || res.lines[0] != want {
		t.Fatalf("cold dry-run line = %v, want %q", res.lines, want)
	}
}
