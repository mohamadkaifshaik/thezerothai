package posts

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TestCounterRollup_EveryTickWhateverViews: the counter half folds its closed-window markers on every tick, also when the
// views half is gated (fresh) or post_views is globally off, and never touches the view markers or viewCount there.
func TestCounterRollup_EveryTickWhateverViews(t *testing.T) {
	for _, tc := range []struct {
		name        string
		off         bool
		lastRun     time.Time
		wantOutcome string
	}{
		{"views due", false, time.Time{}, ViewRollupRan},
		{"views gated", false, rollupNow.Add(-time.Minute), ViewRollupFresh},
		{"post_views globally off", true, time.Time{}, ViewRollupOff},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeRollup()
			f.lastRun = tc.lastRun
			cur := viewWindow(rollupNow)
			f.markers = []ViewMarker{{PostID: "v", Window: cur - 2}}
			f.shards["v"] = 4
			f.counterMarkers = []ViewMarker{
				{PostID: "h", Window: cur - 3, Counter: true}, {PostID: "h", Window: cur - 2, Counter: true},
				{PostID: "open", Window: cur - 1, Counter: true}, // its window closed less than a window ago
			}
			f.likeCount["h"], f.counterShards["h"], f.counterShards["open"] = 100, 7, 3
			forgot := map[string]int{}
			v := &ViewRollup{Repo: f, Off: func() bool { return tc.off }, Now: func() time.Time { return rollupNow },
				Forget: func(id string) { forgot[id]++ }}
			res, err := v.Run(context.Background())
			if err != nil || res.Outcome != tc.wantOutcome {
				t.Fatalf("run = %+v, %v; want outcome %s", res, err, tc.wantOutcome)
			}
			if res.CountersFolded != 1 || res.CounterMarkers != 2 || res.CounterPages != 1 || res.CountersMore {
				t.Fatalf("counter half = %+v, want h folded from 2 markers", res)
			}
			if f.likeCount["h"] != 107 || f.counterShards["h"] != 0 || f.counterShards["open"] != 3 {
				t.Fatalf("likeCount %v shards %v; want h 107 and the grace window untouched", f.likeCount, f.counterShards)
			}
			if len(f.counterMarkers) != 1 || f.counterMarkers[0].PostID != "open" {
				t.Fatalf("counter markers left %v, want only the grace window's", f.counterMarkers)
			}
			if forgot["h"] != 1 {
				t.Fatalf("forgot = %v, want h evicted once", forgot)
			}
			viewsRan := tc.wantOutcome == ViewRollupRan
			if (len(f.markers) == 0) != viewsRan || (f.viewCount["v"] == 4) != viewsRan {
				t.Fatalf("view markers %v viewCount %v; the views half ran = %v", f.markers, f.viewCount, viewsRan)
			}
			// A redelivery right after: the counter half folds nothing more (the plain field does not move).
			if _, err := v.Run(context.Background()); err != nil || f.likeCount["h"] != 107 {
				t.Fatalf("redelivery: %v, likeCount %d", err, f.likeCount["h"])
			}
		})
	}
}

