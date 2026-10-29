//go:build integration

package apiserver

// W7-20 (ADR-0027): the flag classes of the read RPCs (F6), the percent bucket for caller and recipient, DEGRADED_MODE=readonly
// for reads and MarkConversationRead, the shared read limiter, MarkConversationRead then GetMe, the send caps of an
// established account, the suspended recipient and the caller's own mute, and blockedByOverflow accounts, all over the real
// Build chain on the emulators.

import (
	"context"
	"fmt"
	"hash/fnv"
	"os"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// messagingBucket is flags' fnv32a(name:uid) % 100 for the messaging flag, written out so a test can pick a percent that
// puts one account inside and another outside (the flags package keeps the function private).
func messagingBucket(uid string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte("messaging:" + uid))
	return int(h.Sum32() % 100)
}

func allowSpec(users ...dmUser) flags.Spec {
	m := map[string]struct{}{}
	for _, u := range users {
		m[u.uid] = struct{}{}
	}
	return flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: m}
}

func featureDisabled(t *testing.T, err error) {
	t.Helper()
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "messaging" {
		t.Errorf("feature = %q, want messaging", d.GetMetadata()["feature"])
	}
}

// F6 on the read side, over the chain: with messaging globally off every RPC is FEATURE_DISABLED after at most the
// interceptor's one read; with it merely off for the caller (allowlist without them, percent 0) the three read RPCs keep
// working and SendMessage is FEATURE_DISABLED; GetMe lists the feature for the allowlisted uid only.
func TestMessagingChain_ReadRPCsFlagClass(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	setup.mutual(t, a, b)
	setup.mustSend(t, b, a, "hello")
	id := convID(a, b)

	reads := []struct {
		name, rpc string
		call      func(e *dmChain) error
	}{
		{"ListConversations", rpcListConversations, func(e *dmChain) error {
			_, err := e.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
			return err
		}},
		{"ListMessages", rpcListMessages, func(e *dmChain) error {
			_, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: id})
			return err
		}},
		{"MarkConversationRead", rpcMarkRead, func(e *dmChain) error { return e.markRead(a, id) }},
	}
	tests := []struct {
		name       string
		spec       flags.Spec
		globalOff  bool // every RPC is refused
		inFeatures bool // GetMe.enabled_features lists messaging for a
	}{
		{"off (the default)", flags.Spec{Name: "messaging", Mode: flags.Off}, true, false},
		{"allowlist without the caller", allowSpec(b), false, false},
		{"allowlist with the caller", allowSpec(a), false, true},
		{"percent 0", flags.Spec{Name: "messaging", Mode: flags.Percent}, false, false},
		{"on", flags.Spec{Name: "messaging", Mode: flags.On}, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDMChain(t, func(c *config.Config) { c.FeatureMessaging = tt.spec })
			for _, r := range reads {
				err := r.call(e)
				if tt.globalOff {
					featureDisabled(t, err)
					budgettest.Assert(t, r.name+" globally off", e.lineBudget(t, r.rpc), budgettest.Budget{Reads: 1})
					continue
				}
				if err != nil {
					t.Errorf("%s with messaging merely off for the caller: %v", r.name, err)
				}
			}
			_, serr := e.send(a, b, contractKey("dm"), "can I?")
			switch {
			case tt.globalOff, tt.name == "allowlist without the caller", tt.name == "percent 0":
				featureDisabled(t, serr)
				budgettest.Assert(t, "SendMessage caller off", e.lineBudget(t, rpcSendMessage), budgettest.Budget{Reads: 1})
			case tt.name == "allowlist with the caller":
				assertReason(t, wireError(t, serr, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
			default:
				if serr != nil {
					t.Errorf("SendMessage with messaging on: %v", serr)
				}
			}
			feats := e.getMe(t, a).GetEnabledFeatures()
			has := false
			for _, f := range feats {
				has = has || f == "messaging"
			}
			if has != tt.inFeatures {
				t.Errorf("GetMe.enabled_features = %v, messaging listed = %v, want %v", feats, has, tt.inFeatures)
			}
			if got := w3StartupFlags(t, e.chainEnv)["messaging"]; got != string(tt.spec.Mode) {
				t.Errorf("startup feature_flags lists messaging as %v, want %s", got, tt.spec.Mode)
			}
		})
	}
}

