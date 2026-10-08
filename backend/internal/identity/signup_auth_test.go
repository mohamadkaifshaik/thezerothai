package identity

// ADR-0011 amendment M2 (2026-10-08): CreateProfile refuses a verified ID token whose Firebase Auth user was
// deleted or disabled. The token verifier in production does not check revocation or deletion, so the tests drive
// CreateProfile directly with a uid and no token machinery, exactly as the server does after VerifyIDToken.

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	fbauth "firebase.google.com/go/v4/auth"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const signupUID = "uid-signup-1"

type signupHarness struct {
	svc  *service
	repo *fakeRepo
	auth *fakeAuthClient
	log  *opLog
	out  *bytes.Buffer
}

func newSignupHarness(t *testing.T) *signupHarness {
	t.Helper()
	oplog := &opLog{}
	h := &signupHarness{repo: newFakeRepo(), auth: newFakeAuthClient(oplog), log: oplog, out: &bytes.Buffer{}}
	logger := slog.New(slog.NewJSONHandler(h.out, &slog.HandlerOptions{Level: slog.LevelDebug}))
	h.svc = New(h.repo, NewCache(time.Minute), time.Hour, WithSignupAuth(h.auth, logger)).(*service)
	h.svc.signup.notFound = func(err error) bool { return errors.Is(err, errFakeUserNotFound) }
	return h
}

func (h *signupHarness) authCalls() int {
	h.log.mu.Lock()
	defer h.log.mu.Unlock()
	n := 0
	for _, op := range h.log.ops {
		if op == "auth.GetUser" {
			n++
		}
	}
	return n
}

func (h *signupHarness) nothingWritten(t *testing.T) {
	t.Helper()
	if len(h.repo.profiles) != 0 || len(h.repo.handles) != 0 {
		t.Fatalf("wrote state on a refused sign-up: profiles=%d handles=%d", len(h.repo.profiles), len(h.repo.handles))
	}
}

func wantConnectCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T (%v), want *apierr.Error", err, err)
	}
	if ae.Code != want {
		t.Fatalf("code = %v, want %v", ae.Code, want)
	}
}

