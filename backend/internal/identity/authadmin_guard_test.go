package identity

// ADR-0011 IAM control C2 as a type-based CI guard. The runtime service account can read, disable and delete any
// Firebase Auth user, so only internal/identity's authAdmin wrapper (which enforces C1 and writes the C3 audit
// line) and the founder's own cmd/opsctl may use the Admin SDK's user-management methods. The check type-checks
// the whole module (production and test files, with the integration tag) and looks at what each identifier
// resolves to, not at how the source spells it, so it cannot be dodged by an unimported client (`app.Auth(ctx)`),
// a method value, a call through an embedded *baseClient / TenantClient, or an unexported struct field.

import (
	"go/types"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/tools/go/packages"
)

const (
	backendModule = "github.com/dzeroth/dzeroth/backend"
	authSDKPath   = "firebase.google.com/go/v4/auth"
	firebaseSDK   = "firebase.google.com/go/v4"
)

// authClientBuilderFiles (paths relative to backend/) are the only files that may build an Auth client with
// (*firebase.App).Auth: the token verifier (VerifyIDToken only, enforced by the first rule), apiserver.Build (which
// hands the client to identity alone) and the founder's opsctl.
var authClientBuilderFiles = []string{"pkg/platform/authn/firebase.go", "internal/apiserver/apiserver.go", "cmd/opsctl/"}

// authAdminReceivers are the SDK types whose methods manage users, provider configs and links. Their embedded
// *baseClient is where most methods are declared, so promoted calls resolve to it.
var authAdminReceivers = []string{"Client", "TenantClient", "baseClient", "TenantManager"}

func recvName(fn *types.Func) (string, bool) {
	sig, ok := fn.Type().(*types.Signature)
	if !ok || sig.Recv() == nil {
		return "", false
	}
	t := sig.Recv().Type()
	if p, ok := t.(*types.Pointer); ok {
		t = p.Elem()
	}
	named, ok := t.(*types.Named)
	if !ok {
		return "", false
	}
	return named.Obj().Name(), true
}

// guardedAuthMethod reports whether obj is an Auth admin method outside the verify-only set: a method of the SDK's
// admin types, or of identity.AuthClient, the exported interface over four of them (a call through the interface
// does the same thing as a call on the SDK client and must not skip the wrapper either; M3).
func guardedAuthMethod(obj types.Object) bool {
	fn, ok := obj.(*types.Func)
	if !ok || fn.Pkg() == nil {
		return false
	}
	name, ok := recvName(fn)
	switch {
	case !ok:
		return false
	case fn.Pkg().Path() == backendModule+"/internal/identity":
		return name == "AuthClient"
	case fn.Pkg().Path() == authSDKPath && !strings.HasPrefix(fn.Name(), "Verify"):
		return slices.Contains(authAdminReceivers, name)
	}
	return false
}

// mayUseAuthAdmin reports whether the file (relative to backend/) in package pkgPath may call a guarded method:
// cmd/opsctl, and inside internal/identity only the authAdmin wrapper (authadmin.go, which enforces C1 and writes the
// C3 audit line) and tests. Any other identity file, server.go included, could otherwise delete an Auth user
// without either control.
func mayUseAuthAdmin(pkgPath, rel string) bool {
	pkgPath = strings.TrimSuffix(pkgPath, "_test")
	switch {
	case pkgPath == backendModule+"/cmd/opsctl" || strings.HasPrefix(pkgPath, backendModule+"/cmd/opsctl/"):
		return true
	case rel == "internal/apiserver/account_lifecycle_crash_integration_test.go":
		// Exact-path exception (founder-approved): a test-only, pure pass-through wrapper (crashAuth) that forwards
		// each call unchanged to the wrapper-built client and kills the instance afterwards, to inject crashes after
		// Auth calls (T16). It implements no authorization and bypasses none in production code.
		return true
	case pkgPath == backendModule+"/internal/identity":
		return rel == "internal/identity/authadmin.go" || strings.HasSuffix(rel, "_test.go")
	}
	return false
}

// isAppAuth reports whether obj is (*firebase.App).Auth.
func isAppAuth(obj types.Object) bool {
	fn, ok := obj.(*types.Func)
	if !ok || fn.Pkg() == nil || fn.Pkg().Path() != firebaseSDK || fn.Name() != "Auth" {
		return false
	}
	_, ok = recvName(fn)
	return ok
}

// authGuardResult is what authAdminViolations found.
type authGuardResult struct {
	violations  []string // sorted, "file:line: message"
	allowedUses int      // guarded uses inside the allowed packages: proves the walk saw real code
}

