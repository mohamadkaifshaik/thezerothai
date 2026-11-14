package posts

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"
)

// fakeRollupRepo is an in-memory ViewRollupRepo: shards are per-post sums, markers a list, viewCount a map.
type fakeRollupRepo struct {
	lastRun    time.Time
	markers    []ViewMarker
	shards     map[string]int64
	gone       map[string]bool
	viewCount  map[string]int64
	queries    int
	foldErr    error
	deleteErr  error
	acquireErr error
	// rewritten markers survive their delete (a straggler rewrote them).
	rewritten map[string]bool
}

func (f *fakeRollupRepo) AcquireViewRollup(_ context.Context, now time.Time, iv time.Duration) (bool, error) {
	if f.acquireErr != nil {
		return false, f.acquireErr
	}
	if !viewRollupDue(f.lastRun, now, iv) {
		return false, nil
	}
	f.lastRun = now
	return true, nil
}

func (f *fakeRollupRepo) DirtyViewMarkers(_ context.Context, window int64, limit int) ([]ViewMarker, error) {
	f.queries++
	var out []ViewMarker
	for _, m := range f.markers {
		if m.Window < window && len(out) < limit {
			out = append(out, m)
		}
	}
	return out, nil
}

func (f *fakeRollupRepo) FoldViews(_ context.Context, ids []string) (int, int, error) {
	if f.foldErr != nil {
		return 0, 0, f.foldErr
	}
	folded, gone := 0, 0
	for _, id := range ids {
		if f.gone[id] {
			delete(f.shards, id)
			gone++
			continue
		}
		f.viewCount[id] = f.shards[id] // absolute, never an increment
		folded++
	}
	return folded, gone, nil
}

func (f *fakeRollupRepo) DeleteViewMarkers(_ context.Context, ms []ViewMarker) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.markers = slices.DeleteFunc(f.markers, func(m ViewMarker) bool {
		return slices.ContainsFunc(ms, func(d ViewMarker) bool { return d.PostID == m.PostID && d.Window == m.Window }) &&
			!f.rewritten[viewMarkerID(m.Window, m.PostID)]
	})
	return nil
}

func newFakeRollup() *fakeRollupRepo {
	return &fakeRollupRepo{shards: map[string]int64{}, gone: map[string]bool{}, viewCount: map[string]int64{}, rewritten: map[string]bool{}}
}

var rollupNow = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)

// TestViewRollup_FoldsClosedWindowsIdempotently: markers of closed windows are folded (absolute sums), the current
// window's markers wait, a redelivery inside the interval is "fresh", and a later run with nothing new writes the same
// values.
func TestViewRollup_FoldsClosedWindowsIdempotently(t *testing.T) {
	f := newFakeRollup()
	cur := viewWindow(rollupNow)
	f.markers = []ViewMarker{{PostID: "a", Window: cur - 2}, {PostID: "a", Window: cur - 1}, {PostID: "b", Window: cur - 1}, {PostID: "c", Window: cur}}
	f.shards = map[string]int64{"a": 7, "b": 2, "c": 1}
	clock := rollupNow
	v := &ViewRollup{Repo: f, Now: func() time.Time { return clock }}

	res, err := v.Run(context.Background())
	if err != nil || res.Outcome != ViewRollupRan || res.Folded != 2 || res.Markers != 3 || res.More {
		t.Fatalf("run = %+v, %v", res, err)
	}
	if f.viewCount["a"] != 7 || f.viewCount["b"] != 2 || f.viewCount["c"] != 0 {
		t.Fatalf("viewCount = %v, want a=7 b=2 and c untouched (open window)", f.viewCount)
	}
	if len(f.markers) != 1 || f.markers[0].PostID != "c" {
		t.Fatalf("markers left = %v, want only the open window's", f.markers)
	}
	// Scheduler redelivery a minute later: the gate answers fresh, no query.
	clock = rollupNow.Add(time.Minute)
	q := f.queries
	if res, err := v.Run(context.Background()); err != nil || res.Outcome != ViewRollupFresh || f.queries != q {
		t.Fatalf("redelivery = %+v, %v (queries %d -> %d)", res, err, q, f.queries)
	}
	// 15 minutes later c's window has closed: folded; a's value is unchanged (same absolute sum).
	clock = rollupNow.Add(15 * time.Minute)
	if res, err := v.Run(context.Background()); err != nil || res.Folded != 1 || f.viewCount["c"] != 1 || f.viewCount["a"] != 7 {
		t.Fatalf("later run = %+v, %v, counts %v", res, err, f.viewCount)
	}
}

