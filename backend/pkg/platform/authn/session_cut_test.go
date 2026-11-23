package authn_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fakeCutProvider answers a fixed cut (or error) and counts lookups.
type fakeCutProvider struct {
	cut   time.Time
	err   error
	calls atomic.Int64
	uids  []string
}

func (p *fakeCutProvider) SessionsValidAfter(_ context.Context, uid string) (time.Time, error) {
	p.calls.Add(1)
	p.uids = append(p.uids, uid)
	return p.cut, p.err
}

var sessionCut = time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)

// TestSessionCutInterceptor: removal-server design 3.3. No cut or auth_time >= cut passes; an older auth_time, or a zero
// one with a cut set, is UNAUTHENTICATED + SESSION_ENDED before anything after it runs, with session_cut_refused=true on
// the request line and no time or uid in any field; a provider error is INTERNAL; globally off reads nothing.
func TestSessionCutInterceptor(t *testing.T) {
	tests := []struct {
		name       string
		cut        time.Time
		authTime   time.Time
		providErr  error
		enabled    bool
		wantCode   connect.Code // 0 = passes
		wantLookup bool
	}{
		{name: "no cut passes", authTime: sessionCut.Add(-time.Hour), enabled: true, wantLookup: true},
		{name: "auth_time equal to the cut passes (the remover's own session)", cut: sessionCut, authTime: sessionCut, enabled: true, wantLookup: true},
		{name: "auth_time after the cut passes", cut: sessionCut, authTime: sessionCut.Add(time.Second), enabled: true, wantLookup: true},
		{name: "auth_time one second before the cut is refused", cut: sessionCut, authTime: sessionCut.Add(-time.Second), enabled: true, wantCode: connect.CodeUnauthenticated, wantLookup: true},
		{name: "zero auth_time with a cut fails closed", cut: sessionCut, enabled: true, wantCode: connect.CodeUnauthenticated, wantLookup: true},
		{name: "zero auth_time without a cut passes", enabled: true, wantLookup: true},
		{name: "provider error is INTERNAL", providErr: errors.New("firestore unavailable"), authTime: sessionCut, enabled: true, wantCode: connect.CodeInternal, wantLookup: true},
		{name: "globally off skips the check and reads nothing", cut: sessionCut, authTime: sessionCut.Add(-time.Hour), enabled: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider := &fakeCutProvider{cut: tt.cut, err: tt.providErr}
			var info *logger.RequestInfo
			var reached atomic.Int64
			after := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
				return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
					reached.Add(1)
					return next(ctx, req)
				}
			})
			const uid = "uid-session-cut-1"
			verifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"tok": {UID: uid, SignInProvider: authn.SignInProviderGoogle, AuthTime: tt.authTime}}}
			srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(verifier),
				authn.SessionCutInterceptor(provider, func() bool { return tt.enabled }), after)
			err := call(t, srv, map[string]string{"Authorization": "Bearer tok"})
			if got := provider.calls.Load() > 0; got != tt.wantLookup {
				t.Errorf("provider consulted = %v, want %v", got, tt.wantLookup)
			}
			if tt.wantLookup && (len(provider.uids) != 1 || provider.uids[0] != uid) {
				t.Errorf("lookups = %v, want exactly the caller's uid once", provider.uids)
			}
			if tt.wantCode == 0 {
				if err != nil {
					t.Fatalf("want a pass, got %v", err)
				}
				if reached.Load() != 1 {
					t.Errorf("reached = %d, want 1", reached.Load())
				}
				if _, ok := info.Get("session_cut_refused"); ok {
					t.Error("session_cut_refused set on a pass")
				}
				return
			}
			if err == nil {
				t.Fatal("want a refusal, got a pass")
			}
			// An INTERNAL is the raw *apierr.Error, which mw.Logging shapes in the real chain (this test server has no
			// mw.Logging, so it arrives as Unknown here); TestSessionCutInterceptor_ProviderErrorKeepsItsCause pins its code.
			if got := codeOf(t, err); tt.wantCode != connect.CodeInternal && got != tt.wantCode {
				t.Fatalf("code = %v, want %v (err %v)", got, tt.wantCode, err)
			}
			if reached.Load() != 0 {
				t.Errorf("a refused call reached the next interceptor %d times", reached.Load())
			}
			if tt.wantCode == connect.CodeUnauthenticated {
				if got := reasonOf(t, err); got != commonv1.ErrorReason_ERROR_REASON_SESSION_ENDED {
					t.Errorf("reason = %v, want SESSION_ENDED", got)
				}
				if v, _ := info.Get("session_cut_refused"); v != true {
					t.Errorf("session_cut_refused = %v, want true", v)
				}
			}
			// No time and no uid in any request-line field or in the error text (the uid is logged only as
			// mw.Logging's uid_hash).
			for _, a := range info.Fields() {
				s := fmt.Sprint(a.Value.Any())
				if strings.Contains(s, uid) || strings.Contains(s, "2026") {
					t.Errorf("request-line field %s = %q carries a uid or a time", a.Key, s)
				}
				if _, isTime := a.Value.Any().(time.Time); isTime {
					t.Errorf("request-line field %s is a time", a.Key)
				}
			}
			if strings.Contains(err.Error(), uid) || strings.Contains(err.Error(), "2026") {
				t.Errorf("error text carries a uid or a time: %v", err)
			}
		})
	}
}