// authAdminViolations flags, in every loaded package, each use (call, method value, promoted call) of a guarded
// Auth admin method (or of identity.AuthClient) outside identity's authadmin.go and cmd/opsctl, and each use of (*firebase.App).Auth outside the
// allowed builder files. root is the absolute backend/ directory, used to print relative paths.
func authAdminViolations(pkgs []*packages.Package, root string) authGuardResult {
	var res authGuardResult
	seen := map[string]bool{} // a file is type-checked once per test variant
	for _, pkg := range pkgs {
		if pkg.TypesInfo == nil {
			continue
		}
		for id, obj := range pkg.TypesInfo.Uses {
			guarded, builder := guardedAuthMethod(obj), isAppAuth(obj)
			if !guarded && !builder {
				continue
			}
			pos := pkg.Fset.Position(id.Pos())
			rel, err := filepath.Rel(root, pos.Filename)
			if err != nil {
				rel = pos.Filename
			}
			rel = filepath.ToSlash(rel)
			where := rel + ":" + strconv.Itoa(pos.Line)
			switch {
			case guarded && mayUseAuthAdmin(pkg.PkgPath, rel):
				res.allowedUses++
			case guarded:
				if k := where + id.Name; !seen[k] {
					seen[k] = true
					res.violations = append(res.violations, where+": uses the Firebase Admin Auth method "+id.Name+" outside internal/identity/authadmin.go and cmd/opsctl (ADR-0011 C2)")
				}
			case builder && !slices.ContainsFunc(authClientBuilderFiles, func(p string) bool { return strings.HasPrefix(rel, p) }):
				if k := where + id.Name; !seen[k] {
					seen[k] = true
					res.violations = append(res.violations, where+": builds a Firebase Auth admin client outside the allowed files (ADR-0011 C2)")
				}
			}
		}
	}
	slices.Sort(res.violations)
	return res
}

// loadForGuard type-checks the patterns (production, test and integration-tag files) of the backend module.
// overlay maps absolute file paths to virtual source, for the closed-holes test.
func loadForGuard(t *testing.T, root string, overlay map[string][]byte, patterns ...string) []*packages.Package {
	t.Helper()
	cfg := &packages.Config{
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedCompiledGoFiles | packages.NeedImports |
			packages.NeedTypes | packages.NeedSyntax | packages.NeedTypesInfo,
		Dir:        root,
		Tests:      true,
		BuildFlags: []string{"-tags=integration"},
		Env:        append(os.Environ(), "GOWORK=off"),
		Overlay:    overlay,
	}
	pkgs, err := packages.Load(cfg, patterns...)
	if err != nil {
		t.Fatalf("loading packages: %v", err)
	}
	for _, p := range pkgs {
		for _, e := range p.Errors {
			t.Errorf("package %s does not type-check: %v", p.ID, e)
		}
	}
	if t.Failed() {
		t.FailNow()
	}
	return pkgs
}

func backendRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// TestAuthAdminConfinement is the CI guard of IAM control C2.
func TestAuthAdminConfinement(t *testing.T) {
	root := backendRoot(t)
	pkgs := loadForGuard(t, root, nil, "./...")
	if len(pkgs) < 30 {
		t.Fatalf("loaded only %d packages: the load root is wrong", len(pkgs))
	}
	res := authAdminViolations(pkgs, root)
	if len(res.violations) > 0 {
		t.Fatalf("Firebase Admin Auth use outside the narrow wrapper:\n%s", strings.Join(res.violations, "\n"))
	}
	if res.allowedUses == 0 {
		t.Error("saw no Auth admin method use in internal/identity or cmd/opsctl: the type-based walk is not resolving the SDK")
	}
	// The one place that builds the client hands it only to identity.
	b, err := os.ReadFile(filepath.Join(root, "internal", "apiserver", "apiserver.go")) //nolint:gosec // G304: this repository's own source
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(b), "authAdminClient"); n != 3 {
		t.Errorf("apiserver.go mentions authAdminClient %d times, want 3 (built once, passed to identity.WithSignupAuth and identity.NewLifecycle)", n)
	}
}

