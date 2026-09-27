package ratelimit

import (
	"net/http"
	"testing"
	"time"
)

func TestLimiter_AllowsBurstThenBlocks(t *testing.T) {
	l := NewLimiter(60, time.Minute) // 60/min = 1/sec, burst 60
	now := time.Now()
	l.now = func() time.Time { return now }

	for i := 0; i < 60; i++ {
		if ok, _ := l.Allow("uid-1"); !ok {
			t.Fatalf("request %d should be allowed within burst", i)
		}
	}
	if ok, wait := l.Allow("uid-1"); ok {
		t.Fatal("61st immediate request should be rate limited")
	} else if wait <= 0 {
		t.Errorf("expected positive retry-after, got %v", wait)
	}
}

func TestLimiter_RefillsOverTime(t *testing.T) {
	l := NewLimiter(60, time.Minute)
	now := time.Now()
	l.now = func() time.Time { return now }
	for i := 0; i < 60; i++ {
		l.Allow("uid-1")
	}
	if ok, _ := l.Allow("uid-1"); ok {
		t.Fatal("should be exhausted")
	}

	now = now.Add(2 * time.Second) // refills ~2 tokens at 1/sec
	l.now = func() time.Time { return now }
	if ok, _ := l.Allow("uid-1"); !ok {
		t.Fatal("expected a token to have refilled after 2s")
	}
}

func TestLimiter_KeysAreIndependent(t *testing.T) {
	l := NewLimiter(1, time.Minute)
	now := time.Now()
	l.now = func() time.Time { return now }

	if ok, _ := l.Allow("uid-a"); !ok {
		t.Fatal("uid-a first request should be allowed")
	}
	if ok, _ := l.Allow("uid-a"); ok {
		t.Fatal("uid-a second immediate request should be blocked")
	}
	if ok, _ := l.Allow("uid-b"); !ok {
		t.Fatal("uid-b should have its own independent bucket")
	}
}

func TestClientIP_RightmostEntry(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "1.2.3.4, 5.6.7.8, 9.10.11.12")
	if got := ClientIP(h, 1); got != "9.10.11.12" {
		t.Errorf("ClientIP() = %q, want the rightmost entry", got)
	}
}

func TestClientIP_Empty(t *testing.T) {
	if got := ClientIP(http.Header{}, 1); got != "" {
		t.Errorf("ClientIP() = %q, want empty", got)
	}
}

// TestClientIP_HopsConfigurable: TRUSTED_PROXY_HOPS lets an operator count in further from the right when
// there is more than one trusted proxy hop (e.g. Firebase Hosting -> Cloud Run) between the client and us —
// the exact value is meant to be measured in dev, not guessed, so this only locks in the counting behavior.
func TestClientIP_HopsConfigurable(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "1.2.3.4, 5.6.7.8, 9.10.11.12")

	tests := []struct {
		name string
		hops int
		want string
	}{
		{"hops=1 (default, rightmost)", 1, "9.10.11.12"},
		{"hops=2 (skip one trusted hop)", 2, "5.6.7.8"},
		{"hops=3 (skip two trusted hops)", 3, "1.2.3.4"},
		{"hops=0 treated as 1", 0, "9.10.11.12"},
		{"hops beyond entry count clamps to leftmost", 10, "1.2.3.4"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ClientIP(h, tt.hops); got != tt.want {
				t.Errorf("ClientIP(hops=%d) = %q, want %q", tt.hops, got, tt.want)
			}
		})
	}
}

func TestXFFHopCount(t *testing.T) {
	tests := []struct {
		name string
		xff  string
		want int
	}{
		{"empty", "", 0},
		{"one hop", "1.2.3.4", 1},
		{"three hops", "1.2.3.4, 5.6.7.8, 9.10.11.12", 3},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := http.Header{}
			if tt.xff != "" {
				h.Set("X-Forwarded-For", tt.xff)
			}
			if got := XFFHopCount(h); got != tt.want {
				t.Errorf("XFFHopCount() = %d, want %d", got, tt.want)
			}
		})
	}
}
