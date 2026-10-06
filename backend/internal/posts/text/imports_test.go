package text

import (
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestNoInternalImports pins ADR-0010 D21 G3: the pure parser imports nothing under internal/ (the handle
// grammar lives in pkg/platform/handle), so fuzz builds stay small and identity can later import the grammar
// without a cycle.
func TestNoInternalImports(t *testing.T) {
	t.Parallel()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		checked++
		af, err := parser.ParseFile(token.NewFileSet(), f, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		for _, imp := range af.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			if strings.Contains(path, "/internal/") {
				t.Errorf("%s imports %q: posts/text must not import internal packages", f, path)
			}
		}
	}
	if checked == 0 {
		t.Fatal("no non-test files found")
	}
}
