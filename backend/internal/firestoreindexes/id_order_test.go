// Package firestoreindexes_test holds repo-wide checks of firebase/firestore.indexes.json against the Go Firestore queries.
//
// The Firestore emulator enforces no indexes, so a query whose composite index is wrong passes every integration test and
// fails only on a real project with FAILED_PRECONDITION ("The query requires an index"). That is how the #901 lists index
// shipped: DiscoverPage orders by followerCount DESC then document id ASC, the index named only isPrivate ASC,
// followerCount DESC, and Firestore gave the implicit __name__ the last field's direction (DESC).
//
// TestMixedDirectionIDOrderHasExplicitIndex catches that class: a query chain .OrderBy(F, dirA).OrderBy(DocumentID, dirB)
// with dirA != dirB needs a composite index in which F dirA is immediately followed by an explicit __name__ dirB.
//
// It does NOT check that every composite query has an index at all: only a real Firestore project can tell that.
package firestoreindexes_test

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// allowUnresolved lists "path/from/backend.go:line" of OrderBy(DocumentID, ...) calls the check cannot resolve but a
// reviewer has confirmed (say why in the comment). Keep it empty if possible.
var allowUnresolved = map[string]string{}

// idOrder is one OrderBy(DocumentID, dir) call and what precedes it in the same chain.
type idOrder struct {
	pos      string // backend-relative file:line
	field    string // the preceding OrderBy field ("" when no preceding OrderBy)
	fieldDir string // "ASCENDING", "DESCENDING", or "ident:<name>" for a non-constant direction
	idDir    string
	problem  string // set when the call cannot be resolved
}

type indexField struct {
	FieldPath string `json:"fieldPath"`
	Order     string `json:"order"`
}

type indexFile struct {
	Indexes []struct {
		CollectionGroup string       `json:"collectionGroup"`
		Fields          []indexField `json:"fields"`
	} `json:"indexes"`
}

func TestMixedDirectionIDOrderHasExplicitIndex(t *testing.T) {
	backend, indexes := locate(t)
	orders := scan(t, backend)
	if len(orders) == 0 {
		t.Fatal("found no OrderBy(DocumentID, ...) calls; the scan is broken")
	}
	idx := readIndexes(t, indexes)
	mixed := 0
	for _, o := range orders {
		if o.problem == "" && o.field != "" && o.fieldDir != o.idDir {
			mixed++
			t.Logf("mixed-direction id order: %s (%s %s, __name__ %s)", o.pos, o.field, o.fieldDir, o.idDir)
		}
	}
	t.Logf("%d OrderBy(DocumentID) calls, %d with mixed directions", len(orders), mixed)
	for _, msg := range check(orders, idx) {
		t.Error(msg)
	}
}

