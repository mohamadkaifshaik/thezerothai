package media

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// ADR-0024 Amendment 1 A4 rests on one invariant: the media bucket's lifecycle rule deletes an object once
// daysSinceCustomTime >= 1, so the only thing that may ever set customTime on a public object is the retire step. If
// anything else set it (a copy, an upload, a future feature), that object would be deleted a day later with its
// media document still alive. These tests pin both halves: the code that sets it, and the Terraform rule that acts on it.

// customTimeSites returns, for every non-test Go file under backend/ (generated code excluded), the set of enclosing
// function names that mention customTime: an identifier containing "CustomTime" or a string literal containing
// "customTime". The file path is relative to backend/, slash-separated.
func customTimeSites(t *testing.T) map[string]map[string]bool {
	t.Helper()
	root := filepath.Join("..", "..")
	sites := map[string]map[string]bool{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel == "gen" || strings.HasPrefix(rel, "gen/") || d.Name() == ".git" || d.Name() == "node_modules" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", rel, err)
		}
		for _, decl := range f.Decls {
			name := "(file level)"
			if fd, ok := decl.(*ast.FuncDecl); ok {
				name = fd.Name.Name
			}
			ast.Inspect(decl, func(n ast.Node) bool {
				hit := false
				switch v := n.(type) {
				case *ast.Ident:
					hit = strings.Contains(v.Name, "CustomTime")
				case *ast.BasicLit:
					hit = v.Kind == token.STRING && strings.Contains(v.Value, "customTime")
				}
				if hit {
					if sites[rel] == nil {
						sites[rel] = map[string]bool{}
					}
					sites[rel][name] = true
				}
				return true
			})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return sites
}

// TestCustomTimeIsSetOnlyByTheRetireStep: customTime appears in exactly four places in the application code: the one
// objstore method that patches it, the Buckets method that exposes it for the public bucket, the PublicTagger seam
// (declared in retire.go) and Jobs.Retire, its only caller. A copy (CopyTo, Publish), an upload or any other module
// that mentions it fails this test.
func TestCustomTimeIsSetOnlyByTheRetireStep(t *testing.T) {
	want := map[string][]string{
		"pkg/platform/objstore/objstore.go": {"SetCustomTime"},
		"internal/media/gcs.go":             {"SetPublicCustomTime"},
		"internal/media/retire.go":          {"(file level)", "Retire"}, // the PublicTagger declaration and its one call
	}
	got := customTimeSites(t)
	for file, funcs := range got {
		allowed, ok := want[file]
		if !ok {
			t.Errorf("%s mentions customTime in %v: only the retire step may (ADR-0024 Amendment 1 A4)", file, keys(funcs))
			continue
		}
		for fn := range funcs {
			found := false
			for _, a := range allowed {
				found = found || a == fn
			}
			if !found {
				t.Errorf("%s: %s mentions customTime, allowed only in %v", file, fn, allowed)
			}
		}
	}
	for file := range want {
		if got[file] == nil {
			t.Errorf("%s no longer mentions customTime: update this test if the retire step moved", file)
		}
	}
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// tfBlock returns the body of the first Terraform block whose header line matches header (a regexp), found by brace
// matching from the header's opening brace.
func tfBlock(t *testing.T, src, header string) string {
	t.Helper()
	loc := regexp.MustCompile(header).FindStringIndex(src)
	if loc == nil {
		t.Fatalf("no block matching %q", header)
	}
	open := strings.Index(src[loc[1]-1:], "{")
	if open < 0 {
		t.Fatalf("block %q has no body", header)
	}
	start := loc[1] - 1 + open
	depth := 0
	for i := start; i < len(src); i++ {
		switch src[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return src[start : i+1]
			}
		}
	}
	t.Fatalf("block %q is not closed", header)
	return ""
}

// TestMediaBucketLifecycleRuleDeletesOnCustomTime pins the Terraform half: the public media bucket has exactly one
// customTime rule (Delete once daysSinceCustomTime >= 1), no other bucket has one, and the retired document outlives
// the objects' deletion lag (the rule acts within about a day of the condition, so 24-48 h after changedAt).
func TestMediaBucketLifecycleRuleDeletesOnCustomTime(t *testing.T) {
	raw, err := os.ReadFile("../../../infra/terraform/modules/media-buckets/main.tf")
	if err != nil {
		t.Fatalf("read media-buckets module: %v", err)
	}
	src := string(raw)

	media := tfBlock(t, src, `resource "google_storage_bucket" "media" \{`)
	rule := regexp.MustCompile(`lifecycle_rule\s*\{`)
	var customRules []string
	for _, loc := range rule.FindAllStringIndex(media, -1) {
		body := tfBlock(t, media[loc[0]:], `lifecycle_rule\s*\{`)
		if strings.Contains(body, "days_since_custom_time") {
			customRules = append(customRules, body)
		}
	}
	if len(customRules) != 1 {
		t.Fatalf("the media bucket has %d days_since_custom_time rules, want exactly 1", len(customRules))
	}
	body := customRules[0]
	if !regexp.MustCompile(`days_since_custom_time\s*=\s*1\b`).MatchString(body) {
		t.Errorf("the rule must delete at days_since_custom_time = 1 (the 24 h grace of ADR-0024 A4): %s", body)
	}
	if !regexp.MustCompile(`type\s*=\s*"Delete"`).MatchString(body) {
		t.Errorf("the rule's action must be Delete: %s", body)
	}
	for _, other := range []string{"upload", "exports"} {
		b := tfBlock(t, src, `resource "google_storage_bucket" "`+other+`" \{`)
		if strings.Contains(b, "custom_time") {
			t.Errorf("the %s bucket must not carry a customTime rule", other)
		}
	}
	if RetiredDocTTL < 48*time.Hour {
		t.Errorf("RetiredDocTTL = %v: the document must outlive the lifecycle rule's 24-48 h deletion lag, or the objects escape the account eraser", RetiredDocTTL)
	}
}
