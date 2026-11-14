package posts

import (
	"reflect"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
)

// TestStageChildCounter_Cold: the create path's replyCount / quoteCount +1 with threshold 0 (any known), or known below
// the threshold, is byte-identical to the old bumpReplyCount / bumpCount: one Update of the parent with
// {Path: field, Increment(1)}, nothing else.
func TestStageChildCounter_Cold(t *testing.T) {
	for _, tc := range []struct {
		name             string
		threshold, known int64
	}{
		{"threshold 0, huge count", 0, 1 << 40},
		{"below the threshold", 100, 99},
	} {
		for _, field := range []firestore.FieldPath{replyCountField, quoteCountField} {
			t.Run(tc.name+"/"+field[0], func(t *testing.T) {
				r := NewFirestoreRepo(&firestore.Client{})
				r.SetHotCounterThreshold(tc.threshold)
				b := &counterBatch{}
				r.stageCounter(b, hotPID, field, 1, tc.known)()
				old := &counterBatch{}
				bumpCount(old, r.ref(hotPID), field[0], 1) // what repo_create.go staged before
				if len(b.sets) != 0 || !reflect.DeepEqual(b.updates, old.updates) || !reflect.DeepEqual(b.ups, old.ups) {
					t.Fatalf("staged sets %v updates %v %+v; want exactly %v %+v", b.sets, b.updates, b.ups, old.updates, old.ups)
				}
				if !reflect.DeepEqual(b.ups[0], []firestore.Update{{Path: field[0], Value: firestore.Increment(int64(1))}}) {
					t.Fatalf("ups = %+v", b.ups)
				}
			})
		}
	}
}

// TestStageChildCounter_Hot: known at or above the threshold writes one shard of posts/{parent}/viewShards (the same field
// name) plus the counter marker, and no Update of the parent.
func TestStageChildCounter_Hot(t *testing.T) {
	for _, field := range []firestore.FieldPath{replyCountField, quoteCountField} {
		t.Run(field[0], func(t *testing.T) {
			r := NewFirestoreRepo(&firestore.Client{})
			r.SetHotCounterThreshold(50)
			b := &counterBatch{}
			r.stageCounter(b, hotPID, field, 1, 50)()
			if len(b.updates) != 0 || b.setsWith("/posts/"+hotPID+"/viewShards/") != 1 || b.setsWith("/viewDirty/c") != 1 {
				t.Fatalf("hot child write staged sets %v updates %v; want a shard and a counter marker", b.sets, b.updates)
			}
		})
	}
}

// TestGuardParent_Cold: a cold reply or quote reads nothing in the transaction (a nil tx is never touched), and a root
// post has no parent to guard.
func TestGuardParent_Cold(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	r.SetHotCounterThreshold(100)
	for _, p := range []CreateParams{
		{},
		{ParentID: hotPID, ParentReplyCount: 99},
		{QuoteID: hotPID, QuotedQuoteCount: 0},
		{ParentID: hotPID, ParentReplyCount: 1, QuotedQuoteCount: 1 << 40}, // the reply's own count decides, not the quote's
	} {
		if err := r.guardParent(nil, p); err != nil {
			t.Fatalf("guardParent(%+v) = %v, want nil without a read", p, err)
		}
	}
	off := NewFirestoreRepo(&firestore.Client{}) // threshold 0: even a huge count stays cold
	if err := off.guardParent(nil, CreateParams{ParentID: hotPID, ParentReplyCount: 1 << 40}); err != nil {
		t.Fatalf("threshold 0: %v", err)
	}
}

// TestApplyReplyQuote_KnownCounts: the hot decision of the parent counter write comes from the post the service already
// read (the visibility check), and never enters the request hash (computed before applyReply / applyQuote).
func TestApplyReplyQuote_KnownCounts(t *testing.T) {
	var p CreateParams
	applyReply(&p, &Post{ID: hotPID, ReplyCount: 42, QuoteCount: 7})
	if p.ParentID != hotPID || p.ParentReplyCount != 42 || p.QuotedQuoteCount != 0 {
		t.Fatalf("applyReply: %+v", p)
	}
	var q CreateParams
	applyQuote(&q, &Post{ID: hotPID, ReplyCount: 42, QuoteCount: 7})
	if q.QuoteID != hotPID || q.QuotedQuoteCount != 7 || q.ParentReplyCount != 0 {
		t.Fatalf("applyQuote: %+v", q)
	}
}

