package identity

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// TestSessionRevokes_OnlyKeysWiring (H1 security review L1): the refresh-token revoke is reachable from outside identity
// only through apiserver/keys_wiring.go, which hands it to keys' REMOTE removal. It is not a method of Service or
// SessionCuts (which many modules hold), identity.SessionRevokes is named outside identity only in keys_wiring.go, and
// RevokeSessionsAt is called or declared outside identity only by that file and keys' own seam (api.go, service.go).
// Test files are exempt (fakes).
func TestSessionRevokes_OnlyKeysWiring(t *testing.T) {
	for _, iface := range []reflect.Type{reflect.TypeFor[Service](), reflect.TypeFor[SessionCuts]()} {
		if _, ok := iface.MethodByName("RevokeSessionsAt"); ok {
			t.Errorf("%s has RevokeSessionsAt: every holder of it could revoke any uid's refresh tokens", iface)
		}
	}
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	allowedIface := []string{"internal/apiserver/keys_wiring.go"}
	allowedMethod := []string{"internal/apiserver/keys_wiring.go", "internal/keys/api.go", "internal/keys/service.go"}
	var badIface, badMethod []string
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := filepath.ToSlash(strings.TrimPrefix(path, root+string(filepath.Separator)))
		if d.IsDir() {
			if rel == "gen" || rel == "internal/identity" || strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path) //nolint:gosec // a repository source file under the module root
		if err != nil {
			return err
		}
		src := string(b)
		if strings.Contains(src, "identity.SessionRevokes") && !slices.Contains(allowedIface, rel) {
			badIface = append(badIface, rel)
		}
		if strings.Contains(src, "RevokeSessionsAt") && !slices.Contains(allowedMethod, rel) {
			badMethod = append(badMethod, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(badIface) > 0 {
		t.Errorf("identity.SessionRevokes is held outside apiserver/keys_wiring.go: %v", badIface)
	}
	if len(badMethod) > 0 {
		t.Errorf("RevokeSessionsAt is reached outside keys_wiring.go and keys' seam: %v", badMethod)
	}
	// The scan must have seen the allowed files, or it scanned the wrong tree.
	for _, f := range allowedMethod {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(f))); err != nil {
			t.Errorf("allowed file %s not found under %s: %v", f, root, err)
		}
	}
}