func TestCreateProfile_SignupAuthCheck(t *testing.T) {
	t.Parallel()
	disabled := &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: signupUID}, Disabled: true}
	enabled := &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: signupUID}}
	tests := []struct {
		name        string
		setup       func(*signupHarness)
		wantCode    connect.Code // 0 = success
		wantOutcome string
		wantCreated bool
	}{
		{name: "auth user present and enabled is created", setup: func(h *signupHarness) { h.auth.users[signupUID] = enabled }, wantOutcome: `"outcome":"ok"`, wantCreated: true},
		{name: "deleted auth user with a still-valid token is refused", setup: func(h *signupHarness) { h.auth.missing = true }, wantCode: connect.CodePermissionDenied, wantOutcome: `"outcome":"not_found"`},
		{name: "disabled auth user is refused", setup: func(h *signupHarness) { h.auth.users[signupUID] = disabled }, wantCode: connect.CodePermissionDenied, wantOutcome: `"outcome":"disabled"`},
		{name: "auth outage fails closed as UNAVAILABLE", setup: func(h *signupHarness) { h.auth.err["GetUser"] = errors.New("identitytoolkit: 503") }, wantCode: connect.CodeUnavailable, wantOutcome: `"outcome":"error"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			h := newSignupHarness(t)
			tt.setup(h)
			p, err := h.svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice")
			if tt.wantCode == 0 {
				if err != nil {
					t.Fatalf("CreateProfile: %v", err)
				}
				if p.UserID != signupUID || h.repo.profiles[signupUID].UserID != signupUID {
					t.Fatalf("profile not created: %+v", p)
				}
			} else {
				wantConnectCode(t, err, tt.wantCode)
				h.nothingWritten(t)
				if strings.Contains(err.Error(), signupUID) {
					t.Fatalf("error message leaks the uid: %v", err)
				}
			}
			if got := h.authCalls(); got != 1 {
				t.Fatalf("Auth calls = %d, want exactly 1", got)
			}
			line := h.out.String()
			for _, want := range []string{`"auth_admin_op":"get"`, tt.wantOutcome, `"account_job":"signup"`, `"uid_hash"`} {
				if !strings.Contains(line, want) {
					t.Errorf("C3 audit line missing %s: %s", want, line)
				}
			}
			if strings.Contains(line, signupUID) {
				t.Errorf("audit line leaks the raw uid: %s", line)
			}
		})
	}
}

func TestCreateProfile_SignupReplayMakesNoAuthCall(t *testing.T) {
	t.Parallel()
	h := newSignupHarness(t)
	h.auth.users[signupUID] = &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: signupUID}}
	if _, err := h.svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice"); err != nil {
		t.Fatalf("first CreateProfile: %v", err)
	}
	if got := h.authCalls(); got != 1 {
		t.Fatalf("Auth calls after sign-up = %d, want 1", got)
	}
	// The Auth user is gone now (deleted, or the outage the next replay would otherwise hit): an idempotent replay
	// for the existing profile is a pure Firestore read and must not call Auth at all.
	h.auth.missing = true
	h.auth.err["GetUser"] = errors.New("must not be called")
	for range 3 {
		if _, err := h.svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice"); err != nil {
			t.Fatalf("replay: %v", err)
		}
	}
	if got := h.authCalls(); got != 1 {
		t.Fatalf("Auth calls after replays = %d, want still 1", got)
	}
}

func TestCreateProfile_SignupRecoversAfterOutage(t *testing.T) {
	t.Parallel()
	h := newSignupHarness(t)
	h.auth.err["GetUser"] = errors.New("503")
	_, err := h.svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice")
	wantConnectCode(t, err, connect.CodeUnavailable)
	h.nothingWritten(t)
	delete(h.auth.err, "GetUser")
	if _, err := h.svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice"); err != nil {
		t.Fatalf("retry after outage: %v", err)
	}
}

func TestCheckSignup_EmptyUIDIsRefusedAtError(t *testing.T) {
	t.Parallel()
	h := newSignupHarness(t)
	err := h.svc.signup.checkSignup(context.Background(), newSignupTarget(""))
	if !errors.Is(err, ErrAuthAdminRefused) {
		t.Fatalf("err = %v, want ErrAuthAdminRefused", err)
	}
	if h.authCalls() != 0 {
		t.Fatal("an empty uid reached Auth")
	}
	if !strings.Contains(h.out.String(), `"level":"ERROR"`) || !strings.Contains(h.out.String(), `"outcome":"refused"`) {
		t.Fatalf("refusal must log at ERROR with outcome=refused (C4 filter): %s", h.out.String())
	}
}

func TestCreateProfile_NoSignupAuthConfiguredSkipsCheck(t *testing.T) {
	t.Parallel()
	svc := newTestService(newFakeRepo())
	if svc.signup != nil {
		t.Fatal("unit-test default must have no Auth gate")
	}
	if _, err := svc.CreateProfile(context.Background(), signupUID, validKey, "alice", "Alice"); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
}

// TestServer_CreateProfile_DeletedUsersTokenIsRefused drives the wire: the injected claims stand in for a token
// verifier that, like production, never checks revocation or deletion, so the deleted user's token is "valid".
func TestServer_CreateProfile_DeletedUsersTokenIsRefused(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name  string
		setup func(*signupHarness)
		want  connect.Code
	}{
		{"deleted", func(h *signupHarness) { h.auth.missing = true }, connect.CodePermissionDenied},
		{"outage", func(h *signupHarness) { h.auth.err["GetUser"] = errors.New("503") }, connect.CodeUnavailable},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			h := newSignupHarness(t)
			tt.setup(h)
			client, closeFn := newTestServerHTTPWithClaims(t, h.svc, authn.Claims{UID: signupUID, EmailVerified: true, SignInProvider: "google.com"})
			defer closeFn()
			_, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
				IdempotencyKey: validKey, Handle: "zombie", DisplayName: "Zombie",
			}))
			if connect.CodeOf(err) != tt.want {
				t.Fatalf("code = %v (%v), want %v", connect.CodeOf(err), err, tt.want)
			}
			if strings.Contains(err.Error(), signupUID) {
				t.Fatalf("wire error leaks the uid: %v", err)
			}
			h.nothingWritten(t)
		})
	}
}

func TestWithSignupAuth_NilClientLeavesGateOff(t *testing.T) {
	t.Parallel()
	if s := New(newFakeRepo(), NewCache(time.Minute), time.Hour, WithSignupAuth(nil, nil)).(*service); s.signup != nil {
		t.Fatal("a nil AuthClient must not install a gate")
	}
}

func TestSmallContracts(t *testing.T) {
	t.Parallel()
	if got := (&ErrHandleChangeCooldown{}).Error(); got == "" {
		t.Error("empty cooldown error text")
	}
	if ptrTime(time.Time{}) != nil || derefTime(nil) != (time.Time{}) {
		t.Error("zero time must round-trip as nil")
	}
	now := time.Now()
	if got := derefTime(ptrTime(now)); !got.Equal(now) {
		t.Errorf("derefTime(ptrTime(now)) = %v", got)
	}
	var nilJob *deletionJobDoc
	if nilJob.toDomain() != nil || deletionJobToDoc(nil) != nil {
		t.Error("nil job must map to nil")
	}
	j := &DeletionJob{Seq: 3, Step: "identity", Checkpoint: []byte("x"), ProgressAt: now}
	if got := deletionJobToDoc(j).toDomain(); got.Seq != 3 || got.Step != "identity" || string(got.Checkpoint) != "x" {
		t.Errorf("job round trip = %+v", got)
	}
	h := newHarness(t)
	if names := h.l.StepNames(); len(names) < 4 || names[0] != stepAuthDisable || names[len(names)-1] != stepUserDoc {
		t.Errorf("StepNames = %v", names)
	}
	_ = h.l.ExportSectionNames()
}
