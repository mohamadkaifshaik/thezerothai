//go:build integration

// Package e2e boots the real API handler — backend/internal/apiserver.Build, the exact wiring
// cmd/api/main.go runs in production — inside an httptest.Server against the Firebase Emulator Suite
// (testing-strategy skill: "Go e2e suite in backend/e2e: runs against emulators in CI"). No mocks: real
// Connect interceptor chain (ADR-0006 §2), a real Firebase Auth emulator-minted ID token, real Firestore.
// Run via `make test-int`.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/apiserver"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func skipIfNoEmulators(t *testing.T) {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" || os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST/FIREBASE_AUTH_EMULATOR_HOST not set; run via `make test-int`")
	}
}

// newAnonymousIDToken mints a fresh Firebase Auth emulator ID token for a brand-new anonymous user via
// the emulator's identitytoolkit REST API — no service-account credentials needed; the emulator accepts
// any API key and issues a real (emulator-signed) ID token the Admin SDK will verify. Returns the token
// and the uid ("localId") it belongs to.
func newAnonymousIDToken(t *testing.T) (idToken, uid string) {
	t.Helper()
	authHost := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key", authHost)
	resp, err := http.Post(url, "application/json", bytes.NewReader([]byte(`{"returnSecureToken":true}`)))
	if err != nil {
		t.Fatalf("mint id token: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read id token response: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("mint id token: status %d: %s", resp.StatusCode, body)
	}
	var out struct {
		IDToken string `json:"idToken"`
		LocalID string `json:"localId"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode id token response: %v: %s", err, body)
	}
	return out.IDToken, out.LocalID
}

// newPasswordIDToken mints a fresh Firebase Auth emulator email/password user via the same
// identitytoolkit REST API as newAnonymousIDToken, with an email+password instead of an anonymous signup.
// The emulator matches real Firebase behavior here: a brand-new email/password account starts with
// emailVerified: false (returnSecureToken alone never verifies it) — exactly the account H1 (2026-09-27
// security audit) must block from CreateProfile until it verifies.
func newPasswordIDToken(t *testing.T, email, password string) (idToken, uid string) {
	t.Helper()
	authHost := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key", authHost)
	reqBody, err := json.Marshal(map[string]any{
		"email":             email,
		"password":          password,
		"returnSecureToken": true,
	})
	if err != nil {
		t.Fatalf("marshal password signUp request: %v", err)
	}
	resp, err := http.Post(url, "application/json", bytes.NewReader(reqBody))
	if err != nil {
		t.Fatalf("mint password id token: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read password id token response: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("mint password id token: status %d: %s", resp.StatusCode, body)
	}
	var out struct {
		IDToken string `json:"idToken"`
		LocalID string `json:"localId"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode password id token response: %v: %s", err, body)
	}
	return out.IDToken, out.LocalID
}

// uniqueHandle builds a valid, almost-certainly-unique handle (identity/validate.go: 3-15 chars,
// [A-Za-z0-9_]) so re-running these tests against a still-running (not freshly restarted) emulator never
// collides with a previous run's data — `make test-int` starts a fresh emulator per invocation, but a
// developer iterating locally with `make emulators` left running does not.
func uniqueHandle(prefix string) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	suffix := make([]byte, 15-len(prefix))
	for i := range suffix {
		suffix[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return prefix + string(suffix)
}

// authedRequest builds a connect.Request with the caller's ID token attached the way every real client
// does (Authorization: Bearer <idToken>) — never a body field (CLAUDE.md: "the caller's uid comes from
// the token, never the body").
func authedRequest[T any](idToken string, msg *T) *connect.Request[T] {
	req := connect.NewRequest(msg)
	req.Header().Set("Authorization", "Bearer "+idToken)
	return req
}

// newTestServer boots the real handler (apiserver.Build, same wiring as cmd/api/main.go) against the
// currently running emulators, in the given degraded mode. FIREBASE_PROJECT_ID/ENV/etc. come from the
// process environment `firebase emulators:exec` sets (see Makefile EMULATOR_PROJECT) so this test uses
// the exact project the Auth emulator is locked to (firebase.json singleProjectMode).
func newTestServer(t *testing.T, degradedMode config.DegradedMode) (client identityv1connect.IdentityServiceClient, baseURL string) {
	t.Helper()
	return newTestServerCfg(t, func(cfg *config.Config) { cfg.Degraded = degradedMode })
}

// newTestServerCfg is newTestServer generalized to let a test tweak any config field (e.g. rate limits)
// before apiserver.Build wires the real handler — the same *config.Config main.go would load, mutated the
// same way a Terraform/env-var change would.
func newTestServerCfg(t *testing.T, mutate func(*config.Config)) (client identityv1connect.IdentityServiceClient, baseURL string) {
	t.Helper()
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if mutate != nil {
		mutate(&cfg)
	}

	log := logger.New(cfg.ProjectID)
	handler, fsClient, err := apiserver.Build(context.Background(), cfg, log)
	if err != nil {
		t.Fatalf("apiserver.Build: %v", err)
	}
	srv := httptest.NewServer(handler)
	t.Cleanup(func() {
		srv.Close()
		_ = fsClient.Close()
	})
	return identityv1connect.NewIdentityServiceClient(srv.Client(), srv.URL), srv.URL
}

func assertCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error with code %v, got nil", want)
	}
	if got := connect.CodeOf(err); got != want {
		t.Fatalf("code = %v (%v), want %v", got, err, want)
	}
}