// The percent bucket decides caller and recipient independently and deterministically: with a percent that puts the caller
// inside and the recipient outside, A -> B is CANNOT_MESSAGE, B -> A is FEATURE_DISABLED, B still reads, GetMe lists the
// feature for A only, and a second instance gives the same answers.
func TestMessagingChain_PercentBucketDecidesCallerAndRecipient(t *testing.T) {
	setup := newDMChain(t, nil)
	var in, out dmUser
	for range 60 {
		x, y := setup.user(t), setup.user(t)
		if bx, by := messagingBucket(x.uid), messagingBucket(y.uid); bx < by {
			in, out = x, y
			break
		} else if by < bx {
			in, out = y, x
			break
		}
	}
	if in.uid == "" {
		t.Fatal("60 pairs of accounts and no two buckets differ")
	}
	percent := messagingBucket(in.uid) + 1
	setup.mutual(t, in, out)
	setup.mustSend(t, in, out, "seed")
	for instance := 1; instance <= 2; instance++ {
		e := newDMChain(t, func(c *config.Config) {
			c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Percent, Percent: percent}
		})
		_, err := e.send(in, out, contractKey("dm"), "to someone outside the percent")
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
		_, err = e.send(out, in, contractKey("dm"), "from someone outside the percent")
		featureDisabled(t, err)
		if _, err := e.listConvs(out, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX}); err != nil {
			t.Errorf("instance %d: a caller outside the percent cannot list: %v", instance, err)
		}
		if feats := e.getMe(t, in).GetEnabledFeatures(); !contains(feats, "messaging") {
			t.Errorf("instance %d: in-bucket account lacks the feature: %v", instance, feats)
		}
		if feats := e.getMe(t, out).GetEnabledFeatures(); contains(feats, "messaging") {
			t.Errorf("instance %d: out-of-bucket account has the feature: %v", instance, feats)
		}
		if got := w3StartupFlags(t, e.chainEnv)["messaging"]; got != "percent" {
			t.Errorf("startup feature_flags lists messaging as %v, want percent", got)
		}
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// DEGRADED_MODE=readonly (ADR-0027 D11): the three reads stay up, and MarkConversationRead, which writes, is refused in the
// interceptor before any read or write, leaving the unread count alone.
func TestMessagingChain_ReadonlyKeepsReadsAndRefusesMarkRead(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	setup.mutual(t, a, b)
	setup.mustSend(t, b, a, "still readable")
	e := newDMChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })

	r, err := e.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
	if err != nil || len(r.GetConversations()) != 1 || r.GetConversations()[0].GetUnreadCount() != 1 {
		t.Fatalf("ListConversations under readonly = %v, %v", r, err)
	}
	m, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: convID(a, b)})
	if err != nil || len(m.GetMessages()) != 1 || m.GetMessages()[0].GetText() != "still readable" {
		t.Fatalf("ListMessages under readonly = %v, %v", m, err)
	}
	d := wireError(t, e.markRead(a, convID(a, b)), connect.CodeUnavailable)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
	line := e.lineBudget(t, rpcMarkRead)
	budgettest.Assert(t, "MarkConversationRead under readonly", line, budgettest.Budget{})
	if line.Reads() != 0 || line.Writes() != 0 {
		t.Errorf("MarkConversationRead under readonly: reads/writes = %d/%d, want 0/0", line.Reads(), line.Writes())
	}
	if n := setup.unread(t, a, b); n != 1 {
		t.Errorf("unreadCount = %d, want 1 (the refused call changed it)", n)
	}
}

