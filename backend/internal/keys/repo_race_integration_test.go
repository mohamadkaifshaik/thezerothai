//go:build integration

package keys

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// assertPoolInvariant fails unless the stored poolCount equals the real number of pool documents.
func (e *repoEnv) assertPoolInvariant(t *testing.T, uid, id string) {
	t.Helper()
	got := e.snap(t, uid, id).Data()["poolCount"].(int64)
	if real := len(e.poolDocs(t, uid, id)); got != int64(real) {
		t.Fatalf("poolCount = %d, real pool documents = %d", got, real)
	}
}

// An Upload that commits between the pool sweep and the final transaction must not leave a device-less pool: Remove
// notices the refill, sweeps again and then deletes the device.
func TestRepo_RemoveRacingUploadLeavesNoOrphans(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 3), nil, it0); err != nil {
		t.Fatal(err)
	}
	fired := 0
	e.repo.afterPoolSweep = func() {
		fired++
		if fired == 1 {
			if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(10, 12), nil, it0); err != nil {
				t.Errorf("upload in the window: %v", err)
			}
		}
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if fired != 2 {
		t.Fatalf("Remove ran %d rounds, want 2 (one refill)", fired)
	}
	if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err == nil {
		t.Fatal("device document left")
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
		t.Fatalf("%d orphan pool documents", n)
	}
	if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 1), nil, it0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("upload after remove = %v", err)
	}
}

// A pool that refills every round ends Remove with a contention-class error and leaves a device with a true poolCount.
func TestRepo_RemoveGivesUpWhenPoolKeepsRefilling(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	n := 0
	e.repo.afterPoolSweep = func() {
		n++
		if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(n*10, n*10+2), nil, it0); err != nil {
			t.Errorf("upload in the window: %v", err)
		}
	}
	err := e.repo.Remove(ctx, uid, dvc(1))
	if !store.IsContention(err) || n != removeRounds {
		t.Fatalf("err = %v (contention=%v), rounds = %d, want contention after %d", err, store.IsContention(err), n, removeRounds)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	e.repo.afterPoolSweep = nil
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatalf("retry: %v", err)
	}
}

// Remove and Upload racing for real: whatever the order, either nothing is left or the device has a true poolCount.
func TestRepo_ConcurrentRemoveUploadNeverOrphans(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	for round := 0; round < 10; round++ {
		uid := uniqueUID()
		e.mustRegister(t, uid, dvc(1), skey(1), it0)
		if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 5), nil, it0); err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		start := make(chan struct{})
		var rmErr, upErr error
		wg.Add(2)
		go func() { defer wg.Done(); <-start; rmErr = e.repo.Remove(ctx, uid, dvc(1)) }()
		go func() {
			defer wg.Done()
			<-start
			_, _, upErr = e.repo.Upload(ctx, uid, dvc(1), pkgRange(50, 55), nil, it0)
		}()
		close(start)
		wg.Wait()
		if rmErr != nil && !store.IsContention(rmErr) {
			t.Fatalf("round %d: remove: %v", round, rmErr)
		}
		if upErr != nil && !errors.Is(upErr, ErrNotFound) && !store.IsContention(upErr) {
			t.Fatalf("round %d: upload: %v", round, upErr)
		}
		if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err != nil {
			if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
				t.Fatalf("round %d: device gone but %d pool documents left", round, n)
			}
			continue
		}
		e.assertPoolInvariant(t, uid, dvc(1))
	}
}

// Pool documents under a device document that does not exist (written before the fix, or a crash mid-remove) are deleted
// by Remove, and Remove of a missing device without a pool succeeds.
func TestRepo_RemoveMissingDeviceDeletesOrphans(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	for i := 0; i < 3; i++ {
		p := pkgN(i)
		if _, err := e.repo.poolCol(uid, dvc(1)).Doc(pkgDocID(p)).Create(ctx, packageDoc{Data: p, CreatedAt: it0}); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
		t.Fatalf("%d orphan pool documents left", n)
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatalf("remove of nothing: %v", err)
	}
}

// The repository refuses an oversized batch before any read, even for a device that does not exist.
func TestRepo_UploadBatchGuard(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	_, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, MaxUploadBatch+1), nil, it0)
	var ae *apierr.Error
	if !errors.As(err, &ae) || errors.Is(err, ErrNotFound) {
		t.Fatalf("101 packages err = %v, want a validation error before any lookup", err)
	}
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	if n, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, MaxUploadBatch), nil, it0); err != nil || n != MaxUploadBatch {
		t.Fatalf("exactly 100 = %d, %v", n, err)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
}
