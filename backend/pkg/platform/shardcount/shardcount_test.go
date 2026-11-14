package shardcount

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// recBatch is a store.Batch that records what was staged.
type recBatch struct {
	sets    []recSet
	updates []recUpdate
	deletes []string
}

type recSet struct {
	path string
	data any
	opts []firestore.SetOption
}

type recUpdate struct {
	path    string
	updates []firestore.Update
}

func (b *recBatch) Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) store.Batch {
	b.sets = append(b.sets, recSet{path: ref.Path, data: data, opts: opts})
	return b
}
func (b *recBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return b }
func (b *recBatch) Update(ref *firestore.DocumentRef, u []firestore.Update, _ ...firestore.Precondition) store.Batch {
	b.updates = append(b.updates, recUpdate{path: ref.Path, updates: u})
	return b
}
func (b *recBatch) Delete(ref *firestore.DocumentRef, _ ...firestore.Precondition) store.Batch {
	b.deletes = append(b.deletes, ref.Path)
	return b
}

func parent() *firestore.DocumentRef { return (&firestore.Client{}).Collection("posts").Doc("p1") }

func TestNew_Validates(t *testing.T) {
	for _, tc := range []struct {
		name   string
		sub    string
		shards int
		ok     bool
	}{
		{"ok", "viewShards", 10, true},
		{"one shard", "s", 1, true},
		{"max", "s", MaxShards, true},
		{"empty sub", "", 10, false},
		{"slash", "a/b", 10, false},
		{"zero", "s", 0, false},
		{"too many", "s", MaxShards + 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := New(tc.sub, tc.shards)
			if (err == nil) != tc.ok {
				t.Fatalf("New(%q, %d) err = %v, want ok=%v", tc.sub, tc.shards, err, tc.ok)
			}
			if tc.ok && (c.Sub() != tc.sub || c.Shards() != tc.shards) {
				t.Errorf("got %q/%d", c.Sub(), c.Shards())
			}
		})
	}
}

func TestMustNew_Panics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("MustNew with 0 shards did not panic")
		}
	}()
	MustNew("s", 0)
}

func TestRefs_Layout(t *testing.T) {
	c := MustNew("viewShards", 3)
	var got []string
	for _, r := range c.Refs(parent()) {
		got = append(got, r.Path)
	}
	want := []string{"posts/p1/viewShards/0", "posts/p1/viewShards/1", "posts/p1/viewShards/2"}
	// Ref.Path carries the project prefix of a zero client; compare the suffix.
	for i := range want {
		if len(got) != len(want) || !hasSuffix(got[i], want[i]) {
			t.Fatalf("Refs = %v, want suffixes %v", got, want)
		}
	}
}

func hasSuffix(s, suf string) bool { return len(s) >= len(suf) && s[len(s)-len(suf):] == suf }

// TestPick_Distribution: with the default source every shard is used and none is starved (10 shards, 20,000 picks:
// each expected 2,000; the bound 1,500..2,500 is many standard deviations wide, so the test is not flaky).
func TestPick_Distribution(t *testing.T) {
	c := MustNew("s", 10)
	counts := make([]int, 10)
	for range 20_000 {
		i := c.Pick()
		if i < 0 || i >= 10 {
			t.Fatalf("Pick() = %d, out of range", i)
		}
		counts[i]++
	}
	for i, n := range counts {
		if n < 1500 || n > 2500 {
			t.Errorf("shard %d got %d picks, want about 2000 (counts %v)", i, n, counts)
		}
	}
}

func TestPick_InjectedSourceAndClamp(t *testing.T) {
	for _, tc := range []struct{ src, want int }{{3, 3}, {10, 0}, {13, 3}, {-1, 9}, {-11, 9}} {
		c := MustNew("s", 10, WithIntN(func(int) int { return tc.src }))
		if got := c.Pick(); got != tc.want {
			t.Errorf("source %d: Pick() = %d, want %d", tc.src, got, tc.want)
		}
	}
}

