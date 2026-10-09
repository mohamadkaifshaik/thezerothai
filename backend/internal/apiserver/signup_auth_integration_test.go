//go:build integration

package apiserver

// ADR-0011 amendment M2 (2026-10-08) over the real Build chain and the Auth emulator. The production token
// verifier does not check revocation or deletion, so a deleted (or disabled) user's still-valid ID token reaches
// CreateProfile (profile-exempt). The CreateProfile boundary must look the Auth user up and refuse.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// prodLikeVerifier verifies an Auth-emulator ID token the way production does: it checks the claims (audience,
// expiry, subject) and returns them, but performs NO revoked/disabled/deleted lookup. The real verifier cannot be
// used for the M2 tests: in emulator mode the Admin SDK's VerifyIDToken always looks the user up (auth.go, the
// emulator branch forces the revoked/disabled check), so a deleted or disabled user's token is rejected with
// UNAUTHENTICATED before CreateProfile runs. Production (no emulator) skips that lookup, which is the M2 bug these
// tests pin. Emulator tokens are unsigned, so there is no signature to check here.
type prodLikeVerifier struct{ projectID string }

func (v prodLikeVerifier) VerifyIDToken(_ context.Context, idToken string) (authn.Claims, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return authn.Claims{}, errors.New("malformed token")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return authn.Claims{}, fmt.Errorf("decode payload: %w", err)
	}
	var p struct {
		Aud           string  `json:"aud"`
		Exp           float64 `json:"exp"`
		Sub           string  `json:"sub"`
		UserID        string  `json:"user_id"`
		EmailVerified bool    `json:"email_verified"`
		AuthTime      float64 `json:"auth_time"`
		Firebase      struct {
			SignInProvider string `json:"sign_in_provider"`
		} `json:"firebase"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return authn.Claims{}, fmt.Errorf("decode claims: %w", err)
	}
	uid := p.Sub
	if uid == "" {
		uid = p.UserID
	}
	if p.Aud != v.projectID || uid == "" || (p.Exp > 0 && time.Unix(int64(p.Exp), 0).Before(time.Now())) {
		return authn.Claims{}, errors.New("invalid token claims")
	}
	return authn.Claims{UID: uid, EmailVerified: p.EmailVerified, SignInProvider: p.Firebase.SignInProvider, AuthTime: time.Unix(int64(p.AuthTime), 0)}, nil
}

// newM2Env is a lifecycle chain whose token verifier behaves like production's (see prodLikeVerifier); the
// identity AuthClient behind WithSignupAuth is still the real Auth-emulator client.
func newM2Env(t *testing.T) *lifecycleEnv {
	t.Helper()
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	return newLifecycleEnvWith(t, prodLikeVerifier{projectID: cfg.ProjectID})
}

// disableAuthUser disables uid in the Auth emulator (what a suspension or the first deletion step does).
func (e *lifecycleEnv) disableAuthUser(t *testing.T, uid string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"localId": uid, "disableUser": true})
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:update", os.Getenv("FIREBASE_AUTH_EMULATOR_HOST"), e.cfg.ProjectID)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer owner")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("auth disable: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("auth disable: status %d: %s", resp.StatusCode, raw)
	}
}

func (e *lifecycleEnv) tryCreateProfile(token string) error {
	_, err := e.identity.CreateProfile(context.Background(), authed(token, &identityv1.CreateProfileRequest{
		IdempotencyKey: "m2-signup-after-delete-key-0001",
		Handle:         uniqueHandle("m2"),
		DisplayName:    "Zombie",
	}))
	return err
}

func (e *lifecycleEnv) requireNoProfileDocs(t *testing.T, uid string) {
	t.Helper()
	for _, path := range []string{"users/" + uid, "graph/" + uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s was recreated by a refused CreateProfile", path)
		}
	}
	docs, err := e.fs.Collection("handles").Where("uid", "==", uid).Limit(2).Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 0 {
		t.Errorf("handles for the refused uid: %d docs, err %v", len(docs), err)
	}
}

// TestSignupAuth_DeletedAccountTokenCannotRecreateProfile is the M2 scenario end to end: the account is deleted
// through the real lifecycle (DeleteAccount, then the job runs to completion, deleting the Auth user and
// users/{uid}), and the same still-valid ID token then calls CreateProfile. It must be refused and write nothing.
func TestSignupAuth_DeletedAccountTokenCannotRecreateProfile(t *testing.T) {
	ctx := context.Background()
	e := newM2Env(t)
	u := e.newUser(t)

	if _, err := e.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "m2-delete-key-0000001"})); err != nil {
		t.Fatal(err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v", msgs)
	}
	e.pastGate(t, u.uid)
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d, want 204", code)
	}
	e.requireErased(t, referenceAccount{a: u})

	wireError(t, e.tryCreateProfile(u.token), connect.CodePermissionDenied)
	e.requireNoProfileDocs(t, u.uid)
	// A second device with a fresh Build instance (cold caches) is refused the same way.
	other := newM2Env(t)
	wireError(t, other.tryCreateProfile(u.token), connect.CodePermissionDenied)
	e.requireNoProfileDocs(t, u.uid)
}

// TestSignupAuth_DisabledAuthUserCannotCreateProfile: a disabled user (suspended, or mid-deletion) cannot use
// CreateProfile to obtain a fresh ACTIVE profile.
func TestSignupAuth_DisabledAuthUserCannotCreateProfile(t *testing.T) {
	e := newM2Env(t)
	tok, uid := mintToken(t, "")
	e.disableAuthUser(t, uid)
	wireError(t, e.tryCreateProfile(tok), connect.CodePermissionDenied)
	e.requireNoProfileDocs(t, uid)
}

// TestSignupAuth_RealSignUpAndReplay: a present, enabled Auth user signs up, and an idempotent replay succeeds
// (the replay must not need the Auth lookup, but the emulator user exists either way).
func TestSignupAuth_RealSignUpAndReplay(t *testing.T) {
	e := newM2Env(t)
	tok, uid := mintToken(t, "")
	handle := uniqueHandle("m2")
	req := func() error {
		_, err := e.identity.CreateProfile(context.Background(), authed(tok, &identityv1.CreateProfileRequest{
			IdempotencyKey: "m2-signup-replay-key-00001", Handle: handle, DisplayName: "Real",
		}))
		return err
	}
	if err := req(); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if err := req(); err != nil {
		t.Fatalf("replay: %v", err)
	}
	if !fsDocExists(t, e.fs, "users/"+uid) {
		t.Fatal("profile missing")
	}
	// One sign-up and one replay produce exactly one C3 `get` audit line (the replay made no Auth call).
	if n := bytes.Count([]byte(e.logsWithMsg("auth_admin_op")), []byte(`"auth_admin_op":"get"`)); n != 1 {
		t.Errorf("get audit lines = %d, want exactly 1", n)
	}
}
