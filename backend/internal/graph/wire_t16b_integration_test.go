//go:build integration

// wire_t16b_integration_test.go (T16b) is a scenario-specific rig: the real generated Connect handlers for
// identity + graph, served from an httptest.Server over the already-wired services, with the interceptor
// order that matters for these tests (caller uid -> budget counter -> daily list cap -> error mapping). It
// exists so T16b can assert on serialized wire bytes (byte-identical NOT_FOUND, no `blockedBy` in any JSON
// response) and on the interceptor-level list cap. It seeds nothing.
package graph_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

const testUIDHeader = "X-Test-Uid"

// t16bKey returns a valid idempotency key (16-64 chars of [A-Za-z0-9_-]) unique per n.
func t16bKey(n int) string { return fmt.Sprintf("t16b-key-%010d", n) }

type recordedResp struct {
	Path   string
	Status int
	CType  string
	Body   []byte
}

// recorder is an http.RoundTripper that keeps every response body (Connect JSON, errors included).
type recorder struct {
	next http.RoundTripper
	mu   sync.Mutex
	all  []recordedResp
}

func (r *recorder) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := r.next.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	body, rerr := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if rerr != nil {
		return nil, rerr
	}
	r.mu.Lock()
	r.all = append(r.all, recordedResp{Path: req.URL.Path, Status: resp.StatusCode, CType: resp.Header.Get("Content-Type"), Body: body})
	r.mu.Unlock()
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return resp, nil
}

func (r *recorder) last() recordedResp {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.all[len(r.all)-1]
}

func (r *recorder) allBodies() []recordedResp {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]recordedResp(nil), r.all...)
}

type rig struct {
	w   wired
	srv *httptest.Server
	rec *recorder

	mu      sync.Mutex
	counter *budget.Counter // Firestore ops of the most recent server-side call

	// errLog captures what mw.ErrorMapping logs (JSON lines; INTERNAL errors are logged at ERROR).
	errLog *syncBuffer
}

// syncBuffer is a goroutine-safe bytes.Buffer for the server-side log capture.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// errorLines returns the captured log lines at ERROR severity.
func (r *rig) errorLines() []string {
	var out []string
	for _, l := range strings.Split(r.errLog.String(), "\n") {
		if strings.Contains(l, `"level":"ERROR"`) {
			out = append(out, l)
		}
	}
	return out
}

// newRig serves the wired services over HTTP. listDailyCap <= 0 disables the daily list cap.
func newRig(t *testing.T, w wired, listDailyCap int64) *rig {
	t.Helper()
	return newRigWithMutationCap(t, w, listDailyCap, 0)
}

