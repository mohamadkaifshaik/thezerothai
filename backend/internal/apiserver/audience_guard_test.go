package apiserver

// W3-35a: the audience guard (ADR-0025 D3, D4, AQ2; plan Part B rules 5 and 6). A source scan of every non-test Go file
// under backend/internal that fails `make ci` the day a new read path (W4 search, W5 lists, W7 DMs) decides post
// visibility on its own. No emulator is needed. It fails when any of these is true:
//
//	R1  a file other than posts/audience.go compares a post Visibility with the public (or followers) value, with ==, !=
//	    or a `case` clause. The stored posts.visibility is always PUBLIC (D2), so such a test is a silent no-op for a
//	    protected author. Assigning the value (the writers) is not a comparison and is not flagged.
//	R2  a package that builds PostView rows (a composite literal of PostView, or a call to ToView) never names
//	    `Audience`, so no row it builds can have gone through posts.Audience.
//	R3  a file other than the allowlisted ones calls the AQ2 expression: a three-argument `.CanSee(viewer, author,
//	    following)`, which is identity.ProtectedSet.CanSee. posts.Audience.CanSee (four arguments, with the snapshot and
//	    the set) and notifications.AudienceChecker.CanSee (four arguments, with ctx) are different methods and are not
//	    matched; the heuristic is the call's arity, because the scan has no type information.
//
// Each allowlist entry carries the reason and goes stale (and fails) when the call it excuses disappears, like the T11
// guard. The self-tests below prove every rule fires on a synthetic violation and stays quiet on the clean shape.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// audienceCanSeeAllowlist lists the non-test files that may call identity.ProtectedSet.CanSee (rule R3), with why.
var audienceCanSeeAllowlist = map[string]string{
	"posts/audience.go":                 "the one predicate: posts.Audience.CanSee delegates to the AQ2 expression (ADR-0025 AQ2)",
	"identity/service.go":               "GetProfile's pin omission: identity cannot import posts (AQ2, the one named caller outside posts.Audience)",
	"graph/follow_requests.go":          "D-1 (W3-35a report): refuseProtectedList, PROTECTED_ACCOUNT on follower lists (W3-28a); graph imports neither posts nor needs a snapshot, so it asks the set directly. Beyond AQ2's 'these two are the only callers'",
	"apiserver/notifications_wiring.go": "D-1 (W3-35a report): protectedAudience adapts the loader to notifications.AudienceChecker (W3-31). AQ5 says 'adapts it from posts.Audience.CanSee'; it calls the set's expression directly",
}

// audienceFinding is one violation: file (relative to internal/, slash-separated), rule and a message.
type audienceFinding struct{ File, Rule, Msg string }

func (f audienceFinding) String() string { return f.File + ": " + f.Rule + ": " + f.Msg }

// isPublicVisibilityName reports whether an identifier names a post visibility constant.
func isVisibilityConst(name string) bool {
	switch name {
	case "VisibilityPublic", "Visibility_VISIBILITY_PUBLIC", "Visibility_VISIBILITY_FOLLOWERS", "VisibilityFollowers":
		return true
	}
	return false
}

func namesVisibility(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.Ident:
		return isVisibilityConst(v.Name)
	case *ast.SelectorExpr:
		return isVisibilityConst(v.Sel.Name)
	case *ast.CallExpr: // Visibility("PUBLIC"), string(VisibilityPublic)
		for _, a := range v.Args {
			if namesVisibility(a) {
				return true
			}
		}
	case *ast.BasicLit:
		return v.Kind == token.STRING && v.Value == `"PUBLIC"`
	}
	return false
}

// endsInVisibility reports whether e reads a field or variable called Visibility (x.Visibility, visibility).
func endsInVisibility(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.SelectorExpr:
		return v.Sel.Name == "Visibility" || v.Sel.Name == "GetVisibility"
	case *ast.Ident:
		return strings.EqualFold(v.Name, "visibility")
	case *ast.CallExpr:
		if s, ok := v.Fun.(*ast.SelectorExpr); ok && s.Sel.Name == "GetVisibility" {
			return true
		}
		for _, a := range v.Args {
			if endsInVisibility(a) {
				return true
			}
		}
	}
	return false
}

