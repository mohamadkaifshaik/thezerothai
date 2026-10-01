package ratelimit

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDailyCap_AllowsUpToLimitThenBlocks(t *testing.T) {
	d := NewDailyCap(100)
	now := time.Now()
	d.now = func() time.Time { return now }

	for i := 0; i < 100; i++ {
		if !d.Allow("uid-1") {
			t.Fatalf("call %d should be allowed within the daily cap", i)
		}
	}
	if d.Allow("uid-1") {
		t.Fatal("101st call should be rejected")
	}
}

func TestDailyCap_ResetsAtISTMidnight(t *testing.T) {
	d := NewDailyCap(1)
	// 2026-01-01 23:59:00 IST.
	ist := time.FixedZone("IST", 5*3600+30*60)
	now := time.Date(2026, 1, 1, 23, 59, 0, 0, ist)
	d.now = func() time.Time { return now }

	if !d.Allow("uid-1") {
		t.Fatal("first call should be allowed")
	}
	if d.Allow("uid-1") {
		t.Fatal("second call same IST day should be rejected")
	}

	// Cross the IST day boundary.
	now = now.Add(2 * time.Minute)
	d.now = func() time.Time { return now }
	if !d.Allow("uid-1") {
		t.Fatal("expected the cap to reset after IST midnight")
	}
}

func TestDailyCap_KeysAreIndependent(t *testing.T) {
	d := NewDailyCap(1)
	now := time.Now()
	d.now = func() time.Time { return now }

	if !d.Allow("uid-a") {
		t.Fatal("uid-a first call should be allowed")
	}
	if !d.Allow("uid-b") {
		t.Fatal("uid-b should have its own independent counter")
	}
}

// TestDailyCap_OnlyISTMidnightResets is the L1 regression: the day boundary is the only reset. The entry
// used to expire 24h after its first use, so a first call at 12:00 IST on day 1 granted a fresh allowance at
// 12:00 on day 2 -- twice the cap within one IST day.
func TestDailyCap_OnlyISTMidnightResets(t *testing.T) {
	const limit = 100
	d := NewDailyCap(limit)
	ist := time.FixedZone("IST", 5*3600+30*60)
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, ist)
	d.now = func() time.Time { return now }
	if !d.Allow("uid-1") { // first use, day 1 12:00
		t.Fatal("first call should be allowed")
	}

	// Day 2, 00:01 IST: rolled over; spend the whole allowance before 12:00.
	now = time.Date(2026, 1, 2, 0, 1, 0, 0, ist)
	for i := 0; i < limit; i++ {
		if !d.Allow("uid-1") {
			t.Fatalf("day 2 call %d should be allowed", i)
		}
	}
	// 24h + 5min after first use, still day 2: must remain rejected.
	now = time.Date(2026, 1, 2, 12, 5, 0, 0, ist)
	if d.Allow("uid-1") {
		t.Fatal("cap must not reset 24h after first use within the same IST day")
	}
	// Day 3 rolls over.
	now = time.Date(2026, 1, 3, 0, 0, 1, 0, ist)
	if !d.Allow("uid-1") {
		t.Fatal("cap should reset at the next IST midnight")
	}
}

// headroom reserves and immediately releases (0 units) to ask "would a call be admitted now?".
func headroom(d *DailyCap, key string) bool {
	ok, _ := d.Reserve(key)
	if ok {
		d.Release(key, 0)
	}
	return ok
}

