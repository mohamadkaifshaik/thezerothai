//go:build integration

package apiserver

// Report a message (ADR-0027 D12, plan W7-12) over the real Build chain on the emulators: ReportContent with a MESSAGE target
// through the account-status, rate-limit and degraded-mode interceptors, the flag matrix (reports on for the caller, messaging
// only not globally off), the participant matrix with byte-identical NOT_FOUND, the evidence and the report log line (no
// text), the budget of the RPC doc comment (6 reads cold, 3 warm, 2 writes) asserted with budgettest on the logged fs_reads /
// fs_writes, the moderator takedown as both participants see it, and the reporter's erasure. Chains that measure are booted
// AFTER the data is written, so no cache is warm (a cold instance).

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const rpcReportContent = "/dzeroth.moderation.v1.ModerationService/ReportContent"

// reportsOn turns FEATURE_REPORTS on for everyone and lifts the per-minute report bucket (seeding from one address would trip it).
func reportsOn(c *config.Config) {
	c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.On}
	c.RateLimit.ReportPerMinute = 1_000_000
}

// reportChain is a messaging chain with reports on (and messaging on unless mutate changes it).
func newReportChain(t *testing.T, mutate func(*config.Config)) *dmChain {
	t.Helper()
	return newDMChain(t, func(c *config.Config) {
		reportsOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
}

func (e *dmChain) report(who dmUser, convID, msgID string) (*moderationv1.ReportContentResponse, error) {
	r, err := e.moderation.ReportContent(context.Background(), authed(who.token, &moderationv1.ReportContentRequest{
		IdempotencyKey: contractKey("msg-report"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_MESSAGE,
		TargetId: convID + ":" + msgID, Reason: moderationv1.ReportReason_REPORT_REASON_HARASSMENT, Note: "please look",
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *dmChain) reportDoc(t *testing.T, reportID string) map[string]any {
	t.Helper()
	snap, err := e.fs.Collection("reports").Doc(reportID).Get(context.Background())
	if err != nil {
		t.Fatalf("report %s: %v", reportID, err)
	}
	return snap.Data()
}

func (e *dmChain) handleOf(t *testing.T, u dmUser) string {
	t.Helper()
	snap, err := e.fs.Collection("users").Doc(u.uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	h, _ := snap.DataAt("handle")
	return fmt.Sprint(h)
}

// logText is everything the API logged so far.
func (e *dmChain) logText() string {
	e.logs.mu.Lock()
	defer e.logs.mu.Unlock()
	return e.logs.buf.String()
}

// thread is a mutual conversation where a wrote m1 and m2 and b answered with m3.
type reportThread struct {
	a, b       dmUser
	convID     string
	m1, m2, m3 string
}

func (e *dmChain) reportThread(t *testing.T) reportThread {
	t.Helper()
	a, b := e.user(t), e.user(t)
	e.mutual(t, a, b)
	r1 := e.mustSend(t, a, b, "secret text one from a")
	r2 := e.mustSend(t, a, b, "secret text two from a")
	r3 := e.mustSend(t, b, a, "secret text three from b")
	return reportThread{a: a, b: b, convID: messaging.ConversationID(a.uid, b.uid), m1: r1.GetMessage().GetId(), m2: r2.GetMessage().GetId(), m3: r3.GetMessage().GetId()}
}

func requireCode(t *testing.T, err error, code connect.Code) *commonv1.ErrorDetail {
	t.Helper()
	return wireError(t, err, code)
}

// B reports A's message: a report with exactly that message as evidence exists, a repeat is already_reported, and the report
// log line names the target type but never the text.
func TestMessageReport_EvidenceDuplicateAndLog(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)

	res, err := e.report(th.b, th.convID, th.m1)
	if err != nil {
		t.Fatalf("ReportContent: %v", err)
	}
	if res.GetAlreadyReported() || res.GetReportId() != moderation.ReportID(th.b.uid, moderation.TargetMessage, th.convID+":"+th.m1) {
		t.Fatalf("response = %v", res)
	}
	doc := e.reportDoc(t, res.GetReportId())
	ev, _ := doc["evidence"].(map[string]any)
	if doc["targetType"] != "MESSAGE" || doc["targetId"] != th.convID+":"+th.m1 || doc["targetOwnerId"] != th.a.uid || doc["reporterId"] != th.b.uid ||
		doc["status"] != "OPEN" || doc["reason"] != "HARASSMENT" || doc["note"] != "please look" {
		t.Errorf("report = %v", doc)
	}
	if ev["text"] != "secret text one from a" || ev["authorHandle"] != e.handleOf(t, th.a) || ev["postCreatedAt"] == nil {
		t.Errorf("evidence = %v, want that one message's text, the sender's handle and its time", ev)
	}
	// Nothing else of the conversation is copied: the other messages' text is nowhere in the report.
	if raw := fmt.Sprint(doc); strings.Contains(raw, "two from a") || strings.Contains(raw, "three from b") {
		t.Errorf("the report holds more than the reported message: %v", doc)
	}

	again, err := e.report(th.b, th.convID, th.m1)
	if err != nil || !again.GetAlreadyReported() || again.GetReportId() != res.GetReportId() {
		t.Fatalf("repeat = %v, %v, want already_reported with the same id", again, err)
	}
	// B can also report the next message: a second report, not a duplicate.
	if r2, err := e.report(th.b, th.convID, th.m2); err != nil || r2.GetAlreadyReported() || r2.GetReportId() == res.GetReportId() {
		t.Fatalf("second message: %v, %v", r2, err)
	}

	lines := e.logs.requestLines(rpcReportContent)
	if len(lines) != 3 {
		t.Fatalf("%d report lines, want 3", len(lines))
	}
	for i, want := range []string{"created", "duplicate", "created"} {
		if lines[i]["report_target"] != "MESSAGE" || lines[i]["outcome"] != want {
			t.Errorf("line %d: report_target=%v outcome=%v, want MESSAGE/%s", i, lines[i]["report_target"], lines[i]["outcome"], want)
		}
		if lines[i]["conversation_hash"] == "" || lines[i]["conversation_hash"] == nil {
			t.Errorf("line %d has no conversation_hash", i)
		}
	}
	all := e.logText()
	for _, secret := range []string{"secret text", th.convID, th.m1, th.m2, th.a.uid, th.b.uid, "please look"} {
		if strings.Contains(all, secret) {
			t.Errorf("the API log contains %q", secret)
		}
	}
}

// The participant matrix. A participant may report the peer's VISIBLE message; the own message is VALIDATION target_id; and
// a non-participant, an unknown conversation, an unknown message, a taken-down message and a message tombstoned by its
// sender's account deletion all answer NOT_FOUND with the very same bytes.
func TestMessageReport_ParticipantMatrixAndOneNotFound(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)
	stranger := e.user(t)

	if _, err := e.report(th.b, th.convID, th.m1); err != nil {
		t.Fatalf("b reports a's message: %v", err)
	}
	if _, err := e.report(th.a, th.convID, th.m3); err != nil {
		t.Fatalf("a reports b's message: %v", err)
	}
	d := requireCode(t, errOf(e.report(th.a, th.convID, th.m1)), connect.CodeInvalidArgument)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != "target_id" {
		t.Errorf("own message: reason %v meta %v, want VALIDATION target_id", d.GetReason(), d.GetMetadata())
	}
	if _, err := e.report(th.b, th.convID, th.m3); err == nil {
		t.Error("b reported their own message")
	}

	// A taken-down message, and one whose sender deleted the account.
	repo := messaging.NewFirestoreRepo(e.fs, nil)
	if _, err := repo.TakedownMessage(context.Background(), th.convID, th.m2, false); err != nil {
		t.Fatal(err)
	}
	d2 := e.user(t)
	e.mutual(t, th.a, d2)
	gone := e.mustSend(t, d2, th.a, "from the account that is deleted")
	goneConv := messaging.ConversationID(th.a.uid, d2.uid)
	er := messaging.NewEraser(repo, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	var cp []byte
	for i := 0; ; i++ {
		next, done, err := er.PurgeUser(context.Background(), d2.uid, cp)
		if err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
		if cp = next; i > 200 {
			t.Fatal("eraser did not finish")
		}
	}

	// A real message under another real conversation of the caller: a is a participant of both, the message is in one.
	x := e.user(t)
	e.mutual(t, th.a, x)
	e.mustSend(t, x, th.a, "a message in the other conversation")
	otherConv := messaging.ConversationID(th.a.uid, x.uid)

	unknown := strings.Repeat("0", 32)
	cases := map[string]error{
		"non-participant on a real message":                                    errOf(e.report(stranger, th.convID, th.m1)),
		"wrong conversation (a message of another conversation of the caller)": errOf(e.report(th.a, otherConv, th.m3)),
		"unknown message":            errOf(e.report(th.b, th.convID, unknown)),
		"unknown conversation":       errOf(e.report(th.b, unknown, th.m1)),
		"unknown both":               errOf(e.report(stranger, unknown, unknown)),
		"taken down":                 errOf(e.report(th.b, th.convID, th.m2)),
		"sender deleted the account": errOf(e.report(th.a, goneConv, gone.GetMessage().GetId())),
	}
	var want string
	for name, err := range cases {
		requireCode(t, err, connect.CodeNotFound)
		got := wireBytes(t, err)
		if want == "" {
			want = got
		}
		if got != want {
			t.Errorf("%s: %q differs from %q", name, got, want)
		}
	}
	if strings.Contains(want, "conversation") || strings.Contains(want, "participant") {
		t.Errorf("the NOT_FOUND text says too much: %q", want)
	}
}

func errOf[T any](_ T, err error) error { return err }

// A message report needs `reports` on for the caller and `messaging` only not globally off (F6): a user dropped from the
// messaging allowlist can still report. Disabled calls cost at most the interceptor's one read.
func TestMessageReport_FlagMatrix(t *testing.T) {
	setup := newReportChain(t, nil)
	th := setup.reportThread(t)

	tests := []struct {
		name     string
		mutate   func(c *config.Config)
		disabled bool
		feature  string
	}{
		{"reports off", func(c *config.Config) { c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.Off} }, true, ""},
		{"reports allowlist without the reporter", func(c *config.Config) {
			c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}
		}, true, ""},
		{"messaging off", func(c *config.Config) { c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Off} }, true, "messaging"},
		{"messaging allowlist without the reporter", func(c *config.Config) {
			c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}
		}, false, ""},
		{"messaging percent 0", func(c *config.Config) {
			c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Percent, Percent: 0}
		}, false, ""},
		{"messaging on", nil, false, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newReportChain(t, tt.mutate) // a cold instance per case
			_, err := e.report(th.b, th.convID, th.m1)
			got := e.lineBudget(t, rpcReportContent)
			if tt.disabled {
				d := requireCode(t, err, connect.CodeFailedPrecondition)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != tt.feature {
					t.Errorf("reason %v meta %v, want FEATURE_DISABLED feature=%q", d.GetReason(), d.GetMetadata(), tt.feature)
				}
				budgettest.Assert(t, "ReportContent disabled", got, budgettest.Budget{Reads: 1, Writes: 0})
				return
			}
			if err != nil {
				t.Fatalf("ReportContent: %v", err)
			}
		})
	}

	// A POST report never looks at messaging.
	e := newReportChain(t, func(c *config.Config) { c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.Off} })
	_, err := e.moderation.ReportContent(context.Background(), authed(th.b.token, &moderationv1.ReportContentRequest{
		IdempotencyKey: contractKey("post-report"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST,
		TargetId: "0000000000000000001", Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
	}))
	if d := requireCode(t, err, connect.CodeNotFound); d.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Errorf("a POST report was refused for messaging: %v", d)
	}
}

