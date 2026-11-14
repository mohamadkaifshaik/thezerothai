package posts

import (
	"reflect"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
)

// TestStageSetCounter: the plain field is set to n (never an Increment) and every shard holding a non-zero value of the
// field is drained by exactly that value (negative ones too); a shard at 0 or without the field is not written, and the
// views field and the other engagement fields on the same shard docs are never touched.
func TestStageSetCounter(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	post := r.ref(hotPID)
	shards := []shardcount.Shard{
		{Ref: viewShards.ShardRef(post, 0), Data: map[string]any{"count": int64(9), "shareCount": int64(2), "likeCount": int64(5)}},
		{Ref: viewShards.ShardRef(post, 3), Data: map[string]any{"shareCount": int64(-1)}},
		{Ref: viewShards.ShardRef(post, 4), Data: map[string]any{"shareCount": int64(0), "likeCount": int64(1)}},
		{Ref: viewShards.ShardRef(post, 7), Data: map[string]any{"count": int64(3)}},
	}
	b := &counterBatch{}
	stageSetCounter(b, post, shards, shareCountField, 7)
	wantPaths := []string{post.Path, shards[0].Ref.Path, shards[1].Ref.Path}
	wantUps := [][]firestore.Update{
		{{FieldPath: shareCountField, Value: int64(7)}},
		{{FieldPath: shareCountField, Value: firestore.Increment(int64(-2))}},
		{{FieldPath: shareCountField, Value: firestore.Increment(int64(1))}},
	}
	if len(b.sets) != 0 || !reflect.DeepEqual(b.updates, wantPaths) || !reflect.DeepEqual(b.ups, wantUps) {
		t.Fatalf("sets %v\nupdates %v\nups %+v\nwant %v %+v", b.sets, b.updates, b.ups, wantPaths, wantUps)
	}

	// A cold post (no shards) is exactly the old single write.
	b = &counterBatch{}
	stageSetCounter(b, post, nil, shareCountField, 4)
	if len(b.updates) != 1 || b.updates[0] != post.Path || !reflect.DeepEqual(b.ups[0], []firestore.Update{{FieldPath: shareCountField, Value: int64(4)}}) {
		t.Fatalf("cold: updates %v %+v; want the one plain set", b.updates, b.ups)
	}
}

func TestStoredCountTotal(t *testing.T) {
	if got := (StoredCount{Plain: 5, Pending: -2}).Total(); got != 3 {
		t.Fatalf("Total = %d, want 3", got)
	}
}
