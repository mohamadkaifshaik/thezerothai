package ratelimit

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
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

// TestDailyCap_FirstAccessRace (m2): concurrent first accesses share one counter, so no unit is lost.
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
				d.Allow(key)
			}()
		}
		close(start)
		wg.Wait()
		if got := d.Spent(key); got != n {
			t.Fatalf("round %d: spent = %d, want %d: a unit was counted on a replaced counter", round, got, n)
		}
	}
}

func TestDailyCap_AllowN(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		limit int64
		calls []int64
		want  []bool
	}{
		{"exact fit then reject", 10, []int64{4, 6, 1}, []bool{true, true, false}},
		{"over-limit batch counts nothing", 10, []int64{8, 5, 2}, []bool{true, false, true}},
		{"zero and negative are free", 1, []int64{0, -3, 1, 1}, []bool{true, true, true, false}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			d := NewDailyCap(tt.limit)
			now := time.Now()
			d.now = func() time.Time { return now }
			for i, n := range tt.calls {
				if got := d.AllowN("uid-1", n); got != tt.want[i] {
					t.Errorf("call %d AllowN(%d) = %v, want %v", i, n, got, tt.want[i])
				}
			}
			if d.AllowN("uid-2", tt.limit) != true {
				t.Error("another key has its own allowance")
			}
		})
	}
}

func TestDailyCap_RefundReturnsUnitsAndNeverGoesBelowZero(t *testing.T) {
	d := NewDailyCap(10)
	now := time.Now()
	d.now = func() time.Time { return now }
	if !d.AllowN("u", 6) || d.AllowN("u", 5) {
		t.Fatal("6 fits, the next 5 must not")
	}
	d.Refund("u", 2)
	if got := d.Spent("u"); got != 4 {
		t.Fatalf("spent after refund = %d, want 4", got)
	}
	if !d.AllowN("u", 6) {
		t.Fatal("the refunded units must be spendable again")
	}
	d.Refund("u", 100)
	if got := d.Spent("u"); got != 0 {
		t.Fatalf("spent after an over-refund = %d, want 0 (floored)", got)
	}
	d.Refund("u", 0)
	d.Refund("u", -3)
	if got := d.Spent("u"); got != 0 {
		t.Fatalf("spent = %d, want 0 (no-op refunds)", got)
	}
}

func TestDailyCap_ExceededError(t *testing.T) {
	d := NewDailyCap(1)
	ae := d.ExceededError(context.Background(), "some_cap")
	if ae.Code != connect.CodeResourceExhausted || ae.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED || ae.Metadata["limit"] != "some_cap" || ae.RetryAfter <= 0 {
		t.Fatalf("error = %+v", ae)
	}
}
