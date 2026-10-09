package store

import (
	"context"
	"errors"
	"testing"

	"cloud.google.com/go/firestore"

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