// A conversation with a blocked peer stays open so the user can still report it (ADR-0027 D4 "On read").
func TestMessageReport_BlockedPeerIsStillReportable(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)
	if _, err := e.graph.Block(context.Background(), authed(th.b.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("dm-block"), UserId: th.a.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	if _, err := e.report(th.b, th.convID, th.m1); err != nil {
		t.Fatalf("b blocked a and then could not report a's message: %v", err)
	}
	// The blocked side can report too: a is blocked by b and still reads b's message.
	if _, err := e.report(th.a, th.convID, th.m3); err != nil {
		t.Fatalf("a (blocked by b) could not report b's message: %v", err)
	}
}

// The budget of the RPC doc comment, through the whole chain: 6 reads cold (interceptor, conversation, message, sender profile,
// report, quotas) and 2 writes; a second message in the same conversation on the same instance 3 reads (the conversation, the
// sender's profile and the caller's profile are cached; the message, the report and the quotas are not); a repeat 2 reads
// (message, report) and 0 writes.
func TestMessageReport_BudgetColdWarmAndDuplicate(t *testing.T) {
	th := newReportChain(t, nil).reportThread(t)
	e := newReportChain(t, nil) // booted AFTER the data was written: a cold instance

	measure := func(label string, wantReads, wantWrites int64, run func()) {
		t.Helper()
		run()
		got := e.lineBudget(t, rpcReportContent)
		budgettest.Assert(t, "ReportContent MESSAGE "+label, got, budgettest.Budget{Reads: wantReads, Writes: wantWrites})
		if got.Reads() != wantReads || got.Writes() != wantWrites || got.Deletes() != 0 {
			t.Errorf("%s: reads/writes/deletes = %d/%d/%d, want %d/%d/0", label, got.Reads(), got.Writes(), got.Deletes(), wantReads, wantWrites)
		}
		t.Logf("REPORTBUDGET case=%q reads=%d writes=%d deletes=%d", label, got.Reads(), got.Writes(), got.Deletes())
	}
	measure("cold", 6, 2, func() {
		if _, err := e.report(th.b, th.convID, th.m1); err != nil {
			t.Fatal(err)
		}
	})
	measure("warm, a second message", 3, 2, func() {
		if _, err := e.report(th.b, th.convID, th.m2); err != nil {
			t.Fatal(err)
		}
	})
	measure("duplicate", 2, 0, func() {
		if r, err := e.report(th.b, th.convID, th.m2); err != nil || !r.GetAlreadyReported() {
			t.Fatalf("duplicate = %v, %v", r, err)
		}
	})
	measure("refused, unknown message", 1, 0, func() { // the warm conversation costs 0 and the message read 1
		_ = errOf(e.report(th.b, th.convID, strings.Repeat("9", 32)))
	})
}

// A moderator takedown: both participants see the message as removed (state REMOVED, no text) on a first page, and the inbox
// preview of both says so. Then the reporter deletes the account: the report stays as evidence with the reporter cleared.
func TestMessageReport_TakedownAndReporterErasure(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)
	res, err := e.report(th.a, th.convID, th.m3) // a reports b's last message
	if err != nil {
		t.Fatal(err)
	}
	repo := messaging.NewFirestoreRepo(e.fs, nil)
	tr, err := repo.TakedownMessage(context.Background(), th.convID, th.m3, false)
	if err != nil || !tr.Wrote || tr.Entries != 2 {
		t.Fatalf("takedown = %+v, %v", tr, err)
	}

	for _, u := range []dmUser{th.a, th.b} {
		r, err := e.msg.ListMessages(context.Background(), authed(u.token, &messagingv1.ListMessagesRequest{ConversationId: th.convID}))
		if err != nil {
			t.Fatal(err)
		}
		var found bool
		for _, m := range r.Msg.GetMessages() {
			if m.GetId() == th.m3 {
				found = true
				if m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || m.GetText() != "" {
					t.Errorf("%s sees state %v text %q", u.uid, m.GetState(), m.GetText())
				}
			} else if m.GetText() == "" {
				t.Errorf("an untouched message lost its text: %v", m)
			}
		}
		if !found {
			t.Errorf("%s's thread lost the tombstone", u.uid)
		}
		l, err := e.msg.ListConversations(context.Background(), authed(u.token, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX}))
		if err != nil {
			t.Fatal(err)
		}
		if p := l.Msg.GetConversations()[0].GetLastMessage(); p.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || p.GetSnippet() != "" {
			t.Errorf("%s's preview = %v %q", u.uid, p.GetState(), p.GetSnippet())
		}
	}
	// The takedown does not touch the report: the evidence is the message as it was reported.
	if ev, _ := e.reportDoc(t, res.GetReportId())["evidence"].(map[string]any); ev["text"] != "secret text three from b" {
		t.Errorf("evidence after the takedown = %v", ev)
	}

	// The reporter's erasure (ADR-0016 D5, unchanged): reporterId cleared, the evidence kept for the moderator.
	mrepo := moderation.NewFirestoreRepo(e.fs, quota.New(e.fs))
	if _, done, err := mrepo.PurgeReporter(context.Background(), th.a.uid, moderation.Checkpoint{}); err != nil || !done {
		t.Fatalf("PurgeReporter: done=%v err=%v", done, err)
	}
	doc := e.reportDoc(t, res.GetReportId())
	ev, _ := doc["evidence"].(map[string]any)
	if doc["reporterId"] != "" || ev["text"] != "secret text three from b" || doc["targetOwnerId"] != th.b.uid {
		t.Errorf("after the reporter's erasure: %v", doc)
	}
	// Resolving it keeps the retention of every other target (ADR-0016 D5): expireAt = resolved + 90 days, and the evidence is
	// what the TTL deletes then.
	resolvedAt := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	rr, err := mrepo.Resolve(context.Background(), res.GetReportId(), moderation.ResolutionTakedown, "removed", resolvedAt)
	if err != nil {
		t.Fatal(err)
	}
	if want := resolvedAt.Add(moderation.Retention); !rr.ExpireAt.Equal(want) || rr.Evidence == nil || rr.Evidence.Text != "secret text three from b" {
		t.Errorf("resolved report = expire %v evidence %+v, want expire %v with the evidence kept until then", rr.ExpireAt, rr.Evidence, want)
	}
}