// TestNoDuplicateCompositeIndexes fails on two identical composite index entries: `firebase deploy` creates the first and
// then stops with HTTP 409 "index already exists" on the second, leaving every later index in the file undeployed (seen on
// prod 2026-11-14 after #920 repeated the lists and communities nameLower indexes). An explicit trailing __name__ that equals
// the implicit one (the last field's direction) counts as the same index.
func TestNoDuplicateCompositeIndexes(t *testing.T) {
	_, indexes := locate(t)
	b, err := os.ReadFile(indexes)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Indexes []struct {
			CollectionGroup string `json:"collectionGroup"`
			QueryScope      string `json:"queryScope"`
			Fields          []struct {
				FieldPath   string `json:"fieldPath"`
				Order       string `json:"order"`
				ArrayConfig string `json:"arrayConfig"`
			} `json:"fields"`
		} `json:"indexes"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	seen := map[string]int{}
	for i, ix := range f.Indexes {
		parts := make([]string, 0, len(ix.Fields))
		for _, fl := range ix.Fields {
			parts = append(parts, fl.FieldPath+" "+fl.Order+fl.ArrayConfig)
		}
		// Drop an explicit trailing __name__ that matches the implicit one (the last field's order, ASCENDING after an array).
		if n := len(ix.Fields); n >= 2 && ix.Fields[n-1].FieldPath == "__name__" {
			implicit := ix.Fields[n-2].Order
			if implicit == "" {
				implicit = "ASCENDING"
			}
			if ix.Fields[n-1].Order == implicit {
				parts = parts[:n-1]
			}
		}
		key := ix.CollectionGroup + "|" + ix.QueryScope + "|" + strings.Join(parts, ",")
		if j, dup := seen[key]; dup {
			t.Errorf("indexes[%d] repeats indexes[%d] (%s): firebase deploy stops with HTTP 409 on the second copy", i, j, key)
			continue
		}
		seen[key] = i
	}
}

// TestCheckCatchesThe901Index proves the check fails on the index #901 shipped and passes once __name__ is explicit.
func TestCheckCatchesThe901Index(t *testing.T) {
	discover := []idOrder{{pos: "internal/lists/repo_follows.go:234", field: "followerCount", fieldDir: "DESCENDING", idDir: "ASCENDING"}}
	broken := indexFile{}
	broken.Indexes = append(broken.Indexes, struct {
		CollectionGroup string       `json:"collectionGroup"`
		Fields          []indexField `json:"fields"`
	}{"lists", []indexField{{"isPrivate", "ASCENDING"}, {"followerCount", "DESCENDING"}}})
	if got := check(discover, broken); len(got) != 1 {
		t.Fatalf("#901 index: %d problems, want 1: %v", len(got), got)
	}
	fixed := broken
	fixed.Indexes[0].Fields = append(fixed.Indexes[0].Fields, indexField{"__name__", "ASCENDING"})
	if got := check(discover, fixed); len(got) != 0 {
		t.Fatalf("fixed index: %v, want none", got)
	}
	wrongDir := indexFile{}
	wrongDir.Indexes = append(wrongDir.Indexes, struct {
		CollectionGroup string       `json:"collectionGroup"`
		Fields          []indexField `json:"fields"`
	}{"lists", []indexField{{"isPrivate", "ASCENDING"}, {"followerCount", "DESCENDING"}, {"__name__", "DESCENDING"}}})
	if got := check(discover, wrongDir); len(got) != 1 {
		t.Fatalf("explicit __name__ DESC: %d problems, want 1", len(got))
	}
}

// check returns one message per mixed-direction or unresolved call that the indexes do not cover.
func check(orders []idOrder, idx indexFile) []string {
	var out []string
	for _, o := range orders {
		if o.problem != "" {
			if _, ok := allowUnresolved[o.pos]; !ok {
				out = append(out, fmt.Sprintf("%s: %s; make it a plain chain or add it to allowUnresolved with a reason", o.pos, o.problem))
			}
			continue
		}
		if o.field == "" || o.fieldDir == o.idDir {
			continue // id-only order, or the same direction (the implicit __name__ already matches)
		}
		if !covered(idx, o.field, o.fieldDir, o.idDir) {
			out = append(out, fmt.Sprintf("%s: orders by %s %s then document id %s, but no index in firebase/firestore.indexes.json has %q %s immediately followed by an explicit {\"fieldPath\": \"__name__\", \"order\": %q} (the implicit __name__ takes the last field's direction, so the query fails on a real project)",
				o.pos, o.field, o.fieldDir, o.idDir, o.field, o.fieldDir, o.idDir))
		}
	}
	return out
}

func covered(idx indexFile, field, fieldDir, idDir string) bool {
	for _, ix := range idx.Indexes {
		for i := 0; i+1 < len(ix.Fields); i++ {
			if ix.Fields[i].FieldPath == field && ix.Fields[i].Order == fieldDir &&
				ix.Fields[i+1].FieldPath == "__name__" && ix.Fields[i+1].Order == idDir {
				return true
			}
		}
	}
	return false
}

// locate finds the backend module root (go.mod) and firebase/firestore.indexes.json next to it.
func locate(t *testing.T) (backend, indexes string) {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found above the test directory")
		}
		dir = parent
	}
	indexes = filepath.Join(dir, "..", "firebase", "firestore.indexes.json")
	if _, err := os.Stat(indexes); err != nil {
		t.Fatalf("firestore.indexes.json: %v", err)
	}
	return dir, indexes
}

func readIndexes(t *testing.T, path string) indexFile {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f indexFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return f
}

// scan parses every non-test Go file under the backend module and returns each OrderBy(DocumentID, ...) call.
func scan(t *testing.T, backend string) []idOrder {
	t.Helper()
	var out []idOrder
	fset := token.NewFileSet()
	err := filepath.WalkDir(backend, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == "vendor" || name == "testdata" || strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(backend, path)
		rel = filepath.ToSlash(rel)
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			out = append(out, scanFunc(fset, rel, fn.Body)...)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].pos < out[j].pos })
	return out
}

// scanFunc finds OrderBy(DocumentID, dir) calls in one function body.
func scanFunc(fset *token.FileSet, rel string, body *ast.BlockStmt) []idOrder {
	var out []idOrder
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || !isMethod(call, "OrderBy") || len(call.Args) != 2 || !isDocumentID(call.Args[0]) {
			return true
		}
		o := idOrder{pos: fmt.Sprintf("%s:%d", rel, fset.Position(call.Pos()).Line), idDir: direction(call.Args[1])}
		prev, root := precedingOrderBy(call)
		switch {
		case prev != nil:
			o.field, o.fieldDir = fieldName(prev.Args[0]), direction(prev.Args[1])
			if o.fieldDir != o.idDir && (o.field == "" || strings.HasPrefix(o.fieldDir, "ident:") || strings.HasPrefix(o.idDir, "ident:")) {
				o.problem = fmt.Sprintf("cannot resolve the field or directions of OrderBy(%s, %s).OrderBy(DocumentID, %s)", exprString(prev.Args[0]), exprString(prev.Args[1]), exprString(call.Args[1]))
			}
		case root != nil && assignedWithOrderBy(body, root.Name):
			o.problem = fmt.Sprintf("OrderBy(DocumentID) on %s, which is assigned an OrderBy elsewhere in the function (a split chain the check cannot follow)", root.Name)
		}
		out = append(out, o)
		return true
	})
	return out
}

// precedingOrderBy walks the receiver chain of call (through Where, Select, Limit, StartAfter, ...) to the nearest earlier
// OrderBy. With none, it returns the chain's root identifier, if the chain starts at a variable.
func precedingOrderBy(call *ast.CallExpr) (*ast.CallExpr, *ast.Ident) {
	x := call.Fun.(*ast.SelectorExpr).X
	for {
		switch e := x.(type) {
		case *ast.CallExpr:
			sel, ok := e.Fun.(*ast.SelectorExpr)
			if !ok {
				return nil, nil
			}
			if sel.Sel.Name == "OrderBy" && len(e.Args) == 2 {
				return e, nil
			}
			x = sel.X
		case *ast.SelectorExpr:
			x = e.X
		case *ast.ParenExpr:
			x = e.X
		case *ast.Ident:
			return nil, e
		default:
			return nil, nil
		}
	}
}

// assignedWithOrderBy reports whether some assignment to name in body has an OrderBy call on its right-hand side.
func assignedWithOrderBy(body *ast.BlockStmt, name string) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok || found {
			return !found
		}
		for i, lhs := range as.Lhs {
			id, ok := lhs.(*ast.Ident)
			if !ok || id.Name != name || i >= len(as.Rhs) {
				continue
			}
			ast.Inspect(as.Rhs[i], func(m ast.Node) bool {
				if c, ok := m.(*ast.CallExpr); ok && isMethod(c, "OrderBy") && len(c.Args) == 2 && !isDocumentID(c.Args[0]) {
					found = true
				}
				return !found
			})
		}
		return !found
	})
	return found
}

func isMethod(call *ast.CallExpr, name string) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == name
}

func isDocumentID(e ast.Expr) bool {
	if sel, ok := e.(*ast.SelectorExpr); ok && sel.Sel.Name == "DocumentID" {
		return true
	}
	if lit, ok := e.(*ast.BasicLit); ok && lit.Kind == token.STRING {
		s, err := strconv.Unquote(lit.Value)
		return err == nil && s == "__name__"
	}
	return false
}

// direction maps firestore.Asc / firestore.Desc to the index file's names; anything else is "ident:<source>", so two uses of
// the same variable compare equal and a variable never equals a constant.
func direction(e ast.Expr) string {
	if sel, ok := e.(*ast.SelectorExpr); ok {
		switch sel.Sel.Name {
		case "Asc":
			return "ASCENDING"
		case "Desc":
			return "DESCENDING"
		}
	}
	return "ident:" + exprString(e)
}

// fieldName returns a string-literal field path, or "" for anything else.
func fieldName(e ast.Expr) string {
	if lit, ok := e.(*ast.BasicLit); ok && lit.Kind == token.STRING {
		if s, err := strconv.Unquote(lit.Value); err == nil {
			return s
		}
	}
	return ""
}

func exprString(e ast.Expr) string {
	switch v := e.(type) {
	case *ast.Ident:
		return v.Name
	case *ast.SelectorExpr:
		return exprString(v.X) + "." + v.Sel.Name
	case *ast.BasicLit:
		return v.Value
	default:
		return fmt.Sprintf("%T", e)
	}
}
