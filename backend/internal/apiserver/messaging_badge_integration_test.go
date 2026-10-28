//go:build integration

package apiserver

// W7-11 (ADR-0027 D10, D14): GetMe.unread_conversation_count over the real Build chain on the emulators. Cold: 3 reads
// (account-status profile, notification count, the dmInbox count()), warm 0, a send on this instance evicts it through
// messaging.Deps.Badge so the next GetMe recounts (2 with the send's own notification-count eviction), messaging off for the caller 2 reads and 0.

import (
	"context"
	"net/http"
	"testing"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func (e *dmChain) getMe(t *testing.T, u dmUser) *identityv1.GetMeResponse {
	t.Helper()
	cl := identityv1connect.NewIdentityServiceClient(http.DefaultClient, e.url)
	r, err := cl.GetMe(context.Background(), authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	return r.Msg
}

func TestMessagingChain_GetMeUnreadConversations(t *testing.T) {
	setup := newDMChain(t, nil)
	me, p1, p2, p3, p4 := setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	for _, p := range []dmUser{p1, p2, p3, p4} {
		setup.mutual(t, me, p)
	}
	setup.mustSend(t, p1, me, "one")
	setup.mustSend(t, p2, me, "two")
	setup.mustSend(t, p3, me, "three")

	// A fresh chain (cold caches): 3 unread conversations -> 3, 3 reads.
	chain := newDMChain(t, nil)
	if got := chain.getMe(t, me).GetUnreadConversationCount(); got != 3 {
		t.Fatalf("unread_conversation_count = %d, want 3", got)
	}
	budgettest.Assert(t, "GetMe, messaging on (cold)", chain.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 3})
	if hit := chain.logs.requestLines(rpcGetMe)[0]["unread_conversations_cache_hit"]; hit != false {
		t.Errorf("first GetMe unread_conversations_cache_hit = %v, want false", hit)
	}

	// The second call inside 30 s reads nothing and says so.
	if got := chain.getMe(t, me).GetUnreadConversationCount(); got != 3 {
		t.Fatalf("warm count = %d, want 3", got)
	}
	budgettest.Assert(t, "GetMe, messaging on (warm)", chain.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 0})
	lines := chain.logs.requestLines(rpcGetMe)
	if hit := lines[len(lines)-1]["unread_conversations_cache_hit"]; hit != true {
		t.Errorf("second GetMe unread_conversations_cache_hit = %v, want true", hit)
	}

	// A send to `me` on this instance evicts the cached count (Deps.Badge), so the next GetMe recounts. The send's own fresh
	// recipient check (Profiles.Forget, W7-5) also evicts the notification count, so the call reads 2: that count and this one.
	chain.mustSend(t, p4, me, "four")
	if got := chain.getMe(t, me).GetUnreadConversationCount(); got != 4 {
		t.Fatalf("count after a send = %d, want 4", got)
	}
	budgettest.Assert(t, "GetMe after a send (recount)", chain.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 2})

	// Messaging off for the caller: 0 and no count() (the 2 reads of before W7-11).
	offChain := newDMChain(t, func(c *config.Config) {
		c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: map[string]struct{}{p1.uid: {}}}
	})
	if got := offChain.getMe(t, me).GetUnreadConversationCount(); got != 0 {
		t.Fatalf("messaging off: count = %d, want 0", got)
	}
	budgettest.Assert(t, "GetMe, messaging off (cold)", offChain.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 2})
	if _, present := offChain.logs.requestLines(rpcGetMe)[0]["unread_conversations_cache_hit"]; present {
		t.Error("messaging off: unread_conversations_cache_hit must not be logged")
	}
}