// Given more polls in a minute than RATE_LIMIT_MESSAGES_READ_PER_MIN, then RATE_LIMITED: ListConversations and ListMessages share
// one per-user bucket (MarkConversationRead is on the default bucket and does not draw on it), another user's bucket is
// untouched, and the refusal is RESOURCE_EXHAUSTED with the RATE_LIMITED reason, with no Firestore read. The chain runs with a
// limit of 5 a minute rather than the default 30, so the one token the bucket refills every 12 s cannot reach the 6th call even on a
// slow CI machine; that the default is 30 and the 31st call is refused is pinned by TestMessagingReadBucketLimitsPolls.
func TestMessagingChain_ReadLimiterSharedBucket(t *testing.T) {
	const limit = 5
	e := newDMChain(t, func(c *config.Config) { c.RateLimit.MessagesReadPerUserPerMinute = limit })
	a, b := e.user(t), e.user(t)
	e.mutual(t, a, b)
	e.mustSend(t, b, a, "poll me")
	id := convID(a, b)
	for i := range limit {
		var err error
		if i%2 == 0 {
			_, err = e.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
		} else {
			_, err = e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: id, PageSize: 1})
		}
		if err != nil {
			t.Fatalf("call %d of the allowed %d: %v", i+1, limit, err)
		}
	}
	_, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: id})
	d := wireError(t, err, connect.CodeResourceExhausted)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
	budgettest.Assert(t, "ListMessages over the limit", e.lineBudget(t, rpcListMessages), budgettest.Budget{})
	if err := e.markRead(a, id); err != nil {
		t.Errorf("MarkConversationRead is not on the read bucket but was refused: %v", err)
	}
	if _, err := e.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX}); err == nil {
		t.Error("ListConversations, same bucket, was served after the limit")
	}
	if _, err := e.listConvs(b, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX}); err != nil {
		t.Errorf("another user was throttled by a's polls: %v", err)
	}
}

// Given a mark-read on this instance, then the next GetMe recounts (the count drops), and without one the second GetMe in
// 30 s is served from the cache with 0 reads.
func TestMessagingChain_MarkReadDropsTheBadgeOnTheNextGetMe(t *testing.T) {
	setup := newDMChain(t, nil)
	me, p1, p2, p3 := setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	for _, p := range []dmUser{p1, p2, p3} {
		setup.mutual(t, me, p)
		setup.mustSend(t, p, me, "unread")
	}
	e := newDMChain(t, nil)
	if got := e.getMe(t, me).GetUnreadConversationCount(); got != 3 {
		t.Fatalf("count = %d, want 3", got)
	}
	if got := e.getMe(t, me).GetUnreadConversationCount(); got != 3 {
		t.Fatalf("cached count = %d, want 3", got)
	}
	budgettest.Assert(t, "GetMe warm", e.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 0})
	if err := e.markRead(me, convID(me, p1)); err != nil {
		t.Fatal(err)
	}
	if got := e.getMe(t, me).GetUnreadConversationCount(); got != 2 {
		t.Fatalf("count after MarkConversationRead = %d, want 2 (the cache was not evicted)", got)
	}
	budgettest.Assert(t, "GetMe after mark-read (recount)", e.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 1})
	lines := e.logs.requestLines(rpcGetMe)
	if hit := lines[len(lines)-1]["unread_conversations_cache_hit"]; hit != false {
		t.Errorf("unread_conversations_cache_hit = %v after a mark-read, want false", hit)
	}
}

// The caps of an established account through the chain: RATE_LIMIT_MESSAGES_SEND_PER_MIN (the 4th send of 3 a minute) and
// MESSAGES_SENDS_PER_DAY (messages_daily) are RESOURCE_EXHAUSTED + RATE_LIMITED and write nothing; the refusal costs at most
// the interceptor's read, and another account is untouched.
func TestMessagingChain_SendCapsOfAnEstablishedAccount(t *testing.T) {
	tests := []struct {
		name      string
		mutate    func(c *config.Config)
		wantLimit string
	}{
		{"per minute", func(c *config.Config) { c.RateLimit.MessagesSendPerUserPerMinute = 3 }, ""},
		{"per day", func(c *config.Config) { c.RateLimit.MessagesSendsPerDay = 3 }, "messages_daily"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDMChain(t, tt.mutate)
			a, b, c := e.user(t), e.user(t), e.user(t)
			e.mutual(t, a, b)
			e.mutual(t, c, b)
			for i := range 3 {
				if _, err := e.send(a, b, contractKey("dm"), fmt.Sprint("m", i)); err != nil {
					t.Fatalf("send %d of the allowed 3: %v", i+1, err)
				}
			}
			_, err := e.send(a, b, contractKey("dm"), "m3")
			d := wireError(t, err, connect.CodeResourceExhausted)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
			if tt.wantLimit != "" && d.GetMetadata()["limit"] != tt.wantLimit {
				t.Errorf("limit = %q, want %q", d.GetMetadata()["limit"], tt.wantLimit)
			}
			line := e.lineBudget(t, rpcSendMessage)
			budgettest.Assert(t, "SendMessage over the "+tt.name+" cap", line, budgettest.Budget{Reads: 1})
			if line.Writes() != 0 {
				t.Errorf("a refused send wrote %d", line.Writes())
			}
			if n := e.messageCount(t, a, b); n != 3 {
				t.Errorf("messages = %d, want 3", n)
			}
			if _, err := e.send(c, b, contractKey("dm"), "someone else"); err != nil {
				t.Errorf("another account was capped by a's sends: %v", err)
			}
		})
	}
}