// TestCounterFolds_ReplyQuote: the rollup's delta fold moves replyCount and quoteCount from a shard onto the post (the
// shard Increment(-v), the post Increment(+v)), and a shard holding only them is a shard to fold.
func TestCounterFolds_ReplyQuote(t *testing.T) {
	want := map[string]bool{"replyCount": false, "quoteCount": false}
	for _, f := range counterFolds {
		if _, ok := want[f.From[0]]; ok && len(f.From) == 1 && reflect.DeepEqual(f.From, f.To) {
			want[f.From[0]] = true
		}
	}
	if !want["replyCount"] || !want["quoteCount"] {
		t.Fatalf("counterFolds = %v, want replyCount and quoteCount folded onto themselves", counterFolds)
	}
	r := NewFirestoreRepo(&firestore.Client{})
	post := r.ref(hotPID)
	shard := viewShards.ShardRef(post, 2)
	data := map[string]any{"count": int64(4), "replyCount": int64(3), "quoteCount": int64(-1)}
	if !holdsCounters(data) {
		t.Fatal("a shard with only reply/quote deltas must be folded")
	}
	b := &pollBatch{}
	shardcount.StageDeltaFold(b, post, []shardcount.Shard{{Ref: shard, Data: data}}, counterFoldsOf(data)...)
	wantShard := []firestore.Update{
		{FieldPath: replyCountField, Value: firestore.Increment(int64(-3))},
		{FieldPath: quoteCountField, Value: firestore.Increment(int64(1))},
	}
	wantPost := []firestore.Update{
		{FieldPath: replyCountField, Value: firestore.Increment(int64(3))},
		{FieldPath: quoteCountField, Value: firestore.Increment(int64(-1))},
	}
	if !reflect.DeepEqual(b.updPaths, []string{shard.Path, post.Path}) || !reflect.DeepEqual(b.ups, [][]firestore.Update{wantShard, wantPost}) {
		t.Fatalf("fold staged %v %+v\nwant shard %+v\npost %+v", b.updPaths, b.ups, wantShard, wantPost)
	}
}

// TestStageSetCounters_Children: the recount's absolute write of both child counters is ONE post Update (both sets) and
// ONE drain per shard that holds either field (only the non-zero ones), so plain + pending == n after the commit; the
// views field and the engagement fields on the same shard are untouched. No sets stages nothing.
func TestStageSetCounters_Children(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	post := r.ref(hotPID)
	shards := []shardcount.Shard{
		{Ref: viewShards.ShardRef(post, 0), Data: map[string]any{"count": int64(9), "replyCount": int64(2), "likeCount": int64(5)}},
		{Ref: viewShards.ShardRef(post, 1), Data: map[string]any{"replyCount": int64(1), "quoteCount": int64(-1)}},
		{Ref: viewShards.ShardRef(post, 5), Data: map[string]any{"replyCount": int64(0), "shareCount": int64(3)}},
	}
	b := &counterBatch{}
	stageSetCounters(b, post, shards, counterSet{field: replyCountField, n: 6}, counterSet{field: quoteCountField, n: 2})
	wantPaths := []string{post.Path, shards[0].Ref.Path, shards[1].Ref.Path}
	wantUps := [][]firestore.Update{
		{{FieldPath: replyCountField, Value: int64(6)}, {FieldPath: quoteCountField, Value: int64(2)}},
		{{FieldPath: replyCountField, Value: firestore.Increment(int64(-2))}},
		{{FieldPath: replyCountField, Value: firestore.Increment(int64(-1))}, {FieldPath: quoteCountField, Value: firestore.Increment(int64(1))}},
	}
	if len(b.sets) != 0 || !reflect.DeepEqual(b.updates, wantPaths) || !reflect.DeepEqual(b.ups, wantUps) {
		t.Fatalf("updates %v\nups %+v\nwant %v %+v", b.updates, b.ups, wantPaths, wantUps)
	}

	// One field drains only that field (RecountChildren); the other's pending delta stays for the fold.
	b = &counterBatch{}
	stageSetCounter(b, post, shards, quoteCountField, 0)
	if !reflect.DeepEqual(b.updates, []string{post.Path, shards[1].Ref.Path}) ||
		!reflect.DeepEqual(b.ups[1], []firestore.Update{{FieldPath: quoteCountField, Value: firestore.Increment(int64(1))}}) {
		t.Fatalf("one field: %v %+v", b.updates, b.ups)
	}

	b = &counterBatch{}
	if stageSetCounters(b, post, shards); len(b.updates) != 0 {
		t.Fatalf("no sets staged %v", b.updates)
	}
}

// TestStoredCountersOf: plain and pending per field from one GetAll; a missing post is not found.
func TestStoredCountersOf(t *testing.T) {
	if _, _, found, err := storedCountersOf([]*firestore.DocumentSnapshot{nil}, 1, childFields...); found || err != nil {
		t.Fatalf("missing post: found=%v err=%v", found, err)
	}
	if _, _, _, err := storedCountersOf(nil, 1, childFields...); err == nil || !strings.Contains(err.Error(), "documents") {
		t.Fatalf("short read: %v", err)
	}
}

// TestStageDelta_StaysCold: the purge release decrement is a plain Increment on the target whatever
// HOT_COUNTER_THRESHOLD says (the page batch depends on its implicit Exists), byte-identical to before.
func TestStageDelta_StaysCold(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	r.SetHotCounterThreshold(1)
	for _, field := range []string{fieldReplyCount, fieldQuoteCount} {
		b := &counterBatch{}
		r.stageDelta(b, counterDelta{postID: hotPID, field: field, delta: -3})
		want := []firestore.Update{{Path: field, Value: firestore.Increment(int64(-3))}}
		if len(b.sets) != 0 || len(b.updates) != 1 || !strings.HasSuffix(b.updates[0], "/posts/"+hotPID) || !reflect.DeepEqual(b.ups[0], want) {
			t.Fatalf("%s: sets %v updates %v %+v; want the one plain Update", field, b.sets, b.updates, b.ups)
		}
	}
}
