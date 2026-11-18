//go:build integration

package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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

// claimRace is the outcome of n claims started together against one user with one device.
type claimRace struct {
	oneTime    map[string]int // package bytes -> times handed out
	lastResort int
	retries    int
	errs       []error
	took       time.Duration
}

// raceClaims starts n claims of uid behind one barrier and collects what each got.
func (e *repoEnv) raceClaims(t *testing.T, uid string, n int) claimRace {
	t.Helper()
	res := claimRace{oneTime: map[string]int{}}
	var (
		wg    sync.WaitGroup
		start = make(chan struct{})
		mu    sync.Mutex
	)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, info := logger.WithRequestInfo(context.Background())
			<-start
			cl, err := e.repo.Claim(ctx, uid, "", it0)
			r, _ := info.Get(fieldClaimRetries)
			mu.Lock()
			defer mu.Unlock()
			if v, ok := r.(int64); ok {
				res.retries += int(v)
			}
			switch {
			case err != nil:
				res.errs = append(res.errs, err)
			case len(cl) != 1 || !cl[0].HasKeyPackage:
				res.errs = append(res.errs, fmt.Errorf("claim answered %+v", cl))
			case cl[0].LastResort:
				res.lastResort++
			default:
				res.oneTime[string(cl[0].KeyPackage)]++
			}
		}()
	}
	began := time.Now()
	close(start)
	wg.Wait()
	res.took = time.Since(began)
	return res
}

// wantDistinct fails unless every one-time package went to exactly one claimer, all from the seeded range.
func wantDistinct(t *testing.T, res claimRace, from, to int) {
	t.Helper()
	valid := map[string]bool{}
	for _, p := range pkgRange(from, to) {
		valid[string(p)] = true
	}
	for p, c := range res.oneTime {
		if c != 1 || !valid[p] {
			t.Errorf("package %q handed out %d times (seeded: %v)", p, c, valid[p])
		}
	}
	for _, err := range res.errs {
		t.Errorf("claim failed: %v", err)
	}
}

// Twenty concurrent claims against one device with twenty packages: every claim succeeds with a distinct one-time
// package, and the pool ends empty with a true count of 0.
func TestClaim_TwentyConcurrentClaimsGetDistinctPackages(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	const n = 20
	e.seedDevice(t, uid, 1, 0, n, []byte("lr"))
	res := e.raceClaims(t, uid, n)
	t.Logf("20 concurrent claims: %v, %d pick retries in all, %d errors, %d last resort, %d pool documents left",
		res.took, res.retries, len(res.errs), res.lastResort, len(e.poolDocs(t, uid, dvc(1))))
	wantDistinct(t, res, 0, n)
	if len(res.oneTime) != n || res.lastResort != 0 {
		t.Errorf("%d one-time packages and %d last resorts, want %d and 0", len(res.oneTime), res.lastResort, n)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if c := e.poolCount(t, uid, 1); c != 0 {
		t.Errorf("poolCount = %d, want 0", c)
	}
}

// Forty concurrent claims against twenty packages: twenty distinct one-time packages, twenty last-resort answers, no
// error, and a true count of 0.
func TestClaim_FortyClaimsTwentyPackages(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	e.seedDevice(t, uid, 1, 0, 20, []byte("lr"))
	res := e.raceClaims(t, uid, 40)
	t.Logf("40 concurrent claims: %v, %d pick retries in all, %d errors", res.took, res.retries, len(res.errs))
	wantDistinct(t, res, 0, 20)
	if len(res.oneTime) != 20 || res.lastResort != 20 {
		t.Errorf("%d one-time packages and %d last resorts, want 20 and 20", len(res.oneTime), res.lastResort)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if c := e.poolCount(t, uid, 1); c != 0 {
		t.Errorf("poolCount = %d, want 0", c)
	}
}

// A claim racing a Remove of the device answers a package (one-time or last resort) or no device, never an error, and
// leaves either nothing or a device whose poolCount equals its real pool.
func TestClaim_RacingRemove(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	for round := 0; round < 10; round++ {
		uid := uniqueUID()
		e.seedDevice(t, uid, 1, 0, 10, []byte("lr"))
		var wg sync.WaitGroup
		start := make(chan struct{})
		var claimed []Claimed
		var claimErr, removeErr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			claimed, claimErr = e.repo.Claim(ctx, uid, "", it0)
		}()
		go func() {
			defer wg.Done()
			<-start
			removeErr = e.repo.Remove(ctx, uid, dvc(1))
		}()
		close(start)
		wg.Wait()
		if claimErr != nil || removeErr != nil {
			t.Fatalf("round %d: claim %v, remove %v", round, claimErr, removeErr)
		}
		if len(claimed) > 1 || len(claimed) == 1 && !claimed[0].HasKeyPackage {
			t.Fatalf("round %d: claimed %+v, want one package or nothing", round, claimed)
		}
		if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err == nil {
			e.assertPoolInvariant(t, uid, dvc(1))
		} else if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
			t.Fatalf("round %d: device gone, %d pool documents left", round, n)
		}
	}
}

// Uploads and claims of one device running concurrently never break the invariant: after every round poolCount
// equals the real number of pool documents.
func TestRepo_ConcurrentUploadClaimKeepsCount(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	for round := 0; round < 10; round++ {
		uid := uniqueUID()
		e.seedDevice(t, uid, 1, 0, 10, nil)
		var wg sync.WaitGroup
		start := make(chan struct{})
		errs := make(chan error, 6)
		for i := 0; i < 4; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				if _, err := e.repo.Claim(ctx, uid, "", it0); err != nil {
					errs <- fmt.Errorf("claim: %w", err)
				}
			}()
		}
		for i := 0; i < 2; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				if _, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(100+10*i, 105+10*i), nil, it0); err != nil {
					errs <- fmt.Errorf("upload: %w", err)
				}
			}()
		}
		close(start)
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Errorf("round %d: %v", round, err)
		}
		e.assertPoolInvariant(t, uid, dvc(1))
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
