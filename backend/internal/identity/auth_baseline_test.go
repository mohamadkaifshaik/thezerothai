package identity

import (
	"bytes"
	"context"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	fbauth "firebase.google.com/go/v4/auth"
	"google.golang.org/protobuf/proto"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const (
	auditUID     = "uid-audit-1"
	auditEmail   = "Alice@Example.com"
	auditGoogle  = "g-sub-1"
	auditPwEmail = "alice@example.com"
)

type auditHarness struct {
	svc  *service
	repo *fakeRepo
	auth *fakeAuthClient
	out  *bytes.Buffer
}

func newAuditHarness(t *testing.T, audit bool, withSignup bool, providers ...*fbauth.UserInfo) *auditHarness {
	t.Helper()
	h := &auditHarness{repo: newFakeRepo(), auth: newFakeAuthClient(&opLog{}), out: &bytes.Buffer{}}
	log := slog.New(slog.NewJSONHandler(h.out, &slog.HandlerOptions{Level: slog.LevelDebug}))
	opts := []Option{WithAuthIdentityAudit(audit, log)}
	if withSignup {
		opts = append(opts, WithSignupAuth(h.auth, log))
	}
	h.svc = New(h.repo, NewCache(time.Minute), time.Hour, opts...).(*service)
	// A fixed clock: the harnesses are compared field for field, so CreatedAt must not depend on when each ran.
	h.svc.now = func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }
	if providers == nil {
		providers = []*fbauth.UserInfo{
			{ProviderID: "google.com", UID: auditGoogle},
			{ProviderID: "password", UID: auditPwEmail},
		}
	}
	h.auth.users[auditUID] = &fbauth.UserRecord{
		UserInfo:         &fbauth.UserInfo{UID: auditUID, Email: auditEmail},
		ProviderUserInfo: providers,
	}
	if _, err := h.svc.CreateProfile(context.Background(), auditUID, validKey, "alice", "Alice"); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// CreateProfile warmed the cache; evict so the first GetMe reads users/{uid} like a fresh session does.
	h.svc.cache.InvalidateProfile(auditUID)
	h.out.Reset() // drop the sign-up lines; only GetMe output matters below
	return h
}

func claimsCtx(c authn.Claims) context.Context {
	c.UID = auditUID
	return authn.WithClaims(context.Background(), c)
}

func googleClaims(subject string) authn.Claims {
	return authn.Claims{SignInProvider: "google.com", Identities: map[string][]string{"google.com": {subject}}}
}

func TestCreateProfile_WritesAuthBaseline(t *testing.T) {
	t.Parallel()
	oplog := &opLog{}
	repo := newFakeRepo()
	auth := newFakeAuthClient(oplog)
	auth.users[auditUID] = &fbauth.UserRecord{
		UserInfo: &fbauth.UserInfo{UID: auditUID, Email: auditEmail},
		ProviderUserInfo: []*fbauth.UserInfo{
			{ProviderID: "google.com", UID: auditGoogle},
			{ProviderID: "password", UID: auditPwEmail},
		},
	}
	svc := New(repo, NewCache(time.Minute), time.Hour, WithSignupAuth(auth, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)))).(*service)
	if _, err := svc.CreateProfile(context.Background(), auditUID, validKey, "alice", "Alice"); err != nil {
		t.Fatal(err)
	}
	// 0 extra reads: the one Auth GetUser the sign-up check always made, and no repo read at all.
	oplog.mu.Lock()
	authGets := 0
	for _, op := range oplog.ops {
		if op == "auth.GetUser" {
			authGets++
		}
	}
	oplog.mu.Unlock()
	if authGets != 1 || repo.getProfileCalls != 0 || repo.createCalls != 1 {
		t.Fatalf("auth GetUser=%d repo gets=%d creates=%d, want 1/0/1", authGets, repo.getProfileCalls, repo.createCalls)
	}
	enc := repo.profiles[auditUID].AuthBaselineEnc
	if enc == "" {
		t.Fatal("no baseline stored")
	}
	// No email in any form (hashed or raw) and no password subject: only federated subjects are baselined.
	for _, raw := range []string{auditGoogle, auditPwEmail, strings.ToLower(auditEmail), auditEmail, sha256Hex(auditPwEmail), sha256Hex(strings.ToLower(auditEmail))} {
		if strings.Contains(enc, raw) {
			t.Fatalf("baseline holds a value it must not (%q): %s", raw, enc)
		}
	}
	b := decodeAuthBaseline(enc)
	if _, hasPw := b.Subjects["password"]; hasPw {
		t.Errorf("baseline must not keep the password provider (its subject is the email): %v", b.Subjects)
	}
	if !reflect.DeepEqual(b.Subjects["google.com"], []string{sha256Hex(auditGoogle)}) {
		t.Errorf("subjects = %v", b.Subjects)
	}
}