// newRigWithMutationCap is newRig plus the shared graph_mutation_daily cap over the six graph mutations,
// wired exactly like apiserver.Build does. mutationDailyCap <= 0 disables it.
// mods adjust the ratelimit.Config last (e.g. to enable the ADR-0010 read budget).
func newRigWithMutationCap(t *testing.T, w wired, listDailyCap, mutationDailyCap int64, mods ...func(*ratelimit.Config)) *rig {
	t.Helper()
	r := &rig{w: w, errLog: &syncBuffer{}}

	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx = authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get(testUIDHeader)})
			return next(ctx, req)
		}
	})
	count := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx, c := budget.WithCounter(ctx)
			r.mu.Lock()
			r.counter = c
			r.mu.Unlock()
			return next(ctx, req)
		}
	})
	rl := ratelimit.Config{}
	if listDailyCap > 0 {
		dc := ratelimit.NewDailyCap(listDailyCap)
		rl.DailyCaps = map[string]ratelimit.NamedDailyCap{}
		for _, p := range []string{
			graphv1connect.GraphServiceListFollowersProcedure,
			graphv1connect.GraphServiceListFollowingProcedure,
			graphv1connect.GraphServiceListBlockedUsersProcedure,
			graphv1connect.GraphServiceListMutedUsersProcedure,
		} {
			rl.DailyCaps[p] = ratelimit.NamedDailyCap{Name: "graph_list_daily", Cap: dc}
		}
	}
	if mutationDailyCap > 0 {
		mc := ratelimit.NewDailyCap(mutationDailyCap)
		if rl.DailyCaps == nil {
			rl.DailyCaps = map[string]ratelimit.NamedDailyCap{}
		}
		for _, p := range []string{
			graphv1connect.GraphServiceFollowProcedure,
			graphv1connect.GraphServiceUnfollowProcedure,
			graphv1connect.GraphServiceBlockProcedure,
			graphv1connect.GraphServiceUnblockProcedure,
			graphv1connect.GraphServiceMuteProcedure,
			graphv1connect.GraphServiceUnmuteProcedure,
		} {
			rl.DailyCaps[p] = ratelimit.NamedDailyCap{Name: "graph_mutation_daily", Cap: mc}
		}
	}
	for _, mod := range mods {
		mod(&rl)
	}
	opts := connect.WithInterceptors(setUID, count, ratelimit.Interceptor(rl), mw.ErrorMapping(slog.New(slog.NewJSONHandler(r.errLog, nil))))

	mux := http.NewServeMux()
	idPath, idH := identityv1connect.NewIdentityServiceHandler(identity.NewServer(w.identity), opts)
	mux.Handle(idPath, idH)
	gPath, gH := graphv1connect.NewGraphServiceHandler(graph.NewServer(w.graph.Service), opts)
	mux.Handle(gPath, gH)
	r.srv = httptest.NewServer(mux)
	t.Cleanup(r.srv.Close)
	r.rec = &recorder{next: http.DefaultTransport}
	return r
}

// lastOps returns the Firestore op counter of the most recent request handled by the server.
func (r *rig) lastOps() *budget.Counter {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.counter
}

// caller is a pair of generated Connect (JSON) clients acting as one uid.
type caller struct {
	uid   string
	graph graphv1connect.GraphServiceClient
	id    identityv1connect.IdentityServiceClient
}

func (r *rig) as(uid string) caller {
	hc := &http.Client{Transport: r.rec}
	withUID := connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			req.Header().Set(testUIDHeader, uid)
			return next(ctx, req)
		}
	}))
	return caller{
		uid:   uid,
		graph: graphv1connect.NewGraphServiceClient(hc, r.srv.URL, connect.WithProtoJSON(), withUID),
		id:    identityv1connect.NewIdentityServiceClient(hc, r.srv.URL, connect.WithProtoJSON(), withUID),
	}
}

// errInfo is the decoded Connect error: code plus the common.v1.ErrorDetail.
type errInfo struct {
	Code   connect.Code
	Msg    string
	Reason commonv1.ErrorReason
	Meta   map[string]string
	// DetailBytes are the raw serialized details (type + value), for byte-identity comparisons.
	DetailBytes [][]byte
}

func decodeErr(t *testing.T, err error) errInfo {
	t.Helper()
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("error %v (%T) is not a *connect.Error", err, err)
	}
	info := errInfo{Code: ce.Code(), Msg: ce.Message()}
	for _, d := range ce.Details() {
		info.DetailBytes = append(info.DetailBytes, append([]byte(d.Type()+"|"), d.Bytes()...))
		v, verr := d.Value()
		if verr != nil {
			t.Fatalf("detail value: %v", verr)
		}
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			info.Reason, info.Meta = ed.GetReason(), ed.GetMetadata()
		}
	}
	return info
}

// outcomeOf names an RPC result for the visibility matrix: ok | not_found | target_blocked | <code>/<reason>.
func outcomeOf(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		return "ok"
	}
	e := decodeErr(t, err)
	switch {
	case e.Code == connect.CodeNotFound:
		return "not_found"
	case e.Code == connect.CodeFailedPrecondition && e.Reason == commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED:
		return "target_blocked"
	}
	return fmt.Sprintf("%v/%v", e.Code, e.Reason)
}