// A suspended recipient is refused with the same bytes as a block (the existing byte test covers DELETING), and when the
// caller has muted the recipient the message is delivered normally to the recipient while the caller's own entry is the
// silent one.
func TestMessagingChain_SuspendedRecipientAndCallerMute(t *testing.T) {
	setup := newDMChain(t, nil)
	sender, blocker, suspended, muted := setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	if _, err := setup.graph.Block(context.Background(), authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("dm-block"), UserId: sender.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := setup.fs.Doc("users/"+suspended.uid).Update(context.Background(), usersStatusUpdate("SUSPENDED")); err != nil {
		t.Fatal(err)
	}
	setup.mutual(t, sender, muted)
	if _, err := setup.graph.Mute(context.Background(), authed(sender.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("dm-mute"), UserId: muted.uid})); err != nil {
		t.Fatal(err)
	}

	e := newDMChain(t, nil)
	_, err := e.send(sender, blocker, contractKey("dm"), "hi")
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	want := wireBytes(t, err)
	_, err = e.send(sender, suspended, contractKey("dm"), "hi")
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	if got := wireBytes(t, err); got != want {
		t.Errorf("a suspended recipient's refusal differs from a block's:\n got  %q\n want %q", got, want)
	}
	line := e.lineBudget(t, rpcSendMessage)
	budgettest.Assert(t, "SendMessage to a suspended recipient", line, budgettest.Budget{Reads: 5})
	if line.Writes() != 0 {
		t.Errorf("the refusal wrote %d", line.Writes())
	}

	if _, err := e.send(sender, muted, contractKey("dm"), "you muted me, I did not"); err != nil {
		t.Fatalf("send to a recipient the caller muted: %v", err)
	}
	own, ok := e.entry(t, sender, muted, "dmInbox")
	if !ok || own["silent"] != true {
		t.Errorf("the caller's own entry = %v, %v, want silent", own, ok)
	}
	theirs, ok := e.entry(t, muted, sender, "dmInbox")
	if !ok || theirs["silent"] != false || theirs["unreadCount"] != int64(1) {
		t.Errorf("the recipient's entry = %v, %v, want not silent with unreadCount 1", theirs, ok)
	}
}

// overflow marks uid as blocked by so many accounts that blockedBy stopped listing them: the blocker is dropped from the
// array and blockedByOverflow is set (ADR-0008 D2), the stored shape the graph tests build the same way.
func (e *dmChain) overflow(t *testing.T, target dmUser, blockers ...dmUser) {
	t.Helper()
	ups := []firestore.Update{{Path: "blockedByOverflow", Value: true}}
	var gone []any
	for _, b := range blockers {
		gone = append(gone, b.uid)
	}
	if len(gone) > 0 {
		ups = append(ups, firestore.Update{Path: "blockedBy", Value: firestore.ArrayRemove(gone...)})
	}
	if _, err := e.fs.Doc("graph/"+target.uid).Update(context.Background(), ups); err != nil {
		t.Fatal(err)
	}
}

func (e *dmChain) block(t *testing.T, who, target dmUser) {
	t.Helper()
	if _, err := e.graph.Block(context.Background(), authed(who.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("dm-block"), UserId: target.uid})); err != nil {
		t.Fatal(err)
	}
}

