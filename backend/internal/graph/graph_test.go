package graph

import (
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeBatch captures Create() calls without touching Firestore (store.Batch is a pure write-recording
// interface, so this needs no emulator).
type fakeBatch struct {
	created []interface{}
	refs    []*firestore.DocumentRef
}

func (f *fakeBatch) Set(*firestore.DocumentRef, interface{}, ...firestore.SetOption) store.Batch {
	return f
}
func (f *fakeBatch) Create(ref *firestore.DocumentRef, data interface{}) store.Batch {
	f.refs = append(f.refs, ref)
	f.created = append(f.created, data)
	return f
}
func (f *fakeBatch) Update(*firestore.DocumentRef, []firestore.Update) store.Batch { return f }
func (f *fakeBatch) Delete(*firestore.DocumentRef) store.Batch                     { return f }

func TestInitGraph_CreatesEmptyDocAtCorrectPath(t *testing.T) {
	client := &firestore.Client{}
	repo := NewFirestoreRepo(client)
	b := &fakeBatch{}
	now := time.Now()

	repo.InitGraph(b, "uid-1", now)

	if len(b.created) != 1 {
		t.Fatalf("expected exactly 1 Create() call, got %d", len(b.created))
	}
	if got, want := b.refs[0].Path, client.Collection(collection).Doc("uid-1").Path; got != want {
		t.Errorf("ref path = %q, want %q", got, want)
	}
	d, ok := b.created[0].(doc)
	if !ok {
		t.Fatalf("created payload is %T, want doc", b.created[0])
	}
	if d.Following == nil || d.Blocked == nil || d.Muted == nil || d.Requested == nil {
		t.Error("expected all graph arrays to be initialized to empty slices, not nil")
	}
	if len(d.Following) != 0 || len(d.Blocked) != 0 || len(d.Muted) != 0 || len(d.Requested) != 0 {
		t.Error("expected all graph arrays to start empty")
	}
	if !d.UpdatedAt.Equal(now) {
		t.Errorf("UpdatedAt = %v, want %v", d.UpdatedAt, now)
	}
}
