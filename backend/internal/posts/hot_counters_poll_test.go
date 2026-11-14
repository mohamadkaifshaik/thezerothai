package posts

import (
	"reflect"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// pollBatch records every staged write with its data (the shard Set's nested Increment map) and its Updates.
type pollBatch struct {
	setPaths []string
	setData  []any
	updPaths []string
	ups      [][]firestore.Update
}

func (b *pollBatch) Set(ref *firestore.DocumentRef, data interface{}, _ ...firestore.SetOption) store.Batch {
	b.setPaths = append(b.setPaths, ref.Path)
	b.setData = append(b.setData, data)
	return b
}
func (b *pollBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return b }
func (b *pollBatch) Update(ref *firestore.DocumentRef, u []firestore.Update, _ ...firestore.Precondition) store.Batch {
	b.updPaths = append(b.updPaths, ref.Path)
	b.ups = append(b.ups, u)
	return b
}
func (b *pollBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return b }

func (b *pollBatch) setsWith(part string) []int {
	var out []int
	for i, p := range b.setPaths {
		if strings.Contains(p, part) {
			out = append(out, i)
		}
	}
	return out
}

// pollStage is one of the two poll counter writers with fixed choices: a vote for 2, a change 0 -> 3.
type pollStage struct {
	name  string
	stage func(r *FirestoreRepo, b store.Batch, known int64) func()
	// cold is the plain Update of the post; shard is the nested Increment map of the hot shard write.
	cold  []firestore.Update
	shard map[string]any
}

func pollStages() []pollStage {
	return []pollStage{
		{
			name:  "vote",
			stage: func(r *FirestoreRepo, b store.Batch, known int64) func() { return r.StagePollVote(b, hotPID, 2, known) },
			cold: []firestore.Update{
				{FieldPath: firestore.FieldPath{"poll", "counts", "2"}, Value: firestore.Increment(1)},
				{FieldPath: firestore.FieldPath{"poll", "total"}, Value: firestore.Increment(1)},
			},
			shard: map[string]any{"poll": map[string]any{
				"counts": map[string]any{"2": firestore.Increment(int64(1))}, "total": firestore.Increment(int64(1)),
			}},
		},
		{
			name: "change",
			stage: func(r *FirestoreRepo, b store.Batch, known int64) func() {
				return r.StagePollChange(b, hotPID, 0, 3, known)
			},
			cold: []firestore.Update{
				{FieldPath: firestore.FieldPath{"poll", "counts", "0"}, Value: firestore.Increment(-1)},
				{FieldPath: firestore.FieldPath{"poll", "counts", "3"}, Value: firestore.Increment(1)},
			},
			shard: map[string]any{"poll": map[string]any{
				"counts": map[string]any{"0": firestore.Increment(int64(-1)), "3": firestore.Increment(int64(1))},
			}},
		},
	}
}

// TestStagePoll_Cold: threshold 0 (any known), or known below the threshold, is exactly today's write: one Update of the
// post by FieldPath (numeric keys never parsed as dotted strings), no shard, no marker.
func TestStagePoll_Cold(t *testing.T) {
	for _, tc := range []struct {
		name             string
		threshold, known int64
	}{
		{"threshold 0, huge total", 0, 1 << 40},
		{"below the threshold", 100, 99},
		{"no total read", 100, 0},
	} {
		for _, ps := range pollStages() {
			t.Run(tc.name+"/"+ps.name, func(t *testing.T) {
				r := NewFirestoreRepo(&firestore.Client{})
				r.SetHotCounterThreshold(tc.threshold)
				b := &pollBatch{}
				ps.stage(r, b, tc.known)()
				if len(b.setPaths) != 0 || len(b.updPaths) != 1 || !strings.HasSuffix(b.updPaths[0], "/posts/"+hotPID) || !reflect.DeepEqual(b.ups[0], ps.cold) {
					t.Fatalf("sets %v updates %v %v; want the one plain Update %v", b.setPaths, b.updPaths, b.ups, ps.cold)
				}
			})
		}
	}
}

// TestStagePoll_Hot: known at or above the threshold writes ONE shard of posts/{id}/viewShards that moves the poll
// fields together (a vote: counts.<n> and total; a change: -1 and +1 on two counts) plus the counter marker, and no
// Update of the post.
func TestStagePoll_Hot(t *testing.T) {
	for _, ps := range pollStages() {
		t.Run(ps.name, func(t *testing.T) {
			r := NewFirestoreRepo(&firestore.Client{})
			r.SetHotCounterThreshold(100)
			b := &pollBatch{}
			ps.stage(r, b, 100)()
			shards := b.setsWith("/posts/" + hotPID + "/viewShards/")
			if len(b.updPaths) != 0 || len(shards) != 1 || len(b.setsWith("/viewDirty/c")) != 1 {
				t.Fatalf("sets %v updates %v; want one shard write and one counter marker", b.setPaths, b.updPaths)
			}
			if got := b.setData[shards[0]]; !reflect.DeepEqual(got, ps.shard) {
				t.Fatalf("shard data = %#v, want %#v", got, ps.shard)
			}
		})
	}
}

// TestCounterFoldsOf: the fixed folds plus one per poll.counts key the shard holds, whatever the key, in key order.
func TestCounterFoldsOf(t *testing.T) {
	if got := counterFoldsOf(map[string]any{"count": int64(3), "likeCount": int64(1)}); !reflect.DeepEqual(got, counterFolds) {
		t.Fatalf("no poll: %v, want the fixed folds", got)
	}
	got := counterFoldsOf(map[string]any{"poll": map[string]any{"counts": map[string]any{"3": int64(1), "0": int64(2), "9": int64(0)}}})
	var keys []string
	for _, f := range got[len(counterFolds):] {
		if len(f.From) != 3 || f.From[0] != "poll" || f.From[1] != "counts" || !reflect.DeepEqual(f.From, f.To) {
			t.Fatalf("poll fold %v, want poll.counts.<k> -> the same field", f)
		}
		keys = append(keys, f.From[2])
	}
	if !reflect.DeepEqual(keys, []string{"0", "3", "9"}) {
		t.Fatalf("poll fold keys = %v, want every key present, sorted", keys)
	}
}

// TestFoldCounterShard_PollDeltas: a shard that holds ONLY poll deltas (a vote for 0, then a change 1 -> 0 and a vote for
// 3, the -1 left on choice 1) is a shard to fold, and the delta fold moves exactly what it holds: the post gets
// Increment(+v) on each poll.counts.<n> and poll.total, the shard Increment(-v) on the same fields; the views field and
// a zero key are never written. A redelivered fold that reads the shard at 0 stages nothing.
func TestFoldCounterShard_PollDeltas(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	post := r.ref(hotPID)
	shard := viewShards.ShardRef(post, 4)
	data := map[string]any{"count": int64(9), "poll": map[string]any{
		"counts": map[string]any{"0": int64(2), "1": int64(-1), "2": int64(0), "3": int64(1)}, "total": int64(2),
	}}
	if !holdsCounters(data) {
		t.Fatal("a shard with only poll deltas must be folded (else its marker is deleted with the deltas on it)")
	}
	b := &pollBatch{}
	shardcount.StageDeltaFold(b, post, []shardcount.Shard{{Ref: shard, Data: data}}, counterFoldsOf(data)...)
	c := func(k string) firestore.FieldPath { return firestore.FieldPath{"poll", "counts", k} }
	wantShard := []firestore.Update{
		{FieldPath: pollTotalField, Value: firestore.Increment(int64(-2))},
		{FieldPath: c("0"), Value: firestore.Increment(int64(-2))},
		{FieldPath: c("1"), Value: firestore.Increment(int64(1))},
		{FieldPath: c("3"), Value: firestore.Increment(int64(-1))},
	}
	wantPost := []firestore.Update{
		{FieldPath: pollTotalField, Value: firestore.Increment(int64(2))},
		{FieldPath: c("0"), Value: firestore.Increment(int64(2))},
		{FieldPath: c("1"), Value: firestore.Increment(int64(-1))},
		{FieldPath: c("3"), Value: firestore.Increment(int64(1))},
	}
	if !reflect.DeepEqual(b.updPaths, []string{shard.Path, post.Path}) || !reflect.DeepEqual(b.ups, [][]firestore.Update{wantShard, wantPost}) {
		t.Fatalf("fold staged %v %+v\nwant shard %+v\npost %+v", b.updPaths, b.ups, wantShard, wantPost)
	}

	zeroed := map[string]any{"count": int64(9), "poll": map[string]any{
		"counts": map[string]any{"0": int64(0), "1": int64(0), "3": int64(0)}, "total": int64(0),
	}}
	if holdsCounters(zeroed) {
		t.Fatal("a drained shard holds nothing")
	}
	b = &pollBatch{}
	if _, staged := shardcount.StageDeltaFold(b, post, []shardcount.Shard{{Ref: shard, Data: zeroed}}, counterFoldsOf(zeroed)...); staged || len(b.updPaths) != 0 {
		t.Fatalf("redelivered fold staged %v", b.updPaths)
	}
}
