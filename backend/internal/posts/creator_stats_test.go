package posts

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// stagedStat is one identity.StatsWriter call.
type stagedStat struct {
	uid, day, shardKey string
	d                  identity.DailyDelta
}

// recStats is an identity.StatsWriter that records its calls; off is its Off.
type recStats struct {
	calls []stagedStat
	off   bool
}

func (r *recStats) StageDaily(_ store.Batch, uid, day, shardKey string, d identity.DailyDelta) {
	r.calls = append(r.calls, stagedStat{uid, day, shardKey, d})
}

func (r *recStats) Off() bool { return r.off }

func viewTotals(ns ...int64) []shardcount.Totals {
	out := make([]shardcount.Totals, len(ns))
	for i, n := range ns {
		out[i] = shardcount.Totals{shardcount.Key(viewShardField): n}
	}
	return out
}

// sameShard and otherShard are post ids whose dailyStats shard equals / differs from id's.
func shardPeers(t *testing.T, id string) (same, other string) {
	t.Helper()
	for i := 0; same == "" || other == ""; i++ {
		c := "p" + strconv.Itoa(i)
		switch {
		case c == id:
		case identity.StatsShard(c) == identity.StatsShard(id) && same == "":
			same = c
		case identity.StatsShard(c) != identity.StatsShard(id) && other == "":
			other = c
		}
	}
	return same, other
}

// TestImpressionDeltas: new shard total - old viewCount per post, summed per author AND dailyStats shard (the post
// id's) in first-seen order with the group's first post id as shard key, never negative, gone posts left out, and the
// per-post fallback keeps only its post.
func TestImpressionDeltas(t *testing.T) {
	p0 := "p-first"
	same, other := shardPeers(t, p0)
	ids := []string{p0, "pb1", same, "gone", "pc", "pb2", other}
	before := []viewBefore{
		{author: "a", views: 10}, // +5
		{author: "b", views: 4},  // 0: unchanged
		{author: "a", views: 2},  // +1, same shard as p0: one group
		{author: "", views: 0},   // gone
		{author: "c", views: 9},  // lowered (a repair): never negative
		{author: "b", views: 0},  // +7
		{author: "a", views: 0},  // +2, another shard: its own group
	}
	totals := viewTotals(15, 4, 3, 8, 5, 7, 2)
	got := impressionDeltas(before, totals, ids, -1)
	want := []impressionGroup{{"a", p0, 6}, {"b", "pb2", 7}, {"a", other, 2}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("groups = %+v, want %+v", got, want)
	}
	if got := impressionDeltas(before, totals, ids, 2); !reflect.DeepEqual(got, []impressionGroup{{"a", same, 1}}) {
		t.Fatalf("only post 2 = %+v", got)
	}
	// A redelivered fold reads the folded value: nothing.
	if got := impressionDeltas([]viewBefore{{author: "a", views: 15}}, viewTotals(15), []string{p0}, -1); len(got) != 0 {
		t.Fatalf("redelivery staged %v", got)
	}
	if got := impressionDeltas(nil, totals, ids, -1); len(got) != 0 {
		t.Fatal("no before (stats off) staged something")
	}
}

// TestStageImpressions: one Impressions stage per author and shard, on today's day key, and none without Stats.
func TestStageImpressions(t *testing.T) {
	now := time.Date(2026, 11, 15, 19, 0, 0, 0, time.UTC) // already the 16th in IST
	same, _ := shardPeers(t, "x1")
	st := &recStats{}
	r := &FirestoreRepo{now: func() time.Time { return now }}
	r.w.Stats = st
	r.stageImpressions(nil, []viewBefore{{author: "a"}, {author: "a", views: 1}}, viewTotals(2, 3), []string{"x1", same}, -1)
	want := []stagedStat{{"a", "20261116", "x1", identity.DailyDelta{Impressions: 4}}}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
	(&FirestoreRepo{}).stageImpressions(nil, []viewBefore{{author: "a"}}, viewTotals(2), []string{"x1"}, -1) // nil Stats: no panic
}

// TestStatsOn: no Stats or Stats off means no stat-only read (readViewsBefore, releaseParent's parent read).
func TestStatsOn(t *testing.T) {
	r := &FirestoreRepo{}
	if r.statsOn() || !r.StatsOff() {
		t.Fatal("unwired Stats must read as off")
	}
	st := &recStats{off: true}
	r.w.Stats = st
	if r.statsOn() {
		t.Fatal("Stats off must read as off")
	}
	st.off = false
	if !r.statsOn() || r.StatsOff() {
		t.Fatal("Stats on must read as on")
	}
}