func TestStageIncrement_OneMergeSetOnTheChosenShard(t *testing.T) {
	c := MustNew("viewShards", 10, WithIntN(func(int) int { return 7 }))
	b := &recBatch{}
	if got := c.StageIncrement(b, parent(), Delta{Field: firestore.FieldPath{"count"}, N: 1}); got != 7 {
		t.Fatalf("shard = %d, want 7", got)
	}
	if len(b.sets) != 1 || len(b.updates) != 0 || len(b.deletes) != 0 {
		t.Fatalf("staged %+v, want exactly one Set", b)
	}
	s := b.sets[0]
	if !hasSuffix(s.path, "posts/p1/viewShards/7") {
		t.Errorf("path = %s", s.path)
	}
	if len(s.opts) != 1 || !reflect.DeepEqual(s.opts[0], firestore.MergeAll) {
		t.Errorf("opts = %v, want MergeAll", s.opts)
	}
	want := map[string]any{"count": firestore.Increment(int64(1))}
	if !reflect.DeepEqual(s.data, want) {
		t.Errorf("data = %#v, want %#v", s.data, want)
	}
}

// TestStageIncrement_NestedAndMerged is the poll-vote shape: two fields in one write, numeric map keys kept as keys,
// and deltas on the same field added up.
func TestStageIncrement_NestedAndMerged(t *testing.T) {
	c := MustNew("pollShards", 4, WithIntN(func(int) int { return 0 }))
	b := &recBatch{}
	c.StageIncrement(b, parent(),
		Delta{Field: firestore.FieldPath{"poll", "counts", "2"}, N: 1},
		Delta{Field: firestore.FieldPath{"poll", "counts", "0"}, N: -1},
		Delta{Field: firestore.FieldPath{"poll", "total"}, N: 1},
		Delta{Field: firestore.FieldPath{"poll", "counts", "2"}, N: 1},
	)
	want := map[string]any{"poll": map[string]any{
		"counts": map[string]any{"2": firestore.Increment(int64(2)), "0": firestore.Increment(int64(-1))},
		"total":  firestore.Increment(int64(1)),
	}}
	if len(b.sets) != 1 || !reflect.DeepEqual(b.sets[0].data, want) {
		t.Fatalf("data = %#v, want %#v", b.sets, want)
	}
}

func TestStageIncrement_NoDeltasNoWrite(t *testing.T) {
	b := &recBatch{}
	if got := MustNew("s", 2).StageIncrement(b, parent()); got != -1 || len(b.sets) != 0 {
		t.Fatalf("got %d with %d sets, want -1 and none", got, len(b.sets))
	}
}

func TestStageDelete_AllShardsBlind(t *testing.T) {
	b := &recBatch{}
	MustNew("viewShards", 10).StageDelete(b, parent())
	if len(b.deletes) != 10 || !hasSuffix(b.deletes[9], "posts/p1/viewShards/9") {
		t.Fatalf("deletes = %v, want the 10 shards", b.deletes)
	}
}

// TestSum is the rollup math: totals over the shards that exist, nested fields, missing and non-integer values as 0.
func TestSum(t *testing.T) {
	count := firestore.FieldPath{"count"}
	total := firestore.FieldPath{"poll", "total"}
	c2 := firestore.FieldPath{"poll", "counts", "2"}
	docs := []map[string]any{
		{"count": int64(3), "poll": map[string]any{"total": int64(1), "counts": map[string]any{"2": int64(1)}}},
		nil, // a missing shard
		{"count": int64(4)},
		{"count": "seven", "poll": "not a map"},
		{"count": 2}, // an int (a fake), counted
	}
	got := Sum(docs, count, total, c2, firestore.FieldPath{"absent"})
	if got.Get(count) != 9 || got.Get(total) != 1 || got.Get(c2) != 1 || got.Get(firestore.FieldPath{"absent"}) != 0 {
		t.Fatalf("Sum = %v", got)
	}
	if Key(firestore.FieldPath{"a.b"}) == Key(firestore.FieldPath{"a", "b"}) {
		t.Error("Key must not confuse a dotted name with a nested path")
	}
	if n := Sum(nil, count).Get(count); n != 0 {
		t.Errorf("Sum(nil) = %d, want 0", n)
	}
}

