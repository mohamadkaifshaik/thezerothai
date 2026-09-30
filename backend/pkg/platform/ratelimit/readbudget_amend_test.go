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
	procCreate = "/t.Service/CreateProfile" // IP charge-only (A4)
	procCheck  = "/t.Service/CheckHandle"   // IP enforced (A4)
	testIP     = "203.0.113.9"
)

// multiRig serves several procedures through ONE ratelimit.Interceptor instance (so the A3 profile-less marks
// are shared between them, as in production) behind counter/RequestInfo injection standing in for mw.Logging.
type multiRig struct {
	srv  *httptest.Server
	info map[string]*logger.RequestInfo // last RequestInfo per procedure
	mu   sync.Mutex
}

// handler lets a test decide per call how many reads to spend and whether the account-status interceptor
// would have flagged the caller as profile-less.
type handler func(ctx context.Context) (reads int64, profileRequired bool, err error)

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
				reads, profileRequired, err := h(ctx)
				budget.FromContext(ctx).AddReads(reads)
				if profileRequired {
					logger.RequestInfoFromContext(ctx).ProfileRequired = true
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

func fixed(reads int64, profileRequired bool) handler {
	return func(context.Context) (int64, bool, error) { return reads, profileRequired, nil }
}

func a3Config() ratelimit.Config {
	return ratelimit.Config{
		ReadBudget:             ratelimit.NewDailyCap(2000).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		ReadBudgetIP:           ratelimit.NewDailyCap(500).WithMaxCallReads(config.IPReadBudgetMaxCallReads),
		ReadBudgetIPEnforce:    map[string]struct{}{procCheck: {}},
		ReadBudgetIPChargeOnly: map[string]struct{}{procCreate: {}},
	}
}

// TestA3_VerifiedCallerWithoutProfileIsChargedToIPAndMarked: a call the account-status interceptor rejects as
// PROFILE_REQUIRED is charged to the IP key, the uid is marked, and from then on the uid's non-exempt calls
// reserve the IP key and are rejected (retry 10 min, log key=ip, profile_required) once that budget is spent.
// A caller with a profile behind the same IP is never limited.
func TestA3_VerifiedCallerWithoutProfileIsChargedToIPAndMarked(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-noprofile", cfg, map[string]handler{procOther: fixed(1, true)})

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

	// The mark makes the next call reserve the IP key too: spend it, then the uid is rejected with a 10 min retry.
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 500)
	d := rateLimitDetail(t, rig.call(t, procOther, testIP))
	if d.GetMetadata()["limit"] != "read_budget_daily" {
		t.Errorf("limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
	}
	if got := d.GetRetryAfter().AsDuration(); got != ratelimit.ProfileLessMarkTTL {
		t.Errorf("retry_after = %v, want 10m (the mark may be stale)", got)
	}
	if v, _ := rig.lastInfo(procOther).Get("read_budget_key"); v != "ip" {
		t.Errorf("read_budget_key = %v, want ip", v)
	}
	if v, _ := rig.lastInfo(procOther).Get("profile_required"); v != true {
		t.Errorf("profile_required = %v, want true on the rejection too", v)
	}

	// A caller WITH a profile (handler never sets ProfileRequired) behind the same IP is never IP-limited.
	other := newMultiRig(t, "uid-withprofile", cfg, map[string]handler{procOther: fixed(3, false)})
	if err := other.call(t, procOther, testIP); err != nil {
		t.Fatalf("a caller with a profile must not be IP-limited: %v", err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 501 {
		t.Errorf("ip spent = %d, want 501 (callers with a profile are not charged)", got)
	}
}

// TestA3_NoMarkWithoutProfileRequired: a caller whose profile this instance has seen is never marked, so its
// calls never touch the IP key (carrier-grade NAT protection).
func TestA3_NoMarkWithoutProfileRequired(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-a", cfg, map[string]handler{procOther: fixed(2, false)})
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
// longer marked, so its next non-exempt call does not reserve the (spent) IP key.
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
			rig := newMultiRig(t, "uid-x", cfg, map[string]handler{
				procOther:  fixed(1, true),
				procCreate: func(context.Context) (int64, bool, error) { return 2, false, createErr },
			})
			if err := rig.call(t, procOther, testIP); err != nil {
				t.Fatal(err)
			}
			_ = rig.call(t, procCreate, testIP)
			cfg.ReadBudgetIP.Charge(ipKey(testIP), 500) // spend the IP budget
			err := rig.call(t, procOther, testIP)
			if tt.wantMarked {
				assertResourceExhausted(t, err)
			} else if err != nil {
				t.Fatalf("mark must be cleared after a successful CreateProfile: %v", err)
			}
		})
	}
}

// TestA4_CreateProfileIsChargeOnlyOnIP: CreateProfile is charged to the IP key and never rejected by it, so one
// abuser behind a shared IPv4 cannot block sign-ups; CheckHandleAvailability stays enforced.
func TestA4_CreateProfileIsChargeOnlyOnIP(t *testing.T) {
	cfg := a3Config()
	rig := newMultiRig(t, "uid-new", cfg, map[string]handler{procCreate: fixed(2, false), procCheck: fixed(1, false)})
	cfg.ReadBudgetIP.Charge(ipKey(testIP), 500) // IP budget already spent by someone else

	if err := rig.call(t, procCreate, testIP); err != nil {
		t.Fatalf("CreateProfile must never be rejected by the IP key: %v", err)
	}
	if got := cfg.ReadBudgetIP.Spent(ipKey(testIP)); got != 502 {
		t.Errorf("ip spent = %d, want 502 (still charged)", got)
	}
	d := rateLimitDetail(t, rig.call(t, procCheck, testIP))
	if d.GetMetadata()["limit"] != "read_budget_daily" {
		t.Errorf("CheckHandleAvailability limit = %q, want read_budget_daily", d.GetMetadata()["limit"])
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
			rig := newMultiRig(t, "uid-a", cfg, map[string]handler{tt.proc: func(context.Context) (int64, bool, error) {
				admitted.Add(1)
				<-release
				return tt.m, false, nil
			}})
			var wg sync.WaitGroup
			for i := 0; i < n; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if err := rig.call(t, tt.proc, testIP); err != nil {
						rejected.Add(1)
					}
				}()
			}
			deadline := time.Now().Add(5 * time.Second)
			for admitted.Load()+rejected.Load() < n && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond) // bounded poll: the herd decides without the handler's help
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
	rig := newMultiRig(t, "uid-a", ratelimit.Config{ReadBudget: uidCap}, map[string]handler{procOther: fixed(1, false)})
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

	cfg := a3Config()
	rig := newMultiRig(t, "uid-a", cfg, map[string]handler{procCheck: fixed(5, false)}) // 5 > the IP hold of 2
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
