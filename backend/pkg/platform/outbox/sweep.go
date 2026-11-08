package outbox

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// MaxResultErrors caps Result.Errors (one entry per kind and outcome; later errors of the same pair only bump Count).
const MaxResultErrors = 10

// Result counts one Sweep. It holds counts and scrubbed error text only (no ids: a doc id embeds a post or beacon id).
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
	// WriteFailed counts claim, remove or push-back writes that failed.
	WriteFailed int
	// Deferred items were left for the next run because the context ended.
	Deferred int
	// Undecodable docs matched the due query but could not be decoded; each is pushed back by MaxBackoff and skipped.
	Undecodable int
	// Stuck counts items that crossed StuckAfter attempts in this run (each item is counted once, at the crossing).
	Stuck int
	// StuckItems describes those items for the log: kind, hashed uid and the scrubbed cause, never the key.
	StuckItems []StuckItem
	// Errors holds the first scrubbed cause per (kind, outcome), at most MaxResultErrors entries.
	Errors []ItemError
}

// StuckItem is one item that crossed StuckAfter attempts.
type StuckItem struct {
	Kind    string
	UIDHash string
	// Cause is the scrubbed error of the failing attempt (uid hashed, key, document paths and edge ids removed).
	Cause string
}

// ItemError is the first error of one (kind, outcome) pair in a run.
type ItemError struct {
	Kind string
	// Outcome is "failed", "unknown_kind", "write_failed" or "undecodable".
	Outcome string
	// Cause is the scrubbed error text.
	Cause string
	// Count is how many items of the pair had this outcome in the run.
	Count int
}

// LogAttrs are the count fields of a run log line (Errors and StuckItems are logged separately).
func (r Result) LogAttrs() []any {
	return []any{
		"due", r.Due, "done", r.Done, "failed", r.Failed, "unknown_kind", r.UnknownKind, "contended", r.Contended,
		"write_failed", r.WriteFailed, "deferred", r.Deferred, "undecodable", r.Undecodable, "stuck", r.Stuck,
	}
}

// noteError records err for (kind, outcome): the first cause is kept, later ones only count.
func (r *Result) noteError(kind, outcome, cause string) {
	for i := range r.Errors {
		if r.Errors[i].Kind == kind && r.Errors[i].Outcome == outcome {
			r.Errors[i].Count++
			return
		}
	}
	if len(r.Errors) < MaxResultErrors {
		r.Errors = append(r.Errors, ItemError{Kind: kind, Outcome: outcome, Cause: cause, Count: 1})
	}
}

// minKeyRedact is the shortest key scrubCause replaces (a short key would match unrelated text; real keys are ids).
const minKeyRedact = 8

// scrubCause is err's cause chain with the item's uid hashed, its key (a post or beacon id) and any document path or
// edge id removed, so it is safe for a log line next to uid_hash.
func scrubCause(err error, it Item) string {
	msg := logger.ScrubErr(err, it.UID).Error()
	if len(it.Key) >= minKeyRedact {
		msg = strings.ReplaceAll(msg, it.Key, "<key>")
	}
	return msg
}

// Sweep runs one pass: the due items (oldest nextAttemptAt first, at most BatchSize), each claimed and then run. Its error
// is the due query's alone (nothing was processed); per-item outcomes are in Result. It stops early, counting the rest as
// Deferred, when ctx ends.
func (o *Outbox) Sweep(ctx context.Context) (Result, error) {
	var res Result
	now := o.cfg.Now()
	items, st, err := o.b.due(ctx, now, o.cfg.BatchSize)
	if err != nil {
		return res, fmt.Errorf("outbox: due query: %w", err)
	}
	res.Due = len(items)
	res.Undecodable = st.undecodable
	if st.undecodable > 0 {
		res.noteError("", "undecodable", st.decodeCause)
	}
	if st.pushBackFailed > 0 {
		res.WriteFailed += st.pushBackFailed
		res.noteError("", "write_failed", st.pushBackCause)
	}
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

// errWrite wraps a claim or remove failure.
var errWrite = errors.New("outbox: write failed")

// runOne claims it, runs its handler and removes it on success, counting the outcome (and the first cause) in res.
func (o *Outbox) runOne(ctx context.Context, it Item, res *Result) {
	err := o.claimAndRun(ctx, it, res)
	switch {
	case err == nil:
		res.Done++
	case errors.Is(err, errContended):
		res.Contended++
	case errors.Is(err, errNoHandler):
		res.UnknownKind++
		res.noteError(it.Kind, "unknown_kind", scrubCause(err, it))
	case errors.Is(err, errWrite):
		res.WriteFailed++
		res.noteError(it.Kind, "write_failed", scrubCause(err, it))
	default:
		res.Failed++
		res.noteError(it.Kind, "failed", scrubCause(err, it))
	}
}

// claimAndRun is the claim → run → remove protocol shared by Sweep and RunNow. res is nil on the RunNow path; a stuck
// item is still reported there through Config.OnStuck.
func (o *Outbox) claimAndRun(ctx context.Context, it Item, res *Result) error {
	prev := it.Attempts
	attempts := prev + 1
	ut, ok, err := o.b.claim(ctx, it, attempts, o.cfg.Now().Add(o.backoff(attempts)))
	if err != nil {
		return fmt.Errorf("%w: claim: %w", errWrite, err)
	}
	if !ok {
		return errContended
	}
	it.Attempts, it.updateTime = attempts, ut
	// stuck notes an item whose failed attempt crossed StuckAfter (prev below, attempts at or above: once per item).
	stuck := func(cause error) {
		if attempts < o.cfg.StuckAfter || prev >= o.cfg.StuckAfter {
			return
		}
		s := StuckItem{Kind: it.Kind, UIDHash: logger.HashUID(it.UID), Cause: scrubCause(cause, it)}
		if res != nil {
			res.Stuck++
			res.StuckItems = append(res.StuckItems, s)
		}
		if o.cfg.OnStuck != nil {
			o.cfg.OnStuck(ctx, s)
		}
	}
	h, ok := o.handlers[it.Kind]
	if !ok {
		err := fmt.Errorf("%w %s", errNoHandler, it.Kind)
		stuck(err)
		return err
	}
	if err := safeRun(ctx, h, it); err != nil {
		err = fmt.Errorf("outbox: %s: %w", it.Kind, err)
		stuck(err)
		return err
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
// error. A kind with no handler is an error. An item that crosses StuckAfter here is reported through Config.OnStuck.
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