// TestEngagementOfShard: likes, reposts, replies and quotes count (undos included); shares, polls and views do not; the
// author's own hot replies and quotes (the self fields) are subtracted.
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
	self := map[string]any{"replyCount": int64(3), "selfReplyCount": int64(2), "quoteCount": int64(1), "selfQuoteCount": int64(1)}
	if got := engagementOfShard(self); got != 1 {
		t.Fatalf("with self fields = %d, want 1 (3 replies - 2 own + 1 quote - 1 own)", got)
	}
}

// recUpdates records the Updates of a batch, by path.
type recUpdates struct {
	store.Batch
	paths []string
	ups   [][]firestore.Update
}

func (r *recUpdates) Update(ref *firestore.DocumentRef, ups []firestore.Update, _ ...firestore.Precondition) store.Batch {
	r.paths = append(r.paths, ref.Path)
	r.ups = append(r.ups, ups)
	return r
}

// TestFoldWithSelf: the delta fold over a shard holding self fields drains them off the shard but never writes them
// onto the post (dropOnParent); replyCount moves in full (the author's own replies are still replies).
func TestFoldWithSelf(t *testing.T) {
	post := (&firestore.Client{}).Collection("posts").Doc("p1")
	shard := viewShards.ShardRef(post, 3)
	data := map[string]any{"replyCount": int64(2), "selfReplyCount": int64(1)}
	rec := &recUpdates{}
	shardcount.StageDeltaFold(dropOnParent{Batch: rec, parent: post.Path}, post, []shardcount.Shard{{Ref: shard, Data: data}}, append(counterFoldsOf(data), selfFolds...)...)
	if len(rec.paths) != 2 || rec.paths[0] != shard.Path || rec.paths[1] != post.Path {
		t.Fatalf("updates on %v, want the shard then the post", rec.paths)
	}
	if len(rec.ups[0]) != 2 {
		t.Fatalf("shard drain = %+v, want replyCount and selfReplyCount", rec.ups[0])
	}
	if len(rec.ups[1]) != 1 || shardcount.Key(rec.ups[1][0].FieldPath) != shardcount.Key(replyCountField) ||
		!reflect.DeepEqual(rec.ups[1][0].Value, firestore.Increment(int64(2))) {
		t.Fatalf("post update = %+v, want replyCount +2 only", rec.ups[1])
	}
	// Only self fields left for the post: no post Update at all.
	rec = &recUpdates{}
	dropOnParent{Batch: rec, parent: post.Path}.Update(post, []firestore.Update{{FieldPath: selfQuoteCountField, Value: 1}})
	if len(rec.paths) != 0 {
		t.Fatalf("an all-self post update was staged: %v", rec.paths)
	}
}

// TestStageSetCountersDrainsSelf: a repair of replyCount drains selfReplyCount with it (and leaves selfQuoteCount).
func TestStageSetCountersDrainsSelf(t *testing.T) {
	post := (&firestore.Client{}).Collection("posts").Doc("p1")
	shard := viewShards.ShardRef(post, 0)
	rec := &recUpdates{}
	stageSetCounter(rec, post, []shardcount.Shard{{Ref: shard, Data: map[string]any{
		"replyCount": int64(3), "selfReplyCount": int64(1), "selfQuoteCount": int64(1),
	}}}, replyCountField, 9)
	if len(rec.ups) != 2 || len(rec.ups[1]) != 2 || shardcount.Key(rec.ups[1][1].FieldPath) != shardcount.Key(selfReplyCountField) {
		t.Fatalf("updates = %+v, want the post set and a shard drain of replyCount and selfReplyCount", rec.ups)
	}
}

// TestStageEngagementStat: the reply / quote stat goes to the post author with the delta, sharded by the actor, never
// for the author's own engagement, never without an author or without Stats.
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
		{"author", "20261115", "replier", identity.DailyDelta{Engagements: 1}},
		{"author", "20261115", "replier", identity.DailyDelta{Engagements: -1}},
	}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
	(&FirestoreRepo{}).stageEngagementStat(nil, "author", "x", 1) // nil Stats: no panic
}
