package posts

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestRemovalLog_SharedInstantBurstCostsOneReadPerTTL is the B1 regression: 250 entries (a suspension batch) share
// one commit timestamp. The cold load reads the newest 50; every later TTL must cost exactly one read (the
// incremental query starts after the last entry seen), not a 100-read reload forever.
func TestRemovalLog_SharedInstantBurstCostsOneReadPerTTL(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	at := r.now.Add(-time.Minute)
	for i := range 250 {
		r.src.put(fmt.Sprintf("b%03d", i), RemovalRemoved, at)
	}
	cutoff := at.Add(-time.Second)
	if _, trunc, reads := r.since(t, cutoff); !trunc || reads != RemovalMaxIDs {
		t.Fatalf("cold load: trunc=%v reads=%d, want truncated/%d", trunc, reads, RemovalMaxIDs)
	}
	for step := 1; step <= 5; step++ {
		r.now = r.now.Add(testTTL)
		_, trunc, reads := r.since(t, cutoff)
		if reads != 1 {
			t.Fatalf("TTL step %d: reads = %d, want 1 (no reload of the burst)", step, reads)
		}
		if !trunc {
			t.Fatalf("TTL step %d: a token from before the burst must still be rejected", step)
		}
	}
	if want := []string{"newest", "after", "after", "after", "after", "after"}; !reflect.DeepEqual(r.src.queries, want) {
		t.Fatalf("queries = %v, want %v", r.src.queries, want)
	}

	// A newcomer at the same instant with a larger id is found through the (At, id) position, and one strictly
	// later is listed.
	r.src.put("zzz", RemovalRemoved, at)
	r.now = r.now.Add(testTTL)
	if ids, _, reads := r.since(t, at); reads != 1 || len(ids) != 0 {
		t.Fatalf("same-instant newcomer: ids=%v reads=%d, want none (not newer than the cutoff) and 1 read", ids, reads)
	}
	r.src.put("late", RemovalRemoved, r.now.Add(-time.Second))
	r.now = r.now.Add(testTTL)
	if ids, trunc, reads := r.since(t, at); trunc || !reflect.DeepEqual(ids, []string{"late"}) || reads != 1 {
		t.Fatalf("later entry: ids=%v trunc=%v reads=%d, want [late]/false/1", ids, trunc, reads)
	}
}

func TestRemovalLog_FailedRefreshServesStaleAndBacksOff(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	cutoff := r.now.Add(-time.Hour)
	r.src.put("p1", RemovalRemoved, r.now.Add(-time.Minute))
	r.since(t, cutoff)

	r.src.err = errors.New("firestore down")
	r.src.queries = nil
	r.now = r.now.Add(testTTL)
	ids, trunc, _ := r.since(t, cutoff)
	if !reflect.DeepEqual(ids, []string{"p1"}) || trunc {
		t.Fatalf("stale serve: ids=%v trunc=%v, want [p1]/false", ids, trunc)
	}
	// Inside the backoff no further query is attempted; after it, one is.
	r.now = r.now.Add(removalRetryBackoff - time.Second)
	r.since(t, cutoff)
	if len(r.src.queries) != 1 {
		t.Fatalf("queries inside the backoff = %v, want 1 attempt in total", r.src.queries)
	}
	r.now = r.now.Add(2 * time.Second)
	r.since(t, cutoff)
	if len(r.src.queries) != 2 {
		t.Fatalf("queries after the backoff = %v, want a second attempt", r.src.queries)
	}
	// Recovery picks up what was missed.
	r.src.err = nil
	r.src.put("p2", RemovalRemoved, r.now.Add(-time.Second))
	r.now = r.now.Add(removalRetryBackoff)
	if ids, _, _ := r.since(t, cutoff); !reflect.DeepEqual(ids, []string{"p2", "p1"}) {
		t.Fatalf("after recovery ids=%v", ids)
	}
}

func TestRemovalLog_QueryHasItsOwnTimeout(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	r.log.queryTimeout = 20 * time.Millisecond
	r.src.block = make(chan struct{}) // never released: the query only ends through its context
	_, _, err := r.log.RemovedSince(context.Background(), r.now.Add(-time.Hour))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want DeadlineExceeded from the query timeout", err)
	}
}

func TestRemovalLog_WaiterGivesUpOnItsOwnContext(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	r.src.block = make(chan struct{})
	r.src.entered = make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		_, _, err := r.log.RemovedSince(context.Background(), r.now.Add(-time.Hour))
		done <- err
	}()
	<-r.src.entered // the first caller holds the refresh

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, _, err := r.log.RemovedSince(ctx, r.now.Add(-time.Hour)); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("waiter err = %v, want its own DeadlineExceeded", err)
	}
	close(r.src.block)
	if err := <-done; err != nil {
		t.Fatalf("first caller: %v", err)
	}
}

func TestRemovalWorstReads_MatchesReadBudget(t *testing.T) {
	t.Parallel()
	if RemovalWorstReads != config.RemovalLogMaxReads {
		t.Fatalf("RemovalWorstReads = %d, config.RemovalLogMaxReads = %d: keep them equal", RemovalWorstReads, config.RemovalLogMaxReads)
	}
}
