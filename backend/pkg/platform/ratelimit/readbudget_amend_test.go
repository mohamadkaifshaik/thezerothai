package ratelimit_test

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// Tests for the ADR-0010 D5 amendments A1 (interceptor level), A3, A4, A5 and A7.

const (
	procOther  = "/t.Service/Other"         // a non-exempt procedure (needs a profile)
	procCreate = "/t.Service/CreateProfile" // IP charge-only (A4, A8)
	procCheck  = "/t.Service/CheckHandle"   // IP charge-only since A8; enforced only by enforceCheckConfig
	testIP     = "203.0.113.9"
)

// multiRig serves several procedures through ONE ratelimit.Interceptor instance (so the A3 profile-less marks
// are shared between them, as in production) behind counter/RequestInfo injection standing in for mw.Logging.
type multiRig struct {
	srv  *httptest.Server
	info map[string]*logger.RequestInfo // last RequestInfo per procedure
	mu   sync.Mutex
}

// pflag is what the account-status interceptor would have recorded on the RequestInfo: nothing (it never ran, or
// the call was exempt), ProfileRequired (no profile) or ProfileFound (a profile exists, A9).
type pflag int

const (
	pNone pflag = iota
	pRequired
	pFound
)

// handler lets a test decide per call how many reads to spend and what the account-status interceptor would
// have flagged.
type handler func(ctx context.Context) (reads int64, flag pflag, err error)

func newMultiRig(t *testing.T, uid string, cfg ratelimit.Config, handlers map[string]handler) *multiRig {
	t.Helper()
	rig := &multiRig{info: map[string]*logger.RequestInfo{}}
	rl := ratelimit.Interceptor(cfg)
	mux := http.NewServeMux()
	for proc, h := range handlers {
		h := h
		proc := proc
		inject := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
				ctx, _ = budget.WithCounter(ctx)
				ctx, ri := logger.WithRequestInfo(ctx)
				rig.mu.Lock()
				rig.info[proc] = ri
				rig.mu.Unlock()
				return next(ctx, req)
			}
		})
		mux.Handle(proc, connect.NewUnaryHandler(proc,
			func(ctx context.Context, _ *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				reads, flag, err := h(ctx)
				budget.FromContext(ctx).AddReads(reads)
				switch flag { // what authn.AccountStatusInterceptor would have recorded
				case pRequired:
					logger.RequestInfoFromContext(ctx).ProfileRequired = true
				case pFound:
					logger.RequestInfoFromContext(ctx).ProfileFound = true
				}
				if err != nil {
					return nil, err
				}
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			},
			connect.WithInterceptors(inject, authInject(uid), rl),
		))
	}
	rig.srv = httptest.NewServer(mux)
	t.Cleanup(rig.srv.Close)
	return rig
}

func (r *multiRig) call(t *testing.T, proc, xff string) error {
	t.Helper()
	c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](r.srv.Client(), r.srv.URL+proc)
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	if xff != "" {
		req.Header().Set("X-Forwarded-For", xff)
	}
	_, err := c.CallUnary(context.Background(), req)
	return err
}

func (r *multiRig) lastInfo(proc string) *logger.RequestInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.info[proc]
}

func fixed(reads int64, flag pflag) handler {
	return func(context.Context) (int64, pflag, error) { return reads, flag, nil }
}

// a3Config mirrors production since A8: nothing is enforced on the IP key; both exempt procedures are charge-only.
func a3Config() ratelimit.Config {
	return ratelimit.Config{
		ReadBudget:             ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		ReadBudgetIP:           ratelimit.NewDailyCap(500).WithMaxCallReads(config.IPReadBudgetMaxCallReads),
		ReadBudgetIPEnforce:    map[string]struct{}{},
		ReadBudgetIPChargeOnly: map[string]struct{}{procCheck: {}, procCreate: {}},
	}
}

