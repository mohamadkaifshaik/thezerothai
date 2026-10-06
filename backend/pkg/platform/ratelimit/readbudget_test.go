package ratelimit_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

var istZone = time.FixedZone("IST", 5*3600+30*60)

// budgetRig serves one procedure behind the production chain order (counter/info injection standing in for
// mw.Logging, auth, ratelimit). The fake handler "spends" handlerReads Firestore reads per call.
type budgetRig struct {
	srv   *httptest.Server
	calls *atomic.Int64
	info  **logger.RequestInfo
}

func newBudgetServer(t *testing.T, uid string, cfg ratelimit.Config, handlerReads int64, handlerErr error) *budgetRig {
	t.Helper()
	calls := &atomic.Int64{}
	info := new(*logger.RequestInfo)
	counterInject := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx, _ = budget.WithCounter(ctx)
			ctx, ri := logger.WithRequestInfo(ctx)
			*info = ri
			return next(ctx, req)
		}
	})
	h := connect.NewUnaryHandler(procedure,
		func(ctx context.Context, _ *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
			calls.Add(1)
			budget.FromContext(ctx).AddReads(handlerReads)
			if handlerErr != nil {
				return nil, handlerErr
			}
			return connect.NewResponse(&commonv1.ErrorDetail{}), nil
		},
		connect.WithInterceptors(counterInject, authInject(uid), ratelimit.Interceptor(cfg)),
	)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &budgetRig{srv: srv, calls: calls, info: info}
}

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

func TestReadBudget_RejectsAtCapBeforeHandler_ThenResetsAtISTMidnight(t *testing.T) {
	now := time.Date(2026, 1, 1, 23, 59, 0, 0, istZone)
	uidCap := ratelimit.NewDailyCap(2000).WithClock(func() time.Time { return now })
	rig := newBudgetServer(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, 1, nil)

	uidCap.Charge("uid-a", 2000)
	d := rateLimitDetail(t, call(t, rig.srv, ""))
	if d.GetMetadata()["limit"] != "read_budget_daily" {
		t.Errorf("metadata limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
	}
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
		t.Errorf("reason = %v, want RATE_LIMITED", d.GetReason())
	}
	if got := d.GetRetryAfter().AsDuration(); got != time.Minute {
		t.Errorf("retry_after = %v, want 1m (time to IST midnight)", got)
	}
	if rig.calls.Load() != 0 {
		t.Fatalf("handler ran %d times; a rejection must cost 0 Firestore reads", rig.calls.Load())
	}
	if (*rig.info).LimitName != "read_budget_daily" {
		t.Errorf("LimitName = %q", (*rig.info).LimitName)
	}

	now = now.Add(2 * time.Minute) // fake clock crosses IST midnight
	if err := call(t, rig.srv, ""); err != nil {
		t.Fatalf("first call after IST midnight must succeed: %v", err)
	}
}

func TestReadBudget_ChargesActualReadsOnSuccessAndError(t *testing.T) {
	tests := []struct {
		name       string
		handlerErr error
	}{
		{"success", nil},
		{"handler error", connect.NewError(connect.CodeNotFound, errors.New("nope"))},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uidCap := ratelimit.NewDailyCap(2000)
			rig := newBudgetServer(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, 3, tt.handlerErr)
			_ = call(t, rig.srv, "")
			_ = call(t, rig.srv, "")
			if got := uidCap.Spent("uid-a"); got != 6 {
				t.Fatalf("spent = %d, want 6 (2 calls x 3 reads)", got)
			}
			v, ok := (*rig.info).Get("read_budget_spent")
			if !ok || v != int64(6) {
				t.Fatalf("read_budget_spent = %v (ok=%v), want 6", v, ok)
			}
		})
	}
}

// TestReadBudget_SequentialOvershootBoundedByOneCall: one call at a time overshoots by at most one call's
// worst case (concurrency is covered by the single-flight tests below and in daily_cap_test.go).
func TestReadBudget_SequentialOvershootBoundedByOneCall(t *testing.T) {
	const maxCall = config.ReadBudgetMaxCallReads
	uidCap := ratelimit.NewDailyCap(2000).WithMaxCallReads(maxCall)
	rig := newBudgetServer(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, maxCall, nil)
	uidCap.Charge("uid-a", 1999)
	if err := call(t, rig.srv, ""); err != nil {
		t.Fatalf("call at 1,999 spent must be allowed: %v", err)
	}
	if got := uidCap.Spent("uid-a"); got != 1999+maxCall {
		t.Fatalf("spent = %d, want %d", got, 1999+maxCall)
	}
	assertResourceExhausted(t, call(t, rig.srv, ""))
}

