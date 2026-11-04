package store

import (
	"testing"

	"cloud.google.com/go/firestore"
)

// zeroClient builds a Firestore client good enough to construct DocumentRefs and a local WriteBatch
// (pure path/slice bookkeeping, no network I/O) without needing the emulator. Commit is exercised only
// by the emulator integration tests (it requires a real backend).
func zeroClient() *firestore.Client {
	return &firestore.Client{}
}

func TestFirestoreBatch_ChainingReturnsSameBatch(t *testing.T) {
	client := zeroClient()
	b := NewFirestoreBatch(client)

	ref := client.Collection("users").Doc("u1")
	result := b.Set(ref, map[string]interface{}{"a": 1}).Create(client.Collection("h").Doc("x"), map[string]interface{}{})
	if result != Batch(b) {
		t.Error("expected chained calls to return the same underlying batch")
	}
}