func TestViewRollup_GoneBoundedAndSkips(t *testing.T) {
	t.Run("gone post: shards deleted, counted as gone", func(t *testing.T) {
		f := newFakeRollup()
		f.markers = []ViewMarker{{PostID: "x", Window: 1}}
		f.shards["x"], f.gone["x"] = 3, true
		res, err := (&ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }}).Run(context.Background())
		if err != nil || res.Gone != 1 || res.Folded != 0 || len(f.markers) != 0 {
			t.Fatalf("%+v, %v, markers %v", res, err, f.markers)
		}
		if _, ok := f.shards["x"]; ok {
			t.Fatal("a gone post's shards must be deleted")
		}
	})
	t.Run("page bound", func(t *testing.T) {
		f := newFakeRollup()
		for i := range 3 * ViewRollupPage {
			f.markers = append(f.markers, ViewMarker{PostID: fmt.Sprintf("p%d", i), Window: 1})
		}
		res, err := (&ViewRollup{Repo: f, MaxPages: 2, Now: func() time.Time { return rollupNow }}).Run(context.Background())
		if err != nil || res.Pages != 2 || !res.More || len(f.markers) != ViewRollupPage {
			t.Fatalf("%+v, %v, left %d", res, err, len(f.markers))
		}
	})
	t.Run("rewritten markers stay; the run stays bounded", func(t *testing.T) {
		f := newFakeRollup()
		for i := range ViewRollupPage {
			m := ViewMarker{PostID: fmt.Sprintf("p%d", i), Window: 1}
			f.markers = append(f.markers, m)
			f.rewritten[viewMarkerID(1, m.PostID)] = true
		}
		res, err := (&ViewRollup{Repo: f, MaxPages: 3, Now: func() time.Time { return rollupNow }}).Run(context.Background())
		if err != nil || res.Pages != 3 || !res.More || len(f.markers) != ViewRollupPage {
			t.Fatalf("%+v, %v", res, err)
		}
	})
	t.Run("deadline", func(t *testing.T) {
		f := newFakeRollup()
		f.markers = []ViewMarker{{PostID: "a", Window: 1}}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		res, err := (&ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }}).Run(ctx)
		if err != nil || !res.More || res.Pages != 0 {
			t.Fatalf("%+v, %v", res, err)
		}
	})
	t.Run("readonly, flag off, no repo", func(t *testing.T) {
		if res, _ := (&ViewRollup{ReadOnly: true}).Run(context.Background()); res.Outcome != ViewRollupReadOnly {
			t.Fatal(res)
		}
		if res, _ := (&ViewRollup{Off: func() bool { return true }}).Run(context.Background()); res.Outcome != ViewRollupOff {
			t.Fatal(res)
		}
		if _, err := (&ViewRollup{}).Run(context.Background()); err == nil {
			t.Fatal("want an error without a repo")
		}
	})
	t.Run("errors", func(t *testing.T) {
		boom := errors.New("boom")
		for name, f := range map[string]*fakeRollupRepo{
			"acquire": {acquireErr: boom}, "fold": {foldErr: boom}, "delete": {deleteErr: boom},
		} {
			f.markers = []ViewMarker{{PostID: "a", Window: 1}}
			f.shards, f.gone, f.viewCount, f.rewritten = map[string]int64{}, map[string]bool{}, map[string]int64{}, map[string]bool{}
			if _, err := (&ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }}).Run(context.Background()); !errors.Is(err, boom) {
				t.Errorf("%s: err = %v, want boom", name, err)
			}
		}
	})
}

func TestViewRollupDue(t *testing.T) {
	iv := 15 * time.Minute
	for _, tc := range []struct {
		last time.Time
		want bool
	}{
		{time.Time{}, true},
		{rollupNow.Add(-iv), true},
		{rollupNow.Add(-iv + time.Second), false},
		{rollupNow.Add(2 * iv), true}, // a last run in the future (clock step) must not stall the rollup
	} {
		if got := viewRollupDue(tc.last, rollupNow, iv); got != tc.want {
			t.Errorf("due(%v) = %v, want %v", tc.last, got, tc.want)
		}
	}
	if got := distinctMarkerPosts([]ViewMarker{{PostID: "a"}, {PostID: "b"}, {PostID: "a"}}); !slices.Equal(got, []string{"a", "b"}) {
		t.Errorf("distinct = %v", got)
	}
	if len((ViewRollupResult{}).LogAttrs()) != 12 {
		t.Error("log attrs")
	}
}

// TestViewRollup_ForgetsFoldedPosts: every post of a folded page is evicted from the instance cache once, and a post of
// the open window is not (its viewCount did not change).
func TestViewRollup_ForgetsFoldedPosts(t *testing.T) {
	f := newFakeRollup()
	cur := viewWindow(rollupNow)
	f.markers = []ViewMarker{{PostID: "a", Window: cur - 2}, {PostID: "a", Window: cur - 1}, {PostID: "b", Window: cur - 1}, {PostID: "c", Window: cur}}
	f.shards = map[string]int64{"a": 7, "b": 2, "c": 1}
	forgot := map[string]int{}
	v := &ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }, Forget: func(id string) { forgot[id]++ }}
	if _, err := v.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(forgot) != 2 || forgot["a"] != 1 || forgot["b"] != 1 {
		t.Fatalf("forgot = %v, want a and b once each", forgot)
	}
}