// TestReadBudget_InFlightGuardRejectsWithShortRetryAndReleases (M1): while one call is in flight inside the
// last maxCallReads, a second call is rejected with retry_after 1 s (not midnight) and never reaches the
// handler; once the first finishes and spends the budget, rejections switch to the IST-midnight retry.
func TestReadBudget_InFlightGuardRejectsWithShortRetryAndReleases(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, istZone)
	uidCap := ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads).WithClock(func() time.Time { return now })
	uidCap.Charge("uid-a", 1999)

	entered := make(chan struct{})
	release := make(chan struct{})
	// m1: if the hold regresses, the second call is admitted and t.Fatal fires while the first handler is still
	// blocked on release; httptest.Server.Close would then wait on it until the package timeout. closeRelease is
	// registered with t.Cleanup AFTER the server's cleanup below, so (LIFO) it runs first and a regression fails
	// with the real assertion instead of hanging.
	var releaseOnce sync.Once
	closeRelease := func() { releaseOnce.Do(func() { close(release) }) }
	var handled atomic.Int64
	h := connect.NewUnaryHandler(procedure,
		func(ctx context.Context, _ *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
			if handled.Add(1) == 1 {
				close(entered)
				<-release
			}
			budget.FromContext(ctx).AddReads(1)
			return connect.NewResponse(&commonv1.ErrorDetail{}), nil
		},
		connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
				ctx, _ = budget.WithCounter(ctx)
				return next(ctx, req)
			}
		}), authInject("uid-a"), ratelimit.Interceptor(ratelimit.Config{ReadBudget: uidCap})),
	)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Cleanup(closeRelease) // runs before srv.Close

	first := make(chan error, 1)
	go func() { first <- call(t, srv, "") }()
	<-entered

	d := rateLimitDetail(t, call(t, srv, ""))
	if got := d.GetRetryAfter().AsDuration(); got != ratelimit.RetryAfterInFlight {
		t.Fatalf("in-flight rejection retry_after = %v, want 1s", got)
	}
	if d.GetMetadata()["limit"] != "read_budget_inflight" {
		t.Errorf("limit = %q, want read_budget_inflight (A7)", d.GetMetadata()["limit"])
	}
	if handled.Load() != 1 {
		t.Fatalf("handler ran %d times; the rejected call must not reach it", handled.Load())
	}

	closeRelease()
	if err := <-first; err != nil {
		t.Fatalf("first call: %v", err)
	}
	// 1999 + 1 read = 2000: budget exhausted, so the retry hint is now the time to IST midnight.
	d = rateLimitDetail(t, call(t, srv, ""))
	if got := d.GetRetryAfter().AsDuration(); got != 12*time.Hour {
		t.Fatalf("exhausted retry_after = %v, want 12h", got)
	}
}

// TestReadBudget_ChargedAndReleasedWhenHandlerPanics (m1): a panic unwinding past the interceptor (mw.Recover
// sits outside it) still charges the reads spent so far and frees the in-flight slot.
func TestReadBudget_ChargedAndReleasedWhenHandlerPanics(t *testing.T) {
	uidCap := ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads)
	cfg := ratelimit.Config{ReadBudget: uidCap}
	ctx, counter := budget.WithCounter(context.Background())
	ctx = authn.WithClaims(ctx, authn.Claims{UID: "uid-a"})
	next := func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		counter.AddReads(5)
		panic("boom")
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("expected the panic to propagate")
			}
		}()
		_, _ = ratelimit.Interceptor(cfg)(next)(ctx, connect.NewRequest(&commonv1.ErrorDetail{}))
	}()
	if got := uidCap.Spent("uid-a"); got != 5 {
		t.Fatalf("spent after panic = %d, want 5", got)
	}
	// Slot freed: with the key next to the cap, a new call is admitted (a leaked slot would reject it).
	uidCap.Charge("uid-a", 2000-5-1)
	if ok, _ := uidCap.Reserve("uid-a"); !ok {
		t.Fatal("in-flight slot leaked by the panicking call")
	}
}

