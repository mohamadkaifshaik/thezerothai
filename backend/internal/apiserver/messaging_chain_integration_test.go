//go:build integration

package apiserver

// SendMessage (ADR-0027, tickets W7-5 and W7-6) over the real Build chain on the emulators: the account-status,
// rate-limit and degraded-mode interceptors, the flag rules, the documents a send writes, every refusal's bytes, the caps,
// replay, and the budget table of the RPC doc comment (accepted 5 reads / 3 writes, request 4 writes, new conversation 7
// reads / 5 writes), asserted with budgettest on the logged fs_reads / fs_writes / fs_deletes of the request line. Chains
// that measure are booted AFTER the data is written, so no cache is warm (cold instance).

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcSendMessage = "/dzeroth.messaging.v1.MessagingService/SendMessage"

// messagingOn turns FEATURE_MESSAGING on for everyone with the abuse limits relaxed (loopback seeding would trip them)
// and the new-account window off, so every minted user is an established account unless a test puts the window back.
func messagingOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.MessagesSendPerUserPerMinute = 1_000_000
	c.RateLimit.MessagesSendsPerDay = 1_000_000
	c.Quota.NewAccountWindow = time.Nanosecond
	c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.On}
}

type dmUser struct{ token, uid string }

type dmChain struct {
	*chainEnv
	msg   messagingv1connect.MessagingServiceClient
	graph graphv1connect.GraphServiceClient
}

func newDMChain(t *testing.T, mutate func(*config.Config)) *dmChain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		messagingOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &dmChain{
		chainEnv: env,
		msg:      messagingv1connect.NewMessagingServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

func (e *dmChain) user(t *testing.T) dmUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	e.createProfile(t, tok)
	return dmUser{tok, uid}
}

func (e *dmChain) follow(t *testing.T, who, target dmUser) {
	t.Helper()
	if _, err := e.graph.Follow(context.Background(), authed(who.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("dm-follow"), UserId: target.uid})); err != nil {
		t.Fatalf("Follow: %v", err)
	}
}

func (e *dmChain) mutual(t *testing.T, a, b dmUser) { t.Helper(); e.follow(t, a, b); e.follow(t, b, a) }

func (e *dmChain) send(from dmUser, to dmUser, key, text string) (*messagingv1.SendMessageResponse, error) {
	r, err := e.msg.SendMessage(context.Background(), authed(from.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: to.uid}, Text: text,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *dmChain) mustSend(t *testing.T, from, to dmUser, text string) *messagingv1.SendMessageResponse {
	t.Helper()
	r, err := e.send(from, to, contractKey("dm"), text)
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	return r
}

// wireBytes is an error as the client receives it: code, message and the serialised details.
func wireBytes(t *testing.T, err error) string {
	t.Helper()
	var ce *connect.Error
	if !asConnectErr(err, &ce) {
		t.Fatalf("err = %v, want a Connect error", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%v|%s|", ce.Code(), ce.Message())
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			t.Fatal(verr)
		}
		raw, merr := proto.MarshalOptions{Deterministic: true}.Marshal(v)
		if merr != nil {
			t.Fatal(merr)
		}
		b.Write(raw)
	}
	return b.String()
}

func asConnectErr(err error, target **connect.Error) bool {
	ce, ok := err.(*connect.Error) //nolint:errorlint // the Connect client returns the concrete type
	if ok {
		*target = ce
	}
	return ok
}

func (e *dmChain) convDoc(t *testing.T, a, b dmUser) (map[string]any, bool) {
	t.Helper()
	snap, err := e.fs.Doc("conversations/" + messaging.ConversationID(a.uid, b.uid)).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), true
}

func (e *dmChain) entry(t *testing.T, owner, peer dmUser, folder string) (map[string]any, bool) {
	t.Helper()
	snap, err := e.fs.Doc("users/" + owner.uid + "/" + folder + "/" + messaging.ConversationID(owner.uid, peer.uid)).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), true
}

