package identity

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// The repo's errors are wrapped by every module that reads a profile (graph, lists, moderation, timeline, search, the
// export job) and end up on log lines those modules write about somebody else: "decode profile <uid>" inside another
// person's export error named the people that person follows, lists or reported. So no error built in the Firestore
// layer formats a uid or a document id into its text; the operation name and the wrapped cause are enough, and the
// caller that knows whose request it is adds a keyed hash (logger.RedactErr / ScrubErr / ScrubPairErr).
//
// This is a source scan because the decode and transport failures need a live Firestore to provoke: it fails on any
// fmt.Errorf in these files with an argument that is a uid variable, an element of a uid slice or a snapshot's Ref.ID.
func TestRepoErrors_NeverFormatAUIDOrDocID(t *testing.T) {
	t.Parallel()
	files, err := filepath.Glob("repo*.go")
	if err != nil {
		t.Fatal(err)
	}
	files = append(files, "search_handles.go", "home_tabs.go")
	scanned := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		scanned++
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok || !isSelector(call.Fun, "fmt", "Errorf") {
				return true
			}
			for _, arg := range call.Args[1:] {
				if why := namesAPerson(arg); why != "" {
					t.Errorf("%s: fmt.Errorf formats %s into the error text", fset.Position(call.Pos()), why)
				}
			}
			return true
		})
	}
	if scanned < 5 {
		t.Fatalf("scanned %d files, want the Firestore layer (run from the package directory)", scanned)
	}
}

func TestNamesAPerson(t *testing.T) {
	t.Parallel()
	tests := []struct {
		expr string
		bad  bool
	}{
		{"uid", true},
		{"uids[i]", true},
		{"p.UserID", true},
		{"snap.Ref.ID", true},
		{"s.Ref.ID", true},
		{"msg.UID", true},
		{"err", false},
		{"len(uids)", false},
		{"collection", false},
		{"i", false},
		{"logger.HashUID(uid)", false},
	}
	for _, tt := range tests {
		e, err := parser.ParseExpr(tt.expr)
		if err != nil {
			t.Fatal(err)
		}
		if got := namesAPerson(e) != ""; got != tt.bad {
			t.Errorf("namesAPerson(%s) = %v, want %v", tt.expr, got, tt.bad)
		}
	}
}

func isSelector(e ast.Expr, pkg, name string) bool {
	sel, ok := e.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != name {
		return false
	}
	x, ok := sel.X.(*ast.Ident)
	return ok && x.Name == pkg
}

// namesAPerson says why arg is a raw user or document id ("" when it is not): a variable or field called uid / UID /
// UserID, an element of a slice called uids, or a Ref.ID. A call (len(uids), logger.HashUID(uid)) is not one.
func namesAPerson(arg ast.Expr) string {
	switch e := arg.(type) {
	case *ast.Ident:
		if e.Name == "uid" {
			return "the uid"
		}
	case *ast.IndexExpr:
		if x, ok := e.X.(*ast.Ident); ok && x.Name == "uids" {
			return "a uid of the batch"
		}
	case *ast.SelectorExpr:
		switch e.Sel.Name {
		case "UID", "UserID":
			return "a uid field"
		case "ID":
			if x, ok := e.X.(*ast.SelectorExpr); ok && x.Sel.Name == "Ref" {
				return "a document id"
			}
		}
	}
	return ""
}
