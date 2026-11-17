package publicid

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// pairs is the fixed uid -> public id table of the interceptor tests: users 1-5 have an id, user 9 does not.
func icPairs() map[string]string {
	out := map[string]string{}
	for i := 1; i <= 5; i++ {
		out[uidN(i)] = pubN(i)
	}
	return out
}

func on(context.Context) bool  { return true }
func off(context.Context) bool { return false }

// statsRec captures what the interceptor records.
type statsRec struct {
	n    int
	last Stats
}

func (r *statsRec) record(_ context.Context, s Stats) { r.n++; r.last = s }

func newIC(t testing.TB, res Resolver, enabled func(context.Context) bool, rec *statsRec) connect.UnaryInterceptorFunc {
	t.Helper()
	tr, err := NewTranslator(realPlans(t), res, canonicalValid, 500)
	if err != nil {
		t.Fatal(err)
	}
	var record func(context.Context, Stats)
	if rec != nil {
		record = rec.record
	}
	ic, err := NewInterceptor(tr, enabled, record)
	if err != nil {
		t.Fatal(err)
	}
	return ic
}

// userTimeline is a GetUserTimeline response from the handler: two posts by users 2 and 9 (no public id), user 2
// mentioning user 3.
func userTimeline() *timelinev1.GetUserTimelineResponse {
	return &timelinev1.GetUserTimelineResponse{NextPageToken: "tok", Posts: []*postsv1.PostView{
		{Post: &postsv1.Post{PostId: "1", Author: snapshot(uidN(2)), Mentions: []*postsv1.Mention{{UserId: uidN(3)}}}},
		{Post: &postsv1.Post{PostId: "2", Author: snapshot(uidN(9))}},
	}}
}

func marshal(t testing.TB, m proto.Message) string {
	t.Helper()
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func wantInternal(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeInternal || ae.Message != "internal error" || len(ae.Metadata) != 0 {
		t.Fatalf("err = %v (%T), want the generic Internal *apierr.Error", err, err)
	}
	if errors.Unwrap(err) == nil {
		t.Error("Internal error carries no cause for ErrorMapping to report")
	}
}

// TestInterceptor_FlagOffIsByteIdentical: off for the caller (and globally off: a nil Enabled) the request and the
// response reach the handler and the client exactly as they were, with no resolver call and nothing recorded.
func TestInterceptor_FlagOffIsByteIdentical(t *testing.T) {
	for name, enabled := range map[string]func(context.Context) bool{"off for the caller": off, "globally off": nil} {
		t.Run(name, func(t *testing.T) {
			res := newFakeResolver(icPairs())
			rec := &statsRec{}
			ic := newIC(t, res, enabled, rec)
			req := connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: uidN(1), PageSize: 20})
			reqBefore := marshal(t, req.Msg)
			resp := connect.NewResponse(userTimeline())
			respBefore := marshal(t, resp.Msg)
			called := 0
			got, err := ic(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				called++
				if marshal(t, r.Any().(proto.Message)) != reqBefore {
					t.Error("the handler saw a changed request")
				}
				return resp, nil
			})(context.Background(), req)
			if err != nil || called != 1 || got != connect.AnyResponse(resp) {
				t.Fatalf("got (%v, %v), handler calls %d", got, err, called)
			}
			if marshal(t, resp.Msg) != respBefore || marshal(t, req.Msg) != reqBefore {
				t.Error("a message changed with the flag off")
			}
			if len(res.calls) != 0 || rec.n != 0 {
				t.Errorf("resolver calls %v, records %d; want none", res.calls, rec.n)
			}
		})
	}
}

// TestInterceptor_FlagOffAllocatesNothing: the flag-off path is one call to Enabled and no allocation (both a caller
// outside the cohort and the globally-off identity interceptor).
func TestInterceptor_FlagOffAllocatesNothing(t *testing.T) {
	for name, enabled := range map[string]func(context.Context) bool{"off for the caller": off, "globally off": nil} {
		t.Run(name, func(t *testing.T) {
			res := newFakeResolver(icPairs())
			req := connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: uidN(1)})
			resp := connect.NewResponse(userTimeline())
			h := newIC(t, res, enabled, nil)(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return resp, nil })
			ctx := context.Background()
			if n := testing.AllocsPerRun(200, func() { _, _ = h(ctx, req) }); n != 0 {
				t.Errorf("allocs per call = %v, want 0", n)
			}
		})
	}
}

