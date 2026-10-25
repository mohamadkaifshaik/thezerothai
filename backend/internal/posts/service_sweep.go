// service_sweep.go is the orchestration of the scheduled-post publish sweep (ADR-0021 "Sweep" steps 1, 2 and 6):
// the no-op cases, the fetch-then-dispatch of the due items, and the per-author workers. The rules for one item are
// service_sweep_item.go.
//
//	fetch   : the due query, up to SweepMaxPages pages of SweepLimit, every page BEFORE any item runs, so a page-2
//	          item joins its author's queue and counts toward that author's cap (review L-3)
//	dispatch: one worker per author, at most SweepConcurrency at once (errgroup.Group with a limit, never
//	          WithContext: one failure must not cancel the others). A worker runs at most SweepPerAuthorPerRun of its
//	          author's items ONE AFTER ANOTHER, so no two items of one author contend on that author's users and quotas
//	          docs within a run; the rest are deferred to the next run without a write
//	isolate : every item has its own context and its own recover (review M-2); one item's error or panic never stops
//	          the author's next item or any other worker
package posts

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

var _ Sweeper = (*service)(nil)

// sweepTally is the run's counters, written from the author workers.
type sweepTally struct {
	mu  sync.Mutex
	res SweepResult
}

func (t *sweepTally) add(f func(r *SweepResult)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	f(&t.res)
}

func (t *sweepTally) failed(reason ScheduledFailure) {
	t.add(func(r *SweepResult) { r.Failed[reason]++ })
}

func (t *sweepTally) snapshot() SweepResult {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := t.res
	out.Failed = make(map[ScheduledFailure]int, len(t.res.Failed))
	for k, v := range t.res.Failed {
		out.Failed[k] = v
	}
	return out
}

// timeLeft is the time left in the sweep run: the context deadline against real time, or the test seam.
func (s *service) timeLeft(ctx context.Context) time.Duration {
	if s.sweepTimeLeft != nil {
		return s.sweepTimeLeft(ctx)
	}
	dl, ok := ctx.Deadline()
	if !ok {
		return time.Duration(math.MaxInt64)
	}
	return time.Until(dl)
}

// Sweep implements Sweeper. The comment on the interface states the Firestore budget.
func (s *service) Sweep(ctx context.Context) (SweepResult, error) {
	if s.sweep.Repo == nil {
		return SweepResult{Outcome: SweepError, Failed: map[ScheduledFailure]int{}}, errNoSweepRepo
	}
	tally := &sweepTally{res: SweepResult{Outcome: SweepOK, Failed: map[ScheduledFailure]int{}}}

	// 1. The no-op cases, 0 reads. Only the kill switch counts: in allowlist or percent mode the sweep still processes
	// every due doc, because only enabled users could create them (per-user flags are not re-evaluated at publish).
	switch {
	case s.sweep.Flags == nil || s.sweep.Flags.GloballyOff(FlagName) || s.sweep.Flags.GloballyOff(ScheduledPostsFlagName):
		tally.res.Outcome = SweepFlagOff
		return tally.snapshot(), nil
	case s.sweep.ReadOnly:
		tally.res.Outcome = SweepDegraded
		return tally.snapshot(), nil
	}
	lim := s.sweep.Limits
	pageLimit := min(max(lim.Limit, 1), MaxLimit)
	maxPages := max(lim.MaxPages, 1)
	concurrency := max(lim.Concurrency, 1)
	perAuthor := max(lim.PerAuthorPerRun, 1)

	// 2. Fetch every page first. The first page always runs; a later one only while there is time for it and for the
	// items already fetched.
	runNow := s.now()
	var (
		items        []*ScheduledPost
		cursor       *ScheduledDueCursor
		queryErr     error
		pagesFetched int
	)
	for page := 0; page < maxPages; page++ {
		if page > 0 && s.timeLeft(ctx) < sweepMinRemaining {
			break
		}
		pg, err := s.sweep.Repo.DueScheduled(ctx, runNow, pageLimit, cursor)
		if err != nil {
			queryErr = logger.ScrubErr(fmt.Errorf("posts: sweep due query: %w", err))
			break
		}
		pagesFetched++
		items = append(items, pg.Items...)
		tally.res.SkippedBadPath += pg.SkippedBadPath
		tally.res.Undecodable += pg.Undecodable
		if pg.Next == nil {
			break
		}
		cursor = pg.Next
	}
	if queryErr != nil && pagesFetched == 0 {
		// Page 1 failed: nothing was processed, so the route answers 500 and a Cloud Scheduler retry is harmless and wanted.
		res := tally.snapshot()
		res.Outcome = SweepError
		return res, queryErr
	}

	// Group by author in query order. The cap counts across pages: an item over it is deferred without a write.
	var order []string
	byAuthor := make(map[string][]*ScheduledPost)
	for _, it := range items {
		tally.res.Due++
		tally.res.MaxLateness = max(tally.res.MaxLateness, runNow.Sub(it.PublishAt))
		if _, seen := byAuthor[it.UID]; !seen {
			order = append(order, it.UID)
		}
		if len(byAuthor[it.UID]) >= perAuthor {
			tally.res.Deferred++
			continue
		}
		byAuthor[it.UID] = append(byAuthor[it.UID], it)
	}

	// 3. Dispatch: one worker per author, bounded. errgroup.Group (not WithContext), and workers never return an error.
	runCounter := budget.FromContext(ctx)
	var g errgroup.Group
	g.SetLimit(concurrency)
	for _, uid := range order {
		g.Go(func() error {
			s.sweepAuthor(ctx, runRef{now: runNow, counter: runCounter}, uid, byAuthor[uid], tally)
			return nil
		})
	}
	_ = g.Wait()

	res := tally.snapshot()
	if queryErr != nil {
		// A LATER page failed: the pages before it were fetched and processed, so the run is not retried (a 5xx would make
		// Cloud Scheduler re-run the sweep seconds later and burn the attempt ladder of any item that failed transiently).
		// The route answers 204 and reports this error; the items the failed page would have held are due next tick.
		res.Outcome = SweepError
		res.LaterPageErr = queryErr
	}
	return res, nil
}