// TestReadBudget_ChargeOnlyProceduresAreNeverRejected (M2, CLAUDE.md rule 10): a charge-only procedure still
// succeeds for a uid whose budget is spent (and IP budget too), its reads are charged, and other procedures
// are still rejected for the same uid.
func TestReadBudget_ChargeOnlyProceduresAreNeverRejected(t *testing.T) {
	tests := []struct {
		name       string
		chargeOnly map[string]struct{}
		wantOK     bool
	}{
		{"charge-only procedure passes over the cap", map[string]struct{}{procedure: {}}, true},
		{"ordinary procedure is rejected over the cap", map[string]struct{}{"/other/Proc": {}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uidCap := ratelimit.NewDailyCap(2000)
			ipCap := ratelimit.NewDailyCap(500)
			cfg := ratelimit.Config{
				ReadBudget: uidCap, ReadBudgetIP: ipCap,
				ReadBudgetIPEnforce:  map[string]struct{}{procedure: {}},
				ReadBudgetChargeOnly: tt.chargeOnly,
			}
			rig := newBudgetServer(t, "uid-a", cfg, 3, nil)
			uidCap.Charge("uid-a", 5000)
			ipCap.Charge(ipKey("203.0.113.9"), 5000)
			err := call(t, rig.srv, "203.0.113.9")
			if !tt.wantOK {
				assertResourceExhausted(t, err)
				return
			}
			if err != nil {
				t.Fatalf("charge-only procedure must never be rejected by the read budget: %v", err)
			}
			if got := uidCap.Spent("uid-a"); got != 5003 {
				t.Errorf("uid spent = %d, want 5003 (reads are still charged)", got)
			}
			if got := ipCap.Spent(ipKey("203.0.113.9")); got != 5003 {
				t.Errorf("ip spent = %d, want 5003", got)
			}
		})
	}
}

// TestReadBudget_RejectionLogsWhichKeyTripped (m7): the request log names the key (uid or ip); the
// client-visible limit stays read_budget_daily for both.
func TestReadBudget_RejectionLogsWhichKeyTripped(t *testing.T) {
	tests := []struct {
		name    string
		uidOver bool
		want    string
	}{
		{"uid budget", true, "uid"},
		{"ip budget", false, "ip"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uidCap := ratelimit.NewDailyCap(2000)
			ipCap := ratelimit.NewDailyCap(500)
			cfg := ratelimit.Config{ReadBudget: uidCap, ReadBudgetIP: ipCap, ReadBudgetIPEnforce: map[string]struct{}{procedure: {}}}
			rig := newBudgetServer(t, "uid-a", cfg, 1, nil)
			if tt.uidOver {
				uidCap.Charge("uid-a", 2000)
			} else {
				ipCap.Charge(ipKey("203.0.113.9"), 500)
			}
			d := rateLimitDetail(t, call(t, rig.srv, "203.0.113.9"))
			if d.GetMetadata()["limit"] != "read_budget_daily" {
				t.Errorf("limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
			}
			if _, leaked := d.GetMetadata()["read_budget_key"]; leaked {
				t.Error("read_budget_key is log-only and must not be client-visible")
			}
			if v, _ := (*rig.info).Get("read_budget_key"); v != tt.want {
				t.Errorf("read_budget_key = %v, want %s", v, tt.want)
			}
		})
	}
}

func TestReadBudget_IPBudgetOnlyOnProfileExemptProcedures(t *testing.T) {
	tests := []struct {
		name          string
		profileExempt map[string]struct{}
		wantRejected  bool
	}{
		{"profile-exempt procedure: many uids share the IP budget", map[string]struct{}{procedure: {}}, true},
		{"caller with a profile on a non-exempt procedure: never IP-limited", map[string]struct{}{"/other/Proc": {}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ipCap := ratelimit.NewDailyCap(500)
			cfg := ratelimit.Config{ReadBudget: ratelimit.NewDailyCap(2000), ReadBudgetIP: ipCap, ReadBudgetIPEnforce: tt.profileExempt}
			// 5 different uids behind one IP spend 100 reads each = 500.
			for i := 0; i < 5; i++ {
				rig := newBudgetServer(t, "sybil-"+string(rune('a'+i)), cfg, 100, nil)
				if err := call(t, rig.srv, "203.0.113.9"); err != nil {
					t.Fatalf("uid %d: %v", i, err)
				}
			}
			rig := newBudgetServer(t, "sybil-z", cfg, 100, nil)
			err := call(t, rig.srv, "203.0.113.9")
			if tt.wantRejected {
				d := rateLimitDetail(t, err)
				if d.GetMetadata()["limit"] != "read_budget_daily" {
					t.Errorf("limit = %q", d.GetMetadata()["limit"])
				}
				if rig.calls.Load() != 0 {
					t.Error("rejected call must not reach the handler")
				}
				return
			}
			if err != nil {
				t.Fatalf("a caller with a profile must not be IP-limited: %v", err)
			}
			if ipCap.Spent(ipKey("203.0.113.9")) != 0 {
				t.Error("IP budget must not be charged on non-exempt procedures")
			}
		})
	}
}

