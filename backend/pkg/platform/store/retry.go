package store

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ErrContended is returned (wrapping the last Aborted error) when CommitWithRetry exhausted its attempts.
var ErrContended = errors.New("store: write contention")

// TxnWarnAttempts is the ADR-0008/ADR-0010 contention threshold: more attempts than this log one WARN.
const TxnWarnAttempts = 3

// NoteTxnAttempts records txn_attempts on the request's log line (ADR-0010 D20) and WARNs under real
// contention. event names the module's WARN (e.g. "graph_txn_contention"); no ids are logged.
func NoteTxnAttempts(ctx context.Context, event string, attempts int) {
	logger.SetRequestField(ctx, "txn_attempts", attempts)
	if attempts > TxnWarnAttempts {
		slog.WarnContext(ctx, event, "txn_attempts", attempts)
	}
}

// IsContention reports whether err is Firestore's lost-lock-race answer (Aborted, or the emulator's
// "Transaction lock timeout" surfaced as such): safe to retry, nothing was written.
func IsContention(err error) bool { return status.Code(err) == codes.Aborted }

// IsPreconditionFailed reports whether err is the Firestore error for a failed batch precondition (e.g. Exists
// on a missing doc). Firestore surfaces it as NotFound or FailedPrecondition depending on SDK/emulator, so
// both mean "the precondition wasn't met" (a no-op, not a real error).
func IsPreconditionFailed(err error) bool {
	code := status.Code(err)
	return code == codes.NotFound || code == codes.FailedPrecondition
}

// Wait sleeps for a full-jitter delay in [0, ceiling), returning ctx.Err() if the context ends first. Full
// jitter de-synchronises concurrent retries that lost the same lock race.
func Wait(ctx context.Context, ceiling time.Duration) error {
	t := time.NewTimer(rand.N(max(ceiling, 1)))
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// RetryConfig tunes CommitWithRetry. Commit and Sleep are test seams; nil means the real commit and Wait.
type RetryConfig struct {
	MaxAttempts int           // total attempts, >= 1
	Backoff     time.Duration // first jitter ceiling, doubled per retry
	Commit      func(ctx context.Context, b *FirestoreBatch) error
	Sleep       func(ctx context.Context, ceiling time.Duration) error
}

// RetryResult is the outcome of CommitWithRetry.
type RetryResult struct {
	Committed bool // false with a nil error: the batch's precondition failed (a 0-write no-op)
	Attempts  int  // attempts made, for NoteTxnAttempts
}

// CommitWithRetry builds and commits a precondition batch (a bare batch commit is not retried by the SDK, unlike
// RunTransaction) with bounded, full-jitter exponential retry on contention. Each attempt counts into a scratch
// counter folded into the request's counter only on success, so a lost race or failed precondition reports 0
// writes. build must be repeatable. Errors other than contention/precondition are returned as is; exhausting
// the attempts returns an error wrapping ErrContended; a context ending mid-backoff returns ctx's error.
func CommitWithRetry(ctx context.Context, newBatch func(*budget.Counter) *FirestoreBatch, cfg RetryConfig, build func(Batch)) (RetryResult, error) {
	sleep := cfg.Sleep
	if sleep == nil {
		sleep = Wait
	}
	var lastErr error
	for attempt := 0; attempt < cfg.MaxAttempts; attempt++ {
		if attempt > 0 {
			if err := sleep(ctx, cfg.Backoff<<(attempt-1)); err != nil {
				return RetryResult{Attempts: attempt}, err
			}
		}
		var scratch budget.Counter
		b := newBatch(&scratch)
		build(b)
		var err error
		if cfg.Commit != nil {
			err = cfg.Commit(ctx, b)
		} else {
			err = b.Commit(ctx)
		}
		switch {
		case err == nil:
			c := budget.FromContext(ctx)
			c.AddWrites(scratch.Writes())
			c.AddDeletes(scratch.Deletes())
			return RetryResult{Committed: true, Attempts: attempt + 1}, nil
		case IsPreconditionFailed(err):
			return RetryResult{Attempts: attempt + 1}, nil
		case IsContention(err):
			lastErr = err
		default:
			return RetryResult{Attempts: attempt + 1}, err
		}
	}
	return RetryResult{Attempts: cfg.MaxAttempts}, errors.Join(ErrContended, lastErr)
}
