package ratelimit

import (
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

// TestDailyCap_ReserveCharge covers the unit-budget mode (ADR-0010 D5): Reserve checks headroom without
// spending, Charge spends n (overshoot allowed by one call), the IST rollover resets both.
func TestDailyCap_ReserveCharge(t *testing.T) {
	ist := time.FixedZone("IST", 5*3600+30*60)
	now := time.Date(2026, 1, 1, 23, 59, 0, 0, ist)
	d := NewDailyCap(2000).WithClock(func() time.Time { return now })

	if !d.Reserve("u") || d.Spent("u") != 0 {
		t.Fatal("fresh key must have headroom and spend nothing on Reserve")
	}
	d.Charge("u", 1999)
	d.Charge("u", 0)  // no-op
	d.Charge("u", -5) // no-op
	if d.Spent("u") != 1999 || !d.Reserve("u") {
		t.Fatalf("spent = %d, want 1999 with headroom", d.Spent("u"))
	}
	d.Charge("u", 268) // one call's worst case overshoots the cap
	if d.Spent("u") != 2267 || d.Reserve("u") {
		t.Fatalf("spent = %d, Reserve must now be false", d.Spent("u"))
	}
	if !d.Reserve("other") {
		t.Fatal("keys are independent")
	}

	now = now.Add(2 * time.Minute) // IST midnight
	if !d.Reserve("u") || d.Spent("u") != 0 {
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
