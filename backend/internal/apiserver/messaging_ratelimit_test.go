package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestMessagingRateLimitWiring: SendMessage has its own bucket and the shared messages_daily cap;
// ListConversations and ListMessages share one read bucket and have no daily cap (reads);
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
			t.Errorf("%s must not have a daily call cap (a read)", p)
		}
	}
	// F30: ListMessageSuggestions has a bucket of its own and no daily cap.
	sg := messagingv1connect.MessagingServiceListMessageSuggestionsProcedure
	if b := rl.PerProcedure[sg]; b == nil || b == rl.PerProcedure[lc] || b == rl.PerProcedure[send] {
		t.Error("ListMessageSuggestions needs its own per-procedure bucket")
	}
	if _, ok := rl.DailyCaps[sg]; ok {
		t.Error("ListMessageSuggestions must not have a daily call cap (a read)")
	}

}

// TestMessagingShareCheckRateLimit: CheckPostShare has its own 10/min bucket (no other messaging RPC and not the
// default) and its own daily cap messages_share_checks_daily (300 by default, nothing else draws on it). Through the real
// interceptor the (cap+1)-th check of a uid is RATE_LIMITED with that name, another uid is untouched, and a spent check
// budget leaves SendMessage open (separate counters both ways).
func TestMessagingShareCheckRateLimit(t *testing.T) {
	check := messagingv1connect.MessagingServiceCheckPostShareProcedure
	send := messagingv1connect.MessagingServiceSendMessageProcedure
	t.Run("wiring", func(t *testing.T) {
		rl := RateLimitConfig(defaultRateLimitCfg())
		b := rl.PerProcedure[check]
		if b == nil || b == rl.Default {
			t.Fatal("CheckPostShare needs its own per-procedure bucket")
		}
		for _, p := range []string{
			send, messagingv1connect.MessagingServiceListMessagesProcedure, messagingv1connect.MessagingServiceListMessageSuggestionsProcedure,
			messagingv1connect.MessagingServiceCommitConversationProcedure, messagingv1connect.MessagingServiceListWelcomesProcedure,
		} {
			if rl.PerProcedure[p] == b {
				t.Errorf("%s shares the CheckPostShare bucket", p)
			}
		}
		named, ok := rl.DailyCaps[check]
		if !ok || named.Name != "messages_share_checks_daily" || named.Cap == nil {
			t.Fatalf("CheckPostShare daily cap = %+v, want messages_share_checks_daily", named)
		}
		for p, other := range rl.DailyCaps {
			if p != check && (other.Cap == named.Cap || other.Name == named.Name) {
				t.Errorf("%s draws on the CheckPostShare cap", p)
			}
		}
		for i := range 10 {
			if ok, _ := b.Allow("uid-checker"); !ok {
				t.Fatalf("check %d refused, want the first 10 allowed", i+1)
			}
		}
		if ok, retry := b.Allow("uid-checker"); ok || retry <= 0 {
			t.Errorf("check 11 = %v retry %v, want refused with a retry-after", ok, retry)
		}
	})
	t.Run("daily cap through the interceptor", func(t *testing.T) {
		const dailyCap = 3
		cfg := defaultRateLimitCfg()
		cfg.RateLimit.MessagesShareChecksPerDay = dailyCap
		cfg.RateLimit.MessagesShareCheckPerUserPerMinute = 1_000_000
		cfg.RateLimit.MessagesSendPerUserPerMinute = 1_000_000
		invoke := messagingCapInvoker(t, cfg, check, send)
		for i := range dailyCap {
			if err := invoke("uid-checker", check); err != nil {
				t.Fatalf("check %d must pass: %v", i+1, err)
			}
		}
		wantCapRefusal(t, invoke("uid-checker", check), "messages_share_checks_daily")
		if err := invoke("uid-checker", send); err != nil {
			t.Fatalf("SendMessage after the check cap: %v", err)
		}
		if err := invoke("uid-other", check); err != nil {
			t.Fatalf("another user must not share the counter: %v", err)
		}
	})
}

// TestMessagingReadBucketLimitsPolls: the 31st ListMessages call of one user inside a minute is refused by the
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

// TestMessagingDailyCaps (security review M-1): MarkConversationRead has its own per-uid daily cap
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

// The encrypted-conversation procedures: CommitConversation on its own bucket and the daily call cap
// messages_commits_daily; ListConversationCommits, ListEpochMessages, ListWelcomes and AckWelcomes on ONE shared sync
// bucket and no daily cap.
var (
	messagesCommitProcedure = messagingv1connect.MessagingServiceCommitConversationProcedure
	messagesSyncProcedures  = []string{
		messagingv1connect.MessagingServiceListConversationCommitsProcedure,
		messagingv1connect.MessagingServiceListEpochMessagesProcedure,
		messagingv1connect.MessagingServiceListWelcomesProcedure,
		messagingv1connect.MessagingServiceAckWelcomesProcedure,
	}
)

