//go:build integration

package keys

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// seedDevice registers a device at it0 and uploads n one-time packages (from the given offset) and an optional last
// resort, in batches of MaxUploadBatch.
func (e *repoEnv) seedDevice(t *testing.T, uid string, dev int, from, n int, lastResort []byte) {
	t.Helper()
	ctx := context.Background()
	e.mustRegister(t, uid, dvc(dev), skey(byte(dev)), it0)
	for i := from; i < from+n; i += MaxUploadBatch {
		if _, _, err := e.repo.Upload(ctx, uid, dvc(dev), pkgRange(i, min(i+MaxUploadBatch, from+n)), nil, it0); err != nil {
			t.Fatal(err)
		}
	}
	if lastResort != nil {
		if _, _, err := e.repo.Upload(ctx, uid, dvc(dev), nil, lastResort, it0); err != nil {
			t.Fatal(err)
		}
	}
}

func (e *repoEnv) poolCount(t *testing.T, uid string, dev int) int64 {
	t.Helper()
	return e.snap(t, uid, dvc(dev)).Data()["poolCount"].(int64)
}

// A claim removes exactly one pool document per active device (the claimed one), decrements poolCount by one, leaves
// the excluded device's pool alone and does not move lastSeenAt.
func TestClaim_OnePerDeviceAndExcludedKeepsPool(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 5, nil)
	e.seedDevice(t, uid, 2, 100, 3, []byte("lr-2"))
	e.seedDevice(t, uid, 3, 200, 4, nil)
	before := e.snap(t, uid, dvc(1)).UpdateTime

	got, err := e.repo.Claim(ctx, uid, dvc(3), it0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].DeviceID != dvc(1) || got[1].DeviceID != dvc(2) {
		t.Fatalf("claimed %+v, want devices 1 and 2 (oldest first, 3 excluded)", got)
	}
	for i, c := range got {
		dev := i + 1
		if !c.HasKeyPackage || c.LastResort || !bytes.Equal(c.SignatureKey, skey(byte(dev))) {
			t.Fatalf("device %d: %+v", dev, c)
		}
		if _, err := e.repo.poolCol(uid, dvc(dev)).Doc(pkgDocID(c.KeyPackage)).Get(ctx); err == nil {
			t.Fatalf("device %d: the claimed package is still in the pool", dev)
		}
		e.assertPoolInvariant(t, uid, dvc(dev))
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 4 {
		t.Fatalf("device 1 pool = %d, want 4", n)
	}
	if n := len(e.poolDocs(t, uid, dvc(2))); n != 2 {
		t.Fatalf("device 2 pool = %d, want 2", n)
	}
	if n := len(e.poolDocs(t, uid, dvc(3))); n != 4 || e.poolCount(t, uid, 3) != 4 {
		t.Fatalf("excluded device pool = %d (count %d), want 4", n, e.poolCount(t, uid, 3))
	}
	d := e.snap(t, uid, dvc(1))
	if !d.Data()["lastSeenAt"].(time.Time).Equal(it0) {
		t.Fatalf("lastSeenAt moved to %v", d.Data()["lastSeenAt"])
	}
	if d.UpdateTime.Equal(before) {
		t.Fatal("device document not updated (poolCount should have changed)")
	}
}

// An exclude that names none of the target's devices consumes nothing; inactive devices (exactly 30 days unseen) are
// left out of the claim and of ActiveDevices.
func TestClaim_UnknownExcludeAndInactive(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 3, nil)
	if _, err := e.repo.Claim(ctx, uid, dvc(9), it0); !errors.Is(err, ErrExcludeNotFound) {
		t.Fatalf("err = %v, want ErrExcludeNotFound", err)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 3 {
		t.Fatalf("pool = %d after a refused claim", n)
	}

	e.seedDevice(t, uid, 2, 50, 3, nil)
	if _, _, err := e.repo.Upload(ctx, uid, dvc(2), nil, []byte("lr"), it0.Add(InactiveAfter-time.Hour)); err != nil {
		t.Fatal(err) // device 2 seen again 30 days minus an hour later
	}
	at := it0.Add(InactiveAfter) // device 1: exactly 30 days unseen
	act, err := e.repo.ActiveDevices(ctx, uid, at)
	if err != nil || len(act) != 1 || act[0].ID != dvc(2) || act[0].PoolCount != 3 || !act[0].HasLastResort {
		t.Fatalf("active %+v, %v; want device 2 only", act, err)
	}
	got, err := e.repo.Claim(ctx, uid, "", at)
	if err != nil || len(got) != 1 || got[0].DeviceID != dvc(2) {
		t.Fatalf("claimed %+v, %v; want device 2 only", got, err)
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 3 {
		t.Fatalf("inactive device's pool = %d", n)
	}
	// An inactive device can still be the excluded one.
	if _, err := e.repo.Claim(ctx, uid, dvc(1), at); err != nil {
		t.Fatalf("excluding an inactive device: %v", err)
	}
	if got, err := e.repo.Claim(ctx, uniqueUID(), "", at); err != nil || len(got) != 0 {
		t.Fatalf("user without devices: %+v, %v", got, err)
	}
}

// Draining a full pool hands out 100 distinct packages, then the last-resort package repeatedly (kept); a device with
// neither answers HasKeyPackage false. poolCount follows the real count throughout.
func TestClaim_DrainThenLastResort(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, MaxPoolSize, []byte("last-resort-1"))
	e.seedDevice(t, uid, 2, 500, 0, nil)
	seen := map[string]bool{}
	for i := 0; i < MaxPoolSize; i++ {
		got, err := e.repo.Claim(ctx, uid, "", it0)
		if err != nil {
			t.Fatalf("claim %d: %v", i, err)
		}
		c := got[0]
		if !c.HasKeyPackage || c.LastResort || seen[string(c.KeyPackage)] {
			t.Fatalf("claim %d: %+v (seen before: %v)", i, c, seen[string(c.KeyPackage)])
		}
		seen[string(c.KeyPackage)] = true
		if got[1].HasKeyPackage || got[1].LastResort || len(got[1].KeyPackage) != 0 {
			t.Fatalf("claim %d: empty device answered %+v", i, got[1])
		}
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	for i := 0; i < 3; i++ {
		got, err := e.repo.Claim(ctx, uid, "", it0)
		if err != nil {
			t.Fatal(err)
		}
		if c := got[0]; !c.HasKeyPackage || !c.LastResort || string(c.KeyPackage) != "last-resort-1" {
			t.Fatalf("after drain %d: %+v, want the last resort", i, c)
		}
	}
	if e.poolCount(t, uid, 1) != 0 {
		t.Fatalf("poolCount = %d after drain", e.poolCount(t, uid, 1))
	}
}

// A poolCount that claims packages the pool does not have falls back to the last resort and writes no negative count;
// the pool query, not the counter, decides.
func TestClaim_StaleCounterFallsBack(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 0, []byte("lr"))
	if _, err := e.repo.deviceRef(uid, dvc(1)).Update(ctx, []firestore.Update{{Path: "poolCount", Value: 2}}); err != nil {
		t.Fatal(err)
	}
	got, err := e.repo.Claim(ctx, uid, "", it0)
	if err != nil || len(got) != 1 || !got[0].LastResort {
		t.Fatalf("claimed %+v, %v; want the last resort", got, err)
	}
	if c := e.poolCount(t, uid, 1); c < 0 {
		t.Fatalf("poolCount = %d", c)
	}
}