// TestDailyCap_ReserveCharge covers the unit-budget mode (ADR-0010 D5): Reserve checks headroom without
// spending, Charge spends n (the counter may pass the limit by the reads of the calls already admitted; with
// the A1 hold armed that is at most M - 1 above the limit per instance lifetime), the IST rollover resets both.
func TestDailyCap_ReserveCharge(t *testing.T) {
	ist := time.FixedZone("IST", 5*3600+30*60)
	now := time.Date(2026, 1, 1, 23, 59, 0, 0, ist)
	d := NewDailyCap(2000).WithClock(func() time.Time { return now })

	if !headroom(d, "u") || d.Spent("u") != 0 {
		t.Fatal("fresh key must have headroom and spend nothing on Reserve")
	}
	d.Charge("u", 1999)
	d.Charge("u", 0)  // no-op
	d.Charge("u", -5) // no-op
	if d.Spent("u") != 1999 || !headroom(d, "u") {
		t.Fatalf("spent = %d, want 1999 with headroom", d.Spent("u"))
	}
	d.Charge("u", 268) // one call's worst case overshoots the cap
	if d.Spent("u") != 2267 || headroom(d, "u") {
		t.Fatalf("spent = %d, Reserve must now be false", d.Spent("u"))
	}
	if !headroom(d, "other") {
		t.Fatal("keys are independent")
	}

	now = now.Add(2 * time.Minute) // IST midnight
	if !headroom(d, "u") || d.Spent("u") != 0 {
		t.Fatal("IST midnight must reset the budget")
	}
}

// TestDailyCap_AllowSharesCounterWithCharge: Allow is Reserve+Charge(1), on the same counter.
func TestDailyCap_AllowSharesCounterWithCharge(t *testing.T) {
	d := NewDailyCap(3)
	d.Charge("u", 2)
	if !d.Allow("u") {
		t.Fatal("third unit should be allowed")
	}
	if d.Allow("u") {
		t.Fatal("fourth unit must be rejected")
	}
}

func TestDailyCap_ReserveReturnsSpentAndRelease(t *testing.T) {
	d := NewDailyCap(100).WithMaxCallReads(10)
	d.Charge("u", 42)
	ok, spent := d.Reserve("u")
	if !ok || spent != 42 {
		t.Fatalf("Reserve = (%v, %d), want (true, 42)", ok, spent)
	}
	d.Release("u", 7)
	if got := d.Spent("u"); got != 49 {
		t.Fatalf("spent after Release(7) = %d, want 49", got)
	}
	d.Charge("u", 60) // now 109 >= 100
	ok, spent = d.Reserve("u")
	if ok || spent != 109 || d.IsTransient(spent) {
		t.Fatalf("Reserve = (%v, %d, transient=%v), want (false, 109, false): budget exhausted", ok, spent, d.IsTransient(spent))
	}
}

// TestDailyCap_SingleFlightNearCap (M1): inside the last maxCallReads only one call may be in flight; the
// rejection is transient (retry in ~1 s); once the slot is released the next call is admitted, and away from
// the cap concurrency is unrestricted.
func TestDailyCap_SingleFlightNearCap(t *testing.T) {
	d := NewDailyCap(2000).WithMaxCallReads(269)

	// A1: the k-th concurrent call is admitted while spent + k*M <= limit. At 1,000 spent that is 3 calls.
	d.Charge("far", 1000)
	for i := 0; i < 3; i++ {
		if ok, _ := d.Reserve("far"); !ok {
			t.Fatalf("call %d far from the cap must be admitted concurrently", i)
		}
	}
	if ok, spent := d.Reserve("far"); ok || !d.IsTransient(spent) {
		t.Fatalf("4th concurrent call at 1,000 spent: ok=%v, want a transient rejection (1000 + 4*269 > 2000)", ok)
	}

	d.Charge("near", 1999)
	if ok, _ := d.Reserve("near"); !ok {
		t.Fatal("first call near the cap must be admitted")
	}
	ok, spent := d.Reserve("near")
	if ok || !d.IsTransient(spent) {
		t.Fatalf("second concurrent call near the cap: ok=%v transient=%v, want rejected and transient", ok, d.IsTransient(spent))
	}
	d.Release("near", 1) // spent 2000 = cap, slot freed
	ok, spent = d.Reserve("near")
	if ok || d.IsTransient(spent) {
		t.Fatalf("after reaching the cap: ok=%v transient=%v, want rejected and not transient", ok, d.IsTransient(spent))
	}

	d.Charge("edge", 2000-2*269) // spent + 2*max == limit is not "over": two calls admitted, not three
	for i := 0; i < 2; i++ {
		if ok, _ := d.Reserve("edge"); !ok {
			t.Fatalf("call %d at spent+(inflight+1)*max == limit must be admitted", i)
		}
	}
	if ok, _ := d.Reserve("edge"); ok {
		t.Fatal("third call would make spent + 3*max > limit")
	}

	// A fresh day allows floor(2000/269) = 7 calls in flight (ADR-0010 D5 A1, "legitimate parallelism").
	n := 0
	for {
		ok, _ := d.Reserve("fresh")
		if !ok {
			break
		}
		n++
	}
	if n != 7 {
		t.Fatalf("calls in flight on a fresh day = %d, want 7", n)
	}
}

