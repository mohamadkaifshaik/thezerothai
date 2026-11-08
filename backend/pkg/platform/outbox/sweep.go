package outbox

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Result counts one Sweep. It holds counts only (no ids: a doc id embeds a post or beacon id).
type Result struct {
	// Due is how many items the due query returned (at most BatchSize).
	Due int
	// Done items ran and were removed.
	Done int
	// Failed items ran (or panicked) and stay for their next backoff step.
	Failed int
	// UnknownKind items have no handler in this revision; they are backed off, never dropped (a newer revision may own them).
	UnknownKind int
	// Contended items were claimed by someone else between the query and the claim, and skipped.
	Contended int
	// WriteFailed counts claim or remove writes that failed.
	WriteFailed int
	// Deferred items were left for the next run because the context ended.
	Deferred int
	// Stuck counts items whose attempts reached StuckAfter in this run (each item is counted once, at the crossing).
	Stuck int
	// StuckItems describes those items for the log: kind and the hashed uid, never the key (it embeds a post or beacon id).
	StuckItems []StuckItem
}

// StuckItem is one item that reached StuckAfter attempts.
type StuckItem struct {
	Kind    string
	UIDHash string
}

// LogAttrs are the fields of a run log line.
func (r Result) LogAttrs() []any {
	return []any{
		"due", r.Due, "done", r.Done, "failed", r.Failed, "unknown_kind", r.UnknownKind, "contended", r.Contended,
		"write_failed", r.WriteFailed, "deferred", r.Deferred, "stuck", r.Stuck,
	}
}

// Sweep runs one pass: the due items (oldest nextAttemptAt first, at most BatchSize), each claimed and then run. Its error
// is the due query's alone (nothing was processed); per-item outcomes are in Result. It stops early, counting the rest as
// Deferred, when ctx ends.
func (o *Outbox) Sweep(ctx context.Context) (Result, error) {
	var res Result
	now := o.cfg.Now()
	items, err := o.b.due(ctx, now, o.cfg.BatchSize)
	if err != nil {
		return res, fmt.Errorf("outbox: due query: %w", err)
	}
	res.Due = len(items)
	for i, it := range items {
		if ctx.Err() != nil {
			res.Deferred = len(items) - i
			break
		}
		o.runOne(ctx, it, &res)
	}
	return res, nil
}

// errNoHandler marks an item of a kind with no registered handler.
var errNoHandler = errors.New("outbox: no handler for kind")

// errContended marks an item someone else claimed first.
var errContended = errors.New("outbox: item claimed elsewhere")

// runOne claims it, runs its handler and removes it on success, counting the outcome in res.
func (o *Outbox) runOne(ctx context.Context, it Item, res *Result) {
	err := o.claimAndRun(ctx, it, res)
	switch {
	case err == nil:
		res.Done++
	case errors.Is(err, errContended):
		res.Contended++
	case errors.Is(err, errNoHandler):
		res.UnknownKind++
	case errors.Is(err, errWrite):
		res.WriteFailed++
	default:
		res.Failed++
	}
}

// errWrite wraps a claim or remove failure.
var errWrite = errors.New("outbox: write failed")

// claimAndRun is the claim → run → remove protocol shared by Sweep and RunNow. res may be nil.
func (o *Outbox) claimAndRun(ctx context.Context, it Item, res *Result) error {
	attempts := it.Attempts + 1
	ut, ok, err := o.b.claim(ctx, it, attempts, o.cfg.Now().Add(o.backoff(attempts)))
	if err != nil {
		return fmt.Errorf("%w: claim: %w", errWrite, err)
	}
	if !ok {
		return errContended
	}
	it.Attempts, it.updateTime = attempts, ut
	// stuck notes an item that failed its StuckAfter-th attempt (once: the count only passes the threshold once).
	stuck := func() {
		if attempts == o.cfg.StuckAfter && res != nil {
			res.Stuck++
			res.StuckItems = append(res.StuckItems, StuckItem{Kind: it.Kind, UIDHash: logger.HashUID(it.UID)})
		}
	}
	h, ok := o.handlers[it.Kind]
	if !ok {
		stuck()
		return fmt.Errorf("%w %s", errNoHandler, it.Kind)
	}
	if err := safeRun(ctx, h, it); err != nil {
		stuck()
		return fmt.Errorf("outbox: %s: %w", it.Kind, err)
	}
	// Only if unchanged since our claim: a producer that re-staged the item meanwhile wants it run again.
	if err := o.b.remove(ctx, it.id, &ut); err != nil {
		return fmt.Errorf("%w: remove: %w", errWrite, err)
	}
	return nil
}

// safeRun turns a handler panic into an error, so one bad item cannot end the run.
func safeRun(ctx context.Context, h Handler, it Item) (err error) {
	defer func() {
		if v := recover(); v != nil {
			err = fmt.Errorf("handler panic: %v", v)
		}
	}()
	return h(ctx, it)
}

// RunNow runs e's item at once if it is still present, due or not, through the same claim protocol as Sweep (a replayed
// request that wants its follow-up retried). found reports whether the item existed; err is the handler's or a storage
// error. A kind with no handler is an error.
func (o *Outbox) RunNow(ctx context.Context, e Entry) (found bool, err error) {
	if err := e.Validate(); err != nil {
		return false, err
	}
	if _, ok := o.handlers[e.Kind]; !ok {
		return false, fmt.Errorf("%w %s", errNoHandler, e.Kind)
	}
	it, ok, err := o.b.get(ctx, e.ID())
	if err != nil {
		return false, fmt.Errorf("outbox: run now: read: %w", err)
	}
	if !ok {
		return false, nil
	}
	return true, o.claimAndRun(ctx, it, nil)
}
