package posts

import (
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// viewBatch records the paths staged on a batch.
type viewBatch struct{ sets []string }

func (b *viewBatch) Set(ref *firestore.DocumentRef, _ interface{}, _ ...firestore.SetOption) store.Batch {
	b.sets = append(b.sets, ref.Path)
	return b
}
func (b *viewBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return b }
func (b *viewBatch) Update(*firestore.DocumentRef, []firestore.Update, ...firestore.Precondition) store.Batch {
	return b
}
func (b *viewBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return b }

func (b *viewBatch) count(part string) int {
	n := 0
	for _, p := range b.sets {
		if strings.Contains(p, part) {
			n++
		}
	}
	return n
}

// TestStageViews_MarkerOncePerWindow: every view is one shard write; the rollup marker is written once per post and
// window after a commit, again after a failed (uncommitted) attempt, and again in the next window.
func TestStageViews_MarkerOncePerWindow(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	t0 := time.Date(2026, 11, 14, 10, 0, 1, 0, time.UTC)
	ids := []string{"0000000000000000001", "0000000000000000002"}

	b := &viewBatch{}
	_ = r.StageViews(b, ids, t0) // a failed commit: committed() is never called
	if b.count("/viewShards/") != 2 || b.count("/viewDirty/") != 2 {
		t.Fatalf("first attempt staged %v", b.sets)
	}
	b = &viewBatch{}
	done := r.StageViews(b, ids, t0)
	if b.count("/viewDirty/") != 2 {
		t.Fatalf("after a failed attempt the markers must be staged again: %v", b.sets)
	}
	done()
	b = &viewBatch{}
	r.StageViews(b, ids, t0.Add(4*time.Minute))()
	if b.count("/viewShards/") != 2 || b.count("/viewDirty/") != 0 {
		t.Fatalf("same window after a commit: %v, want shards only", b.sets)
	}
	b = &viewBatch{}
	r.StageViews(b, ids[:1], t0.Add(5*time.Minute))()
	want := "/viewDirty/" + viewMarkerID(viewWindow(t0.Add(5*time.Minute)), ids[0])
	if b.count("/viewDirty/") != 1 || b.count(want) != 1 {
		t.Fatalf("next window: %v, want the new window's marker %s", b.sets, want)
	}
}

func TestViewWindowAndMarkerID(t *testing.T) {
	t0 := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	if viewWindow(t0) != viewWindow(t0.Add(ViewWindow-time.Second)) || viewWindow(t0) == viewWindow(t0.Add(ViewWindow)) {
		t.Fatal("a window is 5 minutes, aligned to Unix time")
	}
	if got := viewMarkerID(42, "0000000000000000001"); got != "42_0000000000000000001" {
		t.Fatalf("marker id = %q", got)
	}
}

func TestViewMemo_Bounded(t *testing.T) {
	var m viewMemo
	ids := make([]string, viewMemoMax+10)
	for i := range ids {
		ids[i] = strings.Repeat("x", 1) + time.Duration(i).String()
	}
	m.note(1, ids)
	if len(m.marked) != viewMemoMax {
		t.Fatalf("memo holds %d, want the bound %d", len(m.marked), viewMemoMax)
	}
	if !m.needs(1, ids[len(ids)-1]) || m.needs(1, ids[0]) || !m.needs(2, ids[0]) {
		t.Fatal("memo answers wrong")
	}
}
