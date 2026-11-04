package ratelimit_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

var istZone = time.FixedZone("IST", 5*3600+30*60)

func rateLimitDetail(t *testing.T, err error) *commonv1.ErrorDetail {
	t.Helper()
	assertResourceExhausted(t, err)
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	for _, d := range cerr.Details() {
		v, verr := d.Value()
		if verr != nil {
			continue
		}
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			return ed
		}
	}
	t.Fatal("no ErrorDetail on the error")
	return nil
}

// TestIPBudgetKey (A5): only canonical netip strings come out; raw input never does.
func TestIPBudgetKey(t *testing.T) {
	tests := []struct {
		in     string
		want   string
		wantOK bool
	}{
		{"203.0.113.9", "203.0.113.9", true},
		{"::ffff:203.0.113.9", "203.0.113.9", true},
		{"2001:db8:1:2::1", "2001:db8:1:2::/64", true},
		{"2001:DB8:1:2:FFFF:ffff:ffff:ffff", "2001:db8:1:2::/64", true},
		{"2001:db8:1:3::1", "2001:db8:1:3::/64", true},
		{"fe80::1%eth0", "fe80::/64", true}, // the zone is dropped
		{"not-an-ip", "", false},
		{"", "", false},
		{"203.0.113.9:443", "", false},
		{"1.2.3.4, 5.6.7.8", "", false},
		{strings.Repeat("a", 5000), "", false},
	}
	for _, tt := range tests {
		got, ok := ratelimit.IPBudgetKey(tt.in)
		if got != tt.want || ok != tt.wantOK {
			t.Errorf("IPBudgetKey(%.40q) = (%q, %v), want (%q, %v)", tt.in, got, ok, tt.want, tt.wantOK)
		}
		if len(got) > 43 {
			t.Errorf("key %q is longer than 43 bytes", got)
		}
	}
}

// TestInterceptor_DailyCapRejectionCarriesLimitMetadata: check_handle_daily-style caps also report
// metadata["limit"] and an IST-midnight retry_after: the 101st call in a day is rejected.
func TestInterceptor_DailyCapRejectionCarriesLimitMetadata(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, istZone)
	c := ratelimit.NewDailyCap(100).WithClock(func() time.Time { return now })
	cfg := ratelimit.Config{DailyCaps: map[string]ratelimit.NamedDailyCap{procedure: {Name: "check_handle_daily", Cap: c}}}
	srv := newServer(t, "uid-a", cfg)
	for i := 0; i < 100; i++ {
		if err := call(t, srv, ""); err != nil {
			t.Fatalf("call %d: %v", i+1, err)
		}
	}
	d := rateLimitDetail(t, call(t, srv, ""))
	if d.GetMetadata()["limit"] != "check_handle_daily" {
		t.Errorf("limit = %q, want check_handle_daily", d.GetMetadata()["limit"])
	}
	if got := d.GetRetryAfter().AsDuration(); got != 12*time.Hour {
		t.Errorf("retry_after = %v, want 12h", got)
	}
}

// TestA5_PerMinuteIPLimiterKeysBy64: rotating addresses inside one IPv6 /64 share the in-chain cfg.IP bucket, a
// different /64 does not, and a garbage X-Forwarded-For entry never becomes a key.
func TestA5_PerMinuteIPLimiterKeysBy64(t *testing.T) {
	cfg := ratelimit.Config{IP: ratelimit.NewLimiter(2, time.Minute)}
	srv := newServer(t, "", cfg)
	for i, ip := range []string{"2001:db8:1:2::1", "2001:db8:1:2::2"} {
		if err := call(t, srv, ip); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	assertResourceExhausted(t, call(t, srv, "2001:db8:1:2:aaaa:bbbb:cccc:dddd")) // same /64: third call
	if err := call(t, srv, "2001:db8:1:3::1"); err != nil {
		t.Fatalf("a different /64 has its own bucket: %v", err)
	}
	for i := 0; i < 10; i++ { // no IP key -> unmetered (as without X-Forwarded-For), and it must not panic
		if err := call(t, srv, "not-an-ip"); err != nil {
			t.Fatalf("garbage entry call %d: %v", i, err)
		}
	}
}

// TestA5_PreAuthMiddlewareKeysBy64 is the same for the pre-auth middleware limiter.
func TestA5_PreAuthMiddlewareKeysBy64(t *testing.T) {
	l := ratelimit.NewLimiter(2, time.Minute)
	h := ratelimit.PreAuthIPMiddleware(l, 1, nil)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	do := func(xff string) int {
		r := httptest.NewRequest(http.MethodPost, "/x", nil)
		r.Header.Set("X-Forwarded-For", xff)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	if do("2001:db8:9:9::1") != 200 || do("2001:db8:9:9::2") != 200 {
		t.Fatal("first two calls in the /64 must pass")
	}
	if got := do("2001:db8:9:9:1:2:3:4"); got != http.StatusTooManyRequests {
		t.Fatalf("third call in the same /64 = %d, want 429", got)
	}
	if got := do("2001:db8:9:a::1"); got != 200 {
		t.Fatalf("a different /64 = %d, want 200", got)
	}
}

// TestA5_ResolveClientIPFallsBackToRightmost: an unparseable chosen entry falls back to the rightmost (Google
// front end appended) entry; if that is unparseable too there is no IP.
func TestA5_ResolveClientIPFallsBackToRightmost(t *testing.T) {
	tests := []struct {
		name string
		xff  string
		hops int
		want string
	}{
		{"hosting path, garbage browser entry", "garbage, 66.249.64.10", 1, "66.249.64.10"},
		{"override lands on garbage", "1.2.3.4, junk, 9.9.9.9", 2, "9.9.9.9"},
		{"rightmost garbage", "1.2.3.4, junk", 1, ""},
		{"only garbage", "junk", 1, ""},
		{"port suffix is not an IP", "203.0.113.9:443", 1, ""},
		{"normal", "203.0.113.9", 1, "203.0.113.9"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := http.Header{}
			h.Set("X-Forwarded-For", tt.xff)
			if got := ratelimit.ResolveClientIP(h, tt.hops).IP; got != tt.want {
				t.Errorf("IP = %q, want %q", got, tt.want)
			}
		})
	}
}

// TestA7_InFlightRejectionFields: an in-flight rejection reports limit read_budget_inflight, logs the key, the
