package posts

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The RID-2 regression set (ADR-0016 amendment 2026-10-18 (b)): the removal log answers per feed.

// TestRemovalLog_SuspensionOfAnUnlistedAuthorIsInvisible: a 120-post burst by an author the feed does not show makes
// no id appear and no reset, on a warm instance and on a cold one whose cache only holds the newest 50.
func TestRemovalLog_SuspensionOfAnUnlistedAuthorIsInvisible(t *testing.T) {
	t.Parallel()
	for _, cold := range []bool{false, true} {
		t.Run(fmt.Sprintf("cold=%v", cold), func(t *testing.T) {
			t.Parallel()
			r := newRemovalRig()
			start := r.now
			old := start.Add(-time.Hour)
			if !cold {
				r.sinceFor(t, old, "viewer", "f1") // warm the instance before the burst
			}
			r.now = start.Add(testTTL)
			at := start.Add(10 * time.Second)
			for i := range 120 {
				r.src.putBy(fmt.Sprintf("spam%03d", i), "spammer", RemovalRemoved, at)
			}
			ids, trunc, _ := r.sinceFor(t, old, "viewer", "f1")
			if trunc || len(ids) != 0 {
				t.Fatalf("burst by an unlisted author: ids=%d trunc=%v, want none/false", len(ids), trunc)
			}
			// The author's own profile feed is the one that is affected (more than 50 ids: reset).
			if _, trunc, _ = r.sinceFor(t, old, "spammer"); !trunc {
				t.Fatal("the suspended author's own feed must be reset (120 ids cannot be listed)")
			}
		})
	}
}

// TestRemovalLog_BurstForAFollowedAuthorIsDelivered: a followed author's removals older than the cache's coverage
// (hidden under a later 120-post burst by someone else) are found by the window query and delivered, not reset.
func TestRemovalLog_BurstForAFollowedAuthorIsDelivered(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	start := r.now
	old := start.Add(-time.Hour)
	for i := range 30 {
		r.src.putBy(fmt.Sprintf("f1p%02d", i), "f1", RemovalRemoved, start.Add(-30*time.Minute+time.Duration(i)*time.Second))
	}
	at := start.Add(-time.Minute)
	for i := range 120 {
		r.src.putBy(fmt.Sprintf("spam%03d", i), "spammer", RemovalRemoved, at)
	}
	ids, trunc, refresh := r.sinceFor(t, old, "viewer", "f1") // cold: cache = newest 50, all by the spammer
	if trunc || len(ids) != 30 {
		t.Fatalf("followed author's 30 removals: ids=%d trunc=%v, want 30/false", len(ids), trunc)
	}
	if refresh != RemovalMaxIDs {
		t.Fatalf("cold refresh reads = %d, want %d", refresh, RemovalMaxIDs)
	}
	// The window is the viewer's cost: 30 documents.
	if r.src.windowReads != 30 {
		t.Fatalf("window reads = %d, want 30", r.src.windowReads)
	}
	// 60 removals by the followed author exceed what one response can list: reset, for this feed only.
	for i := 30; i < 60; i++ {
		r.src.putBy(fmt.Sprintf("f1p%02d", i), "f1", RemovalRemoved, start.Add(-90*time.Minute).Add(time.Duration(i)*time.Second))
	}
	if _, trunc, _ = r.sinceFor(t, start.Add(-2*time.Hour), "viewer", "f1"); !trunc {
		t.Fatal("more than 50 removals for the feed must reset it")
	}
	if ids, trunc, _ = r.sinceFor(t, start.Add(-2*time.Hour), "viewer", "f2"); trunc || len(ids) != 0 {
		t.Fatalf("a feed that shows neither author: ids=%d trunc=%v, want none/false", len(ids), trunc)
	}
}

// TestRemovalLog_SteadyStateIsOneReadPerTTLPerInstance: the scope does not change the shared refresh cost.
func TestRemovalLog_SteadyStateIsOneReadPerTTLPerInstance(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	cutoff := r.now.Add(-time.Minute)
	if _, _, reads := r.sinceFor(t, cutoff, "u1"); reads != 1 {
		t.Fatalf("cold reads = %d, want 1", reads)
	}
	for step := range 5 {
		// Many viewers with different scopes inside one TTL: no further reads at all.
		for _, who := range []string{"u2", "u3", "u4"} {
			if _, _, reads := r.sinceFor(t, cutoff, who); reads != 0 {
				t.Fatalf("step %d warm %s reads = %d, want 0", step, who, reads)
			}
		}
		r.now = r.now.Add(testTTL)
		if _, _, reads := r.sinceFor(t, cutoff, "u1"); reads != 1 {
			t.Fatalf("step %d TTL refresh reads = %d, want 1", step, reads)
		}
	}
	if r.src.windowReads != 0 {
		t.Fatalf("window reads = %d, want 0 when the cache covers the cutoff", r.src.windowReads)
	}
}