func TestGetMe_AuthIdentityAudit(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		claims   authn.Claims
		wantWarn bool
	}{
		{name: "matching google identity", claims: googleClaims(auditGoogle)},
		{name: "a password sign-in is not audited", claims: authn.Claims{
			SignInProvider: "password", Identities: map[string][]string{"email": {auditPwEmail}}}},
		{name: "unknown google subject (an attacker-linked identity signs in)", claims: googleClaims("g-attacker"), wantWarn: true},
		{name: "a federated provider with no baseline entry", claims: authn.Claims{
			SignInProvider: "apple.com", Identities: map[string][]string{"apple.com": {"a-sub"}}}, wantWarn: true},
		{name: "a google sign-in with no identities cannot be judged", claims: authn.Claims{SignInProvider: "google.com"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			h := newAuditHarness(t, true, true)
			getsBefore := h.repo.getProfileCalls
			if _, err := h.svc.GetMe(claimsCtx(tt.claims), auditUID); err != nil {
				t.Fatalf("GetMe must never fail on a mismatch: %v", err)
			}
			if h.repo.getProfileCalls-getsBefore != 1 {
				t.Errorf("GetMe profile reads = %d, want exactly 1 (the audit adds none)", h.repo.getProfileCalls-getsBefore)
			}
			out := h.out.String()
			gotWarn := strings.Contains(out, `"msg":"auth_identity_unrecognized"`)
			if gotWarn != tt.wantWarn {
				t.Fatalf("warn = %v, want %v; log: %s", gotWarn, tt.wantWarn, out)
			}
			if !tt.wantWarn {
				if strings.Contains(out, `"level":"WARN"`) {
					t.Fatalf("unexpected warning: %s", out)
				}
				return
			}
			if strings.Count(out, "auth_identity_unrecognized") != 1 || !strings.Contains(out, `"level":"WARN"`) {
				t.Errorf("want exactly one WARN line: %s", out)
			}
			if !strings.Contains(out, `"token_subject_hash"`) || !strings.Contains(out, `"uid_hash"`) {
				t.Errorf("missing hashed fields: %s", out)
			}
			for _, raw := range []string{auditUID, auditGoogle, "g-attacker", "a-sub", auditPwEmail, "example.com"} {
				if strings.Contains(out, raw) {
					t.Errorf("log leaks raw value %q: %s", raw, out)
				}
			}
		})
	}
}

// The headline attack: a password-only account (empty baseline, no federated subjects) has an attacker's Google
// identity linked via a stolen token. The later google.com sign-in must warn — the empty baseline reads as "known, no
// federated subjects", so any federated subject is unrecognized.
func TestGetMe_AuthIdentityAudit_PasswordOnlyVictim(t *testing.T) {
	t.Parallel()
	h := newAuditHarness(t, true, true, &fbauth.UserInfo{ProviderID: "password", UID: auditPwEmail})
	if h.repo.profiles[auditUID].AuthBaselineEnc == "" {
		t.Fatal("a password-only account must still get a present (empty) baseline")
	}
	if _, err := h.svc.GetMe(claimsCtx(googleClaims("g-attacker")), auditUID); err != nil {
		t.Fatal(err)
	}
	out := h.out.String()
	if strings.Count(out, "auth_identity_unrecognized") != 1 || !strings.Contains(out, `"level":"WARN"`) {
		t.Errorf("a federated link onto a password-only account must warn: %s", out)
	}
}

// The audit runs after the cache-or-repo lookup, so a cache hit is audited too: a second GetMe (served from cache)
// still warns. This guards against the audit being moved into the repo-read branch only.
func TestGetMe_AuthIdentityAudit_WarnsOnCacheHit(t *testing.T) {
	t.Parallel()
	h := newAuditHarness(t, true, true)
	before := h.repo.getProfileCalls
	for i := 0; i < 2; i++ {
		if _, err := h.svc.GetMe(claimsCtx(googleClaims("g-attacker")), auditUID); err != nil {
			t.Fatal(err)
		}
	}
	if got := h.repo.getProfileCalls - before; got != 1 {
		t.Fatalf("profile reads = %d, want 1 (second GetMe is a cache hit)", got)
	}
	if n := strings.Count(h.out.String(), "auth_identity_unrecognized"); n != 2 {
		t.Errorf("want a warn on both the repo-read and the cache-hit GetMe, got %d", n)
	}
}

