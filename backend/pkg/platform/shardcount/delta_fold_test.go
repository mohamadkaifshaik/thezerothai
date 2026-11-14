package shardcount

import (
	"reflect"
	"testing"

	"cloud.google.com/go/firestore"
)

var (
	likeShard  = firestore.FieldPath{"likeCount"}
	shareShard = firestore.FieldPath{"shareCount"}
	deltaFolds = []Fold{{From: likeShard, To: likeShard}, {From: shareShard, To: shareShard}}
)

// TestStageDeltaFold: the parent gets Increment(+sum) per field, every shard Increment(-v) by the value read (negative
// values included), zero values and the views field are never written, and a fold of zeroed shards stages nothing.
func TestStageDeltaFold(t *testing.T) {
	c := MustNew("viewShards", 4)
	p := parent()
	shards := []Shard{
		{Ref: c.ShardRef(p, 0), Data: map[string]any{"count": int64(9), "likeCount": int64(3)}},
		{Ref: c.ShardRef(p, 2), Data: map[string]any{"likeCount": int64(-1), "shareCount": int64(2)}},
		{Ref: c.ShardRef(p, 3), Data: map[string]any{"count": int64(4), "likeCount": int64(0)}},
	}
	b := &recBatch{}
	tot, staged := StageDeltaFold(b, p, shards, deltaFolds...)
	if !staged || tot.Get(likeShard) != 2 || tot.Get(shareShard) != 2 {
		t.Fatalf("totals = %v staged %v, want like 2 share 2", tot, staged)
	}
	want := []recUpdate{
		{path: c.ShardRef(p, 0).Path, updates: []firestore.Update{{FieldPath: likeShard, Value: firestore.Increment(int64(-3))}}},
		{path: c.ShardRef(p, 2).Path, updates: []firestore.Update{
			{FieldPath: likeShard, Value: firestore.Increment(int64(1))},
			{FieldPath: shareShard, Value: firestore.Increment(int64(-2))},
		}},
		{path: p.Path, updates: []firestore.Update{
			{FieldPath: likeShard, Value: firestore.Increment(int64(2))},
			{FieldPath: shareShard, Value: firestore.Increment(int64(2))},
		}},
	}
	if !reflect.DeepEqual(b.updates, want) {
		t.Fatalf("updates = %+v\nwant %+v", b.updates, want)
	}
	if len(b.sets) != 0 || len(b.deletes) != 0 {
		t.Fatalf("unexpected sets %v deletes %v", b.sets, b.deletes)
	}

	// A redelivered fold reads the shards at 0 (and views untouched): nothing is staged, the parent is not written.
	zeroed := []Shard{
		{Ref: c.ShardRef(p, 0), Data: map[string]any{"count": int64(9), "likeCount": int64(0)}},
		{Ref: c.ShardRef(p, 2), Data: map[string]any{"likeCount": int64(0), "shareCount": int64(0)}},
	}
	b = &recBatch{}
	if _, staged := StageDeltaFold(b, p, zeroed, deltaFolds...); staged || len(b.updates) != 0 {
		t.Fatalf("redelivery staged %v: %+v", staged, b.updates)
	}
}

// TestStageDeltaFold_NetZeroStillDrainsShards: +1 on one shard and -1 on another sum to 0: the parent is not written, but
// both shards are brought back to 0.
func TestStageDeltaFold_NetZeroStillDrainsShards(t *testing.T) {
	c := MustNew("viewShards", 2)
	p := parent()
	b := &recBatch{}
	_, staged := StageDeltaFold(b, p, []Shard{
		{Ref: c.ShardRef(p, 0), Data: map[string]any{"likeCount": int64(1)}},
		{Ref: c.ShardRef(p, 1), Data: map[string]any{"likeCount": int64(-1)}},
	}, deltaFolds...)
	if !staged || len(b.updates) != 2 {
		t.Fatalf("staged %v, updates %+v; want the two shard drains only", staged, b.updates)
	}
	for _, u := range b.updates {
		if u.path == p.Path {
			t.Fatal("a net-zero fold must not write the parent")
		}
	}
}

// TestStageDeltaFold_DuplicateFromDecrementsOnce: two folds from one shard field decrement it once.
func TestStageDeltaFold_DuplicateFromDecrementsOnce(t *testing.T) {
	c := MustNew("viewShards", 1)
	p := parent()
	b := &recBatch{}
	StageDeltaFold(b, p, []Shard{{Ref: c.ShardRef(p, 0), Data: map[string]any{"likeCount": int64(5)}}},
		Fold{From: likeShard, To: likeShard}, Fold{From: likeShard, To: firestore.FieldPath{"other"}})
	if len(b.updates) != 2 || len(b.updates[0].updates) != 1 {
		t.Fatalf("updates = %+v, want one shard decrement and one parent update", b.updates)
	}
}

func TestShardsOf_SkipsNil(t *testing.T) {
	if got := ShardsOf([]*firestore.DocumentSnapshot{nil}); len(got) != 0 {
		t.Fatalf("ShardsOf(nil) = %v", got)
	}
}
