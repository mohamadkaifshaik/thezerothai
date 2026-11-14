//go:build integration

package shardcount

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func shardTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

var countField = firestore.FieldPath{"count"}

// TestIntegration_IncrementReadFold: increments spread over shards in batches and in a transaction, the read sums them,
// the fold writes the absolute total to the parent, a repeated fold writes the same value, and StageDelete removes the
// shards.
func TestIntegration_IncrementReadFold(t *testing.T) {
	ctx := context.Background()
	client := shardTestClient(t)
	c := MustNew("viewShards", 10)
	parent := client.Collection("posts").Doc(fmt.Sprintf("p%d", rand.Int64()))
	if _, err := parent.Set(ctx, map[string]any{"text": "x"}); err != nil {
		t.Fatal(err)
	}
	for range 25 {
		b := store.NewFirestoreBatch(client)
		c.StageIncrement(b, parent, Delta{Field: countField, N: 1})
		if err := b.Commit(ctx); err != nil {
			t.Fatalf("commit: %v", err)
		}
	}
	if _, err := store.RunTransaction(ctx, client, func(ctx context.Context, tx *firestore.Transaction) error {
		b := store.NewFirestoreTxBatch(tx)
		c.StageIncrement(b, parent, Delta{Field: countField, N: 2})
		return b.Err()
	}); err != nil {
		t.Fatalf("transaction: %v", err)
	}
	tot, err := c.Read(ctx, client, []*firestore.DocumentRef{parent}, countField)
	if err != nil || tot[0].Get(countField) != 27 {
		t.Fatalf("Read = %v, %v, want 27", tot, err)
	}
	snaps, err := client.GetAll(ctx, c.Refs(parent))
	if err != nil {
		t.Fatal(err)
	}
	used := 0
	for _, s := range snaps {
		if s.Exists() {
			used++
		}
	}
	if used < 2 {
		t.Errorf("26 writes landed on %d shard(s), want them spread", used)
	}
	for range 2 { // the second fold is the redelivery: same value
		b := store.NewFirestoreBatch(client)
		StageFold(b, parent, tot[0], Fold{From: countField, To: firestore.FieldPath{"viewCount"}})
		if err := b.Commit(ctx); err != nil {
			t.Fatalf("fold: %v", err)
		}
		s, err := parent.Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if v, _ := s.DataAt("viewCount"); v != int64(27) {
			t.Fatalf("viewCount = %v, want 27", v)
		}
	}
	b := store.NewFirestoreBatch(client)
	c.StageDelete(b, parent)
	if err := b.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	tot, err = c.Read(ctx, client, []*firestore.DocumentRef{parent}, countField)
	if err != nil || tot[0].Get(countField) != 0 {
		t.Fatalf("after StageDelete Read = %v, %v, want 0", tot, err)
	}
}

// TestIntegration_FoldOnMissingParentFails: the fold's Update carries Exists, so a deleted parent writes nothing.
func TestIntegration_FoldOnMissingParentFails(t *testing.T) {
	ctx := context.Background()
	client := shardTestClient(t)
	parent := client.Collection("posts").Doc(fmt.Sprintf("gone%d", rand.Int64()))
	b := store.NewFirestoreBatch(client)
	StageFold(b, parent, Totals{Key(countField): 3}, Fold{From: countField, To: firestore.FieldPath{"viewCount"}})
	if err := b.Commit(ctx); err == nil {
		t.Fatal("a fold on a missing parent must fail")
	}
	if _, err := parent.Get(ctx); err == nil {
		t.Fatal("the fold must not have created the parent")
	}
}
