package apiserver

import (
	"fmt"
	"net/http"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// Secure by default: every route this process serves is registered through a routeTable, and the table offers only
// three ways in, one per protection class. There is no way to hand it a bare handler.
//
//	connect   a generated Connect service. The full interceptor chain (ADR-0006 §2: logging, recover, App Check, ID
//	          token, verified identity, rate limit, degraded mode, account status, error mapping) and the decompressed
//	          read cap are applied by the table, so a new service cannot be registered without them.
//	internal  a Pub/Sub push or Scheduler endpoint behind the OIDC verifier (outside ENV=local the verifier is always
//	          configured: config.Load fails closed, M8).
//	public    served with no authentication. Only the patterns in publicRoutes are accepted; any other pattern panics at
//	          startup, so adding a public route means editing this file and getting it reviewed.
//
// routes_guard_test.go keeps it that way: no file in this package except this one may create a ServeMux or call the
// net/http registration functions, so there is no side door around the table.

// publicRoutes is the complete list of routes served without authentication, each with the reason it is safe.
var publicRoutes = map[string]string{
	"/health":  "Cloud Run startup/liveness probe; returns a fixed body and touches no data",
	"/healthz": "alias of /health for tooling that expects it (*.run.app reserves paths ending in z, so only in-container callers use it)",
}

// routeClass is how a registered route is protected.
type routeClass string

const (
	routeConnect  routeClass = "connect"
	routeInternal routeClass = "internal"
	routePublic   routeClass = "public"
)

// routeRecord is one registered route, kept so tests can assert on the whole table.
type routeRecord struct {
	pattern string
	class   routeClass
}

// routeTable owns the process's ServeMux. Nothing outside this file holds the mux, so every registration goes
// through one of the three methods below.
type routeTable struct {
	mux             *http.ServeMux
	connectOpts     []connect.HandlerOption
	protectInternal func(http.Handler) http.Handler
	records         []routeRecord
}

// newRouteTable builds the table. interceptors is the one interceptor chain every Connect service gets;
// protectInternal wraps /internal/* handlers (the OIDC verifier, or the identity function only in ENV=local).
func newRouteTable(interceptors connect.HandlerOption, protectInternal func(http.Handler) http.Handler) *routeTable {
	return &routeTable{
		mux: http.NewServeMux(),
		// connect.WithReadMaxBytes caps the *decompressed* body at the codec layer (a gzip-bomb guard);
		// http.MaxBytesHandler in build caps the raw bytes before it.
		connectOpts:     []connect.HandlerOption{interceptors, connect.WithReadMaxBytes(limits.MaxRequestBytes)},
		protectInternal: protectInternal,
	}
}

// connect registers a generated Connect service. newHandler is the generated constructor with its service bound, for
// example:
//
//	rt.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
//		return postsv1connect.NewPostServiceHandler(server, o...)
//	})
func (t *routeTable) connect(newHandler func(opts ...connect.HandlerOption) (string, http.Handler)) {
	path, h := newHandler(t.connectOpts...)
	t.add(path, h, routeConnect)
}

// internal registers an /internal/* endpoint behind the OIDC verifier.
func (t *routeTable) internal(pattern string, h http.Handler) {
	t.add(pattern, t.protectInternal(h), routeInternal)
}

// public registers an unauthenticated route. The pattern must be in publicRoutes.
func (t *routeTable) public(pattern string, h http.Handler) {
	if _, ok := publicRoutes[pattern]; !ok {
		panic(fmt.Sprintf("apiserver: %q is not an allowed public route (see publicRoutes)", pattern))
	}
	t.add(pattern, h, routePublic)
}

func (t *routeTable) add(pattern string, h http.Handler, class routeClass) {
	t.mux.Handle(pattern, h)
	t.records = append(t.records, routeRecord{pattern: pattern, class: class})
}

// apiRoot serves protected at both "/" and "/api/": Firebase Hosting's /api/** rewrite forwards the path unchanged
// (B1), and http.StripPrefix hands the same handler the stripped path, so every route answers under both.
func apiRoot(protected http.Handler) http.Handler {
	root := http.NewServeMux()
	root.Handle("/", protected)
	root.Handle("/api/", http.StripPrefix("/api", protected))
	return root
}