// Overflowed accounts (blocked by so many that blockedBy dropped the blocker) are refused on send in both directions with
// the same bytes as a plain block, because each side's own Blocked set is authoritative; the flag itself blocks nothing,
// so an overflowed account still talks to everyone who has not blocked them.
func TestMessagingChain_BlockedByOverflowAccountsOnSend(t *testing.T) {
	setup := newDMChain(t, nil)
	x, p, q, r, s, t2 := setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	setup.mutual(t, x, q)
	setup.block(t, p, x) // p blocks the overflowed x
	setup.block(t, x, r) // x blocks the overflowed r
	setup.block(t, s, t2)
	setup.overflow(t, x, p)
	setup.overflow(t, r, x)

	e := newDMChain(t, nil)
	_, err := e.send(t2, s, contractKey("dm"), "baseline: a plain block")
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	want := wireBytes(t, err)
	for _, tc := range []struct {
		name     string
		from, to dmUser
	}{
		{"the overflowed x writes to the account that blocked x", x, p},
		{"the account that blocked the overflowed x writes to x", p, x},
		{"x writes to the overflowed r that x blocked", x, r},
		{"the overflowed r writes to x who blocked r", r, x},
	} {
		_, err := e.send(tc.from, tc.to, contractKey("dm"), "hello?")
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
		if got := wireBytes(t, err); got != want {
			t.Errorf("%s: bytes differ from a plain block's:\n got  %q\n want %q", tc.name, got, want)
		}
		line := e.lineBudget(t, rpcSendMessage)
		budgettest.Assert(t, "SendMessage refused: "+tc.name, line, budgettest.Budget{Reads: 5})
		if line.Writes() != 0 {
			t.Errorf("%s: the refusal wrote %d", tc.name, line.Writes())
		}
	}
	for _, pair := range [][2]dmUser{{x, p}, {x, r}} {
		if n := setup.messageCount(t, pair[0], pair[1]); n != 0 {
			t.Errorf("a refused send stored %d messages", n)
		}
	}
	if _, err := e.send(x, q, contractKey("dm"), "the flag is not a block"); err != nil {
		t.Errorf("an overflowed account cannot message someone who did not block them: %v", err)
	}
	if _, err := e.send(q, x, contractKey("dm"), "and the other way"); err != nil {
		t.Errorf("someone who did not block an overflowed account cannot message them: %v", err)
	}
}

// DEFECT (Low, filed with the W7-20 report): the read-time block rules of ListConversations and ListMessages consult the
// caller's blockedBy array only (service_list.go requestHiddenBy and canReply), and an overflowed account's blockedBy has
// dropped its blockers. So for an overflowed caller a REQUEST from an account that has since blocked them is still listed,
// and an INBOX conversation with such an account reads can_reply = true, where ADR-0027 D4 "On read" and the W7-7 plan
// text say the request is hidden and the thread is read-only (can_reply = false). A send into it is still refused
// (TestMessagingChain_BlockedByOverflowAccountsOnSend), so nothing leaks; the client shows a composer that cannot send.
// The comment on requestHiddenBy calls the omission deliberate (one graph read per peer); the ADR does not carve it out.
// Run it with W720_RUN_DEFECTS=1 to reproduce.
func TestMessagingChain_BlockedByOverflowCallerReadSide(t *testing.T) {
	if os.Getenv("W720_RUN_DEFECTS") == "" {
		t.Skip("defect: for a blockedByOverflow caller ListConversations still lists a REQUEST from an account that blocked them and reports can_reply=true for it (ADR-0027 D4 on read; service_list.go requestHiddenBy/canReply consult BlockedBy only). Set W720_RUN_DEFECTS=1 to reproduce")
	}
	readSideAfterBlocked(t, true)
}