// assertErrorReason checks both the Connect code and the dzeroth.common.v1.ErrorDetail.Reason carried in
// the error's details (apierr.ToConnect's shape, pkg/platform/apierr) — the exact ErrorReason enum value
// the client's connect_error_mapper.dart switches on.
func assertErrorReason(t *testing.T, err error, wantCode connect.Code, wantReason commonv1.ErrorReason) {
	t.Helper()
	assertCode(t, err, wantCode)
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	for _, d := range cerr.Details() {
		msg, derr := d.Value()
		if derr != nil {
			continue
		}
		if detail, ok := msg.(*commonv1.ErrorDetail); ok && detail.GetReason() == wantReason {
			return
		}
	}
	t.Fatalf("expected ErrorReason %v in details, got none matching (err: %v)", wantReason, err)
}

// TestE2E_Healthz: /health (and its /healthz alias) is a plain http.HandlerFunc outside the Connect interceptor chain (no auth,
// no Firestore) — must always answer 200, in every degraded mode, so Cloud Run's liveness probe never
// depends on downstream health (CLAUDE.md rule 8).
func TestE2E_Healthz(t *testing.T) {
	skipIfNoEmulators(t)
	_, baseURL := newTestServer(t, config.DegradedOff)

	resp, err := http.Get(baseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200", resp.StatusCode)
	}
}

// TestE2E_SignUpThenGetMe drives the real sign-up flow end to end: a brand-new Firebase Auth user has no
// profile yet (GetMe -> PROFILE_REQUIRED, enforced by authn.AccountStatusInterceptor), creates one
// (CreateProfile), and can then read it back (GetMe) — all over real Connect JSON, real ID token
// verification, real Firestore.
func TestE2E_SignUpThenGetMe(t *testing.T) {
	skipIfNoEmulators(t)
	client, _ := newTestServer(t, config.DegradedOff)
	idToken, uid := newAnonymousIDToken(t)

	// Before a profile exists: every non-exempt RPC is rejected with PROFILE_REQUIRED.
	_, err := client.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	assertCode(t, err, connect.CodeFailedPrecondition)

	handle := uniqueHandle("e2e")
	createResp, err := client.CreateProfile(context.Background(), authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-signup-flow-idempotency-key-1",
		Handle:         handle,
		DisplayName:    "E2E Alice",
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if got := createResp.Msg.GetProfile().GetUserId(); got != uid {
		t.Fatalf("CreateProfile: user_id = %q, want %q", got, uid)
	}
	if got := createResp.Msg.GetProfile().GetHandle(); got != handle {
		t.Fatalf("CreateProfile: handle = %q, want %q", got, handle)
	}

	meResp, err := client.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe (after CreateProfile): %v", err)
	}
	if got := meResp.Msg.GetProfile().GetHandle(); got != handle {
		t.Fatalf("GetMe: handle = %q, want %q", got, handle)
	}
	if meResp.Msg.GetStatus() != identityv1.AccountStatus_ACCOUNT_STATUS_ACTIVE {
		t.Fatalf("GetMe: status = %v, want ACTIVE", meResp.Msg.GetStatus())
	}
}