// TestRemovalLog_RefreshIsDetachedFromTheCallersBudget (RID-4): the shared refresh is not charged to the request's
// counter and is logged as removal_log_reads.
func TestRemovalLog_RefreshIsDetachedFromTheCallersBudget(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	for i := range 3 {
		r.src.put(fmt.Sprintf("p%d", i), RemovalRemoved, r.now.Add(-time.Minute))
	}
	ictx, info := logger.WithRequestInfo(context.Background())
	ctx, c := budget.WithCounter(ictx)
	ids, trunc, err := r.log.RemovedSince(ctx, r.now.Add(-time.Hour), RemovalScope{Authors: []string{testAuthor}})
	if err != nil || trunc || len(ids) != 3 {
		t.Fatalf("ids=%v trunc=%v err=%v", ids, trunc, err)
	}
	if c.Reads() != 0 {
		t.Fatalf("request counter = %d reads, want 0 (the refresh belongs to the instance)", c.Reads())
	}
	if got, ok := info.Get("removal_log_reads"); !ok || fmt.Sprint(got) != "3" {
		t.Fatalf("removal_log_reads = %v, want 3", got)
	}
}

func TestRemovalLog_WindowBounds(t *testing.T) {
	t.Parallel()
	mk := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = fmt.Sprintf("a%03d", i)
		}
		return out
	}
	fill := func(r *removalRig) {
		for i := range 60 { // 60 at one instant fill the cache, so a cutoff below it needs the window
			r.src.putBy(fmt.Sprintf("x%02d", i), "other", RemovalRemoved, r.now.Add(-time.Minute))
		}
	}
	t.Run("authors are queried 30 at a time", func(t *testing.T) {
		t.Parallel()
		r := newRemovalRig()
		fill(r)
		r.src.putBy("hit", "a075", RemovalRemoved, r.now.Add(-time.Hour))
		ids, trunc, _ := r.sinceFor(t, r.now.Add(-2*time.Hour), mk(80)...)
		if trunc || !reflect.DeepEqual(ids, []string{"hit"}) {
			t.Fatalf("ids=%v trunc=%v, want [hit]", ids, trunc)
		}
		if len(r.src.windowAuthors) != 3 || len(r.src.windowAuthors[0]) != 30 || len(r.src.windowAuthors[2]) != 20 {
			t.Fatalf("window chunks = %v, want 30/30/20", r.src.windowAuthors)
		}
		if r.src.windowReads > RemovalWindowWorstReads {
			t.Fatalf("window reads = %d, above the documented %d", r.src.windowReads, RemovalWindowWorstReads)
		}
	})
	t.Run("a feed of more than 180 authors is reset instead of queried", func(t *testing.T) {
		t.Parallel()
		r := newRemovalRig()
		fill(r)
		_, trunc, _ := r.sinceFor(t, r.now.Add(-2*time.Hour), mk(RemovalWindowMaxChunks*30+1)...)
		if !trunc || len(r.src.windowAuthors) != 0 {
			t.Fatalf("trunc=%v window queries=%d, want a reset with no window query", trunc, len(r.src.windowAuthors))
		}
	})
	t.Run("a window that starts before authorId existed is reset", func(t *testing.T) {
		t.Parallel()
		r := newRemovalRig()
		fill(r)
		r.log.scopedFrom = r.now.Add(-time.Hour)
		_, trunc, _ := r.sinceFor(t, r.now.Add(-2*time.Hour), "a000")
		if !trunc || len(r.src.windowAuthors) != 0 {
			t.Fatalf("trunc=%v window queries=%d, want a reset with no window query", trunc, len(r.src.windowAuthors))
		}
	})
	t.Run("the cutover option and default gate the window query", func(t *testing.T) {
		t.Parallel()
		cutoff := time.Date(2026, time.October, 20, 0, 0, 0, 0, time.UTC)
		if !cutoff.Before(defaultRemovalAuthorScopedFrom) {
			t.Fatal("test premise: cutoff must precede the production default")
		}
		rBefore := newRemovalRig()
		fill(rBefore)
		rBefore.log.scopedFrom = defaultRemovalAuthorScopedFrom
		if _, trunc, _ := rBefore.sinceFor(t, cutoff, "a000"); !trunc || len(rBefore.src.windowAuthors) != 0 {
			t.Fatalf("before the cutover: trunc=%v window queries=%d, want a reset with no query", trunc, len(rBefore.src.windowAuthors))
		}
		rAfter := newRemovalRig()
		fill(rAfter)
		WithAuthorScopedFromForTest(cutoff.Add(-time.Hour))(rAfter.log)
		if _, trunc, _ := rAfter.sinceFor(t, cutoff, "a000"); trunc || len(rAfter.src.windowAuthors) == 0 {
			t.Fatalf("after the cutover: trunc=%v window queries=%d, want a window query", trunc, len(rAfter.src.windowAuthors))
		}
	})
	t.Run("an empty scope costs nothing", func(t *testing.T) {
		t.Parallel()
		r := newRemovalRig()
		ids, trunc, err := r.log.RemovedSince(context.Background(), r.now.Add(-time.Hour), RemovalScope{})
		if err != nil || trunc || ids != nil || len(r.src.queries) != 0 {
			t.Fatalf("ids=%v trunc=%v err=%v queries=%v", ids, trunc, err, r.src.queries)
		}
	})
}

// An entry written before authorId existed is visible to every feed (correct, only less precise).
func TestRemovalLog_LegacyEntryWithoutAuthorIsGlobal(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	r.src.putBy("old", "", RemovalRemoved, r.now.Add(-time.Minute))
	r.src.putBy("scoped", "someoneElse", RemovalRemoved, r.now.Add(-time.Minute))
	ids, trunc, _ := r.sinceFor(t, r.now.Add(-time.Hour), "f1")
	if trunc || !reflect.DeepEqual(ids, []string{"old"}) {
		t.Fatalf("ids=%v trunc=%v, want only the legacy entry", ids, trunc)
	}
}