// The recipient of a message request (their entry is in dmRequests, not dmInbox) can report the requester's message, with the
// same evidence and cost as anyone else, and before accepting.
func TestMessageReport_RequestRecipientCanReport(t *testing.T) {
	e := newReportChain(t, nil)
	sender, recipient := e.user(t), e.user(t) // no follow: the first message is a request
	sent := e.mustSend(t, sender, recipient, "an unwanted request")
	if _, ok := e.entry(t, recipient, sender, "dmRequests"); !ok {
		t.Fatal("setup: the recipient has no entry in dmRequests")
	}
	if _, ok := e.entry(t, recipient, sender, "dmInbox"); ok {
		t.Fatal("setup: the recipient has an inbox entry before accepting")
	}
	convID := messaging.ConversationID(sender.uid, recipient.uid)
	res, err := e.report(recipient, convID, sent.GetMessage().GetId())
	if err != nil || res.GetAlreadyReported() {
		t.Fatalf("the request recipient's report: %v, %v", res, err)
	}
	ev, _ := e.reportDoc(t, res.GetReportId())["evidence"].(map[string]any)
	if ev["text"] != "an unwanted request" || ev["authorHandle"] != e.handleOf(t, sender) {
		t.Errorf("evidence = %v", ev)
	}
	// The requester can report nothing of the request: the message is their own.
	d := requireCode(t, errOf(e.report(sender, convID, sent.GetMessage().GetId())), connect.CodeInvalidArgument)
	if d.GetMetadata()["field"] != "target_id" {
		t.Errorf("own request message: %v", d.GetMetadata())
	}
}