func (e *dmChain) messageCount(t *testing.T, a, b dmUser) int {
	t.Helper()
	docs, err := e.fs.Collection("conversations").Doc(messaging.ConversationID(a.uid, b.uid)).Collection("messages").Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

// The budget table of the SendMessage doc comment through the whole chain, on a cold instance: an accepted conversation
// costs 5 reads (interceptor, caller graph, recipient graph, recipient profile, conversation) and 3 writes; the next
// request message 4 writes; a new conversation 7 reads (+ the recipient's status fresh, quotas) and 5 writes.
func TestMessagingChain_BudgetTable(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b, c, d := setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	setup.mutual(t, a, b)
	// An existing accepted conversation, so the measured send is the plain 3-write one.
	setup.mustSend(t, a, b, "first")

	measure := func(label string, ceil budgettest.Budget, run func(e *dmChain)) {
		t.Helper()
		e := newDMChain(t, nil) // a cold instance: no cache is warm
		run(e)
		got := e.lineBudget(t, rpcSendMessage)
		budgettest.Assert(t, "SendMessage "+label, got, ceil)
		t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d ceil_deletes=%d", label, got.Reads(), got.Writes(), got.Deletes(), ceil.Reads, ceil.Writes, ceil.Deletes)
	}
	measure("accepted conversation, cold", budgettest.Budget{Reads: 5, Writes: 3}, func(e *dmChain) {
		if _, err := e.send(a, b, contractKey("dm"), "second"); err != nil {
			t.Fatal(err)
		}
	})
	measure("new conversation (mutual), cold", budgettest.Budget{Reads: 7, Writes: 5}, func(e *dmChain) {
		setup.mutual(t, a, c)
		if _, err := e.send(a, c, contractKey("dm"), "hello"); err != nil {
			t.Fatal(err)
		}
	})
	measure("new conversation (request), cold", budgettest.Budget{Reads: 7, Writes: 5}, func(e *dmChain) {
		if _, err := e.send(a, d, contractKey("dm"), "request"); err != nil {
			t.Fatal(err)
		}
	})
	measure("request, 2nd message", budgettest.Budget{Reads: 5, Writes: 4}, func(e *dmChain) {
		if _, err := e.send(a, d, contractKey("dm"), "request again"); err != nil {
			t.Fatal(err)
		}
	})
	measure("reply that accepts a request", budgettest.Budget{Reads: 5, Writes: 4, Deletes: 1}, func(e *dmChain) {
		if _, err := e.send(d, a, contractKey("dm"), "ok"); err != nil {
			t.Fatal(err)
		}
	})
	// Warm: the same instance, caches filled by the previous send: the planning figure is far below the worst case.
	warm := newDMChain(t, nil)
	if _, err := warm.send(a, b, contractKey("dm"), "warm up"); err != nil {
		t.Fatal(err)
	}
	if _, err := warm.send(a, b, contractKey("dm"), "warm"); err != nil {
		t.Fatal(err)
	}
	got := warm.lineBudget(t, rpcSendMessage)
	budgettest.Assert(t, "SendMessage accepted, warm", got, budgettest.Budget{Reads: 1, Writes: 3})
	t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d", "accepted conversation, warm", got.Reads(), got.Writes(), got.Deletes())
}

// Mutual follows land in B's Inbox (unread 1); non-mutuals in B's Requests (unread 1, nothing in the Inbox), the sender's
// own entry is in her Inbox either way; the 4th request message is LIMIT_REACHED request_unanswered.
func TestMessagingChain_MutualRequestAndTheFourthMessage(t *testing.T) {
	e := newDMChain(t, nil)
	a, b, c := e.user(t), e.user(t), e.user(t)
	e.mutual(t, a, b)

	r := e.mustSend(t, a, b, "hello mutual")
	if r.GetConversation().GetState() != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED || r.GetMessage().GetText() != "hello mutual" {
		t.Errorf("mutual response = %v", r)
	}
	in, ok := e.entry(t, b, a, "dmInbox")
	if !ok || in["unreadCount"] != int64(1) {
		t.Errorf("b's dmInbox = %v, %v, want unreadCount 1", in, ok)
	}

	for i := 1; i <= 3; i++ {
		e.mustSend(t, a, c, fmt.Sprintf("request %d", i))
	}
	req, ok := e.entry(t, c, a, "dmRequests")
	if !ok || req["unreadCount"] != int64(3) {
		t.Errorf("c's dmRequests = %v, %v, want unreadCount 3", req, ok)
	}
	if _, ok := e.entry(t, c, a, "dmInbox"); ok {
		t.Error("a request must not be in the recipient's Inbox")
	}
	if _, ok := e.entry(t, a, c, "dmInbox"); !ok {
		t.Error("the requester must see the conversation in her own Inbox")
	}
	_, err := e.send(a, c, contractKey("dm"), "request 4")
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if d.GetMetadata()["limit"] != "request_unanswered" {
		t.Errorf("limit = %q, want request_unanswered", d.GetMetadata()["limit"])
	}
	if n := e.messageCount(t, a, c); n != 3 {
		t.Errorf("messages = %d, want 3", n)
	}
	// The recipient's reply accepts the request and moves her entry to the Inbox.
	e.mustSend(t, c, a, "sure")
	if conv, _ := e.convDoc(t, a, c); conv["state"] != "ACCEPTED" {
		t.Errorf("state after the reply = %v", conv["state"])
	}
	if _, ok := e.entry(t, c, a, "dmRequests"); ok {
		t.Error("the request entry must be gone after the reply")
	}
}

// A block either way, a deleted (or suspended) recipient, a recipient with messaging off and a conversation whose peer
// deleted the account all answer the same bytes, and write nothing.
func TestMessagingChain_RefusalsAreByteIdentical(t *testing.T) {
	setup := newDMChain(t, nil)
	sender, blocker, blocked, ghost, off, gone := setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	if _, err := setup.graph.Block(context.Background(), authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("dm-block"), UserId: sender.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := setup.graph.Block(context.Background(), authed(sender.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("dm-block"), UserId: blocked.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := setup.fs.Doc("users/"+ghost.uid).Update(context.Background(), usersStatusUpdate("DELETING")); err != nil {
		t.Fatal(err)
	}
	// A conversation with `gone`: the peer deleted the account after talking.
	setup.mutual(t, sender, gone)
	setup.mustSend(t, sender, gone, "before")
	if _, err := setup.fs.Doc("conversations/"+messaging.ConversationID(sender.uid, gone.uid)).Update(context.Background(), goneUpdate(gone.uid)); err != nil {
		t.Fatal(err)
	}

	// A fresh chain (cold caches) where `off` is not in the allowlist, so messaging is off for that recipient only.
	chain := newDMChain(t, func(c *config.Config) {
		c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: map[string]struct{}{
			sender.uid: {}, blocker.uid: {}, blocked.uid: {}, ghost.uid: {}, gone.uid: {},
		}}
	})
	cases := []struct {
		name string
		to   dmUser
	}{
		{"the recipient blocks the caller", blocker},
		{"the caller blocks the recipient", blocked},
		{"the recipient's account is being deleted", ghost},
		{"the recipient has messaging off", off},
		{"the conversation is gone", gone},
	}
	var first string
	for i, tc := range cases {
		_, err := chain.send(sender, tc.to, contractKey("dm"), "can you hear me")
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
		got := wireBytes(t, err)
		if i == 0 {
			first = got
		} else if got != first {
			t.Errorf("%s: response bytes differ from the first refusal:\n got  %q\n want %q", tc.name, got, first)
		}
		line := chain.lineBudget(t, rpcSendMessage)
		if line.Writes() != 0 || line.Deletes() != 0 {
			t.Errorf("%s: a refusal wrote %d / deleted %d", tc.name, line.Writes(), line.Deletes())
		}
		budgettest.Assert(t, "SendMessage refused: "+tc.name, line, budgettest.Budget{Reads: 5})
	}
	for _, other := range []dmUser{blocker, blocked, ghost, off} {
		if n := setup.messageCount(t, sender, other); n != 0 {
			t.Errorf("a refused send stored %d messages", n)
		}
	}
}

// B muted A: the message is delivered, the entry is `silent`, nothing counts as unread.
func TestMessagingChain_MutedSenderIsSilent(t *testing.T) {
	e := newDMChain(t, nil)
	a, b := e.user(t), e.user(t)
	e.mutual(t, a, b)
	if _, err := e.graph.Mute(context.Background(), authed(b.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("dm-mute"), UserId: a.uid})); err != nil {
		t.Fatal(err)
	}
	fresh := newDMChain(t, nil) // the mute is in b's stored graph; a cold instance reads it
	if _, err := fresh.send(a, b, contractKey("dm"), "psst"); err != nil {
		t.Fatal(err)
	}
	in, ok := fresh.entry(t, b, a, "dmInbox")
	if !ok || in["silent"] != true {
		t.Fatalf("b's entry = %v, %v, want silent", in, ok)
	}
	if u, _ := in["unreadCount"].(int64); u != 0 {
		t.Errorf("unreadCount = %d, want 0", u)
	}
}

// The same key twice is one message and 0 writes the second time; the same key with other text is VALIDATION on
// idempotency_key; a different sender may reuse the key.
func TestMessagingChain_ReplayAndKeyReuse(t *testing.T) {
	e := newDMChain(t, nil)
	a, b := e.user(t), e.user(t)
	e.mutual(t, a, b)
	key := contractKey("dm")
	first, err := e.send(a, b, key, "once")
	if err != nil {
		t.Fatal(err)
	}
	again, err := e.send(a, b, key, "once")
	if err != nil {
		t.Fatal(err)
	}
	line := e.lineBudget(t, rpcSendMessage)
	if line.Writes() != 0 || line.Deletes() != 0 {
		t.Errorf("the replay wrote %d / deleted %d", line.Writes(), line.Deletes())
	}
	if first.GetMessage().GetId() != again.GetMessage().GetId() || !first.GetMessage().GetCreatedAt().AsTime().Equal(again.GetMessage().GetCreatedAt().AsTime()) {
		t.Errorf("replay answered %v, first %v", again.GetMessage(), first.GetMessage())
	}
	if n := e.messageCount(t, a, b); n != 1 {
		t.Errorf("messages = %d, want 1", n)
	}
	_, err = e.send(a, b, key, "other text")
	d := wireError(t, err, connect.CodeInvalidArgument)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if d.GetMetadata()["field"] != "idempotency_key" {
		t.Errorf("field = %q", d.GetMetadata()["field"])
	}
	if _, err := e.send(b, a, key, "same key, other sender"); err != nil {
		t.Errorf("a different sender with the same key: %v", err)
	}
}

// The 21st new conversation of the day is LIMIT_REACHED dm_new_daily; a brand-new account has 5, so its 6th is.
func TestMessagingChain_NewConversationQuota(t *testing.T) {
	for _, tc := range []struct {
		name   string
		window time.Duration
		max    int
	}{{"established account", time.Nanosecond, 20}, {"new account", 72 * time.Hour, 5}} {
		t.Run(tc.name, func(t *testing.T) {
			e := newDMChain(t, func(c *config.Config) { c.Quota.NewAccountWindow = tc.window })
			sender := e.user(t)
			for i := range tc.max {
				if _, err := e.send(sender, e.user(t), contractKey("dm"), fmt.Sprint("hi ", i)); err != nil {
					t.Fatalf("conversation %d: %v", i+1, err)
				}
			}
			_, err := e.send(sender, e.user(t), contractKey("dm"), "one too many")
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
			if d.GetMetadata()["limit"] != "dm_new_daily" {
				t.Errorf("limit = %q, want dm_new_daily", d.GetMetadata()["limit"])
			}
		})
	}
}

// A new account's SendMessage calls are capped at MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY (the interceptor's cap is the
// established tier), RATE_LIMITED with limit=messages_daily.
func TestMessagingChain_NewAccountDailySendCap(t *testing.T) {
	e := newDMChain(t, func(c *config.Config) {
		c.Quota.NewAccountWindow = 72 * time.Hour
		c.Messaging.NewAccountSendsPerDay = 3
		c.Quota.NewAccountDMNewConversationsPerDay = 100
	})
	sender, peer := e.user(t), e.user(t)
	for i := range 3 {
		if _, err := e.send(sender, peer, contractKey("dm"), fmt.Sprint("m", i)); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	_, err := e.send(sender, peer, contractKey("dm"), "m4")
	d := wireError(t, err, connect.CodeResourceExhausted)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
	if d.GetMetadata()["limit"] != "messages_daily" {
		t.Errorf("limit = %q, want messages_daily", d.GetMetadata()["limit"])
	}
	lines := e.logs.requestLines(rpcSendMessage)
	if last := lines[len(lines)-1]; last["limit_name"] != "messages_daily" {
		t.Errorf("request line limit_name = %v", last["limit_name"])
	}
}

// DEGRADED_MODE=readonly refuses SendMessage in the interceptor, before any handler or read.
func TestMessagingChain_DegradedReadonlyRefusesSend(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	e := newDMChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })
	_, err := e.send(a, b, contractKey("dm"), "hi")
	d := wireError(t, err, connect.CodeUnavailable)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
	if n := setup.messageCount(t, a, b); n != 0 {
		t.Errorf("messages = %d", n)
	}
}

// The flag: off for the caller is FEATURE_DISABLED feature=messaging after at most the interceptor's one read; the
// recipient's flag is CANNOT_MESSAGE.
func TestMessagingChain_FlagModes(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	allow := func(uids ...dmUser) flags.Spec {
		m := map[string]struct{}{}
		for _, u := range uids {
			m[u.uid] = struct{}{}
		}
		return flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: m}
	}
	tests := []struct {
		name string
		spec flags.Spec
		want string // "ok" | "disabled" | "cannot"
	}{
		{"off", flags.Spec{Name: "messaging", Mode: flags.Off}, "disabled"},
		{"allowlist: both", allow(a, b), "ok"},
		{"allowlist: only the caller", allow(a), "cannot"},
		{"allowlist: only the recipient", allow(b), "disabled"},
		{"percent 100", flags.Spec{Name: "messaging", Mode: flags.Percent, Percent: 100}, "ok"},
		{"percent 0", flags.Spec{Name: "messaging", Mode: flags.Percent}, "disabled"},
		{"on", flags.Spec{Name: "messaging", Mode: flags.On}, "ok"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDMChain(t, func(c *config.Config) { c.FeatureMessaging = tt.spec })
			_, err := e.send(a, b, contractKey("dm"), "hi")
			switch tt.want {
			case "ok":
				if err != nil {
					t.Fatal(err)
				}
			case "disabled":
				d := wireError(t, err, connect.CodeFailedPrecondition)
				assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if d.GetMetadata()["feature"] != "messaging" {
					t.Errorf("feature = %q", d.GetMetadata()["feature"])
				}
				budgettest.Assert(t, "SendMessage flag off", e.lineBudget(t, rpcSendMessage), budgettest.Budget{Reads: 1})
			case "cannot":
				assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
			}
		})
	}
}

