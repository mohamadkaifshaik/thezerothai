package store

import (
	"context"
	"time"

	"cloud.google.com/go/firestore"
)

// TxnRunner is the part of *firestore.Client RunTransaction needs (a seam for unit tests).
type TxnRunner interface {
	RunTransaction(ctx context.Context, f func(context.Context, *firestore.Transaction) error, opts ...firestore.TransactionOption) error
}

// TxnFunc is a transaction body. Firestore re-runs it when it retries an Aborted transaction.
type TxnFunc func(ctx context.Context, tx *firestore.Transaction) error

// RunTransaction is client.RunTransaction that also returns the number of body runs, for NoteTxnAttempts.
func RunTransaction(ctx context.Context, client TxnRunner, fn TxnFunc, opts ...firestore.TransactionOption) (attempts int, err error) {
	err = client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		attempts++
		return fn(ctx, tx)
	}, opts...)
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
// NoteTxnAttempts.
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
