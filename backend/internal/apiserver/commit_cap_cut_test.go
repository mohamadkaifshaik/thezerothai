package apiserver

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
)

// messages_commits_daily keyed by the session cut (lane D PR 5, removal-server design Q8): through the real chain, a
// drain before the cut does not block the session that signed in at the cut, and without a cut the counter is the bare
// uid, as before this change.

// lockedCuts is a SessionCutProvider the test can change between calls (the handler runs on the server's goroutines).
type lockedCuts struct {
	mu  sync.Mutex
	cut map[string]time.Time
}

func (c *lockedCuts) SessionsValidAfter(_ context.Context, uid string) (time.Time, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cut[uid], nil
}

func (c *lockedCuts) set(uid string, t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cut[uid] = t
}

// peek is the cache peek the cap key uses: a miss when the uid has no entry at all.
func (c *lockedCuts) peek(uid string) (time.Time, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	t, ok := c.cut[uid]
	return t, ok
}

// TestWithCommitCapCutKey: the key is set on CommitConversation's cap alone; a nil peek leaves the config as
// RateLimitConfig built it; a cache miss keys by the bare uid (no read); a hit tags a post-cut session only.
func TestWithCommitCapCutKey(t *testing.T) {
	commit := messagingv1connect.MessagingServiceCommitConversationProcedure
	cut := time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)
	cuts := &lockedCuts{cut: map[string]time.Time{"uid-cut": cut, "uid-none": {}}}
	rl := withCommitCapCutKey(RateLimitConfig(defaultRateLimitCfg()), cuts.peek)
	for p, named := range rl.DailyCaps {
		if (named.Key != nil) != (p == commit) {
			t.Errorf("%s: key set = %v, want it on CommitConversation only", p, named.Key != nil)
		}
	}
	if withCommitCapCutKey(RateLimitConfig(defaultRateLimitCfg()), nil).DailyCaps[commit].Key != nil {
		t.Error("a nil peek set a key")
	}
	key := rl.DailyCaps[commit].Key
	at := func(authTime time.Time) context.Context {
		return authn.WithClaims(context.Background(), authn.Claims{UID: "x", AuthTime: authTime})
	}
	for _, tc := range []struct {
		name string
		uid  string
		ctx  context.Context
		want string
	}{
		{"cache miss: the bare uid", "uid-missing", at(cut), "uid-missing"},
		{"no cut", "uid-none", at(cut), "uid-none"},
		{"post-cut session", "uid-cut", at(cut), "uid-cut|c20261126"},
		{"pre-cut session (globally off)", "uid-cut", at(cut.Add(-time.Minute)), "uid-cut"},
	} {
		if got := key(tc.ctx, tc.uid); got != tc.want {
			t.Errorf("%s: key = %q, want %q", tc.name, got, tc.want)
		}
	}
	p := identityCutPeek(func(uid string) (identity.Profile, bool) {
		return identity.Profile{SessionsValidAfter: cut}, uid == "hit"
	})
	if c, ok := p("hit"); !ok || !c.Equal(cut) {
		t.Errorf("identityCutPeek hit = %v, %v", c, ok)
	}
	if _, ok := p("miss"); ok {
		t.Error("identityCutPeek turned a miss into a hit")
	}
}

func TestChain_CommitDailyCapFreshAfterCut(t *testing.T) {
	const (
		uid   = "uid-chain-cap-cut"
		daily = 2
	)
	cut := time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)
	commit := messagingv1connect.MessagingServiceCommitConversationProcedure

	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 1_000_000
	cfg.RateLimit.PerIPPerMinute = 1_000_000
	cfg.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	cfg.RateLimit.MessagesCommitsPerDay = daily
	cuts := &lockedCuts{cut: map[string]time.Time{}}
	rl := withCommitCapCutKey(RateLimitConfig(cfg), cuts.peek)
	var cutOn atomic.Bool
	cutOn.Store(true)
	ics := chainInterceptors(chainDeps{
		log: slog.New(slog.NewTextHandler(io.Discard, nil)), projectID: "demo-dzeroth-local",
		appCheck: chainAppCheck{}, appCheckMode: authn.ModeMonitor,
		idVerifier: chainIDVerifier{
			"thief": {UID: uid, SignInProvider: authn.SignInProviderGoogle, EmailVerified: true, AuthTime: cut.Add(-time.Hour)},
			"owner": {UID: uid, SignInProvider: authn.SignInProviderGoogle, EmailVerified: true, AuthTime: cut},
		},
		profileExempt: profileExemptProcedures(),
		sessionCuts:   cuts, sessionCutOn: cutOn.Load,
		rateLimit: rl, degradedMode: config.DegradedMode(""), media: degraded.ProcedureSet{},
		accountStatus: chainActive{}, publicIDs: passThrough,
	})
	mux := http.NewServeMux()
	mux.Handle(commit, connect.NewUnaryHandler(commit,
		func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
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
	wantLimit := func(err error) {
		t.Helper()
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("= %v, want RESOURCE_EXHAUSTED", err)
		}
		for _, d := range ce.Details() {
			if v, verr := d.Value(); verr == nil {
				if ed, ok := v.(*commonv1.ErrorDetail); ok && ed.GetMetadata()["limit"] == messagesCommitsDailyName {
					return
				}
			}
		}
		t.Fatalf("= %v, want limit %s", err, messagesCommitsDailyName)
	}

	// Before the cut the thief drains the cap; the counter is the bare uid, as before this change.
	for i := range daily {
		if err := invoke("thief"); err != nil {
			t.Fatalf("thief call %d = %v, want a pass", i+1, err)
		}
	}
	wantLimit(invoke("thief"))
	if got := rl.DailyCaps[commit].Cap.Spent(uid); got != daily {
		t.Fatalf("pre-cut spent under the uid = %d, want %d", got, daily)
	}

	// The REMOTE removal records the cut at the owner's sign-in: the thief is refused before the limiter, and the owner's
	// commits draw on a fresh counter.
	cuts.set(uid, cut)
	if err := invoke("thief"); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("thief after the cut = %v, want UNAUTHENTICATED", err)
	}
	for i := range daily {
		if err := invoke("owner"); err != nil {
			t.Fatalf("owner call %d after the cut = %v, want a pass (a fresh counter)", i+1, err)
		}
	}
	wantLimit(invoke("owner"))
	if got := rl.DailyCaps[commit].Cap.Spent(messaging.CapKeyAfterCut(uid, cut)); got != daily {
		t.Errorf("post-cut spent = %d, want %d", got, daily)
	}
	if got := rl.DailyCaps[commit].Cap.Spent(uid); got != daily {
		t.Errorf("the pre-cut counter moved to %d, want %d", got, daily)
	}

	// device_sign_out globally off (the emergency lever): the thief's session passes the cut check but stays on the
	// drained pre-cut counter; it never gets the remover's fresh one.
	cutOn.Store(false)
	wantLimit(invoke("thief"))
	if got := rl.DailyCaps[commit].Cap.Spent(messaging.CapKeyAfterCut(uid, cut)); got != daily {
		t.Errorf("a pre-cut session drew on the post-cut counter: %d", got)
	}
}