// auditAudience scans sources (path relative to internal/ -> Go source, non-test files only) and returns the findings,
// sorted. allow is the R3 allowlist; an entry with no finding to excuse is itself a finding (stale).
func auditAudience(t *testing.T, sources map[string]string, allow map[string]string) []audienceFinding {
	t.Helper()
	var out []audienceFinding
	fset := token.NewFileSet()
	type pkgState struct {
		builds    []string // files that build PostView rows
		namesAud  bool
		seenFiles int
	}
	pkgs := map[string]*pkgState{}
	canSeeHit := map[string]bool{}

	paths := make([]string, 0, len(sources))
	for p := range sources {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, path := range paths {
		f, err := parser.ParseFile(fset, path, sources[path], 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		pkg := filepath.ToSlash(filepath.Dir(path))
		ps := pkgs[pkg]
		if ps == nil {
			ps = &pkgState{}
			pkgs[pkg] = ps
		}
		ps.seenFiles++
		ast.Inspect(f, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BinaryExpr:
				// R1: == / != between a Visibility and the public value.
				if (x.Op == token.EQL || x.Op == token.NEQ) && path != "posts/audience.go" {
					if (namesVisibility(x.X) && (endsInVisibility(x.Y) || isVisibilityConstExpr(x.Y))) ||
						(namesVisibility(x.Y) && (endsInVisibility(x.X) || isVisibilityConstExpr(x.X))) {
						out = append(out, audienceFinding{path, "R1", "compares a post Visibility with a visibility constant at " + fset.Position(x.Pos()).String()})
					}
				}
			case *ast.CaseClause:
				// R1: `case VisibilityPublic:` in a switch on a Visibility.
				if path != "posts/audience.go" {
					for _, e := range x.List {
						if isVisibilityConstExpr(e) {
							out = append(out, audienceFinding{path, "R1", "case clause on a visibility constant at " + fset.Position(x.Pos()).String()})
						}
					}
				}
			case *ast.CompositeLit:
				// R2: builds a PostView row.
				if isNamed(x.Type, "PostView") {
					ps.builds = append(ps.builds, path)
				}
			case *ast.CallExpr:
				if isNamed(x.Fun, "ToView") {
					ps.builds = append(ps.builds, path)
				}
				// R3: the AQ2 expression, identity.ProtectedSet.CanSee(viewer, author, following).
				if s, ok := x.Fun.(*ast.SelectorExpr); ok && s.Sel.Name == "CanSee" && len(x.Args) == 3 {
					canSeeHit[path] = true
					if _, ok := allow[path]; !ok {
						out = append(out, audienceFinding{path, "R3", "calls ProtectedSet.CanSee outside posts.Audience at " + fset.Position(x.Pos()).String()})
					}
				}
			case *ast.Ident:
				if x.Name == "Audience" {
					ps.namesAud = true
				}
			}
			return true
		})
	}
	for pkg, ps := range pkgs {
		if len(ps.builds) > 0 && !ps.namesAud {
			out = append(out, audienceFinding{ps.builds[0], "R2", "package " + pkg + " builds PostView rows and never names posts.Audience"})
		}
	}
	for path := range allow {
		if !canSeeHit[path] {
			out = append(out, audienceFinding{path, "R3", "stale allowlist entry: the file no longer calls ProtectedSet.CanSee"})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].String() < out[j].String() })
	return out
}

func isVisibilityConstExpr(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.Ident:
		return isVisibilityConst(v.Name)
	case *ast.SelectorExpr:
		return isVisibilityConst(v.Sel.Name)
	case *ast.CallExpr:
		for _, a := range v.Args {
			if isVisibilityConstExpr(a) {
				return true
			}
		}
	}
	return false
}

func isNamed(e ast.Expr, name string) bool {
	switch v := e.(type) {
	case *ast.Ident:
		return v.Name == name
	case *ast.SelectorExpr:
		return v.Sel.Name == name
	}
	return false
}