// Twenty concurrent claims against one device with twenty packages each get a distinct package, and the pool ends
// empty with a true count. All twenty must succeed within the repository's transaction retry budget.
func TestClaim_TwentyConcurrentClaimsGetDistinctPackages(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	const n = 20
	e.seedDevice(t, uid, 1, 0, n, []byte("lr"))

	var (
		wg       sync.WaitGroup
		start    = make(chan struct{})
		mu       sync.Mutex
		got      = map[string]int{}
		attempts int
		errs     []error
	)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, info := logger.WithRequestInfo(context.Background())
			<-start
			cl, err := e.repo.Claim(ctx, uid, "", it0)
			a, _ := info.Get("txn_attempts")
			mu.Lock()
			defer mu.Unlock()
			if v, ok := a.(int64); ok {
				attempts += int(v)
			}
			if err != nil {
				errs = append(errs, err)
				return
			}
			if len(cl) != 1 || !cl[0].HasKeyPackage || cl[0].LastResort {
				errs = append(errs, errors.New("claim did not get a one-time package"))
				return
			}
			got[string(cl[0].KeyPackage)]++
		}()
	}
	began := time.Now()
	close(start)
	wg.Wait()
	t.Logf("20 concurrent claims: %v, %d transaction body runs in all, %d errors, %d pool documents left",
		time.Since(began), attempts, len(errs), len(e.poolDocs(t, uid, dvc(1))))
	for _, err := range errs {
		t.Errorf("claim failed: %v", err)
	}
	for p, c := range got {
		if c != 1 {
			t.Errorf("package %q handed out %d times", p, c)
		}
	}
	if len(got) != n-len(errs) {
		t.Errorf("%d distinct packages for %d successful claims", len(got), n-len(errs))
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if len(errs) == 0 && e.poolCount(t, uid, 1) != 0 {
		t.Errorf("poolCount = %d, want 0", e.poolCount(t, uid, 1))
	}
}

// A Claim that commits between the sweep's page query and its batch: the page deletion fails on the vanished
// document, re-lists and retries, so a device that survives keeps a true poolCount.
func TestRepo_SweepRacingClaimKeepsCount(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 5, nil)
	fired := 0
	e.repo.beforePageDelete = func() {
		fired++
		if fired == 1 {
			if _, err := e.repo.Claim(ctx, uid, "", it0); err != nil {
				t.Errorf("claim in the window: %v", err)
			}
		}
	}
	if err := e.repo.sweepPool(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if c := e.poolCount(t, uid, 1); c != 0 {
		t.Fatalf("poolCount = %d, want 0", c)
	}
	if fired != 2 {
		t.Fatalf("sweep ran %d page deletions, want 2 (one retry)", fired)
	}
}

// The same race through a whole Remove leaves neither a device nor a pool.
func TestRepo_RemoveRacingClaimLeavesNothing(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 5, []byte("lr"))
	fired := 0
	e.repo.beforePageDelete = func() {
		fired++
		if fired == 1 {
			if _, err := e.repo.Claim(ctx, uid, "", it0); err != nil {
				t.Errorf("claim in the window: %v", err)
			}
		}
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err == nil {
		t.Fatal("device document left")
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
		t.Fatalf("%d pool documents left", n)
	}
}
