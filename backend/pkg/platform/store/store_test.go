package store

import (
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// zeroClient builds a Firestore client good enough to construct DocumentRefs and a local WriteBatch
// (pure path/slice bookkeeping, no network I/O) without needing the emulator. Commit is exercised only
// by the emulator integration tests (it requires a real backend).
func zeroClient() *firestore.Client {
	return &firestore.Client{}
}

func TestFirestoreBatch_CountsWritesAndDeletes(t *testing.T) {
	client := zeroClient()
	c := &budget.Counter{}
	b := NewFirestoreBatch(client, c)

	ref := client.Collection("users").Doc("u1")
	b.Set(ref, map[string]interface{}{"a": 1})
	b.Create(client.Collection("handles").Doc("h1"), map[string]interface{}{"uid": "u1"})
	b.Update(ref, []firestore.Update{{Path: "postsCount", Value: firestore.Increment(int64(1))}})
	b.Delete(client.Collection("handles").Doc("old"))

	if c.Writes() != 3 {
		t.Errorf("Writes() = %d, want 3 (set+create+update)", c.Writes())
	}
	if c.Deletes() != 1 {
		t.Errorf("Deletes() = %d, want 1", c.Deletes())
	}
	if c.Reads() != 0 {
		t.Errorf("Reads() = %d, want 0 (Batch never reads)", c.Reads())
	}
}

func TestFirestoreBatch_ChainingReturnsSameBatch(t *testing.T) {
	client := zeroClient()
	c := &budget.Counter{}
	b := NewFirestoreBatch(client, c)

	ref := client.Collection("users").Doc("u1")
	result := b.Set(ref, map[string]interface{}{"a": 1}).Create(client.Collection("h").Doc("x"), map[string]interface{}{})
	if result != Batch(b) {
		t.Error("expected chained calls to return the same underlying batch")
	}
}