func TestFoldUpdates_AbsoluteAndIdempotent(t *testing.T) {
	tot := Totals{Key(firestore.FieldPath{"count"}): 42, Key(firestore.FieldPath{"neg"}): -3}
	folds := []Fold{
		{From: firestore.FieldPath{"count"}, To: firestore.FieldPath{"viewCount"}},
		{From: firestore.FieldPath{"neg"}, To: firestore.FieldPath{"other"}},
	}
	first := FoldUpdates(tot, folds...)
	want := []firestore.Update{
		{FieldPath: firestore.FieldPath{"viewCount"}, Value: int64(42)},
		{FieldPath: firestore.FieldPath{"other"}, Value: int64(0)},
	}
	if !reflect.DeepEqual(first, want) {
		t.Fatalf("FoldUpdates = %#v, want %#v", first, want)
	}
	if again := FoldUpdates(tot, folds...); !reflect.DeepEqual(again, first) {
		t.Error("a repeated fold must write the same values (redelivery)")
	}
	b := &recBatch{}
	StageFold(b, parent(), tot, folds...)
	StageFold(b, parent(), tot)
	if len(b.updates) != 1 || !reflect.DeepEqual(b.updates[0].updates, want) {
		t.Fatalf("StageFold staged %+v", b.updates)
	}
}

// fakeGetter answers GetAll with zero snapshots (missing documents) or an error, and records the refs it was asked for.
type fakeGetter struct {
	refs  int
	err   error
	short bool
}

func (g *fakeGetter) GetAll(_ context.Context, refs []*firestore.DocumentRef) ([]*firestore.DocumentSnapshot, error) {
	g.refs = len(refs)
	if g.err != nil {
		return nil, g.err
	}
	out := make([]*firestore.DocumentSnapshot, len(refs))
	for i := range out {
		out[i] = &firestore.DocumentSnapshot{Ref: refs[i]}
	}
	if g.short {
		out = out[1:]
	}
	return out, nil
}

func TestRead(t *testing.T) {
	c := MustNew("viewShards", 10)
	client := &firestore.Client{}
	ps := []*firestore.DocumentRef{client.Collection("posts").Doc("a"), client.Collection("posts").Doc("b")}
	g := &fakeGetter{}
	got, err := c.Read(context.Background(), g, ps, firestore.FieldPath{"count"})
	if err != nil || len(got) != 2 || got[0].Get(firestore.FieldPath{"count"}) != 0 || g.refs != 20 {
		t.Fatalf("Read = %v, %v (refs %d), want two zero totals from one GetAll of 20", got, err, g.refs)
	}
	if got, err := c.Read(context.Background(), g, nil); got != nil || err != nil {
		t.Errorf("Read(no parents) = %v, %v", got, err)
	}
	many := make([]*firestore.DocumentRef, MaxReadDocs/10+1)
	for i := range many {
		many[i] = ps[0]
	}
	g2 := &fakeGetter{}
	if _, err := c.Read(context.Background(), g2, many); !errors.Is(err, ErrTooManyDocs) || g2.refs != 0 {
		t.Errorf("Read over the bound = %v (refs %d), want ErrTooManyDocs before any read", err, g2.refs)
	}
	boom := errors.New("boom")
	if _, err := c.Read(context.Background(), &fakeGetter{err: boom}, ps); !errors.Is(err, boom) {
		t.Errorf("Read error = %v, want wrapped boom", err)
	}
	if _, err := c.Read(context.Background(), &fakeGetter{short: true}, ps); err == nil {
		t.Error("a short GetAll answer must be an error")
	}
}