// TestAuthAdminConfinement_ClosedHoles feeds the guard the evasions the earlier AST heuristics let through (virtual
// files overlaid on the real module so they type-check against the real SDK) and requires each to be caught.
func TestAuthAdminConfinement_ClosedHoles(t *testing.T) {
	root := backendRoot(t)
	files := map[string]string{
		// app.Auth(ctx) in a file that never imports the auth package: the client type is inferred.
		"internal/sneaky/a.go": "package sneaky\nimport (\n\t\"context\"\n\tfirebase \"firebase.google.com/go/v4\"\n)\n" +
			"func A(ctx context.Context, app *firebase.App) error { c, _ := app.Auth(ctx); return c.DeleteUser(ctx, \"someone-else\") }\n",
		// a method value is a selector, not a call.
		"internal/sneaky/b.go": "package sneaky\nimport fbauth \"firebase.google.com/go/v4/auth\"\n" +
			"func B(c *fbauth.Client) { del := c.DeleteUser; _ = del }\n",
		// a call through an embedded *auth.Client (promoted from *baseClient) and through a *TenantClient.
		"internal/sneaky/c.go": "package sneaky\nimport (\n\t\"context\"\n\tfbauth \"firebase.google.com/go/v4/auth\"\n)\n" +
			"type wrap struct{ *fbauth.Client }\n" +
			"func C(ctx context.Context, w wrap) error { return w.DeleteUser(ctx, \"u\") }\n" +
			"func D(ctx context.Context, tc *fbauth.TenantClient) error { return tc.DeleteUser(ctx, \"u\") }\n",
		// an unexported field in the token verifier's package: the old text grep only read firebase.go.
		"pkg/platform/authn/zz_evil.go": "package authn\nimport (\n\t\"context\"\n\tfbauth \"firebase.google.com/go/v4/auth\"\n)\n" +
			"type zzEvil struct{ client *fbauth.Client }\n" +
			"func (e zzEvil) wipe(ctx context.Context) error { return e.client.RevokeRefreshTokens(ctx, \"u\") }\n",
		// a second file in apiserver building a client: only apiserver.go may.
		"internal/apiserver/zz_builder.go": "package apiserver\nimport (\n\t\"context\"\n\tfirebase \"firebase.google.com/go/v4\"\n)\n" +
			"func zzBuild(ctx context.Context, app *firebase.App) { _, _ = app.Auth(ctx) }\n",
		// a call through identity.AuthClient from another package (the interface is exported for apiserver).
		"internal/sneaky/d.go": "package sneaky\nimport (\n\t\"context\"\n\t\"github.com/dzeroth/dzeroth/backend/internal/identity\"\n)\n" +
			"func E(ctx context.Context, c identity.AuthClient) error { return c.DeleteUser(ctx, \"u\") }\n",
		// inside identity but outside authadmin.go: through the SDK client and through the AuthClient interface.
		"internal/identity/zz_server.go": "package identity\nimport (\n\t\"context\"\n\tfbauth \"firebase.google.com/go/v4/auth\"\n)\n" +
			"func zzSDK(ctx context.Context, c *fbauth.Client) error { return c.DeleteUser(ctx, \"u\") }\n" +
			"func zzIface(ctx context.Context, c AuthClient) error { return c.RevokeRefreshTokens(ctx, \"u\") }\n",
		// allowed: a test file in identity may call everything, and anyone may verify tokens.
		"internal/identity/zz_ok_test.go": "package identity\nimport (\n\t\"context\"\n\tfbauth \"firebase.google.com/go/v4/auth\"\n)\n" +
			"func zzOK(ctx context.Context, c *fbauth.Client) error { _, _ = c.VerifyIDToken(ctx, \"t\"); return c.DeleteUser(ctx, \"u\") }\n",
	}
	overlay := map[string][]byte{}
	for rel, src := range files {
		overlay[filepath.Join(root, filepath.FromSlash(rel))] = []byte(src)
	}
	pkgs := loadForGuard(t, root, overlay, "./internal/sneaky", "./pkg/platform/authn", "./internal/apiserver", "./internal/identity")
	res := authAdminViolations(pkgs, root)
	byFile := map[string]int{}
	for _, v := range res.violations {
		byFile[v[:strings.Index(v, ":")]]++
	}
	want := map[string]int{
		"internal/sneaky/a.go":             2, // the client builder and the DeleteUser call
		"internal/sneaky/b.go":             1,
		"internal/sneaky/c.go":             2, // promoted and TenantClient
		"internal/sneaky/d.go":             1, // through identity.AuthClient
		"internal/identity/zz_server.go":   2, // SDK client and AuthClient inside identity, outside authadmin.go
		"pkg/platform/authn/zz_evil.go":    1,
		"internal/apiserver/zz_builder.go": 1,
	}
	for f, n := range want {
		if byFile[f] != n {
			t.Errorf("%s: %d violations, want %d\nall: %v", f, byFile[f], n, res.violations)
		}
	}
	if len(byFile) != len(want) {
		t.Errorf("violations in unexpected files (identity's real files and the verifier's real code must stay clean): %v", res.violations)
	}
}