// DEFECT D-2 (Low, only reachable by editing a document by hand): ADR-0027 D5 and W7-8 say ListMessages answers NOT_FOUND, with the
// bytes of an unknown id, for "a malformed-but-shaped id" and a non-participant. SendMessage by conversation_id treats a conversation
// whose participant list is not a pair the same way (service_send.go: `peerOf == ""` is notFound(); unit test
// TestSend_ByConversationID "a malformed participant list is NOT_FOUND"). ListMessages has no such check: `peerOf` returns "" and
// listMessages (service_messages.go, the `peer := peerOf(...)` line) goes on to look up that empty peer. This test takes a real conversation
// document, cuts its participants to the caller alone, and expects the unknown-id bytes from both RPCs. Run it with W720_RUN_DEFECTS=1.
func TestMessagingChain_ListMessagesMalformedParticipantListIsNotFound(t *testing.T) {
	if os.Getenv("W720_RUN_DEFECTS") == "" {
		t.Skip("defect: ListMessages on a conversation document whose participants list is not a pair does not answer the NOT_FOUND of an unknown id (SendMessage by conversation_id does); ListMessages looks up the empty peer. Set W720_RUN_DEFECTS=1 to reproduce")
	}
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	setup.mutual(t, a, b)
	setup.mustSend(t, a, b, "hello")
	if _, err := setup.fs.Doc("conversations/"+convID(a, b)).Update(context.Background(), []firestore.Update{{Path: "participants", Value: []string{a.uid}}}); err != nil {
		t.Fatal(err)
	}

	e := newDMChain(t, nil)
	_, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: messaging.ConversationID(a.uid, "uid-nobody-at-all")})
	wireError(t, err, connect.CodeNotFound)
	want := wireBytes(t, err)
	_, err = e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: convID(a, b)})
	if connect.CodeOf(err) != connect.CodeNotFound { // fails today: the answer is INTERNAL
		t.Errorf("ListMessages on the malformed document = %v, want NOT_FOUND", err)
	} else if got := wireBytes(t, err); got != want {
		t.Errorf("ListMessages bytes differ from an unknown id's:\n got  %q\n want %q", got, want)
	}
	_, serr := e.msg.SendMessage(context.Background(), authed(a.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("dm"), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID(a, b)}, Text: "anyone there?",
	}))
	wireError(t, serr, connect.CodeNotFound)
	if got := wireBytes(t, serr); got != want {
		t.Errorf("SendMessage by conversation_id bytes differ from an unknown id's:\n got  %q\n want %q", got, want)
	}
}

// The same scenario for an account whose blockedBy is intact (the control of the test above): the request is hidden and
// the accepted conversation is read-only, on the list and in the thread header.
func TestMessagingChain_BlockedByCallerReadSide(t *testing.T) {
	readSideAfterBlocked(t, false)
}

// readSideAfterBlocked: x has one REQUEST from asker and one accepted conversation with friend, then both block x; with
// overflowed, x's blockedBy has dropped them (x is blocked by so many accounts that the array stopped listing blockers).
func readSideAfterBlocked(t *testing.T, overflowed bool) {
	t.Helper()
	setup := newDMChain(t, nil)
	x, asker, friend := setup.user(t), setup.user(t), setup.user(t)
	setup.mustSend(t, asker, x, "a request") // not mutual: lands in x's Requests
	setup.mutual(t, x, friend)
	setup.mustSend(t, friend, x, "an accepted conversation")
	setup.block(t, asker, x)
	setup.block(t, friend, x)
	if overflowed {
		setup.overflow(t, x, asker, friend)
	}

	e := newDMChain(t, nil)
	reqs, err := e.listConvs(x, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_REQUESTS})
	if err != nil {
		t.Fatal(err)
	}
	if len(reqs.GetConversations()) != 0 {
		t.Errorf("REQUESTS lists %d entries from an account that blocked the caller, want 0", len(reqs.GetConversations()))
	}
	inbox, err := e.listConvs(x, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.GetConversations()) != 1 {
		t.Fatalf("INBOX lists %d conversations, want the 1 with the friend (a blocked peer stays, read-only)", len(inbox.GetConversations()))
	}
	if inbox.GetConversations()[0].GetCanReply() {
		t.Error("INBOX conversation with an account that blocked the caller reads can_reply = true")
	}
	th, err := e.listMsgs(x, &messagingv1.ListMessagesRequest{ConversationId: convID(x, friend)})
	if err != nil {
		t.Fatal(err)
	}
	if th.GetConversation().GetCanReply() {
		t.Error("ListMessages header reads can_reply = true for a conversation with an account that blocked the caller")
	}
}
