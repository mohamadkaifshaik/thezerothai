package posts

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// counterBatch records every staged write by kind and path.
type counterBatch struct {
	sets    []string
	updates []string
	ups     [][]firestore.Update
}

func (b *counterBatch) Set(ref *firestore.DocumentRef, _ interface{}, _ ...firestore.SetOption) store.Batch {
	b.sets = append(b.sets, ref.Path)
	return b
}
func (b *counterBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return b }
func (b *counterBatch) Update(ref *firestore.DocumentRef, u []firestore.Update, _ ...firestore.Precondition) store.Batch {
	b.updates = append(b.updates, ref.Path)
	b.ups = append(b.ups, u)
	return b
}
func (b *counterBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch {
	return b
}

func (b *counterBatch) setsWith(part string) int {
	n := 0
	for _, p := range b.sets {
		if strings.Contains(p, part) {
			n++
		}
	}
	return n
}

const hotPID = "0000000000000000001"

// stagers are the three routed counter writers, by post field.
func stagers(r *FirestoreRepo) map[string]func(store.Batch, string, int64, int64) func() {
	return map[string]func(store.Batch, string, int64, int64) func(){
		"likeCount": r.StageLikeCount, "repostCount": r.StageRepostCount, "shareCount": r.StageShareCount,
	}
}

// TestStageCounter_Cold: threshold 0 (any known), or known below the threshold, is exactly today's write: one Update of
// the post with Increment(delta) on the field, nothing else.
func TestStageCounter_Cold(t *testing.T) {
	for _, tc := range []struct {
		name             string
		threshold, known int64
	}{
		{"threshold 0, huge count", 0, 1 << 40},
		{"below the threshold", 100, 99},
		{"no count read", 100, 0},
	} {
		r := NewFirestoreRepo(&firestore.Client{})
		r.SetHotCounterThreshold(tc.threshold)
		for field, stage := range stagers(r) {
			t.Run(tc.name+"/"+field, func(t *testing.T) {
				b := &counterBatch{}
				stage(b, hotPID, -1, tc.known)()
				want := []firestore.Update{{Path: field, Value: firestore.Increment(int64(-1))}}
				if len(b.sets) != 0 || len(b.updates) != 1 || !strings.HasSuffix(b.updates[0], "/posts/"+hotPID) || !reflect.DeepEqual(b.ups[0], want) {
					t.Fatalf("sets %v updates %v %v; want the one plain Update", b.sets, b.updates, b.ups)
				}
			})
		}
	}
}

// TestStageCounter_Hot: known at or above the threshold writes one shard of posts/{id}/viewShards (the same field name)
// and the counter marker, no Update of the post; the marker is written once per window after a commit, and again after
// an uncommitted attempt.
func TestStageCounter_Hot(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	r.SetHotCounterThreshold(100)
	if !r.Hot(100) || r.Hot(99) || NewFirestoreRepo(&firestore.Client{}).Hot(1<<40) {
		t.Fatal("Hot must be threshold > 0 && known >= threshold")
	}
	for field := range stagers(r) {
		t.Run(field, func(t *testing.T) {
			fresh := NewFirestoreRepo(&firestore.Client{}) // its own memo
			fresh.SetHotCounterThreshold(100)
			stage := stagers(fresh)[field]
			b := &counterBatch{}
			_ = stage(b, hotPID, 1, 100) // a failed commit: committed() is never called
			if len(b.updates) != 0 || b.setsWith("/posts/"+hotPID+"/viewShards/") != 1 || b.setsWith("/viewDirty/c") != 1 {
				t.Fatalf("hot write staged sets %v updates %v; want a shard and a counter marker", b.sets, b.updates)
			}
			b = &counterBatch{}
			stage(b, hotPID, 1, 100)()
			if b.setsWith("/viewDirty/c") != 1 {
				t.Fatalf("after a failed attempt the marker must be staged again: %v", b.sets)
			}
		})
	}
	// One memo for the three fields: once the post's counter marker is committed, the next hot write of any of them
	// stages the shard only (checked unless the test straddled a window boundary).
	w0 := viewWindow(time.Now())
	r.StageShareCount(&counterBatch{}, hotPID, 1, 100)()
	b := &counterBatch{}
	r.StageLikeCount(b, hotPID, 1, 1000)()
	if b.setsWith("/viewShards/") != 1 || (viewWindow(time.Now()) == w0 && b.setsWith("/viewDirty/c") != 0) {
		t.Fatalf("committed marker: %v, want the shard only", b.sets)
	}
	// The views memo is separate: a view still writes its own marker.
	vb := &viewBatch{}
	r.StageViews(vb, []string{hotPID}, time.Now())()
	if vb.count("/viewDirty/c") != 0 || vb.count("/viewDirty/") != 1 {
		t.Fatalf("view marker = %v", vb.sets)
	}
	if r.SetHotCounterThreshold(-5); r.Hot(0) {
		t.Fatal("a negative threshold reads as off")
	}
}

// TestStageCounter_LateCommitAtTheBoundary (M1, staging side, with the injected clock): the first hot write of window W
// commits the marker cW; a hot write staged in the last second of W stages the shard only (the memo has cW), so its
// value rides on cW even when its commit lands after the boundary; the first write of W+1 stages c(W+1). The rollup side
// (TestCounterRollup_LateCommitAtTheBoundary) keeps cW until a full window after W closed, so that late value is folded.
func TestStageCounter_LateCommitAtTheBoundary(t *testing.T) {
	r := NewFirestoreRepo(&firestore.Client{})
	r.SetHotCounterThreshold(10)
	w := viewWindow(time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC))
	start := time.Unix(w*int64(ViewWindow/time.Second), 0)
	clock := start
	r.now = func() time.Time { return clock }

	b := &counterBatch{}
	r.StageLikeCount(b, hotPID, 1, 10)()
	if want := "/viewDirty/" + counterMarkers.id(w, hotPID); b.setsWith(want) != 1 {
		t.Fatalf("first write in W staged %v, want %s", b.sets, want)
	}
	clock = start.Add(ViewWindow - time.Second) // the last second of W; the commit lands after the boundary
	b = &counterBatch{}
	r.StageLikeCount(b, hotPID, 1, 10)()
	if b.setsWith("/viewShards/") != 1 || b.setsWith("/viewDirty/") != 0 {
		t.Fatalf("late write in W staged %v, want the shard only (cW is committed)", b.sets)
	}
	if foldBefore(start.Add(ViewWindow)) != w { // a tick at the boundary folds only windows before W
		t.Fatal("a tick at the boundary must not fold W")
	}
	clock = start.Add(ViewWindow)
	b = &counterBatch{}
	r.StageLikeCount(b, hotPID, 1, 10)()
	if want := "/viewDirty/" + counterMarkers.id(w+1, hotPID); b.setsWith(want) != 1 {
		t.Fatalf("first write in W+1 staged %v, want %s", b.sets, want)
	}
}

// TestGuardHot_NoReadWhenCold: on the cold path GuardHot reads nothing (a nil transaction would panic on a read).
func TestGuardHot_NoReadWhenCold(t *testing.T) {
	for _, tc := range []struct {
		name             string
		threshold, known int64
	}{
		{"threshold off", 0, 1 << 40},
		{"below the threshold", 100, 99},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := NewFirestoreRepo(&firestore.Client{})
			r.SetHotCounterThreshold(tc.threshold)
			if err := r.GuardHot(nil, hotPID, tc.known); err != nil {
				t.Fatalf("GuardHot = %v, want nil with no read", err)
			}
		})
	}
}