// Delete-for-me (clearedAt set for the caller, their entry removed) does not take the message out of reach of a report: the
// founder confirmed it stays reportable (ADR-0027 D12). The delete goes through the real DeleteConversation RPC.
func TestMessageReport_StaysReportableAfterDeleteForMe(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)
	convID := th.convID
	ctx := context.Background()
	if _, err := e.msg.DeleteConversation(ctx, authed(th.b.token, &messagingv1.DeleteConversationRequest{
		IdempotencyKey: contractKey("dm-delete"), ConversationId: convID,
	})); err != nil {
		t.Fatalf("DeleteConversation: %v", err)
	}
	if _, ok := e.entry(t, th.b, th.a, "dmInbox"); ok {
		t.Fatal("setup: b's entry survived the delete")
	}
	// Premise: b's thread no longer shows a's messages.
	lm, err := e.msg.ListMessages(ctx, authed(th.b.token, &messagingv1.ListMessagesRequest{ConversationId: convID}))
	if err != nil || len(lm.Msg.GetMessages()) != 0 {
		t.Fatalf("setup: b still sees %d messages (%v)", len(lm.Msg.GetMessages()), err)
	}
	res, err := e.report(th.b, convID, th.m1)
	if err != nil || res.GetAlreadyReported() {
		t.Fatalf("report after delete-for-me: %v, %v", res, err)
	}
	if ev, _ := e.reportDoc(t, res.GetReportId())["evidence"].(map[string]any); ev["text"] != "secret text one from a" {
		t.Errorf("evidence = %v", ev)
	}
}

