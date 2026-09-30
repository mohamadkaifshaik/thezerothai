package ratelimit_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
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

func TestReadBudget_OvershootBoundedByOneCall(t *testing.T) {
	uidCap := ratelimit.NewDailyCap(2000)
	rig := newBudgetServer(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, 268, nil)
	uidCap.Charge("uid-a", 1999)
	if err := call(t, rig.srv, ""); err != nil {
		t.Fatalf("call at 1,999 spent must be allowed: %v", err)
	}
	if got := uidCap.Spent("uid-a"); got != 1999+268 {
		t.Fatalf("spent = %d, want %d", got, 1999+268)
	}
	assertResourceExhausted(t, call(t, rig.srv, ""))
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
			cfg := ratelimit.Config{ReadBudget: ratelimit.NewDailyCap(2000), ReadBudgetIP: ipCap, ProfileExempt: tt.profileExempt}
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
			if ipCap.Spent(ratelimit.IPBudgetKey("203.0.113.9")) != 0 {
				t.Error("IP budget must not be charged on non-exempt procedures")
			}
		})
	}
}

// TestReadBudget_IPv6KeyedBy64: a host rotating addresses inside its /64 shares one budget; another /64 does not.
func TestReadBudget_IPv6KeyedBy64(t *testing.T) {
	cfg := ratelimit.Config{
		ReadBudget:    ratelimit.NewDailyCap(2000),
		ReadBudgetIP:  ratelimit.NewDailyCap(100),
		ProfileExempt: map[string]struct{}{procedure: {}},
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

func TestIPBudgetKey(t *testing.T) {
	tests := []struct{ in, want string }{
		{"203.0.113.9", "203.0.113.9"},
		{"::ffff:203.0.113.9", "203.0.113.9"},
		{"2001:db8:1:2::1", "2001:db8:1:2::/64"},
		{"2001:db8:1:2:ffff:ffff:ffff:ffff", "2001:db8:1:2::/64"},
		{"2001:db8:1:3::1", "2001:db8:1:3::/64"},
		{"not-an-ip", "not-an-ip"},
	}
	for _, tt := range tests {
		if got := ratelimit.IPBudgetKey(tt.in); got != tt.want {
			t.Errorf("IPBudgetKey(%q) = %q, want %q", tt.in, got, tt.want)
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
