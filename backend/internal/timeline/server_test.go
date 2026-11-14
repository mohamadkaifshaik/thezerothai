package timeline

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

type fakeFlags struct{ on bool }

func (f fakeFlags) Enabled(string, string) bool { return f.on }

func ctxFor(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

// TestServer_RPCsAreBehindTheFlag: off => FEATURE_DISABLED without touching storage (the enabled paths are in service_test.go).
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
			ctx := ctxFor("u1")
			err := call(NewServer(Deps{Flags: fakeFlags{}}), ctx)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("err = %#v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
			}
		})
	}
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// TestImports_OnlySeamsOfPostsGraphIdentity is the handoff import lint: timeline reads posts
// through posts.Reader and the social context through graph.Reader, never another module's package (and so
// never a repo or a collection). Test files are included so a test cannot smuggle in a repo either.
func TestImports_OnlySeamsOfPostsGraphIdentity(t *testing.T) {
	const internalPrefix = "github.com/dzeroth/dzeroth/backend/internal/"
	allowed := map[string]bool{"posts": true, "graph": true, "identity": true, "lists": true, "communities": true}

	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob: %v (%d files)", err, len(files))
	}
	// The only identifiers timeline may use from those packages: the read seams and their value types, never a
	// repo, a cache constructor or a Firestore-backed type (L1: importing the package alone is not enough).
	allowedSel := map[string]map[string]bool{
		"posts": {
			// Article profile feed uses the optional read seam and preview value;
			// moderation value is used by canonical visibility fixtures.
			"ArticleReader": true, "ArticlePreview": true, "ModerationTakenDown": true,
			"Reader": true, "Removals": true, "RemovalLag": true, "RemovalScope": true, "Window": true, "Position": true, "Post": true, "Recent": true, "Mention": true,
			"AuthorSnapshot": true, "Embedded": true, "Kind": true, "Visibility": true, "ErrNotFound": true, "ErrInvalidID": true,
			"FlagChecker": true, "GuardFeature": true, "FlagName": true, "ToProto": true,
			"MaxGetMany": true, "MaxByAuthors": true, "MaxLimit": true, "MaxRecent": true,
			"KindPost": true, "KindReply": true, "KindQuote": true, "KindRepost": true,
			"VisibilityPublic": true, "VisibilityFollowers": true,
			// The author-status rule (F-03) every feed shares with GetPost and search.
			"AuthorDirectory": true, "ResolveActiveAuthors": true, "AuthorDrop": true, "AuthorTombstone": true, "TombstonedQuote": true,
			// Viewer flags are posts' ViewerFlags seam; ToView renders them.
			"ViewerFlags": true, "ViewerSet": true, "ToView": true, "Audience": true, "NewSnapshotAudience": true, "SurfaceDirect": true, "SurfaceOwnProfile": true, "Surface": true, "Show": true, "ApplyEmbedState": true, "ApplyWireVisibility": true, "ApplyPublicViews": true, "EngagementFlagName": true, "BookmarksFlagName": true, "HydrateViewer": true, "Poll": true, "BeaconPlans": true, "BeaconLive": true, "HydrateBeacons": true, "PostBeaconFlagName": true,
		},
		"graph": {"Reader": true, "Snapshot": true},
		// lists: the Reader seam, its value type, the flag gate and the three exports GetListTimeline shares with GetList.
		"lists": {"Header": true, "Reader": true, "ListMembers": true, "FlagName": true, "ListView": true, "List": true, "Guard": true, "FlagChecker": true, "ErrNotFound": true, "NotFoundError": true, "ValidateListID": true, "MembersInfo": true, "FollowFlagName": true},
		// communities: the flag gate, its checker seam and the Reader GetCommunityTimeline reads.
		"communities": {"FlagName": true, "Guard": true, "FlagChecker": true,
			// The Reader seam and its value types, the NOT_FOUND and id checks, the header renderer and the roles and statuses the feed reads.
			"Reader": true, "ErrNotFound": true, "NotFoundError": true, "ValidateCommunityID": true, "HeaderProto": true, "Community": true, "Removal": true,
			"Role": true, "RoleOwner": true, "RoleModerator": true, "RoleMember": true, "RoleNone": true, "RoleBanned": true,
			"Status": true, "StatusActive": true, "StatusArchived": true, "StatusSuspended": true},
		// identity: the Directory seam, its Profile value type, the one missing-user error and the uid predicate.
		"identity": {"ProtectedAuthors": true, "ProtectedSet": true, "Directory": true, "Profile": true, "AccountStatusActive": true, "ProfileNotFoundError": true, "ValidUserID": true,
			// The pinned-tab value type and kind, the idempotency sentinel of the store seam.
			"HomeTab": true, "HomeTabKindList": true, "HomeTabKindCommunity": true, "ErrKeyReused": true, "ErrNotFound": true},
	}
	sawAny := false
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		af, err := parser.ParseFile(token.NewFileSet(), f, src, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		local := map[string]string{} // local import name -> module package
		for _, imp := range af.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			rest, ok := strings.CutPrefix(path, internalPrefix)
			if !ok {
				continue
			}
			sawAny = true
			pkg := strings.SplitN(rest, "/", 2)[0]
			if !allowed[pkg] || strings.Contains(rest, "/") {
				t.Errorf("%s imports %s: timeline may import only the posts, graph, identity, lists and communities packages", f, path)
				continue
			}
			name := pkg
			if imp.Name != nil {
				name = imp.Name.Name
			}
			local[name] = pkg
		}
		ast.Inspect(af, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			id, ok := sel.X.(*ast.Ident)
			if !ok {
				return true
			}
			if pkg, ok := local[id.Name]; ok && !allowedSel[pkg][sel.Sel.Name] {
				t.Errorf("%s uses %s.%s: timeline may use only %v from %s", f, id.Name, sel.Sel.Name, keys(allowedSel[pkg]), pkg)
			}
			return true
		})
	}
	if !sawAny {
		t.Fatal("timeline imports neither posts nor graph; the import lint is not testing anything")
	}
}