// TestCounterRollup_KeepsMarkersOfUnfinishedFolds: a post whose fold lost to contention keeps its markers, is not
// attempted twice in one run, and a page that brings no new post ends the pass (no re-query storm); a fold error deletes the markers of the posts done before it and is returned.
func TestCounterRollup_KeepsMarkersOfUnfinishedFolds(t *testing.T) {
	t.Run("contention", func(t *testing.T) {
		f := newFakeRollup()
		for i := range ViewRollupPage {
			f.counterMarkers = append(f.counterMarkers, ViewMarker{PostID: fmt.Sprintf("p%d", i), Window: 1, Counter: true})
			f.contended[fmt.Sprintf("p%d", i)] = true
		}
		res, err := (&ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }}).Run(context.Background())
		if err != nil || res.CounterPages != 2 || !res.CountersMore || len(f.counterMarkers) != ViewRollupPage || f.foldCalls != 1 {
			t.Fatalf("%+v, %v, left %d, fold calls %d; want one fold, then one page with nothing new", res, err, len(f.counterMarkers), f.foldCalls)
		}
	})
	t.Run("error after a done post", func(t *testing.T) {
		boom := errors.New("boom")
		f := newFakeRollup()
		f.counterMarkers = []ViewMarker{{PostID: "a", Window: 1, Counter: true}, {PostID: "b", Window: 1, Counter: true}}
		f.counterShards["a"], f.counterShards["b"] = 1, 1
		f.counterErr, f.failAt = boom, "b"
		_, err := (&ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }}).Run(context.Background())
		if !errors.Is(err, boom) {
			t.Fatalf("err = %v, want boom", err)
		}
		if len(f.counterMarkers) != 1 || f.counterMarkers[0].PostID != "b" || f.likeCount["a"] != 1 {
			t.Fatalf("markers %v likeCount %v; want a folded and its marker deleted, b kept", f.counterMarkers, f.likeCount)
		}
	})
	t.Run("readonly skips both halves", func(t *testing.T) {
		f := newFakeRollup()
		f.counterMarkers = []ViewMarker{{PostID: "a", Window: 1, Counter: true}}
		if res, _ := (&ViewRollup{Repo: f, ReadOnly: true}).Run(context.Background()); res.Outcome != ViewRollupReadOnly || f.counterQueries != 0 {
			t.Fatalf("%+v, counter queries %d", res, f.counterQueries)
		}
	})
}

func TestMarkerKinds(t *testing.T) {
	if got := counterMarkers.id(42, "0000000000000000001"); got != "c42_0000000000000000001" {
		t.Errorf("counter marker id = %q", got)
	}
	if got := viewMarkers.id(42, "0000000000000000001"); got != "42_0000000000000000001" {
		t.Errorf("view marker id = %q", got)
	}
	if d := counterMarkers.data(42, "x"); d["counterWindow"] != int64(42) || d["postId"] != "x" || d["window"] != nil {
		t.Errorf("counter marker data = %v", d)
	}
	if got := markersOf([]ViewMarker{{PostID: "a"}, {PostID: "b"}, {PostID: "a"}}, []string{"a"}); len(got) != 2 {
		t.Errorf("markersOf = %v", got)
	}
}

// TestCounterRollup_LateCommitAtTheBoundary (M1): a hot write staged at the end of window W without a marker (the memo
// had it) commits just after the boundary. The prod tick fires exactly on the boundary (start of W+1): it must not fold
// W yet, so it neither deletes cW nor reads the shard before the late value lands; the tick at W+2 folds both values
// and only then deletes the marker.
func TestCounterRollup_LateCommitAtTheBoundary(t *testing.T) {
	w := viewWindow(rollupNow)
	boundary := time.Unix((w+1)*int64(ViewWindow/time.Second), 0) // the first second of W+1
	f := newFakeRollup()
	f.counterMarkers = []ViewMarker{{PostID: "p", Window: w, Counter: true}} // committed earlier in W
	f.likeCount["p"], f.counterShards["p"] = 100, 1
	v := &ViewRollup{Repo: f, Now: func() time.Time { return boundary }}
	if res, err := v.Run(context.Background()); err != nil || res.CounterMarkers != 0 || f.foldCalls != 0 {
		t.Fatalf("tick at the boundary = %+v, %v, fold calls %d; want W left alone", res, err, f.foldCalls)
	}
	if len(f.counterMarkers) != 1 || f.likeCount["p"] != 100 {
		t.Fatalf("marker %v likeCount %d; want cW kept and nothing folded", f.counterMarkers, f.likeCount["p"])
	}
	f.counterShards["p"]++ // the late commit lands, with no marker of its own (the memo had cW)
	v.Now = func() time.Time { return boundary.Add(ViewWindow) }
	if res, err := v.Run(context.Background()); err != nil || res.CountersFolded != 1 {
		t.Fatalf("tick at W+2 = %+v, %v", res, err)
	}
	if f.likeCount["p"] != 102 || f.counterShards["p"] != 0 || len(f.counterMarkers) != 0 {
		t.Fatalf("likeCount %d shards %d markers %v; want both values folded, then the marker deleted", f.likeCount["p"], f.counterShards["p"], f.counterMarkers)
	}
}