// TestDailyCap_InvariantAtAnyConcurrency (A1): from many starting spends, every admitted call spends exactly
// M; the final count never passes limit - 1 + M, however many callers race.
func TestDailyCap_InvariantAtAnyConcurrency(t *testing.T) {
	const (
		limit = 2000
		m     = 269
		herd  = 32
	)
	for _, start := range []int64{0, 500, 1000, 1462, 1463, 1731, 1900, 1999} {
		t.Run(fmt.Sprintf("start=%d", start), func(t *testing.T) {
			d := NewDailyCap(limit).WithMaxCallReads(m)
			d.Charge("u", start)
			admitted := 0
			for i := 0; i < herd; i++ { // all admitted calls overlap: none releases until the herd is done
				if ok, _ := d.Reserve("u"); ok {
					admitted++
				}
			}
			if got := d.Inflight("u"); got != admitted {
				t.Fatalf("Inflight = %d, want %d", got, admitted)
			}
			for i := 0; i < admitted; i++ {
				d.Release("u", m)
			}
			if got, bound := d.Spent("u"), int64(limit-1+m); got > bound {
				t.Fatalf("spent = %d exceeds the A1 bound %d after %d admitted", got, bound, admitted)
			}
			if d.Inflight("u") != 0 {
				t.Fatal("slots leaked")
			}
		})
	}
}

// TestDailyCap_ConcurrentReserveAtLimitMinusOne (M1, ADR-0010 D5): N goroutines hit a key at limit-1 while
// each admitted call holds its slot and then spends one full worst-case call. Total spend never exceeds
// limit - 1 + one call's worst case, and no more than one call is ever admitted.
func TestDailyCap_ConcurrentReserveAtLimitMinusOne(t *testing.T) {
	const (
		limit   = 2000
		maxCall = 269
		n       = 64
	)
	d := NewDailyCap(limit).WithMaxCallReads(maxCall)
	d.Charge("u", limit-1)

	var admitted, rejected atomic.Int64
	start := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			ok, _ := d.Reserve("u")
			if !ok {
				rejected.Add(1)
				return
			}
			admitted.Add(1)
			<-release // hold the slot while the rest of the herd is rejected
			d.Release("u", maxCall)
		}()
	}
	close(start)
	// Wait until every goroutine has either been rejected or is the one holder (no sleep-based sync).
	deadline := time.Now().Add(5 * time.Second)
	for admitted.Load()+rejected.Load() < n && time.Now().Before(deadline) {
		runtime.Gosched()
	}
	close(release)
	wg.Wait()

	if got := admitted.Load(); got != 1 {
		t.Fatalf("admitted = %d, want exactly 1 while one call is in flight near the cap", got)
	}
	if got, bound := d.Spent("u"), int64(limit-1+maxCall); got > bound {
		t.Fatalf("spent = %d exceeds the D5 bound %d (limit - 1 + one call's worst case)", got, bound)
	}
}

// TestDailyCap_FirstAccessRace (m2): concurrent first accesses share one counter, so no Charge is lost.
// A start barrier releases all goroutines at once so they really collide on the first access, over several
// fresh keys.
func TestDailyCap_FirstAccessRace(t *testing.T) {
	d := NewDailyCap(1_000_000)
	const n = 200
	for round := 0; round < 20; round++ {
		key := fmt.Sprintf("fresh-%d", round)
		start := make(chan struct{})
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				d.Charge(key, 1)
			}()
		}
		close(start)
		wg.Wait()
		if got := d.Spent(key); got != n {
			t.Fatalf("round %d: spent = %d, want %d: a Charge was applied to a replaced counter", round, got, n)
		}
	}
}
