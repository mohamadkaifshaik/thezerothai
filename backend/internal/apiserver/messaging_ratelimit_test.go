package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestMessagingRateLimitWiring (ADR-0027 D13, W7-4): SendMessage has its own bucket and the shared messages_daily cap;
// ListConversations and ListMessages share one read bucket and have no daily cap (reads: the read budget covers them);
// the guard enumeration sees both reads and the budget covers every messaging RPC.
func TestMessagingRateLimitWiring(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())

	send := messagingv1connect.MessagingServiceSendMessageProcedure
	lc := messagingv1connect.MessagingServiceListConversationsProcedure
	lm := messagingv1connect.MessagingServiceListMessagesProcedure

	if rl.PerProcedure[send] == nil {
		t.Error("SendMessage has no per-procedure bucket")
	}
	if rl.PerProcedure[lc] == nil || rl.PerProcedure[lc] != rl.PerProcedure[lm] {
		t.Error("ListConversations and ListMessages must share one read bucket")
	}
	if rl.PerProcedure[send] == rl.PerProcedure[lc] {
		t.Error("the send and read buckets must be separate")
	}
	if named, ok := rl.DailyCaps[send]; !ok || named.Name != "messages_daily" || named.Cap == nil {
		t.Errorf("SendMessage daily cap = %+v, want messages_daily", named)
	}
	for _, p := range []string{lc, lm} {
		if _, ok := rl.DailyCaps[p]; ok {
			t.Errorf("%s must not have a daily call cap (a read: the read budget covers it)", p)
		}
	}

	procs := noSideEffectsProcedures(t)
	for _, p := range []string{lc, lm} {
		if !slices.Contains(procs, p) {
			t.Errorf("guard enumeration does not see %s", p)
		}
	}
	for _, p := range []string{
		send, lc, lm,
		messagingv1connect.MessagingServiceMarkConversationReadProcedure,
		messagingv1connect.MessagingServiceAcceptMessageRequestProcedure,
		messagingv1connect.MessagingServiceDeleteConversationProcedure,
	} {
		if !rl.ReadBudgetCovers(p) {
			t.Errorf("%s is not covered by the daily read budget", p)
		}
	}
}

// TestMessagingReadBucketLimitsPolls (W7-8): the 31st ListMessages call of one user inside a minute is refused by the
// shared read bucket (30/min per instance), and another user's bucket is untouched.
func TestMessagingReadBucketLimitsPolls(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	lim := rl.PerProcedure[messagingv1connect.MessagingServiceListMessagesProcedure]
	for i := 1; i <= 30; i++ {
		if ok, _ := lim.Allow("uid-poller"); !ok {
			t.Fatalf("poll %d refused, want the first 30 allowed", i)
		}
	}
	if ok, retry := lim.Allow("uid-poller"); ok || retry <= 0 {
		t.Errorf("poll 31 = %v retry %v, want refused with a retry-after", ok, retry)
	}
	if ok, _ := lim.Allow("uid-other"); !ok {
		t.Error("another user was refused")
	}
}

// messagingCapInvoker serves the given procedures behind the real rate-limit interceptor (RateLimitConfig(cfg)) with a stub
// handler and returns a caller: invoke(uid, procedure) is nil when the call got through to the handler.
func messagingCapInvoker(t *testing.T, cfg config.Config, procs ...string) func(uid, proc string) error {
	t.Helper()
	cfg.RateLimit.PerUserPerMinute = 1_000_000
	cfg.RateLimit.PerIPPerMinute = 1_000_000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	rl := RateLimitConfig(cfg)
	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range procs {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return func(uid, proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("X-Test-Uid", uid)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
}

// wantCapRefusal: err is RESOURCE_EXHAUSTED with reason RATE_LIMITED and limit=name, the shape every daily cap answers with.
func wantCapRefusal(t *testing.T, err error, name string) {
	t.Helper()
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("err = %v, want ResourceExhausted", err)
	}
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			continue
		}
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			if ed.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED || ed.GetMetadata()["limit"] != name {
				t.Errorf("detail = reason %v limit %q, want RATE_LIMITED limit %q", ed.GetReason(), ed.GetMetadata()["limit"], name)
			}
			return
		}
	}
	t.Errorf("no ErrorDetail on the refusal: %v", err)
}