// TestFoldBefore: the cutoff is one full window behind the current one.
func TestFoldBefore(t *testing.T) {
	w := viewWindow(rollupNow)
	if foldBefore(rollupNow) != w-1 {
		t.Fatalf("foldBefore = %d, want %d", foldBefore(rollupNow), w-1)
	}
}

// TestCounterRollup_UnfinishedPostNotRetriedOnLaterPages (m4): a post left by contention on page 1 stays at the head of
// the query; the next page folds only the posts it brings that were not attempted yet.
func TestCounterRollup_UnfinishedPostNotRetriedOnLaterPages(t *testing.T) {
	f := newFakeRollup()
	for i := range ViewRollupPage {
		f.counterMarkers = append(f.counterMarkers, ViewMarker{PostID: fmt.Sprintf("p%02d", i), Window: 1, Counter: true})
		f.counterShards[fmt.Sprintf("p%02d", i)] = 1
	}
	f.contended["p00"] = true
	f.counterMarkers = append(f.counterMarkers, ViewMarker{PostID: "q", Window: 2, Counter: true})
	f.counterShards["q"] = 1
	attempts := map[string]int{}
	v := &ViewRollup{Repo: f, Now: func() time.Time { return rollupNow }, Forget: func(id string) { attempts[id]++ }}
	res, err := v.Run(context.Background())
	if err != nil || res.CountersFolded != ViewRollupPage || f.likeCount["q"] != 1 {
		t.Fatalf("%+v, %v; want p01..p49 and q folded", res, err)
	}
	if attempts["p00"] != 1 || attempts["q"] != 1 {
		t.Fatalf("attempts = p00 %d, q %d; want each once", attempts["p00"], attempts["q"])
	}
	if len(f.counterMarkers) != 1 || f.counterMarkers[0].PostID != "p00" {
		t.Fatalf("markers left %v, want p00's only", f.counterMarkers)
	}
}

// TestAfterShardFold (m2): only a failed precondition on a post confirmed missing by a re-read is "gone" (the caller
// then deletes every shard); a post that still exists, or a failed re-read, is an error that keeps the markers.
func TestAfterShardFold(t *testing.T) {
	notFound := status.Error(codes.NotFound, "no document to update")
	failedPre := status.Error(codes.FailedPrecondition, "precondition")
	aborted := status.Error(codes.Aborted, "contention")
	boom := errors.New("boom")
	exists := func(ok bool, err error) func() (bool, error) { return func() (bool, error) { return ok, err } }
	for _, tc := range []struct {
		name          string
		err           error
		exists        func() (bool, error)
		gone, contend bool
		wantErr       bool
		reread        bool
	}{
		{name: "ok", err: nil},
		{name: "contention", err: aborted, contend: true},
		{name: "other error", err: boom, wantErr: true},
		{name: "not found, post missing", err: notFound, exists: exists(false, nil), gone: true, reread: true},
		{name: "failed precondition, post missing", err: failedPre, exists: exists(false, nil), gone: true, reread: true},
		{name: "not found, post still there", err: notFound, exists: exists(true, nil), wantErr: true, reread: true},
		{name: "not found, re-read fails", err: notFound, exists: exists(false, boom), wantErr: true, reread: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reread := false
			ex := func() (bool, error) {
				reread = true
				if tc.exists == nil {
					return true, nil
				}
				return tc.exists()
			}
			gone, contended, err := afterShardFold(tc.err, ex)
			if gone != tc.gone || contended != tc.contend || (err != nil) != tc.wantErr || reread != tc.reread {
				t.Fatalf("gone %v contended %v err %v reread %v; want %v %v err=%v reread %v", gone, contended, err, reread, tc.gone, tc.contend, tc.wantErr, tc.reread)
			}
		})
	}
}