// TestE2E_DegradedReadonly_RejectsWritesButAllowsReads exercises the DEGRADED_MODE=readonly switch
// (CLAUDE.md "degraded-mode switch", pkg/platform/degraded) through the full stack: a mutating RPC must
// be rejected even though it would otherwise succeed, while a read-only RPC and /health keep working.
func TestE2E_DegradedReadonly_RejectsWritesButAllowsReads(t *testing.T) {
	skipIfNoEmulators(t)
	client, baseURL := newTestServer(t, config.DegradedReadonly)
	idToken, _ := newAnonymousIDToken(t)

	resp, err := http.Get(baseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200 even in readonly mode", resp.StatusCode)
	}

	// CheckHandleAvailability is NO_SIDE_EFFECTS and profile-exempt: must still work in readonly mode.
	if _, err := client.CheckHandleAvailability(context.Background(), authedRequest(idToken, &identityv1.CheckHandleAvailabilityRequest{
		Handle: uniqueHandle("e2e"),
	})); err != nil {
		t.Fatalf("CheckHandleAvailability should succeed in readonly mode: %v", err)
	}

	// CreateProfile is a write: must be rejected, never reaching Firestore.
	_, err = client.CreateProfile(context.Background(), authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-degraded-readonly-idempotency-key",
		Handle:         uniqueHandle("e2e"),
		DisplayName:    "Should Not Be Created",
	}))
	assertCode(t, err, connect.CodeUnavailable)

	// Confirm the rejected CreateProfile really did not create a profile: a fresh, non-degraded server
	// against the same Firestore project should still see PROFILE_REQUIRED for this uid.
	onlineClient, _ := newTestServer(t, config.DegradedOff)
	_, err = onlineClient.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// TestE2E_APIPrefix_HealthzAndRPC (B1): Firebase Hosting forwards `/api/**` to Cloud Run unchanged
// (firebase.json) — every route apiserver.Build registers must also answer under that prefix, not just at
// the bare path the generated Connect client uses by default.
func TestE2E_APIPrefix_HealthzAndRPC(t *testing.T) {
	skipIfNoEmulators(t)
	_, baseURL := newTestServer(t, config.DegradedOff)

	resp, err := http.Get(baseURL + "/api/health")
	if err != nil {
		t.Fatalf("GET /api/health: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/health status = %d, want 200", resp.StatusCode)
	}

	apiClient := identityv1connect.NewIdentityServiceClient(http.DefaultClient, baseURL+"/api")
	idToken, _ := newAnonymousIDToken(t)
	if _, err := apiClient.CheckHandleAvailability(context.Background(), authedRequest(idToken, &identityv1.CheckHandleAvailabilityRequest{
		Handle: uniqueHandle("e2e"),
	})); err != nil {
		t.Fatalf("CheckHandleAvailability via /api prefix: %v", err)
	}
}

// TestE2E_CORS_AllowsLocalDevOrigin (M10): config.Load defaults CORS on for localhost origins in local
// dev (the env `make test-int`/`make dev` run under) so Flutter web (a different origin than the API) can
// call it directly without going through Firebase Hosting's same-origin rewrite.
func TestE2E_CORS_AllowsLocalDevOrigin(t *testing.T) {
	skipIfNoEmulators(t)
	_, baseURL := newTestServer(t, config.DegradedOff)

	req, err := http.NewRequest(http.MethodGet, baseURL+"/health", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Origin", "http://localhost:54321")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /health with Origin header: %v", err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "http://localhost:54321" {
		t.Errorf("Access-Control-Allow-Origin = %q, want the echoed local dev origin", got)
	}
}

// TestE2E_RateLimitRunsBeforeAccountStatus (M1): a profile-less caller must be rate limited like any other
// caller — the old interceptor order (account status before rate limit) let such a caller retry a
// non-exempt RPC without limit, since AccountStatusInterceptor rejected (PROFILE_REQUIRED) before
// ratelimit.Interceptor ever ran. With the fixed order, a second call within the same window must be
// RESOURCE_EXHAUSTED, never PROFILE_REQUIRED again.
func TestE2E_RateLimitRunsBeforeAccountStatus(t *testing.T) {
	skipIfNoEmulators(t)
	client, _ := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.RateLimit.PerUserPerMinute = 1
		cfg.RateLimit.PerIPPerMinute = 1000 // avoid the shared-IP bucket masking the per-uid assertion below
	})
	idToken, _ := newAnonymousIDToken(t)

	// First call: consumes the caller's only token for this window, then still correctly reports
	// PROFILE_REQUIRED (rate limiting must never mask a real, distinct rejection reason).
	_, err := client.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	assertCode(t, err, connect.CodeFailedPrecondition)

	// Second call, same minute: must be rejected by the limiter before ever reaching account status /
	// Firestore.
	_, err = client.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	assertCode(t, err, connect.CodeResourceExhausted)
}