// messagingE2EERateLimitViolations asserts that wiring: the commit bucket and the sync bucket exist, are distinct from each
// other and from every other messaging bucket, every sync procedure is on the one sync bucket, CommitConversation carries
// messages_commits_daily (and nothing else draws on it), and no sync procedure has a daily cap.
func messagingE2EERateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	commit, sync := rl.PerProcedure[messagesCommitProcedure], rl.PerProcedure[messagesSyncProcedures[0]]
	if commit == nil {
		out = append(out, "CommitConversation is not mapped")
	}
	if sync == nil {
		out = append(out, "the sync bucket is not mapped")
	}
	for _, p := range messagesSyncProcedures {
		if rl.PerProcedure[p] != sync {
			out = append(out, p+" does not share the sync bucket")
		}
		if _, capped := rl.DailyCaps[p]; capped {
			out = append(out, p+" must not be on a daily cap")
		}
	}
	if commit != nil && commit == sync {
		out = append(out, "the commit and sync buckets must be different limiters")
	}
	for _, other := range []string{
		messagingv1connect.MessagingServiceSendMessageProcedure, messagingv1connect.MessagingServiceListMessagesProcedure,
		messagingv1connect.MessagingServiceListMessageSuggestionsProcedure,
	} {
		if b := rl.PerProcedure[other]; b != nil && (b == commit || b == sync) {
			out = append(out, other+" shares an encrypted-conversation bucket")
		}
	}
	if rl.Default != nil && (commit == rl.Default || sync == rl.Default) {
		out = append(out, "an encrypted-conversation bucket is the default limiter")
	}
	if named, ok := rl.DailyCaps[messagesCommitProcedure]; !ok || named.Cap == nil || named.Name != "messages_commits_daily" {
		out = append(out, "CommitConversation has no messages_commits_daily cap")
	}
	for p, named := range rl.DailyCaps {
		if named.Name == "messages_commits_daily" && p != messagesCommitProcedure {
			out = append(out, "messages_commits_daily is drawn on by "+p)
		}
	}
	return out
}

// TestMessagingE2EERateLimit_Guard proves the guard passes on the shipped wiring and can fail.
func TestMessagingE2EERateLimit_Guard(t *testing.T) {
	lw := messagingv1connect.MessagingServiceListWelcomesProcedure
	ack := messagingv1connect.MessagingServiceAckWelcomesProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"commit loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, messagesCommitProcedure) }, "CommitConversation is not mapped"},
		{"ack gets its own bucket", func(c *ratelimit.Config) { c.PerProcedure[ack] = ratelimit.NewLimiter(60, idleBucketTTL) }, "does not share the sync bucket"},
		{"list welcomes falls to the default", func(c *ratelimit.Config) { delete(c.PerProcedure, lw) }, "does not share the sync bucket"},
		{"commit shares the sync bucket", func(c *ratelimit.Config) { c.PerProcedure[messagesCommitProcedure] = c.PerProcedure[lw] }, "must be different limiters"},
		{"commit loses its daily cap", func(c *ratelimit.Config) { delete(c.DailyCaps, messagesCommitProcedure) }, "no messages_commits_daily cap"},
		{"ack joins the commits cap", func(c *ratelimit.Config) { c.DailyCaps[ack] = c.DailyCaps[messagesCommitProcedure] }, "must not be on a daily cap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(messagingE2EERateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestMessagingE2EERateLimit_Buckets: through the limiters, the commit bucket is 20/min and the sync bucket one budget of
// 60/min across its four procedures; another user is untouched.
func TestMessagingE2EERateLimit_Buckets(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	for _, g := range []struct {
		procs []string
		n     int
	}{{[]string{messagesCommitProcedure}, 20}, {messagesSyncProcedures, 60}} {
		for i := range g.n {
			if ok, _ := rl.PerProcedure[g.procs[i%len(g.procs)]].Allow("uid-e2ee"); !ok {
				t.Fatalf("%v call %d refused, want the first %d allowed", g.procs, i+1, g.n)
			}
		}
		for _, p := range g.procs {
			if ok, retry := rl.PerProcedure[p].Allow("uid-e2ee"); ok || retry <= 0 {
				t.Errorf("%s after %d calls in the group = %v retry %v, want refused", p, g.n, ok, retry)
			}
		}
		if ok, _ := rl.PerProcedure[g.procs[0]].Allow("uid-e2ee-other"); !ok {
			t.Errorf("%v: another user was refused", g.procs)
		}
	}
}

// TestMessagingCommitsDailyCap: through the real interceptor the (cap+1)-th CommitConversation of a uid is RATE_LIMITED
// with metadata limit=messages_commits_daily (the interceptor runs before the service, so every call counts, a retry
// included), another uid is untouched, and a sync RPC (no daily cap) still passes.
func TestMessagingCommitsDailyCap(t *testing.T) {
	const dailyCap = 3
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.MessagesCommitsPerDay = dailyCap
	cfg.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	cfg.RateLimit.MessagesSyncPerUserPerMinute = 1_000_000
	lw := messagingv1connect.MessagingServiceListWelcomesProcedure
	invoke := messagingCapInvoker(t, cfg, messagesCommitProcedure, lw)
	for i := range dailyCap {
		if err := invoke("uid-committer", messagesCommitProcedure); err != nil {
			t.Fatalf("commit %d must pass: %v", i+1, err)
		}
	}
	wantCapRefusal(t, invoke("uid-committer", messagesCommitProcedure), "messages_commits_daily")
	for i := range dailyCap + 2 {
		if err := invoke("uid-committer", lw); err != nil {
			t.Fatalf("ListWelcomes %d must pass (no daily cap): %v", i+1, err)
		}
	}
	if err := invoke("uid-other", messagesCommitProcedure); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}