// TestMessagingDailyCaps (W7-29, security review W7-22 M-1): MarkConversationRead has its own per-uid daily cap
// (messages_mark_read_daily) and AcceptMessageRequest + DeleteConversation share ONE (messages_mutation_daily). Through the
// real interceptor the (cap+1)-th call of a uid is RATE_LIMITED with the cap's name, another uid is untouched, and the
// three caps (with SendMessage's messages_daily) are separate counters.
func TestMessagingDailyCaps(t *testing.T) {
	const markCap, mutCap = 4, 6
	mark := messagingv1connect.MessagingServiceMarkConversationReadProcedure
	accept := messagingv1connect.MessagingServiceAcceptMessageRequestProcedure
	del := messagingv1connect.MessagingServiceDeleteConversationProcedure
	send := messagingv1connect.MessagingServiceSendMessageProcedure
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.MessagesMarkReadPerDay = markCap
	cfg.RateLimit.MessagesMutationsPerDay = mutCap
	// The default 60/min bucket is not what is under test.
	cfg.RateLimit.PerUserPerMinute = 1_000_000

	t.Run("mark read trips at cap+1 per uid", func(t *testing.T) {
		invoke := messagingCapInvoker(t, cfg, mark, accept, del, send)
		for i := range markCap {
			if err := invoke("uid-a", mark); err != nil {
				t.Fatalf("mark read %d must pass: %v", i+1, err)
			}
		}
		wantCapRefusal(t, invoke("uid-a", mark), "messages_mark_read_daily")
		wantCapRefusal(t, invoke("uid-a", mark), "messages_mark_read_daily")
		if err := invoke("uid-b", mark); err != nil {
			t.Fatalf("another uid must not share the counter: %v", err)
		}
		// A spent mark-read budget leaves the other messaging RPCs open.
		for _, p := range []string{accept, del, send} {
			if err := invoke("uid-a", p); err != nil {
				t.Fatalf("%s after the mark-read cap: %v", p, err)
			}
		}
	})

	t.Run("accept and delete share one counter, tripping at cap+1 per uid", func(t *testing.T) {
		invoke := messagingCapInvoker(t, cfg, mark, accept, del, send)
		for i := range mutCap {
			p := accept
			if i%2 == 1 {
				p = del
			}
			if err := invoke("uid-a", p); err != nil {
				t.Fatalf("mutation %d (%s) must pass: %v", i+1, p, err)
			}
		}
		wantCapRefusal(t, invoke("uid-a", accept), "messages_mutation_daily")
		wantCapRefusal(t, invoke("uid-a", del), "messages_mutation_daily")
		if err := invoke("uid-b", del); err != nil {
			t.Fatalf("another uid must not share the counter: %v", err)
		}
		if err := invoke("uid-b", accept); err != nil {
			t.Fatalf("another uid must not share the counter: %v", err)
		}
		// A spent mutation budget leaves mark-read and send open (separate counters).
		for _, p := range []string{mark, send} {
			if err := invoke("uid-a", p); err != nil {
				t.Fatalf("%s after the mutation cap: %v", p, err)
			}
		}
	})
}

// TestMessagingDailyCapWiring: the three procedures carry their named cap, Accept and Delete hold the SAME DailyCap and
// MarkConversationRead a different one, and the two reads (ListConversations, ListMessages) carry none.
func TestMessagingDailyCapWiring(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	mark := rl.DailyCaps[messagingv1connect.MessagingServiceMarkConversationReadProcedure]
	accept := rl.DailyCaps[messagingv1connect.MessagingServiceAcceptMessageRequestProcedure]
	del := rl.DailyCaps[messagingv1connect.MessagingServiceDeleteConversationProcedure]
	send := rl.DailyCaps[messagingv1connect.MessagingServiceSendMessageProcedure]
	if mark.Name != "messages_mark_read_daily" || mark.Cap == nil {
		t.Errorf("MarkConversationRead cap = %+v, want messages_mark_read_daily", mark)
	}
	if accept.Name != "messages_mutation_daily" || del.Name != "messages_mutation_daily" || accept.Cap == nil || accept.Cap != del.Cap {
		t.Errorf("Accept / Delete caps = %+v / %+v, want one shared messages_mutation_daily", accept, del)
	}
	if mark.Cap == accept.Cap || mark.Cap == send.Cap || accept.Cap == send.Cap {
		t.Error("the mark-read, mutation and send caps must be separate counters")
	}
}
