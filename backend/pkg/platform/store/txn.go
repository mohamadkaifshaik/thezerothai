package store

import (
	"context"

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
func RunTransaction(ctx context.Context, client TxnRunner, fn TxnFunc) (attempts int, err error) {
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
	})
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
