package apiserver

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/known/emptypb"
)

// These tests keep the route table (routes.go) the only way to serve a route, and prove each class is protected.

// rejectingInterceptor stands in for the real chain: any call that reaches the handler through it is refused.
func rejectingInterceptor() connect.HandlerOption {
	return connect.WithInterceptors(connect.UnaryInterceptorFunc(func(connect.UnaryFunc) connect.UnaryFunc {
		return func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("chain ran"))
		}
	}))
}

func denyInternal(http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "unauthorized", http.StatusUnauthorized) })
}

// A Connect service registered through the table cannot run without the interceptor chain: the table, not the
// caller, supplies it.
func TestRouteTable_ConnectAlwaysRunsTheInterceptorChain(t *testing.T) {
	var reached atomic.Bool
	rt := newRouteTable(rejectingInterceptor(), denyInternal)
	rt.connect(func(opts ...connect.HandlerOption) (string, http.Handler) {
		const proc = "/test.v1.Probe/Do"
		return proc, connect.NewUnaryHandler(proc, func(context.Context, *connect.Request[emptypb.Empty]) (*connect.Response[emptypb.Empty], error) {
			reached.Store(true)
			return connect.NewResponse(&emptypb.Empty{}), nil
		}, opts...)
	})

	req := httptest.NewRequest(http.MethodPost, "/test.v1.Probe/Do", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	rt.mux.ServeHTTP(rec, req)

	if reached.Load() {
		t.Fatal("the handler ran although the interceptor chain rejects every call")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 from the interceptor", rec.Code)
	}
	if got := rt.records; len(got) != 1 || got[0].class != routeConnect || got[0].pattern != "/test.v1.Probe/Do" {
		t.Fatalf("records = %+v, want one connect route /test.v1.Probe/Do", got)
	}
}

// An /internal/* handler registered through the table cannot run without the OIDC wrapper.
func TestRouteTable_InternalIsAlwaysWrapped(t *testing.T) {
	var reached atomic.Bool
	rt := newRouteTable(rejectingInterceptor(), denyInternal)
	rt.internal("/internal/jobs", http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached.Store(true) }))

	rec := httptest.NewRecorder()
	rt.mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/jobs", nil))

	if reached.Load() || rec.Code != http.StatusUnauthorized {
		t.Fatalf("handler reached = %v, status = %d; want the wrapper to answer 401 first", reached.Load(), rec.Code)
	}
}

// Only the allowlisted patterns can be public, and the allowlist itself is pinned here so a change is a visible diff.
func TestRouteTable_PublicIsAllowlisted(t *testing.T) {
	if got := sortedRouteKeys(publicRoutes); !slices.Equal(got, []string{"/health", "/healthz"}) {
		t.Fatalf("publicRoutes = %v; adding a public route needs a security review and an update of this test", got)
	}
	for pattern, why := range publicRoutes {
		if strings.TrimSpace(why) == "" {
			t.Errorf("public route %q has no stated reason", pattern)
		}
	}

	rt := newRouteTable(rejectingInterceptor(), denyInternal)
	rt.public("/health", http.NotFoundHandler()) // allowed

	defer func() {
		if recover() == nil {
			t.Fatal("registering a non-allowlisted public route did not panic")
		}
	}()
	rt.public("/admin", http.NotFoundHandler())
}

func sortedRouteKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// No file in this package other than routes.go may create a ServeMux or use net/http's registration functions, so
// nothing can bypass the route table. (Method calls such as media.Handle(ctx, data) are unrelated and not matched:
// only the net/http package-level names are.)
func TestRoutes_NoSideDoorAroundTheTable(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	banned := map[string]bool{"NewServeMux": true, "Handle": true, "HandleFunc": true, "DefaultServeMux": true}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") || file == "routes.go" {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		httpName := "http"
		for _, imp := range f.Imports {
			if imp.Path.Value == `"net/http"` && imp.Name != nil {
				httpName = imp.Name.Name
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok || !banned[sel.Sel.Name] {
				return true
			}
			if id, ok := sel.X.(*ast.Ident); ok && id.Name == httpName {
				t.Errorf("%s uses http.%s: register routes through routeTable (routes.go) instead", file, sel.Sel.Name)
			}
			return true
		})
	}
}

// The interceptor chain is unary-only (connect.UnaryInterceptorFunc), so a streaming RPC would be served without App
// Check, ID token verification, rate limiting or account-status checks. Until stream interceptors exist, no linked
// dzeroth service may declare one.
func TestLinkedServices_AreAllUnary(t *testing.T) {
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if !strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			return true
		}
		for i := 0; i < fd.Services().Len(); i++ {
			svc := fd.Services().Get(i)
			for j := 0; j < svc.Methods().Len(); j++ {
				m := svc.Methods().Get(j)
				if m.IsStreamingClient() || m.IsStreamingServer() {
					t.Errorf("%s/%s is a streaming RPC: the interceptor chain is unary-only, so it would bypass authentication. Add stream interceptors first", svc.FullName(), m.Name())
				}
			}
		}
		return true
	})
}