// TestReadBudget_IPv6KeyedBy64: a host rotating addresses inside its /64 shares one budget; another /64 does not.
func TestReadBudget_IPv6KeyedBy64(t *testing.T) {
	cfg := ratelimit.Config{
		ReadBudget:          ratelimit.NewDailyCap(2000),
		ReadBudgetIP:        ratelimit.NewDailyCap(100),
		ReadBudgetIPEnforce: map[string]struct{}{procedure: {}},
	}
	rig := newBudgetServer(t, "uid-a", cfg, 100, nil)
	if err := call(t, rig.srv, "2001:db8:1:2::1"); err != nil {
		t.Fatalf("first: %v", err)
	}
	assertResourceExhausted(t, call(t, rig.srv, "2001:db8:1:2:aaaa:bbbb:cccc:dddd")) // same /64, new address
	if err := call(t, rig.srv, "2001:db8:1:3::1"); err != nil {                      // different /64
		t.Fatalf("a different /64 must have its own budget: %v", err)
	}
}

// ipKey is IPBudgetKey for inputs the test knows are valid.
func ipKey(ip string) string {
	k, ok := ratelimit.IPBudgetKey(ip)
	if !ok {
		panic("test IP does not parse: " + ip)
	}
	return k
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

func TestConfig_ReadBudgetCovers(t *testing.T) {
	c := ratelimit.Config{}
	if c.ReadBudgetCovers("/a/B") {
		t.Error("nil ReadBudget covers nothing")
	}
	c.ReadBudget = ratelimit.NewDailyCap(1)
	if !c.ReadBudgetCovers("/a/B") {
		t.Error("ReadBudget covers every procedure by default")
	}
	c.ReadBudgetExempt = map[string]struct{}{"/a/B": {}}
	if c.ReadBudgetCovers("/a/B") || !c.ReadBudgetCovers("/a/C") {
		t.Error("only exempt procedures are uncovered")
	}
}

// TestInterceptor_DailyCapRejectionCarriesLimitMetadata: check_handle_daily-style caps also report
// metadata["limit"] and an IST-midnight retry_after (T3): the 101st call in a day is rejected.
func TestInterceptor_DailyCapRejectionCarriesLimitMetadata(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, istZone)
	c := ratelimit.NewDailyCap(100).WithClock(func() time.Time { return now })
	cfg := ratelimit.Config{DailyCaps: map[string]ratelimit.NamedDailyCap{procedure: {Name: "check_handle_daily", Cap: c}}}
	rig := newBudgetServer(t, "uid-a", cfg, 0, nil)
	for i := 0; i < 100; i++ {
		if err := call(t, rig.srv, ""); err != nil {
			t.Fatalf("call %d: %v", i+1, err)
		}
	}
	d := rateLimitDetail(t, call(t, rig.srv, ""))
	if d.GetMetadata()["limit"] != "check_handle_daily" {
		t.Errorf("limit = %q, want check_handle_daily", d.GetMetadata()["limit"])
	}
	if got := d.GetRetryAfter().AsDuration(); got != 12*time.Hour {
		t.Errorf("retry_after = %v, want 12h", got)
	}
}

// ADR-0010 D5 / T3 acceptance: 2,000 read units are admitted (one call each), the 2,001st is rejected with
// RATE_LIMITED, limit_name=read_budget_daily and 0 handler reads.
func TestReadBudget_2001stUnitRejectedWithReadBudgetDaily(t *testing.T) {
	now := time.Date(2026, 1, 1, 10, 0, 0, 0, istZone)
	uidCap := ratelimit.NewDailyCap(2000).WithClock(func() time.Time { return now })
	rig := newBudgetServer(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, 1, nil)

	for i := 1; i <= 2000; i++ {
		if err := call(t, rig.srv, ""); err != nil {
			t.Fatalf("call %d rejected: %v", i, err)
		}
	}
	if got := uidCap.Spent("uid-a"); got != 2000 {
		t.Fatalf("spent = %d, want 2000", got)
	}
	d := rateLimitDetail(t, call(t, rig.srv, ""))
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
		t.Errorf("reason = %v, want RATE_LIMITED", d.GetReason())
	}
	if d.GetMetadata()["limit"] != "read_budget_daily" {
		t.Errorf("metadata limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
	}
	if (*rig.info).LimitName != "read_budget_daily" {
		t.Errorf("LimitName = %q", (*rig.info).LimitName)
	}
	if rig.calls.Load() != 2000 {
		t.Errorf("handler ran %d times, want 2000 (the 2,001st must cost 0 reads)", rig.calls.Load())
	}
}
