package apiserver

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
)

// The chain order of the session cut (security audit H2; removal-server design 3.3 and 5, "apiserver chain-order
// test"): through the real chainInterceptors, a session refused with SESSION_ENDED draws on no per-minute bucket and no
// daily cap, and the verified-identity gate still runs before the cut lookup.

type chainAppCheck struct{}

func (chainAppCheck) VerifyToken(context.Context, string) error { return nil }

type chainIDVerifier map[string]authn.Claims

func (v chainIDVerifier) VerifyIDToken(_ context.Context, tok string) (authn.Claims, error) {
	c, ok := v[tok]
	if !ok {
		return authn.Claims{}, errors.New("bad token")
	}
	return c, nil
}

type chainCuts struct {
	cut   map[string]time.Time
	calls atomic.Int64
}

func (c *chainCuts) SessionsValidAfter(_ context.Context, uid string) (time.Time, error) {
	c.calls.Add(1)
	return c.cut[uid], nil
}

type chainActive struct{}

func (chainActive) AccountStatus(context.Context, string) (bool, authn.AccountStatus, error) {
	return true, authn.AccountStatusActive, nil
}

var passThrough = connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc { return next })

func TestChain_SessionCutRunsBeforeTheRateLimiter(t *testing.T) {
	const (
		uid       = "uid-chain-cut"
		perMinute = 3
		daily     = 5
	)
	cut := time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)
	commit := messagingv1connect.MessagingServiceCommitConversationProcedure

	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 1_000_000
	cfg.RateLimit.PerIPPerMinute = 1_000_000
	cfg.RateLimit.MessagesCommitPerUserPerMinute = perMinute
	cfg.RateLimit.MessagesCommitsPerDay = daily
	rl := RateLimitConfig(cfg)
	cuts := &chainCuts{cut: map[string]time.Time{uid: cut}}
	var cutOn atomic.Bool
	cutOn.Store(true)
	ics := chainInterceptors(chainDeps{
		log: slog.New(slog.NewTextHandler(io.Discard, nil)), projectID: "demo-dzeroth-local",
		appCheck: chainAppCheck{}, appCheckMode: authn.ModeMonitor,
		idVerifier: chainIDVerifier{
			"old":      {UID: uid, SignInProvider: authn.SignInProviderGoogle, EmailVerified: true, AuthTime: cut.Add(-time.Hour)},
			"fresh":    {UID: uid, SignInProvider: authn.SignInProviderGoogle, EmailVerified: true, AuthTime: cut},
			"phone":    {UID: uid, SignInProvider: "phone", AuthTime: cut.Add(-time.Hour)},
			"old-free": {UID: "uid-other", SignInProvider: authn.SignInProviderGoogle, AuthTime: cut.Add(-time.Hour)},
		},
		profileExempt: profileExemptProcedures(),
		sessionCuts:   cuts, sessionCutOn: cutOn.Load,
		rateLimit: rl, degradedMode: config.DegradedMode(""), media: degraded.ProcedureSet{},
		accountStatus: chainActive{}, publicIDs: passThrough,
	})
	var reached atomic.Int64
	mux := http.NewServeMux()
	mux.Handle(commit, connect.NewUnaryHandler(commit,
		func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
			reached.Add(1)
			return connect.NewResponse(&commonv1.ErrorDetail{}), nil
		}, connect.WithInterceptors(ics...)))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(tok string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+commit)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("Authorization", "Bearer "+tok)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
	reasonOf := func(err error) commonv1.ErrorReason {
		var ce *connect.Error
		if !errors.As(err, &ce) {
			return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED
		}
		for _, d := range ce.Details() {
			if v, verr := d.Value(); verr == nil {
				if ed, ok := v.(*commonv1.ErrorDetail); ok {
					return ed.GetReason()
				}
			}
		}
		return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED
	}

	// Many more refused calls than the bucket and the daily cap allow.
	for i := range 3 * daily {
		err := invoke("old")
		if connect.CodeOf(err) != connect.CodeUnauthenticated || reasonOf(err) != commonv1.ErrorReason_ERROR_REASON_SESSION_ENDED {
			t.Fatalf("call %d with the old session = %v, want UNAUTHENTICATED + SESSION_ENDED", i+1, err)
		}
	}
	if reached.Load() != 0 {
		t.Fatalf("a refused call reached the handler %d times", reached.Load())
	}
	if spent := rl.DailyCaps[commit].Cap.Spent(uid); spent != 0 {
		t.Fatalf("messages_commits_daily spent %d by refused calls, want 0 (the cut must run before the rate limiter)", spent)
	}
	// The fresh session (signed in at the cut) has its whole bucket.
	for i := range perMinute {
		if err := invoke("fresh"); err != nil {
			t.Fatalf("fresh call %d = %v, want a pass (the bucket must be untouched)", i+1, err)
		}
	}
	if spent := rl.DailyCaps[commit].Cap.Spent(uid); spent != perMinute {
		t.Errorf("daily spent %d after %d fresh calls, want %d", spent, perMinute, perMinute)
	}

	// The 0-read verified-identity gate still runs first: a refused provider costs no cut lookup.
	before := cuts.calls.Load()
	if err := invoke("phone"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("phone provider = %v, want the gate's FAILED_PRECONDITION", err)
	}
	if cuts.calls.Load() != before {
		t.Error("the gate let a refused provider reach the cut lookup")
	}

	// Globally off: nothing is read and an old session passes the cut.
	cutOn.Store(false)
	before = cuts.calls.Load()
	if err := invoke("old-free"); err != nil {
		t.Fatalf("flag globally off: %v, want a pass", err)
	}
	if cuts.calls.Load() != before {
		t.Error("globally off still read the cut")
	}
}
