package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeRunner re-runs the body `runs` times like the SDK retrying Aborted attempts, returning the last body's result
// (or finalErr if set, as when the commit itself fails).
type fakeRunner struct {
	runs     int
	finalErr error
}

func (f fakeRunner) RunTransaction(ctx context.Context, fn func(context.Context, *firestore.Transaction) error, _ ...firestore.TransactionOption) error {
	var err error
	for range f.runs {
		if err = fn(ctx, nil); err != nil {
			return err
		}
	}
	return f.finalErr
}

// TestRunTransaction_RetriesDoNotInflateWrites: a transaction retried after Aborted counts every attempt's reads
// (they happened) but only the committed attempt's writes and deletes.
func TestRunTransaction_RetriesDoNotInflateWrites(t *testing.T) {
	tests := []struct {
		name                 string
		runs                 int
		finalErr             error
		wantReads            int64
		wantWrites, wantDels int64
		wantAttempts         int
	}{
		{"single attempt commits", 1, nil, 2, 3, 1, 1},
		{"six concurrent callers: five aborted attempts", 6, nil, 12, 3, 1, 6},
		{"commit fails: reads count, nothing was written", 3, errors.New("commit failed"), 6, 0, 0, 3},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, c := budget.WithCounter(context.Background())
			attempts, err := RunTransaction(ctx, fakeRunner{runs: tt.runs, finalErr: tt.finalErr}, func(ctx context.Context, _ *firestore.Transaction) error {
				counter := budget.FromContext(ctx)
				counter.AddReads(2)
				counter.AddWrites(3)
				counter.AddDeletes(1)
				return nil
			})
			if (err != nil) != (tt.finalErr != nil) || attempts != tt.wantAttempts {
				t.Fatalf("attempts %d, err %v", attempts, err)
			}
			if c.Reads() != tt.wantReads || c.Writes() != tt.wantWrites || c.Deletes() != tt.wantDels {
				t.Errorf("reads/writes/deletes = %d/%d/%d, want %d/%d/%d", c.Reads(), c.Writes(), c.Deletes(), tt.wantReads, tt.wantWrites, tt.wantDels)
			}
		})
	}
}

func TestRunTransaction_BodyErrorCountsNoWrites(t *testing.T) {
	ctx, c := budget.WithCounter(context.Background())
	boom := errors.New("boom")
	_, err := RunTransaction(ctx, fakeRunner{runs: 1}, func(ctx context.Context, _ *firestore.Transaction) error {
		budget.FromContext(ctx).AddReads(1)
		budget.FromContext(ctx).AddWrites(1)
		return boom
	})
	if !errors.Is(err, boom) || c.Reads() != 1 || c.Writes() != 0 {
		t.Errorf("err %v reads %d writes %d", err, c.Reads(), c.Writes())
	}
}

// scriptedRunner answers each RunTransaction call with the next error of its script (nil = commit), running the body
// once per call, like the SDK after its own attempts.
type scriptedRunner struct {
	script []error
	calls  int
}

func (s *scriptedRunner) RunTransaction(ctx context.Context, fn func(context.Context, *firestore.Transaction) error, _ ...firestore.TransactionOption) error {
	i := s.calls
	s.calls++
	if err := fn(ctx, nil); err != nil {
		return err
	}
	if i < len(s.script) {
		return s.script[i]
	}
	return nil
}

// TestRunTransactionRetry_BoundedReruns: contention re-runs the transaction up to MaxRuns in all; any other result
// (success or a different error) stops at once; the run count is the total number of body runs.
func TestRunTransactionRetry_BoundedReruns(t *testing.T) {
	aborted := status.Error(codes.Aborted, "lock")
	boom := errors.New("boom")
	tests := []struct {
		name         string
		script       []error
		wantErr      error
		wantAttempts int
	}{
		{"commits first time", nil, nil, 1},
		{"one conflict then commits", []error{aborted}, nil, 2},
		{"conflict on every run gives up after MaxRuns", []error{aborted, aborted, aborted, aborted, aborted}, aborted, 3},
		{"other error is not retried", []error{boom}, boom, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &scriptedRunner{script: tt.script}
			attempts, err := RunTransactionRetry(context.Background(), r, TxnRetry{Timeout: time.Second, MaxRuns: 3, Backoff: time.Microsecond}, func(context.Context, *firestore.Transaction) error { return nil })
			if tt.wantErr == nil && err != nil || tt.wantErr != nil && !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if attempts != tt.wantAttempts {
				t.Errorf("attempts = %d, want %d", attempts, tt.wantAttempts)
			}
		})
	}
}

// optionRunner records how many transaction options each RunTransaction call received.
type optionRunner struct{ got []int }

func (o *optionRunner) RunTransaction(ctx context.Context, fn func(context.Context, *firestore.Transaction) error, opts ...firestore.TransactionOption) error {
	o.got = append(o.got, len(opts))
	return fn(ctx, nil)
}

// TestRunTransactionRetry_PassesOptionsToEveryRun: TxnRetry.Options (for example firestore.ReadOnly) reaches the SDK on
// each run, and a call without options passes none.
func TestRunTransactionRetry_PassesOptionsToEveryRun(t *testing.T) {
	body := func(context.Context, *firestore.Transaction) error { return nil }
	with, without := &optionRunner{}, &optionRunner{}
	if _, err := RunTransactionRetry(context.Background(), with, TxnRetry{MaxRuns: 2, Options: []firestore.TransactionOption{firestore.ReadOnly}}, body); err != nil {
		t.Fatal(err)
	}
	if _, err := RunTransactionRetry(context.Background(), without, TxnRetry{MaxRuns: 2}, body); err != nil {
		t.Fatal(err)
	}
	if len(with.got) != 1 || with.got[0] != 1 || len(without.got) != 1 || without.got[0] != 0 {
		t.Errorf("options seen: with %v, without %v", with.got, without.got)
	}
}
