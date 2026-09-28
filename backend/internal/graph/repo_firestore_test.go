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
func (f *fakeBatch) Update(*firestore.DocumentRef, []firestore.Update) store.Batch        { return f }
func (f *fakeBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return f }

func TestInitGraph_CreatesEmptyDocAtCorrectPath(t *testing.T) {
	client := &firestore.Client{}
	repo := NewFirestoreRepo(client)
	b := &fakeBatch{}
	now := time.Now()

	repo.InitGraph(b, "uid-1", now)

	if len(b.created) != 1 {
		t.Fatalf("expected exactly 1 Create() call, got %d", len(b.created))
	}
	if got, want := b.refs[0].Path, client.Collection(graphCollection).Doc("uid-1").Path; got != want {
		t.Errorf("ref path = %q, want %q", got, want)
	}
	d, ok := b.created[0].(doc)
	if !ok {
		t.Fatalf("created payload is %T, want doc", b.created[0])
	}
	if d.Following == nil || d.Blocked == nil || d.Muted == nil || d.Requested == nil || d.BlockedBy == nil {
		t.Error("expected all graph arrays to be initialized to empty slices, not nil")
	}
	if len(d.Following) != 0 || len(d.Blocked) != 0 || len(d.Muted) != 0 || len(d.Requested) != 0 || len(d.BlockedBy) != 0 {
		t.Error("expected all graph arrays to start empty")
	}
	if d.BlockedByOverflow {
		t.Error("expected blockedByOverflow to start false")
	}
	if !d.UpdatedAt.Equal(now) {
		t.Errorf("UpdatedAt = %v, want %v", d.UpdatedAt, now)
	}
}

// TestDoc_SnapshotAndSetHelpers exercises the doc<->Snapshot conversion and membership helpers used by the
// service layer (Reader.Snapshot, block checks, relationship computation).
func TestDoc_SnapshotAndSetHelpers(t *testing.T) {
	d := doc{
		Following: []string{"a", "b"},
		Blocked:   []string{"c"},
		Muted:     []string{"d"},
		BlockedBy: []string{"e"},
	}
	if !d.hasFollowing("a") || d.hasFollowing("z") {
		t.Error("hasFollowing mismatch")
	}
	if !d.hasBlocked("c") || d.hasBlocked("z") {
		t.Error("hasBlocked mismatch")
	}
	if !d.hasMuted("d") || d.hasMuted("z") {
		t.Error("hasMuted mismatch")
	}
	if !d.hasBlockedBy("e") || d.hasBlockedBy("z") {
		t.Error("hasBlockedBy mismatch")
	}

	snap := d.toSnapshot()
	if !snap.isFollowing("a") || !snap.isBlocked("c") || !snap.isMuted("d") || !snap.isBlockedBy("e") {
		t.Errorf("unexpected snapshot: %+v", snap)
	}
	if snap.isFollowing("z") {
		t.Error("expected isFollowing(z) to be false")
	}
}

func TestDoc_ToSnapshot_EmptyArraysAreNonNilSets(t *testing.T) {
	snap := doc{}.toSnapshot()
	if snap.Following == nil || snap.Blocked == nil || snap.Muted == nil || snap.Requested == nil || snap.BlockedBy == nil {
		t.Error("expected an empty doc to decode to non-nil empty sets")
	}
}
