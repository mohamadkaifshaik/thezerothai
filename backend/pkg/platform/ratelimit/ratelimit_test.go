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

// TestResolveClientIP_DirectPath: mobile calling Cloud Run directly — GFE appends exactly one entry, the
// real client IP, at the rightmost position. It is not a recognized Google address, so it is trusted as-is
// (M2, ADR-0006 §3 amendment).
func TestResolveClientIP_DirectPath(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "203.0.113.7")

	got := ResolveClientIP(h, 1)
	if got.IP != "203.0.113.7" {
		t.Errorf("IP = %q, want the single (real client) entry", got.IP)
	}
	if got.ViaHosting {
		t.Error("ViaHosting = true, want false on the direct path")
	}
	if got.Hops != 1 {
		t.Errorf("Hops = %d, want 1", got.Hops)
	}
}

// TestResolveClientIP_HostingPath: web calling through the Firebase Hosting `/api/**` rewrite — GFE (in
// front of Cloud Run) appends Hosting's own egress IP at the rightmost position; Hosting itself appended
// the real browser IP one position to the left of that before forwarding. 66.249.64.10 is inside the range
// the audit observed live as Cloud Run's httpRequest.remoteIp for exactly this path.
func TestResolveClientIP_HostingPath(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "198.51.100.9, 66.249.64.10")

	got := ResolveClientIP(h, 1)
	if got.IP != "198.51.100.9" {
		t.Errorf("IP = %q, want the real browser IP one hop left of the Hosting egress address", got.IP)
	}
	if !got.ViaHosting {
		t.Error("ViaHosting = false, want true: rightmost entry is a recognized Google egress IP")
	}
	if got.Hops != 2 {
		t.Errorf("Hops = %d, want 2", got.Hops)
	}
}

// TestResolveClientIP_SpoofedXFFOnDirectPath: an attacker calling Cloud Run directly (no Hosting involved)
// cannot control the rightmost entry — GFE appends its own observed peer IP there — but can prepend
// whatever it likes to the left, including an address that *looks* like a Google range. That must never
// cause us to walk left: only the rightmost entry's ownership is ever consulted.
func TestResolveClientIP_SpoofedXFFOnDirectPath(t *testing.T) {
	h := http.Header{}
	// "66.249.64.1" here is attacker-supplied (prepended by the caller itself), not appended by any real
	// Google proxy; "6.6.6.6" is the attacker's real IP, appended last by GFE.
	h.Set("X-Forwarded-For", "66.249.64.1, 6.6.6.6")

	got := ResolveClientIP(h, 1)
	if got.IP != "6.6.6.6" {
		t.Errorf("IP = %q, want the rightmost (GFE-appended) entry, not the spoofed left entry", got.IP)
	}
	if got.ViaHosting {
		t.Error("ViaHosting = true, want false: the Google-looking address is spoofed, not the rightmost entry")
	}
}

// TestResolveClientIP_HostingEgressWithNothingToItsLeft: defensive edge case — if the rightmost entry is
// recognized as Google's own but there is nothing to its left (should not happen in our real topology,
// where Hosting always appends the browser IP before forwarding), fall back to that entry rather than
// index out of range.
func TestResolveClientIP_HostingEgressWithNothingToItsLeft(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "66.249.64.10")

	got := ResolveClientIP(h, 1)
	if got.IP != "66.249.64.10" {
		t.Errorf("IP = %q, want the only entry present", got.IP)
	}
	if got.ViaHosting {
		t.Error("ViaHosting = true, want false: there is no entry to its left to attribute as the real client")
	}
}

// TestResolveClientIP_ExplicitHopsOverrideSkipsHostingDetection: TrustedProxyHops > 1 is an explicit
// operator override (ResolveClientIP's doc comment) — it must count hops literally and skip the
// Google-egress heuristic entirely, even when the entry it lands on happens to look Google-owned.
func TestResolveClientIP_ExplicitHopsOverrideSkipsHostingDetection(t *testing.T) {
	h := http.Header{}
	h.Set("X-Forwarded-For", "1.2.3.4, 66.249.64.10, 9.9.9.9")

	got := ResolveClientIP(h, 2)
	if got.IP != "66.249.64.10" {
		t.Errorf("IP = %q, want the literal hops=2 entry regardless of it looking Google-owned", got.IP)
	}
	if got.ViaHosting {
		t.Error("ViaHosting = true, want false: an explicit hops override bypasses detection entirely")
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