// Cold budgets of the refusals and the duplicate, each on its own cold instance (booted after the data was written). The
// RPC doc comment promises at most 3 reads for a refusal and 6 for a duplicate.
func TestMessageReport_ColdBudgetsOfRefusalsAndDuplicate(t *testing.T) {
	setup := newReportChain(t, nil)
	th := setup.reportThread(t)
	stranger := setup.user(t)
	if _, err := setup.report(th.b, th.convID, th.m1); err != nil { // the report a duplicate repeats
		t.Fatal(err)
	}
	unknownMsg := strings.Repeat("9", 32)

	tests := []struct {
		name      string
		who       dmUser
		conv, msg string
		wantReads int64
		duplicate bool
	}{
		{"non-participant: interceptor, conversation", stranger, th.convID, th.m1, 2, false},
		{"participant, unknown message: interceptor, conversation, message", th.b, th.convID, unknownMsg, 3, false},
		{"duplicate: interceptor, conversation, message, sender profile, report", th.b, th.convID, th.m1, 5, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newReportChain(t, nil) // a cold instance
			res, err := e.report(tt.who, tt.conv, tt.msg)
			if tt.duplicate {
				if err != nil || !res.GetAlreadyReported() {
					t.Fatalf("duplicate = %v, %v", res, err)
				}
			} else {
				requireCode(t, err, connect.CodeNotFound)
			}
			budgettest.Assert(t, "ReportContent MESSAGE cold "+tt.name, e.lineBudget(t, rpcReportContent), budgettest.Budget{Reads: tt.wantReads, Writes: 0})
		})
	}
}