// TestSessionCutInterceptor_ProviderErrorKeepsItsCause: like AccountStatusInterceptor (M3), the INTERNAL error is the raw
// *apierr.Error with its cause, so mw.Logging can report it; the client still sees only "internal error".
func TestSessionCutInterceptor_ProviderErrorKeepsItsCause(t *testing.T) {
	cause := errors.New("firestore unavailable")
	ic := authn.SessionCutInterceptor(&fakeCutProvider{err: cause}, func() bool { return true })
	next := func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		t.Fatal("next must not run")
		return nil, nil
	}
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "u1", AuthTime: sessionCut})
	_, err := ic(next)(ctx, connect.NewRequest(&commonv1.ErrorDetail{}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeInternal || !errors.Is(err, cause) {
		t.Fatalf("err = %#v, want a raw INTERNAL *apierr.Error wrapping the cause", err)
	}
}

// TestSessionCutInterceptor_NoClaimsPasses: a request without verified claims (never the case behind IDTokenInterceptor)
// has no session to cut: it passes without a lookup, and the interceptors after it decide.
func TestSessionCutInterceptor_NoClaimsPasses(t *testing.T) {
	p := &fakeCutProvider{cut: sessionCut}
	ic := authn.SessionCutInterceptor(p, func() bool { return true })
	called := false
	next := func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		called = true
		return nil, nil
	}
	if _, err := ic(next)(context.Background(), connect.NewRequest(&commonv1.ErrorDetail{})); err != nil || !called || p.calls.Load() != 0 {
		t.Errorf("err %v, next %v, lookups %d; want a pass with no lookup", err, called, p.calls.Load())
	}
}

// TestSessionCutInterceptor_EnabledIsAskedPerRequest: the switch is read on every request (a flag flip applies at once,
// never captured at build time).
func TestSessionCutInterceptor_EnabledIsAskedPerRequest(t *testing.T) {
	var on atomic.Bool
	p := &fakeCutProvider{cut: sessionCut}
	ic := authn.SessionCutInterceptor(p, on.Load)
	next := func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return nil, nil }
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "u1", AuthTime: sessionCut.Add(-time.Hour)})
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	if _, err := ic(next)(ctx, req); err != nil {
		t.Fatalf("off: %v", err)
	}
	on.Store(true)
	if _, err := ic(next)(ctx, req); err == nil {
		t.Fatal("on: want SESSION_ENDED")
	}
}