// TestAudienceGuard_Backend scans the real tree.
func TestAudienceGuard_Backend(t *testing.T) {
	root := ".." // backend/internal, relative to this package
	sources := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		sources[filepath.ToSlash(rel)] = string(b)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) < 100 {
		t.Fatalf("scanned only %d files under %s: the guard would pass vacuously", len(sources), root)
	}
	for _, f := range auditAudience(t, sources, audienceCanSeeAllowlist) {
		t.Errorf("%s", f)
	}
}

// TestAudienceGuard_SelfTest proves each rule fires on a violation and stays quiet on the clean shape.
func TestAudienceGuard_SelfTest(t *testing.T) {
	const pre = "package x\n"
	tests := []struct {
		name  string
		files map[string]string
		allow map[string]string
		want  []string // "<file>|<rule>" of every expected finding
	}{
		{"clean writer assigns the value", map[string]string{"posts/w.go": pre + `func f() { p.Visibility = VisibilityPublic }`}, nil, nil},
		{"R1 equality on the field", map[string]string{"search/s.go": pre + `func f(p P) bool { return p.Visibility == posts.VisibilityPublic }`}, nil, []string{"search/s.go|R1"}},
		{"R1 inequality, constant on the left", map[string]string{"lists/s.go": pre + `func f(p P) bool { return VisibilityPublic != p.Visibility }`}, nil, []string{"lists/s.go|R1"}},
		{"R1 against the wire enum", map[string]string{"dm/s.go": pre + `func f(p P) bool { return p.GetVisibility() == postsv1.Visibility_VISIBILITY_PUBLIC }`}, nil, []string{"dm/s.go|R1"}},
		{"R1 string literal", map[string]string{"dm/s.go": pre + `func f(p P) bool { return string(p.Visibility) == "PUBLIC" }`}, nil, []string{"dm/s.go|R1"}},
		{"R1 case clause", map[string]string{"posts/convert.go": pre + `func f(v Visibility) int { switch v { case VisibilityPublic: return 1 }; return 0 }`}, nil, []string{"posts/convert.go|R1"}},
		{"R1 is exempt in audience.go", map[string]string{"posts/audience.go": pre + `func f(p P) bool { return p.Visibility == VisibilityPublic }`}, nil, nil},
		{"R1 ignores an unrelated PUBLIC compare", map[string]string{"x/a.go": pre + `func f(k string) bool { return k == "PUBLIC" }`}, nil, nil},
		{"R2 builder without Audience", map[string]string{"search/s.go": pre + `func f() { _ = &postsv1.PostView{} }`}, nil, []string{"search/s.go|R2"}},
		{"R2 ToView caller without Audience", map[string]string{"lists/s.go": pre + `func f(p *P) { _ = posts.ToView(p, vs, "u") }`}, nil, []string{"lists/s.go|R2"}},
		{"R2 satisfied by naming Audience", map[string]string{"lists/s.go": pre + `func f(p *P, a *posts.Audience) { _ = posts.ToView(p, vs, "u") }`}, nil, nil},
		{"R2 satisfied from a sibling file of the package", map[string]string{
			"lists/s.go": pre + `func f(p *P) { _ = posts.ToView(p, vs, "u") }`,
			"lists/a.go": pre + `type Audience interface{}`,
		}, nil, nil},
		{"R3 the AQ2 expression outside the allowlist", map[string]string{"search/s.go": pre + `func f(set S) bool { return set.CanSee(v, a, false) }`}, nil, []string{"search/s.go|R3"}},
		{"R3 allowlisted", map[string]string{"identity/service.go": pre + `func f(set S) bool { return set.CanSee(v, a, false) }`}, map[string]string{"identity/service.go": "pin"}, nil},
		{"R3 stale allowlist entry", map[string]string{"identity/service.go": pre + `func f() {}`}, map[string]string{"identity/service.go": "pin"}, []string{"identity/service.go|R3"}},
		{"R3 four-argument CanSee is a different method", map[string]string{"notifications/f.go": pre + `func f() { _, _ = d.Audience.CanSee(ctx, r, a, true) }`}, nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got []string
			for _, f := range auditAudience(t, tc.files, tc.allow) {
				got = append(got, f.File+"|"+f.Rule)
			}
			sort.Strings(got)
			want := append([]string(nil), tc.want...)
			sort.Strings(want)
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Errorf("findings = %v, want %v", got, want)
			}
		})
	}
}