// runRef is what every worker of one run shares.
type runRef struct {
	now     time.Time
	counter *budget.Counter
}

// sweepAuthor runs one author's items, one after another, on a counter of its own that is folded into the run's counter
// when the worker ends (a context holds one counter, so the per-author total needs its own; the fold keeps the run's
// fs_reads and fs_writes exact). It recovers on its own as well as per item, so the fold and the reads warning can
// never take the process down.
func (s *service) sweepAuthor(ctx context.Context, run runRef, uid string, items []*ScheduledPost, tally *sweepTally) {
	actx, ac := budget.WithCounter(ctx)
	defer func() {
		if v := recover(); v != nil {
			s.reportPanic(actx, v, "uid_hash", logger.HashUID(uid))
		}
		run.counter.AddReads(ac.Reads())
		run.counter.AddWrites(ac.Writes())
		run.counter.AddDeletes(ac.Deletes())
		if warn := s.sweep.Limits.AuthorReadsWarn; warn > 0 && ac.Reads() > int64(warn) {
			s.sweep.Log.WarnContext(actx, "scheduled_author_reads", append([]any{"uid_hash", logger.HashUID(uid), "fs_reads", ac.Reads(), "warn_above", warn}, logger.TraceAttrs(actx)...)...)
		}
	}()
	for i, it := range items {
		// Out of time, or the run was cancelled (a client that hung up): leave the rest PENDING for the next run, without
		// burning an attempt on an error the cancellation caused.
		if actx.Err() != nil || s.timeLeft(actx) < sweepMinRemaining {
			n := len(items) - i
			tally.add(func(r *SweepResult) { r.Deferred += n })
			return
		}
		s.sweepItemSafe(actx, run, it, tally)
	}
}

// sweepItemSafe runs one item on its own context, converting a panic anywhere in it into FAILED INTERNAL (review M-2).
// A panic after the publish commit (the cache update, the post events) finds the doc already PUBLISHED: the FAILED write's
// precondition then fails, which is correct, and nothing is "fixed" with an unconditional write.
func (s *service) sweepItemSafe(ctx context.Context, run runRef, it *ScheduledPost, tally *sweepTally) {
	ictx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			s.itemPanicked(ictx, it, v, tally)
		}
	}()
	s.sweepItem(ictx, run, it, tally)
}

// itemPanicked retires the item FAILED INTERNAL and reports the panic TYPE only (its value could carry a uid or text).
// Its own recover keeps a second panic from taking the process down while this one is being handled; the second one is
// logged (its TYPE only) so it is not silent.
func (s *service) itemPanicked(ctx context.Context, it *ScheduledPost, v any, tally *sweepTally) {
	defer func() {
		if v2 := recover(); v2 != nil {
			s.sweep.Log.WarnContext(ctx, "scheduled_item_second_panic", append(append(itemAttrs(it), "panic_type", fmt.Sprintf("%T", v2)), logger.TraceAttrs(ctx)...)...)
		}
	}()
	s.reportPanic(ctx, v, itemAttrs(it)...)
	s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureInternal}, tally)
}

// itemAttrs identify an item in a log line or an Error Reporting entry: the one-way uid hash and the scheduled id (itself
// a SHA-256 prefix, so it does not reveal the uid either). Never the raw uid.
func itemAttrs(it *ScheduledPost) []any {
	return []any{"uid_hash", logger.HashUID(it.UID), "scheduled_id", it.ID}
}

// reportPanic sends the panic type to Error Reporting, with attrs naming the item or author it happened on.
func (s *service) reportPanic(ctx context.Context, v any, attrs ...any) {
	s.reportErr(ctx, logger.ScrubErr(fmt.Errorf("panic of type %T", v)), attrs...)
}

// reportErr writes an Error Reporting entry. err must already be scrubbed (logger.ScrubErr). attrs identify the item
// (itemAttrs) so an operator can find it; the trace attributes are added here.
func (s *service) reportErr(ctx context.Context, err error, attrs ...any) {
	mw.ReportError(ctx, s.sweep.Log.With(append(attrs, logger.TraceAttrs(ctx)...)...), sweepOp, err)
}