// TestInterceptor_FlagOnTranslatesBothWays: the handler sees the uid; the client gets public ids, the tombstone for a
// uid with none, and the filled public_id; stats are recorded once on the request's log line.
func TestInterceptor_FlagOnTranslatesBothWays(t *testing.T) {
	res := newFakeResolver(icPairs())
	ic := newIC(t, res, on, nil)
	ctx, info := logger.WithRequestInfo(context.Background())
	req := connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pubN(1), PageSize: 20})
	got, err := ic(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
		if uid := r.Any().(*timelinev1.GetUserTimelineRequest).GetUserId(); uid != uidN(1) {
			t.Errorf("handler saw user_id %q, want uid1", uid)
		}
		return connect.NewResponse(userTimeline()), nil
	})(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	page := got.Any().(*timelinev1.GetUserTimelineResponse)
	a, b := page.GetPosts()[0].GetPost(), page.GetPosts()[1].GetPost()
	if a.GetAuthor().GetUserId() != pubN(2) || a.GetAuthor().GetPublicId() != pubN(2) || a.GetMentions()[0].GetUserId() != pubN(3) {
		t.Errorf("post 1 = %v", a)
	}
	if b.GetAuthor().GetUserId() != Tombstone || b.GetAuthor().GetPublicId() != Tombstone {
		t.Errorf("post 2 author = %v, want the tombstone", b.GetAuthor())
	}
	if len(res.calls) != 2 {
		t.Errorf("resolver calls = %v, want one per direction", res.calls)
	}
	want := map[string]any{LogFieldIDs: int64(4), LogFieldUnmapped: int64(1), LogFieldUnknown: int64(0), LogFieldReads: int64(2)}
	for k, v := range want {
		if got, ok := info.Get(k); !ok || got != v {
			t.Errorf("log field %s = %v (%v), want %v", k, got, ok, v)
		}
	}
}

// TestInterceptor_InboundValidationShortCircuits: a raw uid (an old client) or garbage in a translated field is
// VALIDATION naming the field; the handler never runs and nothing is looked up. "" and the tombstone are not errors.
func TestInterceptor_InboundValidationShortCircuits(t *testing.T) {
	for _, v := range []string{uidN(1), "not-an-id", "U00000000000000000000000001"} {
		res := newFakeResolver(icPairs())
		rec := &statsRec{}
		ic := newIC(t, res, on, rec)
		called := false
		_, err := ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
			called = true
			return nil, nil
		})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: v}))
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "user_id" {
			t.Errorf("%q: err = %v, want VALIDATION field=user_id", v, err)
		}
		if called || len(res.calls) != 0 {
			t.Errorf("%q: handler called %v, resolver calls %v", v, called, res.calls)
		}
	}
	for _, v := range []string{"", Tombstone, pubN(7)} {
		res := newFakeResolver(icPairs())
		ic := newIC(t, res, on, nil)
		var seen string
		_, err := ic(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
			seen = r.Any().(*timelinev1.GetUserTimelineRequest).GetUserId()
			return connect.NewResponse(&timelinev1.GetUserTimelineResponse{}), nil
		})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: v}))
		if err != nil || seen != v {
			t.Errorf("%q: handler saw %q, err %v; want it unchanged", v, seen, err)
		}
	}
}

// codedResolver fails one direction with err.
type codedResolver struct {
	*fakeResolver
	inErr, outErr error
}

func (c codedResolver) UIDsForPublicIDs(ctx context.Context, ids []string) (map[string]string, error) {
	if c.inErr != nil {
		return nil, c.inErr
	}
	return c.fakeResolver.UIDsForPublicIDs(ctx, ids)
}

func (c codedResolver) PublicIDsForUIDs(ctx context.Context, ids []string) (map[string]string, error) {
	if c.outErr != nil {
		return nil, c.outErr
	}
	return c.fakeResolver.PublicIDsForUIDs(ctx, ids)
}

// TestInterceptor_ResolverFailureIsInternal: a lookup failure is the generic Internal (with the cause for ErrorMapping's
// report), whatever error type the resolver returned (an apierr NOT_FOUND or a connect error must not lend its code).
// Inbound the handler does not run; outbound the untranslated response is never returned.
func TestInterceptor_ResolverFailureIsInternal(t *testing.T) {
	causes := map[string]error{
		"plain":   errResolver,
		"apierr":  apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "nope"),
		"connect": connect.NewError(connect.CodePermissionDenied, errors.New("nope")),
	}
	for name, cause := range causes {
		t.Run("inbound "+name, func(t *testing.T) {
			ic := newIC(t, codedResolver{fakeResolver: newFakeResolver(icPairs()), inErr: cause}, on, nil)
			called := false
			resp, err := ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
				called = true
				return nil, nil
			})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pubN(1)}))
			wantInternal(t, err)
			if called || resp != nil {
				t.Errorf("handler called %v, resp %v", called, resp)
			}
		})
		t.Run("outbound "+name, func(t *testing.T) {
			rec := &statsRec{}
			ic := newIC(t, codedResolver{fakeResolver: newFakeResolver(icPairs()), outErr: cause}, on, rec)
			page := userTimeline()
			before := marshal(t, page)
			resp, err := ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
				return connect.NewResponse(page), nil
			})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{}))
			wantInternal(t, err)
			if resp != nil {
				t.Errorf("resp = %v, want nil: never the untranslated page", resp)
			}
			if marshal(t, page) != before {
				t.Error("a failed walk changed the page")
			}
			if rec.n != 1 || rec.last.ResolverCalls != 1 {
				t.Errorf("records %d, last %+v; want the failed call counted", rec.n, rec.last)
			}
		})
	}
}

