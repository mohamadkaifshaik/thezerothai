package ratelimit

import (
	"testing"
	"time"
)

func TestDailyCap_AllowsUpToLimitThenBlocks(t *testing.T) {
	d := NewDailyCap(100, time.Hour)
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
	d := NewDailyCap(1, time.Hour)
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
	d := NewDailyCap(1, time.Hour)
	now := time.Now()
	d.now = func() time.Time { return now }

	if !d.Allow("uid-a") {
		t.Fatal("uid-a first call should be allowed")
	}
	if !d.Allow("uid-b") {
		t.Fatal("uid-b should have its own independent counter")
	}
}
