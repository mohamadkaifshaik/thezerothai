package authn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestIDTokenVerifier_NoPerRequestRevocationCheck pins a fact the H1 design relies on: production verifies ID tokens with
// the Admin SDK's VerifyIDToken, which does not look the user up, never VerifyIDTokenAndCheckRevoked (one Auth read per
// request). So after a refresh-token revoke (identity's RevokeSessionsAt) an ID token keeps passing this verifier until it
// expires (at most 1 h), and the session cut (SessionCutInterceptor) is what refuses the removed device meanwhile. The
// apiserver chain tests model exactly this with their unrevokedVerifier. Changing it is an owner decision: it adds an Auth
// read to every request and changes what the remover sees after a removal.
func TestIDTokenVerifier_NoPerRequestRevocationCheck(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	sawVerify := false
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f) //nolint:gosec // a source file of this package
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if strings.Contains(src, "VerifyIDTokenAndCheckRevoked") {
			t.Errorf("%s calls VerifyIDTokenAndCheckRevoked: a per-request revocation check (owner decision, see the test comment)", f)
		}
		if f == "firebase.go" && strings.Contains(src, "v.client.VerifyIDToken(ctx, idToken)") {
			sawVerify = true
		}
	}
	if !sawVerify {
		t.Error("firebase.go no longer calls v.client.VerifyIDToken(ctx, idToken); re-check the H1 window and this guard")
	}
}
