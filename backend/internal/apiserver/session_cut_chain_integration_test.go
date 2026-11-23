//go:build integration

package apiserver

// The session cut over the real Build chain (Firestore and Auth emulators; security audit H2, removal-server design 5,
// "Auth emulator, two sessions"): one password account signed in twice. Session A is the older; session B signs in again
// and removes A's device with reason REMOTE. A's next call, and A's call with a refreshed ID token (same auth_time), answer
// SESSION_ENDED; B keeps working; A after a fresh sign-in passes; A's refused CommitConversation draws on no cap. With
// device_sign_out off for the remover a REMOTE removal marks but does not cut. A stored cut is enforced for an account the
// allowlist does not list.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// authSession is one Auth-emulator sign-in: its ID token, its refresh token and the token's auth_time.
type authSession struct {
	idToken, refresh string
	authTime         int64
}

func authEmulatorPost(t *testing.T, path string, body map[string]any, owner bool) []byte {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, "http://"+os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if owner {
		req.Header.Set("Authorization", "Bearer owner")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("%s: status %d: %s", path, resp.StatusCode, out)
	}
	return out
}

// tokenAuthTime reads the auth_time claim of an (emulator) ID token.
func tokenAuthTime(t *testing.T, idToken string) int64 {
	t.Helper()
	parts := strings.Split(idToken, ".")
	if len(parts) < 2 {
		t.Fatalf("not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims struct {
		AuthTime int64 `json:"auth_time"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	return claims.AuthTime
}

// passwordAccount signs a verified password account up and returns its uid, email and a first session.
func passwordAccount(t *testing.T, projectID string) (uid, email string, s authSession) {
	t.Helper()
	email = fmt.Sprintf("cut-%d@example.test", rand.Int63())
	_, uid = mintToken(t, email)
	authEmulatorPost(t, fmt.Sprintf("/identitytoolkit.googleapis.com/v1/projects/%s/accounts:update", projectID), map[string]any{"localId": uid, "emailVerified": true}, true)
	return uid, email, signInPassword(t, email)
}

func signInPassword(t *testing.T, email string) authSession {
	t.Helper()
	out := authEmulatorPost(t, "/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key",
		map[string]any{"email": email, "password": "correct horse battery staple", "returnSecureToken": true}, false)
	var r struct {
		IDToken      string `json:"idToken"`
		RefreshToken string `json:"refreshToken"`
	}
	if err := json.Unmarshal(out, &r); err != nil || r.IDToken == "" {
		t.Fatalf("sign in: %v: %s", err, out)
	}
	return authSession{r.IDToken, r.RefreshToken, tokenAuthTime(t, r.IDToken)}
}

// signInAfter signs in again until the new session's auth_time (whole seconds) is after `after`: no sleep, a bounded
// sequence of real sign-ins.
func signInAfter(t *testing.T, email string, after int64) authSession {
	t.Helper()
	for range 2000 {
		if s := signInPassword(t, email); s.authTime > after {
			return s
		}
	}
	t.Fatal("auth_time never moved past the earlier session")
	return authSession{}
}

// refreshIDToken exchanges the refresh token for a new ID token (the auth_time is kept).
func refreshIDToken(t *testing.T, refresh string) string {
	t.Helper()
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}}
	resp, err := http.Post("http://"+os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")+"/securetoken.googleapis.com/v1/token?key=fake-api-key",
		"application/x-www-form-urlencoded", strings.NewReader(form.Encode()))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	var r struct {
		IDToken string `json:"id_token"`
	}
	if resp.StatusCode != http.StatusOK || json.Unmarshal(out, &r) != nil || r.IDToken == "" {
		t.Fatalf("refresh: status %d: %s", resp.StatusCode, out)
	}
	return r.IDToken
}

func wantSessionEnded(t *testing.T, what string, err error) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("%s = %v, want UNAUTHENTICATED + SESSION_ENDED", what, err)
	}
	var ce *connect.Error
	if !asConnectErr(err, &ce) {
		t.Fatalf("%s: not a Connect error", what)
	}
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok && ed.GetReason() == commonv1.ErrorReason_ERROR_REASON_SESSION_ENDED {
				return
			}
		}
	}
	t.Fatalf("%s = %v, want reason SESSION_ENDED", what, err)
}

func TestSessionCutChain_TwoSessions(t *testing.T) {
	ctx := context.Background()
	skipIfNoEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	uid, email, a := passwordAccount(t, cfg.ProjectID)
	offUID, offEmail, offA := passwordAccount(t, cfg.ProjectID)
	listed := map[string]struct{}{uid: {}}
	const dailyCommits = 3
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}, offUID: {}}}
		// device_sign_out on for uid only: offUID is "allowlist off" (not globally off), so a cut on it is still enforced.
		c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: listed}
		c.RateLimit.MessagesCommitsPerDay = dailyCommits
		c.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	})
	e.createProfile(t, a.idToken)
	e.createProfile(t, offA.idToken)
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	sig := bytes.Repeat([]byte{7}, 32)
	const deviceA = "session-cut-device-a01"
	if _, err := keysClient.RegisterKeyDevice(ctx, authed(a.idToken, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("cut-reg"), DeviceId: deviceA, SignaturePublicKey: sig})); err != nil {
		t.Fatalf("A registers its device: %v", err)
	}

	// A refreshes its ID token: a new token with A's auth_time. Taken before B signs in, because the Auth emulator stamps a
	// refreshed token with the account's LAST sign-in time, while real Firebase keeps the session's own auth_time (the
	// thief's refresh token keeps minting tokens with the old auth_time, which is what this check reproduces).
	refreshed := refreshIDToken(t, a.refresh)
	if tokenAuthTime(t, refreshed) != a.authTime {
		t.Fatal("a refresh before any other sign-in changed auth_time")
	}

	// B signs in again (a newer auth_time) and removes A's device with reason REMOTE.
	b := signInAfter(t, email, a.authTime)
	rm, err := keysClient.RemoveKeyDevice(ctx, authed(b.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("cut-rm"), DeviceId: deviceA, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
	if err != nil {
		t.Fatalf("B removes A's device: %v", err)
	}
	if !rm.Msg.GetOtherSessionsEnded() {
		t.Fatal("other_sessions_ended = false, want true (device_sign_out on for the remover)")
	}
	snap, err := e.fs.Doc("users/" + uid).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if v, err := snap.DataAt("sessionsValidAfter"); err != nil || v.(time.Time).Unix() != b.authTime {
		t.Fatalf("stored cut = %v (%v), want B's auth_time %d", v, err, b.authTime)
	}

	getMe := func(tok string) error {
		_, err := e.identity.GetMe(ctx, authed(tok, &identityv1.GetMeRequest{}))
		return err
	}
	wantSessionEnded(t, "A's next call", getMe(a.idToken))
	wantSessionEnded(t, "A's call with a refreshed token", getMe(refreshed))
	// A's refused commits draw on no cap: B still has the whole daily cap of the same uid afterwards.
	for i := range dailyCommits + 2 {
		_, err := e.msg.CommitConversation(ctx, authed(a.idToken, &messagingv1.CommitConversationRequest{IdempotencyKey: contractKey("cut-commit")}))
		wantSessionEnded(t, fmt.Sprintf("A's commit %d", i+1), err)
	}
	for i := range dailyCommits {
		_, err := e.msg.CommitConversation(ctx, authed(b.idToken, &messagingv1.CommitConversationRequest{IdempotencyKey: contractKey("cut-commit-b")}))
		if connect.CodeOf(err) == connect.CodeResourceExhausted || connect.CodeOf(err) == connect.CodeUnauthenticated {
			t.Fatalf("B's commit %d = %v: A's refused calls used up the cap, or B was cut", i+1, err)
		}
	}
	if err := getMe(b.idToken); err != nil {
		t.Fatalf("B keeps working: %v", err)
	}
	a2 := signInPassword(t, email)
	if err := getMe(a2.idToken); err != nil {
		t.Fatalf("A after a fresh sign-in: %v", err)
	}

	t.Run("flag off for the remover: marked, not cut", func(t *testing.T) {
		const deviceOff = "session-cut-device-off1"
		if _, err := keysClient.RegisterKeyDevice(ctx, authed(offA.idToken, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("cut-reg-off"), DeviceId: deviceOff, SignaturePublicKey: sig})); err != nil {
			t.Fatal(err)
		}
		offB := signInAfter(t, offEmail, offA.authTime)
		rm, err := keysClient.RemoveKeyDevice(ctx, authed(offB.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("cut-rm-off"), DeviceId: deviceOff, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
		if err != nil || rm.Msg.GetOtherSessionsEnded() {
			t.Fatalf("= %v, %v; want success with other_sessions_ended false", rm, err)
		}
		if _, err := e.fs.Doc("users/" + offUID + "/keyDeviceRemovals/" + deviceOff).Get(ctx); err != nil {
			t.Fatalf("no removed mark: %v", err)
		}
		if err := getMe(offA.idToken); err != nil {
			t.Fatalf("the older session must keep working without a cut: %v", err)
		}
	})

	t.Run("a stored cut is enforced for an account the allowlist does not list", func(t *testing.T) {
		// offUID is not on the device_sign_out allowlist; a direct write seeds a cut after its first session (standing in for
		// a cut made while it was listed). The chain above has the profile cached for 60 s, so a new chain (a cold cache,
		// like another instance after its TTL) serves the check.
		if _, err := e.fs.Doc("users/"+offUID).Update(ctx, []firestore.Update{{Path: "sessionsValidAfter", Value: time.Unix(offA.authTime+1, 0).UTC()}}); err != nil {
			t.Fatal(err)
		}
		cold := newDMChain(t, func(c *config.Config) {
			c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: listed}
		})
		_, err := cold.identity.GetMe(ctx, authed(offA.idToken, &identityv1.GetMeRequest{}))
		wantSessionEnded(t, "an unlisted account's old session", err)
		globallyOff := newDMChain(t, func(c *config.Config) {
			c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Off}
		})
		if _, err := globallyOff.identity.GetMe(ctx, authed(offA.idToken, &identityv1.GetMeRequest{})); err != nil {
			t.Fatalf("globally off must not enforce: %v", err)
		}
	})
}
