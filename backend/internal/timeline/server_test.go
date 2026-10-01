package timeline

import (
	"context"
	"errors"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

type fakeFlags struct{ on bool }

func (f fakeFlags) Enabled(string, string) bool { return f.on }

func ctxFor(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

// TestServer_RPCsAreBehindTheFlag: off => FEATURE_DISABLED with 0 reads; on => Unimplemented until T12/T13.
func TestServer_RPCsAreBehindTheFlag(t *testing.T) {
	calls := map[string]func(*Server, context.Context) error{
		"GetHomeTimeline": func(s *Server, ctx context.Context) error {
			_, err := s.GetHomeTimeline(ctx, connect.NewRequest(&timelinev1.GetHomeTimelineRequest{}))
			return err
		},
		"GetUserTimeline": func(s *Server, ctx context.Context) error {
			_, err := s.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{}))
			return err
		},
	}
	for name, call := range calls {
		t.Run(name+" flag off", func(t *testing.T) {
			ctx, counter := budget.WithCounter(ctxFor("u1"))
			err := call(NewServer(Deps{Flags: fakeFlags{}}), ctx)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("err = %#v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
			}
			if counter.Reads() != 0 {
				t.Fatalf("a disabled call read %d docs", counter.Reads())
			}
		})
		t.Run(name+" flag on", func(t *testing.T) {
			err := call(NewServer(Deps{Flags: fakeFlags{on: true}}), ctxFor("u1"))
			if connect.CodeOf(err) != connect.CodeUnimplemented {
				t.Fatalf("err = %v, want UNIMPLEMENTED", err)
			}
		})
	}
}

// TestImports_OnlyPostsAndGraphAmongInternalModules is the ADR-0004 handoff import lint: timeline reads posts
// through posts.Reader and the social context through graph.Reader, never another module's package (and so
// never a repo or a collection). Test files are included so a test cannot smuggle in a repo either.
func TestImports_OnlyPostsAndGraphAmongInternalModules(t *testing.T) {
	const internalPrefix = "github.com/dzeroth/dzeroth/backend/internal/"
	allowed := map[string]bool{"posts": true, "graph": true}

	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob: %v (%d files)", err, len(files))
	}
	sawAny := false
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		af, err := parser.ParseFile(token.NewFileSet(), f, src, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		for _, imp := range af.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			if rest, ok := strings.CutPrefix(path, internalPrefix); ok {
				sawAny = true
				if !allowed[strings.SplitN(rest, "/", 2)[0]] || strings.Contains(rest, "/") {
					t.Errorf("%s imports %s: timeline may import only the posts and graph packages", f, path)
				}
			}
		}
	}
	if !sawAny {
		t.Fatal("timeline imports neither posts nor graph; the import lint is not testing anything")
	}
}