// TestE2E_CreateProfile_UnverifiedPasswordEmail_Rejected (H1, docs/reviews/security-audit-v0.1.0.md): the
// Firebase Auth emulator mints unverified email/password users by default, exactly like real Firebase —
// real end-to-end proof that CreateProfile rejects such a caller with EMAIL_NOT_VERIFIED before ever
// reaching Firestore, over the real Connect interceptor chain and real Admin-SDK token verification.
func TestE2E_CreateProfile_UnverifiedPasswordEmail_Rejected(t *testing.T) {
	skipIfNoEmulators(t)
	client, _ := newTestServer(t, config.DegradedOff)
	email := fmt.Sprintf("h1-unverified-%d@example.com", rand.Int63())
	idToken, _ := newPasswordIDToken(t, email, "correct horse battery staple")

	_, err := client.CreateProfile(context.Background(), authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-h1-unverified-idempotency-key",
		Handle:         uniqueHandle("e2eh1"),
		DisplayName:    "Should Not Be Created",
	}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)

	// Confirm the rejected CreateProfile really did not create a profile.
	_, err = client.GetMe(context.Background(), authedRequest(idToken, &identityv1.GetMeRequest{}))
	assertCode(t, err, connect.CodeFailedPrecondition) // PROFILE_REQUIRED, not the EMAIL_NOT_VERIFIED above
}

// doXFFRequest issues method/url with an X-Forwarded-For header, simulating what Cloud Run's front end
// would append for a direct client at xff (httptest's raw loopback connections carry no such header on
// their own, unlike real Cloud Run traffic — pkg/platform/ratelimit.ResolveClientIP has nothing to key on
// without it).
func doXFFRequest(t *testing.T, method, url, xff string, body []byte) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatalf("build %s %s: %v", method, url, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", xff)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	return resp
}

// TestE2E_PreAuthIPLimiter_BlocksFloodExemptsHealth (M1, docs/reviews/security-audit-v0.1.0.md): a flood of
// completely unauthenticated requests (no Authorization header at all) to a real RPC path must be rejected
// once the caller's IP exceeds the pre-auth budget — proof the rejection happens as plain net/http
// middleware in front of the Connect handler chain, not the post-auth ratelimit.Interceptor. /health must
// stay exempt throughout, for the same source IP.
func TestE2E_PreAuthIPLimiter_BlocksFloodExemptsHealth(t *testing.T) {
	skipIfNoEmulators(t)
	_, baseURL := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.RateLimit.PreAuthIPPerMinute = 1
	})
	rpcURL := baseURL + identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure
	const xff = "203.0.113.55"

	resp1 := doXFFRequest(t, http.MethodPost, rpcURL, xff, []byte(`{}`))
	defer resp1.Body.Close()
	if resp1.StatusCode == http.StatusTooManyRequests {
		t.Fatalf("first request should not be pre-auth-limited yet, got %d", resp1.StatusCode)
	}

	resp2 := doXFFRequest(t, http.MethodPost, rpcURL, xff, []byte(`{}`))
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("second request from the same IP status = %d, want 429 (pre-auth limiter)", resp2.StatusCode)
	}

	healthResp := doXFFRequest(t, http.MethodGet, baseURL+"/health", xff, nil)
	defer healthResp.Body.Close()
	if healthResp.StatusCode != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200 (exempt from the pre-auth limiter)", healthResp.StatusCode)
	}
}

// TestE2E_MaxRequestBodyRejected (hardening, docs/reviews/security-audit-v0.1.0.md informational finding):
// a body over limits.MaxRequestBytes must never reach the handler/service layer — http.MaxBytesHandler
// wraps the whole mux in apiserver.Build.
func TestE2E_MaxRequestBodyRejected(t *testing.T) {
	skipIfNoEmulators(t)
	_, baseURL := newTestServer(t, config.DegradedOff)

	oversized := bytes.Repeat([]byte("a"), 300*1024) // > 256 KiB (limits.MaxRequestBytes)
	resp, err := http.Post(baseURL+identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure, "application/json", bytes.NewReader(oversized))
	if err != nil {
		t.Fatalf("POST oversized body: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 400 {
		t.Fatalf("oversized body status = %d, want a 4xx/5xx rejection", resp.StatusCode)
	}
}