// Warn-only: the same GetMe answer with a matching and a hostile token, and with the audit off.
func TestGetMe_AuthIdentityAudit_ResponseUnchanged(t *testing.T) {
	t.Parallel()
	good := newAuditHarness(t, true, true)
	bad := newAuditHarness(t, true, true)
	off := newAuditHarness(t, false, true)
	wantRes, err := good.svc.GetMe(claimsCtx(googleClaims(auditGoogle)), auditUID)
	if err != nil {
		t.Fatal(err)
	}
	// The wire answer too: the serialized GetMeResponse must be byte-identical.
	wire := func(h *auditHarness, c authn.Claims) []byte {
		resp, err := NewServer(h.svc).GetMe(claimsCtx(c), connect.NewRequest(&identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("Server.GetMe: %v", err)
		}
		b, err := proto.MarshalOptions{Deterministic: true}.Marshal(resp.Msg)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	wantWire := wire(good, googleClaims(auditGoogle))
	for name, h := range map[string]*auditHarness{"mismatch": bad, "audit off": off} {
		hostile := googleClaims("g-attacker")
		res, err := h.svc.GetMe(claimsCtx(hostile), auditUID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !reflect.DeepEqual(res, wantRes) {
			t.Errorf("%s: GetMe answer changed:\n got %+v\nwant %+v", name, res, wantRes)
		}
		if got := wire(h, hostile); !bytes.Equal(got, wantWire) {
			t.Errorf("%s: serialized GetMeResponse differs from the matching-token answer", name)
		}
	}
	if !strings.Contains(bad.out.String(), "auth_identity_unrecognized") {
		t.Error("mismatch run should have warned")
	}
}

func TestGetMe_AuthIdentityAudit_OffNeverLogsOrReads(t *testing.T) {
	t.Parallel()
	h := newAuditHarness(t, false, true)
	before := h.repo.getProfileCalls
	if _, err := h.svc.GetMe(claimsCtx(googleClaims("g-attacker")), auditUID); err != nil {
		t.Fatal(err)
	}
	if h.out.Len() != 0 {
		t.Errorf("audit off must log nothing, got %s", h.out.String())
	}
	if h.repo.getProfileCalls-before != 1 {
		t.Errorf("profile reads = %d, want 1", h.repo.getProfileCalls-before)
	}
}

// An account created before the baseline existed (or without the sign-up check wired) is never warned about.
func TestGetMe_AuthIdentityAudit_NoBaselineNoWarn(t *testing.T) {
	t.Parallel()
	h := newAuditHarness(t, true, false)
	if h.repo.profiles[auditUID].AuthBaselineEnc != "" {
		t.Fatal("no sign-up check wired, so no baseline expected")
	}
	if _, err := h.svc.GetMe(claimsCtx(googleClaims("g-attacker")), auditUID); err != nil {
		t.Fatal(err)
	}
	out := h.out.String()
	if strings.Contains(out, `"level":"WARN"`) || strings.Contains(out, "auth_identity_unrecognized") {
		t.Errorf("no baseline must not warn: %s", out)
	}
	if !strings.Contains(out, "auth_baseline_absent") || !strings.Contains(out, `"level":"DEBUG"`) {
		t.Errorf("want a debug auth_baseline_absent: %s", out)
	}
}

// A request with no claims in the context (not reachable through the interceptor chain) is skipped, not an error.
func TestGetMe_AuthIdentityAudit_NoClaimsSkipped(t *testing.T) {
	t.Parallel()
	h := newAuditHarness(t, true, true)
	if _, err := h.svc.GetMe(context.Background(), auditUID); err != nil {
		t.Fatal(err)
	}
	if h.out.Len() != 0 {
		t.Errorf("no claims must log nothing: %s", h.out.String())
	}
}

// UpdateProfile rewrites the whole document; the baseline must survive it (userDoc round trip).
func TestAuthBaseline_SurvivesProfileRoundTrip(t *testing.T) {
	t.Parallel()
	p := Profile{UserID: "u", AuthBaselineEnc: encodeAuthBaseline(&AuthBaseline{Subjects: map[string][]string{"google.com": {"x"}}})}
	if got := profileToDoc(p).toProfile("u").AuthBaselineEnc; got != p.AuthBaselineEnc {
		t.Fatalf("baseline lost on a whole-doc rewrite: %q vs %q", got, p.AuthBaselineEnc)
	}
}