// enforceCheckConfig is a TEST-ONLY config that enforces one IP procedure (procCheck). Production can no longer
// reach that path (A8: ReadBudgetIPEnforce is empty), but the seam, including releasing the uid key's in-flight
// slot when the IP key rejects, must stay correct (ADR-0010 Handoff 13).
func enforceCheckConfig() ratelimit.Config {
	cfg := a3Config()
	cfg.ReadBudgetIPEnforce = map[string]struct{}{procCheck: {}}
	cfg.ReadBudgetIPChargeOnly = map[string]struct{}{procCreate: {}}
	return cfg
}

// TestA3_VerifiedCallerWithoutProfileIsChargedToIPAndMarked: a call the account-status interceptor rejects as
// PROFILE_REQUIRED is charged to the IP key and the uid is marked; from then on the uid's non-exempt calls are
// charged to the IP key too (A8: never rejected, even when that budget is spent). A caller with a profile
// behind the same IP is never charged.
func TestA3_VerifiedCallerWithoutProfileIsChargedToIPAndMarked(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-noprofile", cfg, map[string]handler{procOther: fixed(1, pRequired)})

	if err := rig.call(t, procOther, testIP); err != nil {
		t.Fatalf("first call: %v", err) // the handler stands in for the PROFILE_REQUIRED rejection; it is not a limiter rejection
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 1 {
		t.Fatalf("ip spent = %d, want 1 (the profile-less call is charged to the IP key)", got)
	}
	if v, _ := rig.lastInfo(procOther).Get("profile_required"); v != true {
		t.Errorf("profile_required = %v, want true", v)
	}
	if v, _ := rig.lastInfo(procOther).Get("read_budget_ip_spent"); v != int64(1) {
		t.Errorf("read_budget_ip_spent = %v, want 1", v)
	}

	// A8: with the IP budget spent, the marked uid's next non-exempt call still reaches the handler (it is
	// charged, not rejected) and is answered PROFILE_REQUIRED by account status, not RATE_LIMITED.
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 500)
	if err := rig.call(t, procOther, testIP); err != nil {
		t.Fatalf("a spent IP key must not reject a marked uid (A8): %v", err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 502 {
		t.Errorf("ip spent = %d, want 502 (still charged after the budget is spent)", got)
	}
	if got := cfg.ReadBudgetIP.Inflight(ipKey(testIP)); got != 0 {
		t.Errorf("ip inflight = %d, want 0 (the IP key is never held)", got)
	}
	if v, _ := rig.lastInfo(procOther).Get("profile_required"); v != true {
		t.Errorf("profile_required = %v, want true", v)
	}
	if v, _ := rig.lastInfo(procOther).Get("read_budget_ip_spent"); v != int64(502) {
		t.Errorf("read_budget_ip_spent = %v, want 502", v)
	}

	// A caller WITH a profile (the handler records ProfileFound) behind the same IP is never charged.
	other := newMultiRig(t, "uid-withprofile", cfg, map[string]handler{procOther: fixed(3, pFound)})
	if err := other.call(t, procOther, testIP); err != nil {
		t.Fatalf("a caller with a profile must not be IP-limited: %v", err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 502 {
		t.Errorf("ip spent = %d, want 502 (callers with a profile are not charged)", got)
	}
}

// TestA3_ProfileLessIPChargeKeysBy64 (audit #23): a profile-less verified uid calling from two addresses in one
// IPv6 /64 is charged to ONE IP key (the /64), and an address in another /64 is charged to a different key.
func TestA3_ProfileLessIPChargeKeysBy64(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-v6", cfg, map[string]handler{procOther: fixed(3, pRequired)})
	const a, b, other = "2001:db8:1:2::1", "2001:db8:1:2::2", "2001:db8:1:3::1"
	if ipKey(a) != ipKey(b) || ipKey(a) == ipKey(other) {
		t.Fatalf("test premise: keys a=%q b=%q other=%q", ipKey(a), ipKey(b), ipKey(other))
	}
	for _, ip := range []string{a, b} {
		if err := rig.call(t, procOther, ip); err != nil {
			t.Fatalf("call from %s: %v", ip, err)
		}
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(a)); got != 6 {
		t.Errorf("/64 key spent = %d, want 6 (both calls charge the one shared key)", got)
	}
	if err := rig.call(t, procOther, other); err != nil {
		t.Fatal(err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(other)); got != 3 {
		t.Errorf("other /64 spent = %d, want 3", got)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(a)); got != 6 {
		t.Errorf("/64 key spent = %d after the other /64 call, want still 6", got)
	}
}

// TestA3_NoMarkWithoutProfileRequired: a caller whose profile this instance has seen is never marked, so its
// calls never touch the IP key (carrier-grade NAT protection).
func TestA3_NoMarkWithoutProfileRequired(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-a", cfg, map[string]handler{procOther: fixed(2, pFound)})
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 10_000)
	for i := 0; i < 3; i++ {
		if err := rig.call(t, procOther, testIP); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 10_000 {
		t.Errorf("ip spent = %d, want untouched", got)
	}
}

// TestA3_SuccessfulCreateProfileClearsTheMark: after CreateProfile succeeds on this instance the uid is no
// longer marked, so its next non-exempt call (no flags: only the mark decides) is not charged to the IP key;
// after a failed CreateProfile the mark stays and the call is charged.
func TestA3_SuccessfulCreateProfileClearsTheMark(t *testing.T) {
	tests := []struct {
		name       string
		createErr  error
		wantMarked bool
	}{
		{"create succeeds", nil, false},
		{"create fails", connect.NewError(connect.CodeAlreadyExists, nil), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := a3Config()
			createErr := tt.createErr
			var otherCalls atomic.Int64
			rig := newMultiRig(t, "uid-x", cfg, map[string]handler{
				procOther: func(context.Context) (int64, pflag, error) {
					if otherCalls.Add(1) == 1 {
						return 1, pRequired, nil // first call: no profile, marks the uid
					}
					return 7, pNone, nil
				},
				procCreate: func(context.Context) (int64, pflag, error) { return 2, pNone, createErr },
			})
			if err := rig.call(t, procOther, testIP); err != nil {
				t.Fatal(err)
			}
			_ = rig.call(t, procCreate, testIP)
			before := cfg.ReadBudgetIP.Spent(ipKey(testIP)) // 1 + 2
			if err := rig.call(t, procOther, testIP); err != nil {
				t.Fatalf("A8: the IP key never rejects: %v", err)
			}
			got := cfg.ReadBudgetIP.Spent(ipKey(testIP)) - before
			if tt.wantMarked && got != 7 {
				t.Errorf("marked uid's call charged the IP key %d, want 7", got)
			}
			if !tt.wantMarked && got != 0 {
				t.Errorf("mark must be cleared after a successful CreateProfile; IP charged %d, want 0", got)
			}
		})
	}
}

// TestA9_StaleMarkIsClearedByACallThatFindsAProfile: a uid marked on this instance whose next non-exempt call
// finds a profile (it was created on another instance) is charged 0 on the IP key for that call, its mark is
// deleted, the uid key is charged as usual, the IP spend is not logged for it, and a following heavy call adds
// nothing to the IP meter.
func TestA9_StaleMarkIsClearedByACallThatFindsAProfile(t *testing.T) {
	cfg := a3Config()
	var calls atomic.Int64
	rig := newMultiRig(t, "uid-stale", cfg, map[string]handler{
		procOther: func(context.Context) (int64, pflag, error) {
			switch calls.Add(1) {
			case 1:
				return 1, pRequired, nil // marks the uid
			case 2:
				return 3, pFound, nil // the profile now exists
			default:
				return 269, pFound, nil // a heavy call, e.g. GetHomeTimeline
			}
		},
	})
	if err := rig.call(t, procOther, testIP); err != nil {
		t.Fatal(err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 1 {
		t.Fatalf("ip spent after the marking call = %d, want 1", got)
	}

	if err := rig.call(t, procOther, testIP); err != nil {
		t.Fatal(err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 1 {
		t.Errorf("ip spent = %d, want 1 (the call that found a profile is charged 0 on the IP key)", got)
	}
	if got := cfg.ReadBudget.Spent("uid-stale"); got != 4 {
		t.Errorf("uid spent = %d, want 4 (the uid key is charged as usual: 1 + 3)", got)
	}
	info := rig.lastInfo(procOther)
	if _, ok := info.Get("read_budget_ip_spent"); ok {
		t.Error("read_budget_ip_spent must not be logged for a call whose IP charge was skipped")
	}
	if v, _ := info.Get("read_budget_spent"); v != int64(4) {
		t.Errorf("read_budget_spent = %v, want 4", v)
	}

	if err := rig.call(t, procOther, testIP); err != nil {
		t.Fatal(err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 1 {
		t.Errorf("ip spent = %d, want 1 (the mark is gone: a heavy call adds nothing to the IP meter)", got)
	}
	if got := cfg.ReadBudget.Spent("uid-stale"); got != 4+269 {
		t.Errorf("uid spent = %d, want %d", got, 4+269)
	}
}

// TestA9_MarkedCallThatStaysProfileLessKeepsTheMark: without ProfileFound the mark survives and every call is
// charged (found == false is the only thing that keeps A3 working).
func TestA9_MarkedCallThatStaysProfileLessKeepsTheMark(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-still", cfg, map[string]handler{procOther: fixed(1, pRequired)})
	for i := 1; i <= 3; i++ {
		if err := rig.call(t, procOther, testIP); err != nil {
			t.Fatal(err)
		}
		if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != int64(i) {
			t.Fatalf("after call %d ip spent = %d, want %d", i, got, i)
		}
	}
}

// TestA8_ExemptProceduresAreChargeOnlyOnTheIPKey: with the IP budget already spent by someone else, both exempt
// procedures are admitted and still charged; nothing is reserved on the IP key.
func TestA8_ExemptProceduresAreChargeOnlyOnTheIPKey(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-new", cfg, map[string]handler{procCreate: fixed(2, pNone), procCheck: fixed(1, pNone)})
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 500) // IP budget already spent by someone else

	for i, proc := range []string{procCreate, procCheck, procCheck} {
		if err := rig.call(t, proc, testIP); err != nil {
			t.Fatalf("call %d (%s) must never be rejected by the IP key: %v", i, proc, err)
		}
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 504 {
		t.Errorf("ip spent = %d, want 504 (2 + 1 + 1, still charged)", got)
	}
	if got := cfg.ReadBudgetIP.Inflight(ipKey(testIP)); got != 0 {
		t.Errorf("ip inflight = %d, want 0", got)
	}
}

// TestMJ1_IPKeyRejectionReleasesTheUIDInFlightSlot (code review 2 MJ1): when a later (IP) key rejects the call,
// the in-flight slot already taken on the uid key must be freed, or the uid is locked out for the rest of the
// instance lifetime (inflight is never reset). Uses the test-only enforcing config; both the daily and the
// transient IP rejection are covered.
func TestMJ1_IPKeyRejectionReleasesTheUIDInFlightSlot(t *testing.T) {
	tests := []struct {
		name      string
		prepIP    func(t *testing.T, c *ratelimit.DailyCap)
		wantLimit string
	}{
		{"daily IP rejection", func(_ *testing.T, c *ratelimit.DailyCap) { c.Charge(ipKey(testIP), 500) }, "read_budget_daily"},
		{"transient IP rejection", func(t *testing.T, c *ratelimit.DailyCap) {
			c.Charge(ipKey(testIP), 499)
			if ok, _ := c.Reserve(ipKey(testIP)); !ok { // another call is already in flight near the cap
				t.Fatal("setup: reserve on the IP key")
			}
		}, "read_budget_inflight"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := enforceCheckConfig()
			cfg.ReadBudget.Charge("uid-a", 1999) // a leaked slot would now reject every call of this uid
			tt.prepIP(t, cfg.ReadBudgetIP)
			rig := newMultiRig(t, "uid-a", cfg, map[string]handler{procCheck: fixed(1, pNone), procOther: fixed(1, pFound)})

			for i := 0; i < 3; i++ {
				d := rateLimitDetail(t, rig.call(t, procCheck, testIP))
				if d.GetMetadata()["limit"] != tt.wantLimit {
					t.Fatalf("call %d limit = %q, want %q", i, d.GetMetadata()["limit"], tt.wantLimit)
				}
				if v, _ := rig.lastInfo(procCheck).Get("read_budget_key"); v != "ip" {
					t.Fatalf("read_budget_key = %v, want ip (the IP key must be the one that rejected)", v)
				}
				if got := cfg.ReadBudget.Inflight("uid-a"); got != 0 {
					t.Fatalf("after rejected call %d uid inflight = %d, want 0 (slot leaked)", i, got)
				}
			}
			if got := cfg.ReadBudget.Spent("uid-a"); got != 1999 {
				t.Errorf("uid spent = %d, want 1999 (a rejected call costs 0 units)", got)
			}
			// The next call by the same uid is admitted: at spent = 1,999 a leaked slot would reject it as in-flight.
			if err := rig.call(t, procOther, ""); err != nil {
				t.Fatalf("next non-exempt call after the IP rejections must be admitted: %v", err)
			}
		})
	}
}

// TestA4_EnforcedIPProcedureStillRejectsWithMidnightRetry keeps the test-only enforcing seam honest: a
// procedure in ReadBudgetIPEnforce is rejected once the IP budget is spent, with retry_after to IST midnight,
// while a charge-only one is not. (Production enforces nothing since A8; the guard test asserts that.)
func TestA4_EnforcedIPProcedureStillRejectsWithMidnightRetry(t *testing.T) {
	cfg := enforceCheckConfig()
	rig := newMultiRig(t, "uid-new", cfg, map[string]handler{procCreate: fixed(2, pNone), procCheck: fixed(1, pNone)})
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 500)

	if err := rig.call(t, procCreate, testIP); err != nil {
		t.Fatalf("a charge-only procedure must never be rejected by the IP key: %v", err)
	}
	d := rateLimitDetail(t, rig.call(t, procCheck, testIP))
	if d.GetMetadata()["limit"] != "read_budget_daily" {
		t.Errorf("limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
	}
	if got := d.GetRetryAfter().AsDuration(); got <= 0 || got > 24*time.Hour {
		t.Errorf("retry_after = %v, want the time to IST midnight", got)
	}
}

// TestA1_InterceptorConcurrencyBound: through the interceptor, however many calls race at limit-1, exactly one
// is admitted and spend never passes limit - 1 + M; on the IP key (M = 2) the same holds for 500.
func TestA1_InterceptorConcurrencyBound(t *testing.T) {
	tests := []struct {
		name    string
		limit   int64
		m       int64
		proc    string
		ipKeyed bool
	}{
		{"uid key", 2000, config.ReadBudgetMaxCallReads, procOther, false},
		{"ip key", 500, config.IPReadBudgetMaxCallReads, procCheck, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uidCap := ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads)
			ipCap := ratelimit.NewDailyCap(500).WithMaxCallReads(config.IPReadBudgetMaxCallReads)
			cfg := ratelimit.Config{ReadBudget: uidCap, ReadBudgetIP: ipCap, ReadBudgetIPEnforce: map[string]struct{}{procCheck: {}}}
			capUnderTest, key := uidCap, "uid-a"
			if tt.ipKeyed {
				capUnderTest, key = ipCap, ipKey(testIP)
			}
			capUnderTest.Charge(key, tt.limit-1)

			const n = 40
			var admitted, rejected atomic.Int64
			release := make(chan struct{})
			decided := make(chan struct{}, n) // one token per call once the herd has decided it (admitted or rejected)
			rig := newMultiRig(t, "uid-a", cfg, map[string]handler{tt.proc: func(context.Context) (int64, pflag, error) {
				admitted.Add(1)
				decided <- struct{}{}
				<-release
				return tt.m, pNone, nil
			}})
			var wg sync.WaitGroup
			for i := 0; i < n; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if err := rig.call(t, tt.proc, testIP); err != nil {
						rejected.Add(1)
						decided <- struct{}{}
					}
				}()
			}
			for i := 0; i < n; i++ { // rendezvous: every call is admitted (handler entered) or rejected before release
				select {
				case <-decided:
				case <-time.After(10 * time.Second):
					t.Fatalf("herd did not decide after %d of %d calls", i, n)
				}
			}
			close(release)
			wg.Wait()
			if admitted.Load() != 1 || rejected.Load() != n-1 {
				t.Fatalf("admitted=%d rejected=%d, want exactly 1 admitted", admitted.Load(), rejected.Load())
			}
			if got, bound := capUnderTest.Spent(key), tt.limit-1+tt.m; got > bound {
				t.Fatalf("spent %d exceeds the A1 bound %d", got, bound)
			}
		})
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
// inflight count and the uid spend, and is never confused with a spent budget.
func TestA7_InFlightRejectionFields(t *testing.T) {
	uidCap := ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads)
	uidCap.Charge("uid-a", 1999)
	if ok, _ := uidCap.Reserve("uid-a"); !ok { // a call already in flight
		t.Fatal("reserve")
	}
	rig := newMultiRig(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, map[string]handler{procOther: fixed(1, pNone)})
	d := rateLimitDetail(t, rig.call(t, procOther, ""))
	if d.GetMetadata()["limit"] != "read_budget_inflight" {
		t.Errorf("limit = %q, want read_budget_inflight", d.GetMetadata()["limit"])
	}
	if got := d.GetRetryAfter().AsDuration(); got != time.Second {
		t.Errorf("retry_after = %v, want 1s", got)
	}
	info := rig.lastInfo(procOther)
	if info.LimitName != "read_budget_inflight" {
		t.Errorf("limit_name = %q", info.LimitName)
	}
	if v, _ := info.Get("read_budget_key"); v != "uid" {
		t.Errorf("read_budget_key = %v, want uid", v)
	}
	if v, _ := info.Get("read_budget_inflight"); v != int64(1) {
		t.Errorf("read_budget_inflight = %v, want 1", v)
	}
	if v, _ := info.Get("read_budget_spent"); v != int64(1999) {
		t.Errorf("read_budget_spent = %v, want 1999", v)
	}
}

// TestA7_SpendFieldsAndOverMaxWarning: read_budget_spent is always the uid's and read_budget_ip_spent the IP
// key's; a call that reads more than its hold logs WARN read_budget_over_max=true (and no IP address).
func TestA7_SpendFieldsAndOverMaxWarning(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })

	// The hold (and so the warning) only exists on a RESERVED key: since A8 that is only possible on the test-only
	// enforcing config (production reserves the uid key only, whose hold is 269).
	cfg := enforceCheckConfig()
	rig := newMultiRig(t, "uid-a", cfg, map[string]handler{procCheck: fixed(5, pNone)}) // 5 > the IP hold of 2
	if err := rig.call(t, procCheck, testIP); err != nil {
		t.Fatal(err)
	}
	info := rig.lastInfo(procCheck)
	if v, _ := info.Get("read_budget_spent"); v != int64(5) {
		t.Errorf("read_budget_spent = %v, want 5 (the uid's)", v)
	}
	if v, _ := info.Get("read_budget_ip_spent"); v != int64(5) {
		t.Errorf("read_budget_ip_spent = %v, want 5", v)
	}
	out := buf.String()
	if !bytes.Contains([]byte(out), []byte(`"read_budget_over_max":true`)) || !bytes.Contains([]byte(out), []byte(`"level":"WARN"`)) {
		t.Errorf("expected a WARN read_budget_over_max=true line, got %q", out)
	}
	if bytes.Contains([]byte(out), []byte(testIP)) || bytes.Contains([]byte(out), []byte("uid-a")) {
		t.Errorf("log must contain neither the IP nor the raw uid: %q", out)
	}
}