// A non-participant gets the very same bytes, and the very same cost, whether the instance has the conversation cached or not
// (W7-28, security review W7-22 H-1): the cache answers only a participant, so a probe is always the interceptor's read plus one
// fresh conversation read (2 cold, 2 warm) and leaves nothing in the cache. No read count or timing separates "exists" from
// "missing" for a caller who is not in the conversation.
func TestMessageReport_NonParticipantSameBytesWarmOrCold(t *testing.T) {
	setup := newReportChain(t, nil)
	th := setup.reportThread(t)
	stranger := setup.user(t)

	cold := newReportChain(t, nil)
	coldErr := errOf(cold.report(stranger, th.convID, th.m1))
	coldReads := cold.lineBudget(t, rpcReportContent).Reads()

	warm := newReportChain(t, nil)
	if _, err := warm.report(th.b, th.convID, th.m2); err != nil { // a participant warms the conversation cache
		t.Fatal(err)
	}
	warmErr := errOf(warm.report(stranger, th.convID, th.m1))
	warmReads := warm.lineBudget(t, rpcReportContent).Reads()

	unknownErr := errOf(warm.report(stranger, strings.Repeat("0", 32), strings.Repeat("0", 32)))
	requireCode(t, coldErr, connect.CodeNotFound)
	requireCode(t, warmErr, connect.CodeNotFound)
	if wireBytes(t, coldErr) != wireBytes(t, warmErr) || wireBytes(t, warmErr) != wireBytes(t, unknownErr) {
		t.Errorf("bytes differ: cold %q, warm %q, unknown conversation %q", wireBytes(t, coldErr), wireBytes(t, warmErr), wireBytes(t, unknownErr))
	}
	t.Logf("non-participant reads: cold %d, warm %d", coldReads, warmReads)
	if coldReads != 2 || warmReads != 2 {
		t.Errorf("reads cold/warm = %d/%d, want 2/2", coldReads, warmReads)
	}
}