// Request lines carry the D11 fields and never the text, a uid or the conversation id.
func TestMessagingChain_RequestLineHasNoSecrets(t *testing.T) {
	e := newDMChain(t, nil)
	a, b := e.user(t), e.user(t)
	text := "a very private sentence"
	r := e.mustSend(t, a, b, text)
	lines := e.logs.requestLines(rpcSendMessage)
	last := lines[len(lines)-1]
	for k, want := range map[string]any{"kind": "send", "state": "new", "silent": false, "replay": false} {
		if last[k] != want {
			t.Errorf("%s = %v, want %v", k, last[k], want)
		}
	}
	if last["conversation_hash"] == nil || last["uid_hash"] == nil {
		t.Errorf("missing conversation_hash / uid_hash: %v", last)
	}
	raw := fmt.Sprint(last)
	for _, secret := range []string{text, a.uid, b.uid, r.GetConversation().GetId(), r.GetMessage().GetId()} {
		if strings.Contains(raw, secret) {
			t.Errorf("the request line contains %q: %s", secret, raw)
		}
	}
}

func usersStatusUpdate(status string) []firestore.Update {
	return []firestore.Update{{Path: "status", Value: status}}
}

func goneUpdate(uid string) []firestore.Update {
	return []firestore.Update{{Path: "gone", Value: []string{uid}}}
}
