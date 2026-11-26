//go:build integration

package apiserver

// The H1 refresh-token revoke over the real Build chain (Firestore and Auth emulators): a REMOTE removal with
// device_sign_out on for the remover writes the cut, then revokes the account's refresh tokens through identity's
// authadmin.go (one RevokeRefreshTokens: Firebase's validSince moves to now), then notes revokeDone on the mark.
//
// Two emulator facts shape these tests (firebase-tools 15.31, read from lib/emulator/auth):
//   - The Admin SDK's VerifyIDToken checks revocation on EVERY call when FIREBASE_AUTH_EMULATOR_HOST is set (auth.go
//     verifyIDToken: `if c.isEmulator || checkRevokedOrDisabled`); in production it does not (authn/firebase.go calls
//     VerifyIDToken, not VerifyIDTokenAndCheckRevoked). So in the emulator a revoke at once refuses every ID token issued
//     before it, while production keeps accepting them until they expire (at most 1 h) and the session cut is what
//     refuses the thief meanwhile. The session-cut chain tests therefore run with unrevokedVerifier, which accepts a token
//     the emulator refuses ONLY as revoked, so they keep testing what production does.
//   - The emulator's securetoken endpoint does NOT check validSince (operations.js grantToken, state.js
//     validateRefreshToken): a revoked refresh token still refreshes there; real Firebase refuses it. That part is only
//     checkable on dev (.superpowers/sdd/2026-11-23-e2ee-plan-6/h1-dev-check.md). The emulator's Identity Toolkit does
//     check validSince for an ID token (operations.js parseIdToken: iat >= validSince, else TOKEN_EXPIRED), which is the
//     account-change (link) path of H1; this file checks that.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	fbauth "firebase.google.com/go/v4/auth"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// unrevokedVerifier is the real (emulator) ID-token verifier, except that a token the SDK refuses only because it was
// issued before the account's validSince is accepted with its own claims, as production's VerifyIDToken does. Any other
// failure (bad token, disabled or deleted user) is still a refusal. Narrower than signup_auth's prodLikeVerifier, which
// skips the whole user lookup: here only the revocation check is production's.
type unrevokedVerifier struct{ real authn.IDTokenVerifier }

func newUnrevokedVerifier(t *testing.T) authn.IDTokenVerifier {
	t.Helper()
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	real, err := authn.NewIDTokenVerifier(context.Background(), cfg.ProjectID)
	if err != nil {
		t.Fatal(err)
	}
	return unrevokedVerifier{real: real}
}

func (v unrevokedVerifier) VerifyIDToken(ctx context.Context, idToken string) (authn.Claims, error) {
	claims, err := v.real.VerifyIDToken(ctx, idToken)
	if err == nil || !fbauth.IsIDTokenRevoked(errors.Unwrap(err)) {
		return claims, err
	}
	// The SDK verified everything else before its revocation check; read the claims from the (unsigned) payload.
	parts := strings.Split(idToken, ".")
	if len(parts) < 2 {
		return authn.Claims{}, err
	}
	raw, derr := base64.RawURLEncoding.DecodeString(parts[1])
	if derr != nil {
		return authn.Claims{}, err
	}
	var p struct {
		UserID        string  `json:"user_id"`
		EmailVerified bool    `json:"email_verified"`
		AuthTime      float64 `json:"auth_time"`
		Firebase      struct {
			SignInProvider string         `json:"sign_in_provider"`
			Identities     map[string]any `json:"identities"`
		} `json:"firebase"`
	}
	if json.Unmarshal(raw, &p) != nil || p.UserID == "" {
		return authn.Claims{}, err
	}
	return authn.Claims{UID: p.UserID, EmailVerified: p.EmailVerified, SignInProvider: p.Firebase.SignInProvider,
		AuthTime: time.Unix(int64(p.AuthTime), 0), Identities: testNormalizeIdentities(p.Firebase.Identities)}, nil
}

// testNormalizeIdentities is authn's normalizeIdentities (pkg/platform/authn/firebase.go, unexported), copied so the
// relaxed path yields the same Claims.Identities as the real one: entries that are not lists of strings are dropped,
// empty subjects too, and an empty result is nil.
func testNormalizeIdentities(raw map[string]any) map[string][]string {
	var out map[string][]string
	for provider, v := range raw {
		list, ok := v.([]any)
		if !ok {
			continue
		}
		var subjects []string
		for _, item := range list {
			if s, ok := item.(string); ok && s != "" {
				subjects = append(subjects, s)
			}
		}
		if len(subjects) == 0 {
			continue
		}
		if out == nil {
			out = map[string][]string{}
		}
		out[provider] = subjects
	}
	return out
}

