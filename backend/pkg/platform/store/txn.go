package store

import (
	"context"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TxnRunner is the part of *firestore.Client RunTransaction needs (a seam for unit tests of the accounting).
type TxnRunner interface {
	RunTransaction(ctx context.Context, f func(context.Context, *firestore.Transaction) error, opts ...firestore.TransactionOption) error
}

// TxnFunc is a transaction body. The ctx it receives carries a per-attempt scratch budget counter: code in the body
// keeps calling budget.FromContext(ctx) (and NewFirestoreTxBatch(tx, thatCounter)) unchanged.
type TxnFunc func(ctx context.Context, tx *firestore.Transaction) error

// RunTransaction is client.RunTransaction with correct budget accounting. A body counts its writes when it queues
// them, but Firestore retries an Aborted transaction by re-running the body, and only the final attempt can commit.
// Each attempt therefore counts into its own scratch counter. Reads are real on every attempt and are always folded
// into the request's counter; writes and deletes are folded only when the transaction commits (a rolled-back or
// failed transaction wrote nothing). It returns the number of body runs, for NoteTxnAttempts.
func RunTransaction(ctx context.Context, client TxnRunner, fn TxnFunc, opts ...firestore.TransactionOption) (attempts int, err error) {
	var reads int64
	var last *budget.Counter
	err = client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		attempts++
		if last != nil {
			reads += last.Reads()
		}
		actx, scratch := budget.WithCounter(ctx)
		last = scratch
		return fn(actx, tx)
	}, opts...)
	real := budget.FromContext(ctx)
	if last != nil {
		reads += last.Reads()
	}
	real.AddReads(reads)
	if err == nil && last != nil {
		real.AddWrites(last.Writes())
		real.AddDeletes(last.Deletes())
	}
	return attempts, err
}

// TxnRetry bounds RunTransactionRetry: the whole call (all runs) ends after Timeout; a transaction that still reports
// contention after the SDK's own attempts is re-run up to MaxRuns times in all, with a full-jitter wait that starts at
// Backoff and doubles.
type TxnRetry struct {
	Timeout time.Duration
	MaxRuns int
	Backoff time.Duration
	// Options are passed to every run (for example firestore.ReadOnly for a body that only reads: no locks, no commit).
	Options []firestore.TransactionOption
}

// RunTransactionRetry is RunTransaction re-run a bounded number of times when Firestore reports contention (Aborted)
// after the SDK's own attempts, under one overall timeout. It returns the total number of body runs, for
// NoteTxnAttempts. Budget accounting is RunTransaction's: only the committing run's writes are counted.
func RunTransactionRetry(ctx context.Context, client TxnRunner, cfg TxnRetry, fn TxnFunc) (int, error) {
	if cfg.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, cfg.Timeout)
		defer cancel()
	}
	total := 0
	var err error
	for run := 0; run < max(cfg.MaxRuns, 1); run++ {
		if run > 0 {
			if werr := Wait(ctx, cfg.Backoff<<(run-1)); werr != nil {
				return total, werr
			}
		}
		var n int
		n, err = RunTransaction(ctx, client, fn, cfg.Options...)
		total += n
		if !IsContention(err) {
			break
		}
	}
	return total, err
}