// TestInterceptor_HandlerErrorPassesThrough: the handler's error (and its response value) come back untouched, the
// response is not walked, and the request's stats are still recorded.
func TestInterceptor_HandlerErrorPassesThrough(t *testing.T) {
	res := newFakeResolver(icPairs())
	rec := &statsRec{}
	ic := newIC(t, res, on, rec)
	herr := apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "not found")
	_, err := ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		return nil, herr
	})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pubN(1)}))
	if err != herr { // the very value, not an equivalent one
		t.Fatalf("err = %v, want the handler's own error value", err)
	}
	if len(res.calls) != 1 || rec.n != 1 || rec.last != (Stats{InboundIDs: 1, ResolverCalls: 1}) {
		t.Errorf("resolver calls %v, records %d %+v", res.calls, rec.n, rec.last)
	}
}

// TestInterceptor_NilPlanAndUnplanned: a message pair with no user reference passes through untouched with no lookup
// (stats recorded as zeros); a message type that was never planned fails closed as Internal before the handler.
func TestInterceptor_NilPlanAndUnplanned(t *testing.T) {
	res := newFakeResolver(icPairs())
	rec := &statsRec{}
	ic := newIC(t, res, on, rec)
	req := connect.NewRequest(&postsv1.DeletePostRequest{PostId: "1", IdempotencyKey: "k"})
	resp := connect.NewResponse(&postsv1.DeletePostResponse{})
	got, err := ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return resp, nil })(context.Background(), req)
	if err != nil || got != connect.AnyResponse(resp) || len(res.calls) != 0 || rec.n != 1 || rec.last != (Stats{}) {
		t.Errorf("nil plan: (%v, %v), calls %v, records %d %+v", got, err, res.calls, rec.n, rec.last)
	}

	called := false
	_, err = ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		called = true
		return nil, nil
	})(context.Background(), connect.NewRequest(&emptypb.Empty{}))
	wantInternal(t, err)
	if called || !errors.Is(err, ErrNoPlan) {
		t.Errorf("unplanned request: handler called %v, err %v", called, err)
	}
	_, err = ic(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		return connect.NewResponse(&emptypb.Empty{}), nil
	})(context.Background(), connect.NewRequest(&postsv1.DeletePostRequest{}))
	wantInternal(t, err)
}

// TestInterceptor_EchoesUnknownInboundID: an unknown public id the handler echoes goes back unchanged (not tombstoned).
func TestInterceptor_EchoesUnknownInboundID(t *testing.T) {
	ic := newIC(t, newFakeResolver(icPairs()), on, nil)
	got, err := ic(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
		id := r.Any().(*timelinev1.GetUserTimelineRequest).GetUserId()
		return connect.NewResponse(&timelinev1.GetUserTimelineResponse{Posts: []*postsv1.PostView{{Post: &postsv1.Post{Author: &commonv1.AuthorSnapshot{UserId: id}}}}}), nil
	})(context.Background(), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pubN(8)}))
	if err != nil {
		t.Fatal(err)
	}
	if a := got.Any().(*timelinev1.GetUserTimelineResponse).GetPosts()[0].GetPost().GetAuthor(); a.GetUserId() != pubN(8) || a.GetPublicId() != pubN(8) {
		t.Errorf("echoed author = %v, want pub8 in both fields", a)
	}
}

func TestNewInterceptor_NilTranslator(t *testing.T) {
	if _, err := NewInterceptor(nil, on, nil); err == nil {
		t.Fatal("want an error")
	}
}

// TestRecordStats_NoRequestInfo: recording without a request log line is a no-op, never a panic.
func TestRecordStats_NoRequestInfo(t *testing.T) {
	RecordStats(context.Background(), Stats{InboundIDs: 1})
}