// newDMChainUnrevoked is newDMChain over unrevokedVerifier: the session-cut chain tests, whose tokens predate a revoke.
func newDMChainUnrevoked(t *testing.T, mutate func(*config.Config)) *dmChain {
	t.Helper()
	env := newChainWith(t, func(c *config.Config) {
		messagingOn(c)
		if mutate != nil {
			mutate(c)
		}
	}, newUnrevokedVerifier(t))
	return &dmChain{
		chainEnv: env,
		msg:      messagingv1connect.NewMessagingServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

// authEmulatorTry is authEmulatorPost that returns the status and body instead of failing on a non-200.
func authEmulatorTry(t *testing.T, path string, body map[string]any) (int, string) {
	t.Helper()
	raw, _ := json.Marshal(body)
	resp, err := http.Post("http://"+os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")+path, "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

// validSince is the account's Firebase validSince (unix seconds; what RevokeRefreshTokens moves), via accounts:lookup.
func validSince(t *testing.T, projectID, uid string) int64 {
	t.Helper()
	out := authEmulatorPost(t, fmt.Sprintf("/identitytoolkit.googleapis.com/v1/projects/%s/accounts:lookup", projectID), map[string]any{"localId": []string{uid}}, true)
	var r struct {
		Users []struct {
			ValidSince string `json:"validSince"`
		} `json:"users"`
	}
	if err := json.Unmarshal(out, &r); err != nil || len(r.Users) != 1 {
		t.Fatalf("lookup: %v: %s", err, out)
	}
	if r.Users[0].ValidSince == "" {
		return 0
	}
	n, err := strconv.ParseInt(r.Users[0].ValidSince, 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// TestSessionRevokeChain_RemoteRemovalRevokes: the thief's ID token can change the Auth account (the H1 link path)
// before the removal and not after it; the revoke happens once per mark (a retry does not move validSince again); the
// honest remover passes again after a fresh sign-in; a removal with device_sign_out off revokes nothing.
func TestSessionRevokeChain_RemoteRemovalRevokes(t *testing.T) {
	ctx := context.Background()
	skipIfNoEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	uid, email, thief := passwordAccount(t, cfg.ProjectID)
	offUID, offEmail, offA := passwordAccount(t, cfg.ProjectID)
	mutate := func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}, offUID: {}}}
		c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
	}
	e := newDMChainUnrevoked(t, mutate)
	e.createProfile(t, thief.idToken)
	e.createProfile(t, offA.idToken)
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	const lost = "revoke-chain-lost-dev01"
	if _, err := keysClient.RegisterKeyDevice(ctx, authed(thief.idToken, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("rv-reg"), DeviceId: lost, SignaturePublicKey: bytes.Repeat([]byte{3}, 32)})); err != nil {
		t.Fatalf("register the lost device: %v", err)
	}
	accountUpdate := func(idToken string) (int, string) {
		return authEmulatorTry(t, "/identitytoolkit.googleapis.com/v1/accounts:update?key=fake-api-key", map[string]any{"idToken": idToken, "displayName": "changed by a session"})
	}
	// linkGoogle is the H1 attack step: link a (fake) Google identity to the account with a session's ID token
	// (accounts:signInWithIdp with idToken; the emulator takes strict-JSON claims as the Google id_token).
	linkGoogle := func(idToken string) (int, string) {
		sub := fmt.Sprintf("h1-link-%d", rand.Int63())
		claims, _ := json.Marshal(map[string]any{"sub": sub, "email": sub + "@google.test", "email_verified": true})
		return authEmulatorTry(t, "/identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=fake-api-key", map[string]any{
			"idToken": idToken, "requestUri": "http://localhost", "returnSecureToken": true,
			"postBody": url.Values{"id_token": {string(claims)}, "providerId": {"google.com"}}.Encode(),
		})
	}
	// Before the removal the thief's ID token may change the Auth account (what linking a provider needs).
	if code, body := accountUpdate(thief.idToken); code != http.StatusOK {
		t.Fatalf("the thief's account change before the removal = %d %s, want 200 (the precondition of H1)", code, body)
	}

	owner := signInAfter(t, email, thief.authTime)
	before := validSince(t, cfg.ProjectID, uid)
	rm, err := keysClient.RemoveKeyDevice(ctx, authed(owner.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("rv-rm"), DeviceId: lost, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
	if err != nil || !rm.Msg.GetOtherSessionsEnded() {
		t.Fatalf("REMOTE removal = %v, %v; want other_sessions_ended", rm, err)
	}
	after := validSince(t, cfg.ProjectID, uid)
	if after < owner.authTime || after <= before {
		t.Fatalf("validSince %d -> %d, want moved to the removal (>= the remover's auth_time %d)", before, after, owner.authTime)
	}
	mark, err := e.fs.Doc("users/" + uid + "/keyDeviceRemovals/" + lost).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if d := mark.Data(); d["cutDone"] != true || d["revokeDone"] != true {
		t.Fatalf("mark = %v, want cutDone and revokeDone", d)
	}

	// H1: the thief's ID token (issued before the revoke) can no longer change the Auth account.
	if code, body := accountUpdate(thief.idToken); code != http.StatusBadRequest || !strings.Contains(body, "TOKEN_EXPIRED") {
		t.Fatalf("the thief's account change after the revoke = %d %s, want 400 TOKEN_EXPIRED", code, body)
	}
	// ...nor link a Google identity to it (the H1 attack): the emulator applies validSince to signInWithIdp's idToken.
	if code, body := linkGoogle(thief.idToken); code != http.StatusBadRequest || !strings.Contains(body, "TOKEN_EXPIRED") {
		t.Fatalf("the thief's link after the revoke = %d %s, want 400 TOKEN_EXPIRED", code, body)
	}
	// Our API refuses the thief by the cut (production keeps the ID token valid until it expires).
	_, err = e.identity.GetMe(ctx, authed(thief.idToken, &identityv1.GetMeRequest{}))
	wantSessionEnded(t, "the thief's call after the removal", err)

	// The honest remover: on the emulator's strict verifier (which checks revocation like a refresh would) the
	// remover's pre-revoke token is refused unless issued in the revoke's own second; a fresh sign-in passes both the
	// verifier and the cut.
	strict := newChain(t, func(c *config.Config) { messagingOn(c); mutate(c) })
	again := signInAfter(t, email, after-1)
	if _, err := strict.identity.GetMe(ctx, authed(again.idToken, &identityv1.GetMeRequest{})); err != nil {
		t.Fatalf("the remover after a fresh sign-in: %v", err)
	}
	if code, body := accountUpdate(again.idToken); code != http.StatusOK {
		t.Fatalf("the remover's account change after a fresh sign-in = %d %s, want 200", code, body)
	}
	// Control for the link refusal above: the same link with a post-revoke token goes through, so the refusal was the
	// revoke and not a malformed request.
	if code, body := linkGoogle(again.idToken); code != http.StatusOK {
		t.Fatalf("a link with a fresh post-revoke token = %d %s, want 200 (control)", code, body)
	}
	if owner.authTime < after {
		_, err := strict.identity.GetMe(ctx, authed(owner.idToken, &identityv1.GetMeRequest{}))
		if connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("the remover's pre-revoke token on the emulator's revocation-checking verifier = %v, want UNAUTHENTICATED", err)
		}
	}

	// A retry of the same removal, a second later than the revoke: done marks, so no second revoke.
	later := signInAfter(t, email, after)
	rm, err = keysClient.RemoveKeyDevice(ctx, authed(later.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("rv-rm-retry"), DeviceId: lost, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
	if err != nil || !rm.Msg.GetOtherSessionsEnded() {
		t.Fatalf("retry = %v, %v; want success with other_sessions_ended", rm, err)
	}
	if got := validSince(t, cfg.ProjectID, uid); got != after {
		t.Fatalf("validSince after the retry = %d, want unchanged %d (revoked once per mark)", got, after)
	}

	t.Run("device_sign_out off for the remover: no cut, no revoke", func(t *testing.T) {
		const dev = "revoke-chain-off-dev01"
		if _, err := keysClient.RegisterKeyDevice(ctx, authed(offA.idToken, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("rv-reg-off"), DeviceId: dev, SignaturePublicKey: bytes.Repeat([]byte{4}, 32)})); err != nil {
			t.Fatal(err)
		}
		offB := signInAfter(t, offEmail, offA.authTime)
		vs := validSince(t, cfg.ProjectID, offUID)
		rm, err := keysClient.RemoveKeyDevice(ctx, authed(offB.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("rv-rm-off"), DeviceId: dev, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
		if err != nil || rm.Msg.GetOtherSessionsEnded() {
			t.Fatalf("= %v, %v; want success without a cut", rm, err)
		}
		if got := validSince(t, cfg.ProjectID, offUID); got != vs {
			t.Fatalf("validSince %d -> %d, want unchanged", vs, got)
		}
		if code, body := accountUpdate(offA.idToken); code != http.StatusOK {
			t.Fatalf("the older session's account change = %d %s, want 200 (nothing revoked)", code, body)
		}
	})
}
