package apiserver

import (
	"slices"
	"testing"

	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
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
