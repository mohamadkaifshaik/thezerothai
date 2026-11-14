package posts

import (
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// stagedStat is one identity.StatsWriter call.
type stagedStat struct {
	uid, day string
	d        identity.DailyDelta
}

// recStats is an identity.StatsWriter that records its calls.
type recStats struct{ calls []stagedStat }

func (r *recStats) StageDaily(_ store.Batch, uid, day string, d identity.DailyDelta) {
	r.calls = append(r.calls, stagedStat{uid, day, d})
}

func viewTotals(ns ...int64) []shardcount.Totals {
	out := make([]shardcount.Totals, len(ns))
	for i, n := range ns {
		out[i] = shardcount.Totals{shardcount.Key(viewShardField): n}
	}
	return out
}

// TestImpressionDeltas: new shard total - old viewCount per post, summed per author in first-seen order, never
// negative, gone posts (no author) left out, and the per-post fallback keeps only its post.
func TestImpressionDeltas(t *testing.T) {
	before := []viewBefore{
		{author: "a", views: 10}, // +5
		{author: "b", views: 4},  // 0: unchanged
		{author: "a", views: 2},  // +1
		{author: "", views: 0},   // gone
		{author: "c", views: 9},  // lowered (a repair): never negative
		{author: "b", views: 0},  // +7
	}
	totals := viewTotals(15, 4, 3, 8, 5, 7)
	authors, sums := impressionDeltas(before, totals, -1)
	if !reflect.DeepEqual(authors, []string{"a", "b"}) || sums["a"] != 6 || sums["b"] != 7 || sums["c"] != 0 {
		t.Fatalf("authors %v sums %v, want [a b] a=6 b=7", authors, sums)
	}
	authors, sums = impressionDeltas(before, totals, 2)
	if !reflect.DeepEqual(authors, []string{"a"}) || sums["a"] != 1 {
		t.Fatalf("only post 2: authors %v sums %v, want a=1", authors, sums)
	}
	// A redelivered fold reads the folded value: nothing.
	if authors, _ := impressionDeltas([]viewBefore{{author: "a", views: 15}}, viewTotals(15), -1); len(authors) != 0 {
		t.Fatalf("redelivery staged %v", authors)
	}
	if authors, _ := impressionDeltas(nil, totals, -1); len(authors) != 0 {
		t.Fatal("no before (stats not wired) staged something")
	}
}

// TestStageImpressions: one Impressions stage per author, on today's day key, and none without Stats.
func TestStageImpressions(t *testing.T) {
	now := time.Date(2026, 11, 15, 19, 0, 0, 0, time.UTC) // already the 16th in IST
	st := &recStats{}
	r := &FirestoreRepo{now: func() time.Time { return now }}
	r.w.Stats = st
	r.stageImpressions(nil, []viewBefore{{author: "a"}, {author: "a", views: 1}}, viewTotals(2, 3), -1)
	want := []stagedStat{{"a", "20261116", identity.DailyDelta{Impressions: 4}}}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
	(&FirestoreRepo{}).stageImpressions(nil, []viewBefore{{author: "a"}}, viewTotals(2), -1) // nil Stats: no panic
}

// TestEngagementOfShard: likes, reposts, replies and quotes count (undos included); shares, polls and views do not.
func TestEngagementOfShard(t *testing.T) {
	data := map[string]any{
		"count": int64(50), "likeCount": int64(3), "repostCount": int64(-1), "replyCount": int64(2), "quoteCount": int64(1),
		"shareCount": int64(9), "poll": map[string]any{"total": int64(4)},
	}
	if got := engagementOfShard(data); got != 5 {
		t.Fatalf("engagementOfShard = %d, want 5", got)
	}
	if got := engagementOfShard(map[string]any{"count": int64(7), "shareCount": int64(2)}); got != 0 {
		t.Fatalf("views and shares only = %d, want 0", got)
	}
}

// TestStageEngagementStat: the reply / quote stat goes to the post author with the delta, never for the author's own
// engagement, never without an author or without Stats.
func TestStageEngagementStat(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	st := &recStats{}
	r := &FirestoreRepo{now: func() time.Time { return now }}
	r.w.Stats = st
	r.stageEngagementStat(nil, "author", "replier", 1)
	r.stageEngagementStat(nil, "author", "replier", -1) // delete reply: the undo
	r.stageEngagementStat(nil, "author", "author", 1)   // self-reply thread
	r.stageEngagementStat(nil, "", "replier", 1)        // unknown author
	want := []stagedStat{
		{"author", "20261115", identity.DailyDelta{Engagements: 1}},
		{"author", "20261115", identity.DailyDelta{Engagements: -1}},
	}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
	(&FirestoreRepo{}).stageEngagementStat(nil, "author", "x", 1) // nil Stats: no panic
}
