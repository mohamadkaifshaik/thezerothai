package posts

// W6-6 guard (ADR-0029 D4): the posts converter is the only place that knows who may see a poll's per-choice counts and the
// viewer's choice. This source scan fails the day a PostView producer builds a view (or a Poll) without it. It names the
// producers by file:
//
//	GetPost, GetThread         posts/server.go             ToView + HydrateViewer (viewerSet)
//	home and user timelines    timeline/service.go         ToView + HydrateViewer (every tab shares the page builder)
//	SearchPosts                search/service_posts.go     ToView + HydrateViewer
//	ListBookmarks              engagement/server_bookmarks.go (ToView) with service_bookmarks_list.go (HydrateViewer)
//	ListLikedPosts (W3-10)     engagement/server_likes_list.go (ToView) with service_likes_list.go (HydrateViewer)
//	CreatePost                 posts/server.go             ToProtoForViewer: the caller is the author, so the author rule applies
//	VotePoll (W6-7)            engagement/server_polls.go   ToView with the voter's set (service_polls.go builds it: the choice comes from the vote just made)
//
// Plain ToProto has no viewer and hides every count even from the author, so no production code may call it.

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

// pollProducerCalls maps each producer file to the calls it must make (ToView builds the view, HydrateViewer fills the set).
var pollProducerCalls = map[string][]string{
	"posts/server.go":                      {"ToView", "HydrateViewer", "ToProtoForViewer"},
	"timeline/service.go":                  {"ToView", "HydrateViewer"},
	"search/service_posts.go":              {"ToView", "HydrateViewer"},
	"engagement/server_bookmarks.go":       {"ToView"},
	"engagement/service_bookmarks_list.go": {"HydrateViewer"},
	"engagement/server_polls.go":           {"ToView"},
	"engagement/server_likes_list.go":      {"ToView"},
	"engagement/service_likes_list.go":     {"HydrateViewer"},
}

// pollBuilders are the files allowed to build the wire shapes themselves, with why.
var pollBuilders = map[string]string{
	"posts/convert.go": "the converter",
	"posts/server.go":  "CreatePost wraps ToProtoForViewer in a PostView: the caller is the author (counts visible), nothing to hydrate",
}

type pollFinding struct{ File, Msg string }

// scanPollProducers returns the findings for the non-test Go files under root (slash paths relative to it).
func scanPollProducers(t *testing.T, root string, files map[string]string) []pollFinding {
	t.Helper()
	var out []pollFinding
	calls := map[string]map[string]bool{}
	for rel, src := range files {
		f, err := parser.ParseFile(token.NewFileSet(), rel, src, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", rel, err)
		}
		pkg := f.Name.Name
		_, builder := pollBuilders[rel]
		seen := map[string]bool{}
		calls[rel] = seen
		ast.Inspect(f, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.CompositeLit:
				if sel, ok := x.Type.(*ast.SelectorExpr); ok && !builder {
					switch sel.Sel.Name {
					case "PostView", "Poll", "PollChoice":
						if id, ok := sel.X.(*ast.Ident); ok && id.Name == "postsv1" {
							out = append(out, pollFinding{rel, "builds postsv1." + sel.Sel.Name + " itself; go through posts.ToView"})
						}
					}
				}
			case *ast.CallExpr:
				name, qual := "", ""
				switch fn := x.Fun.(type) {
				case *ast.Ident:
					name = fn.Name
				case *ast.SelectorExpr:
					name = fn.Sel.Name
					if id, ok := fn.X.(*ast.Ident); ok {
						qual = id.Name
					}
				}
				seen[name] = true
				plain := name == "ToProto" && (qual == "posts" || (qual == "" && pkg == "posts"))
				if plain && rel != "posts/convert.go" {
					out = append(out, pollFinding{rel, "calls plain posts.ToProto, which hides every poll count even from the author"})
				}
				if name == "ToProtoForViewer" && !builder {
					out = append(out, pollFinding{rel, "calls ToProtoForViewer outside the allowlisted CreatePost"})
				}
			}
			return true
		})
	}
	for rel, want := range pollProducerCalls {
		src, ok := files[rel]
		if !ok {
			out = append(out, pollFinding{rel, "named producer file is missing; update pollProducerCalls"})
			continue
		}
		_ = src
		for _, c := range want {
			if !calls[rel][c] {
				out = append(out, pollFinding{rel, "no longer calls " + c + " (the producer bypasses the converter or moved; update the guard)"})
			}
		}
	}
	for rel := range pollBuilders {
		if _, ok := files[rel]; !ok {
			out = append(out, pollFinding{rel, "allowlisted builder is missing; update pollBuilders"})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].File+out[i].Msg < out[j].File+out[j].Msg })
	return out
}

func TestPollConverterGuard_Repo(t *testing.T) {
	t.Parallel()
	root := ".." // backend/internal
	files := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		files[filepath.ToSlash(strings.TrimPrefix(filepath.ToSlash(p), "../"))] = string(b)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range scanPollProducers(t, root, files) {
		t.Errorf("%s: %s", f.File, f.Msg)
	}
}

// The self-tests prove each rule fires on a synthetic violation and stays quiet on the clean shape.
func TestPollConverterGuard_SelfTest(t *testing.T) {
	t.Parallel()
	clean := map[string]string{}
	for rel, calls := range pollProducerCalls {
		pkg := filepath.Base(filepath.Dir(rel))
		body := "package " + pkg + "\nfunc f() {\n"
		for _, c := range calls {
			body += "\tx." + c + "()\n"
		}
		clean[rel] = body + "}\n"
	}
	clean["posts/convert.go"] = "package posts\nfunc f() { _ = ToProto(nil); _ = &postsv1.PostView{} }\n"
	if got := scanPollProducers(t, "", clean); len(got) != 0 {
		t.Fatalf("clean shape flagged: %v", got)
	}
	bad := func(rel, src string) map[string]string {
		m := map[string]string{}
		for k, v := range clean {
			m[k] = v
		}
		m[rel] = src
		return m
	}
	tests := []struct {
		name string
		in   map[string]string
	}{
		{"PostView literal in a new producer", bad("lists/x.go", "package lists\nfunc f() { _ = &postsv1.PostView{} }\n")},
		{"Poll literal outside the converter", bad("lists/x.go", "package lists\nfunc f() { _ = &postsv1.Poll{} }\n")},
		{"plain ToProto from another package", bad("lists/x.go", "package lists\nfunc f() { _ = posts.ToProto(nil) }\n")},
		{"plain ToProto inside posts", bad("posts/other.go", "package posts\nfunc f() { _ = ToProto(nil) }\n")},
		{"ToProtoForViewer elsewhere", bad("lists/x.go", "package lists\nfunc f() { _ = posts.ToProtoForViewer(nil, \"\") }\n")},
		{"producer stops calling ToView", bad("timeline/service.go", "package timeline\nfunc f() { x.HydrateViewer() }\n")},
		{"producer stops hydrating", bad("search/service_posts.go", "package search\nfunc f() { x.ToView() }\n")},
	}
	for _, tt := range tests {
		if got := scanPollProducers(t, "", tt.in); len(got) == 0 {
			t.Errorf("%s: not flagged", tt.name)
		}
	}
	// A same-named ToProto in another package (notifications) is a different function.
	if got := scanPollProducers(t, "", bad("notifications/server.go", "package notifications\nfunc f() { _ = ToProto(n) }\n")); len(got) != 0 {
		t.Errorf("notifications.ToProto flagged: %v", got)
	}
}
