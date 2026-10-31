package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var (
	testConvID    = strings.Repeat("c", 32)
	testMsgID     = strings.Repeat("d", 32)
	testMsgTarget = testConvID + ":" + testMsgID
)

type takedownCall struct {
	conv, msg string
	dryRun    bool
}

// fakeMessageModerator is a messaging.Moderator that records its calls and answers from a script.
type fakeMessageModerator struct {
	calls []takedownCall
	res   messaging.TakedownResult
	err   error
}

func (f *fakeMessageModerator) TakedownMessage(_ context.Context, convID, msgID string, dryRun bool) (messaging.TakedownResult, error) {
	f.calls = append(f.calls, takedownCall{convID, msgID, dryRun})
	if f.err != nil {
		return messaging.TakedownResult{}, f.err
	}
	res := f.res
	if res.Before == "" {
		res = messaging.TakedownResult{Before: messaging.MessageStateVisible, After: messaging.MessageStateRemoved, Entries: 2, Wrote: !dryRun}
	}
	if dryRun {
		res.Wrote = false
	}
	return res, nil
}

type msgFixture struct {
	ops *fakeOps
	mod *fakeMessageModerator
}

func newMsgFixture() *msgFixture {
	return &msgFixture{ops: &fakeOps{report: &moderation.Report{
		TargetType: moderation.TargetMessage, TargetID: testMsgTarget, TargetOwnerID: "u2", Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{Text: "you are worthless", AuthorHandle: "mallory", PostCreatedAt: time.Unix(7, 0).UTC()},
	}}, mod: &fakeMessageModerator{}}
}

func (m *msgFixture) run(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{reports: m.ops, messages: m.mod, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestMessagesTakedown_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no sub-command", []string{"messages", "--project", "dzeroth-dev"}, "messages needs a sub-command"},
		{"unknown sub-command", []string{"messages", "restore", testMsgTarget, "--project", "dzeroth-dev"}, "messages needs a sub-command"},
		{"no target", []string{"messages", "takedown", "--project", "dzeroth-dev"}, "CONVERSATION_ID:MESSAGE_ID"},
		{"target without separator", []string{"messages", "takedown", testConvID + testMsgID, "--project", "dzeroth-dev"}, "CONVERSATION_ID:MESSAGE_ID"},
		{"target with upper-case hex", []string{"messages", "takedown", strings.ToUpper(testMsgTarget), "--project", "dzeroth-dev"}, "CONVERSATION_ID:MESSAGE_ID"},
		{"a post id is not a message", []string{"messages", "takedown", testPostID, "--project", "dzeroth-dev"}, "CONVERSATION_ID:MESSAGE_ID"},
		{"bad report id", []string{"messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", "zz"}, "32-character report id"},
		{"note without report", []string{"messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--note", "x"}, "needs --report"},
		{"no project", []string{"messages", "takedown", testMsgTarget}, "--project is required"},
		{"unquoted note must not swallow --dry-run", []string{"messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID, "--note", "two", "words", "--dry-run"}, "unexpected argument"},
		{"a second positional argument", []string{"messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "extra"}, "unexpected argument"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newMsgFixture()
			code, _, stderr := f.run("", tt.args...)
			if code != 2 || !strings.Contains(stderr, tt.want) {
				t.Fatalf("code=%d stderr=%q, want code 2 containing %q", code, stderr, tt.want)
			}
			if len(f.mod.calls) != 0 || len(f.ops.resolved) != 0 {
				t.Error("a rejected command must not touch storage")
			}
		})
	}
}

// The target is the first argument after the sub-command (the plan's form) and the flags follow it; no --uid is needed.
func TestMessagesTakedown_TakesDownAndResolvesTheReport(t *testing.T) {
	t.Parallel()
	f := newMsgFixture()
	code, out, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID, "--note", "harassment")
	if code != 0 {
		t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
	}
	if len(f.mod.calls) != 1 || f.mod.calls[0] != (takedownCall{testConvID, testMsgID, false}) {
		t.Fatalf("calls = %+v", f.mod.calls)
	}
	if f.ops.resolved[testReportID] != moderation.ResolutionTakedown || f.ops.notes[testReportID] != "harassment" {
		t.Errorf("resolved = %v notes = %v", f.ops.resolved, f.ops.notes)
	}
	for _, want := range []string{"VISIBLE -> REMOVED", "2 inbox preview(s) rewritten", "audit: messages takedown project=dzeroth-dev",
		"before=VISIBLE after=REMOVED previews=2 wrote=true dry_run=false report=" + testReportID, "RESOLVED (TAKEDOWN)", "cost: reads=0 writes=0"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	// A takedown now reaches devices that cached the thread or the inbox: the output no longer warns that they keep the text.
	if strings.Contains(out, "keeps it until") || !strings.Contains(out, "drops the text at its next poll or inbox refresh") {
		t.Errorf("the output misstates how a takedown reaches cached devices:\n%s", out)
	}
	// Without --report there is nothing to resolve and the same takedown still runs.
	f = newMsgFixture()
	if code, out, stderr = f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev"); code != 0 || len(f.ops.resolved) != 0 || len(f.mod.calls) != 1 || !strings.Contains(out, "report=-") {
		t.Fatalf("no report: code=%d out=%q stderr=%q resolved=%v", code, out, stderr, f.ops.resolved)
	}
}

// The output carries one-way hashes of the ids and never the ids themselves, the message text, or a handle. The conversation
// hash is the keyed one of the request logs (W7-34, L-7) when CURSOR_HMAC_KEY is set, and never the plain SHA-256.
// Not parallel: it sets the environment and the logger's process-wide key.
func TestMessagesTakedown_OutputHasNoIDsAndNoText(t *testing.T) {
	t.Setenv(cursorKeyEnv, "test-cursor-hmac-key")
	f := newMsgFixture()
	code, out, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	for _, secret := range []string{testConvID, testMsgID, "you are worthless", "mallory", "u2"} {
		if strings.Contains(out, secret) {
			t.Errorf("output contains %q:\n%s", secret, out)
		}
	}
	for _, want := range []string{"conversation_hash=" + logger.HashConversation(testConvID), "message_hash=" + logger.HashUID(testMsgID), "at=1970-01-12T13:46:40Z"} {
		if !strings.Contains(out, want) {
			t.Errorf("audit line lacks %q:\n%s", want, out)
		}
	}
}

func TestMessagesTakedown_DryRunWritesNothing(t *testing.T) {
	t.Parallel()
	f := newMsgFixture()
	code, out, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID, "--dry-run")
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if len(f.mod.calls) != 1 || !f.mod.calls[0].dryRun {
		t.Fatalf("calls = %+v, want one dry-run call", f.mod.calls)
	}
	if len(f.ops.resolved) != 0 {
		t.Errorf("a dry run resolved %v", f.ops.resolved)
	}
	for _, want := range []string{"dry-run: would set the message REMOVED (text cleared), bump the conversation revision and rewrite 2 inbox preview(s): 4 writes (nothing written)",
		"wrote=false dry_run=true", "dry-run: would resolve report " + testReportID + " as TAKEDOWN"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "VISIBLE -> REMOVED") {
		t.Errorf("a dry run claimed a change:\n%s", out)
	}
}

func TestMessagesTakedown_AlreadyTombstonedIsIdempotent(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct{ state, want string }{
		"removed":         {messaging.MessageStateRemoved, "already REMOVED; nothing written"},
		"deleted account": {messaging.MessageStateDeletedAccount, "already DELETED_ACCOUNT (its sender deleted the account"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newMsgFixture()
			f.mod.res = messaging.TakedownResult{Before: tc.state, After: tc.state}
			code, out, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID)
			if code != 0 || !strings.Contains(out, tc.want) || !strings.Contains(out, "wrote=false") {
				t.Fatalf("code=%d out=%q stderr=%q", code, out, stderr)
			}
			// The content is gone either way, so the report still closes.
			if f.ops.resolved[testReportID] != moderation.ResolutionTakedown {
				t.Errorf("resolved = %v", f.ops.resolved)
			}
		})
	}
}

func TestMessagesTakedown_UnknownMessageIsAnErrorAndResolvesNothing(t *testing.T) {
	t.Parallel()
	f := newMsgFixture()
	f.mod.err = messaging.ErrNotFound
	code, _, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID)
	if code != 1 || !strings.Contains(stderr, "no such message") || len(f.ops.resolved) != 0 {
		t.Fatalf("code=%d stderr=%q resolved=%v", code, stderr, f.ops.resolved)
	}
	f = newMsgFixture()
	f.mod.err = errors.New("firestore down")
	if code, _, _ = f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev"); code != 1 {
		t.Errorf("storage error: code=%d, want 1", code)
	}
}

func TestMessagesTakedown_ReportMustBeAboutThisMessage(t *testing.T) {
	t.Parallel()
	other := strings.Repeat("e", 32)
	tests := []struct {
		name   string
		report *moderation.Report
		want   string
	}{
		{"a report about a post", &moderation.Report{TargetType: moderation.TargetPost, TargetID: testPostID, Status: moderation.StatusOpen}, "not MESSAGE"},
		{"a report about another message", &moderation.Report{TargetType: moderation.TargetMessage, TargetID: testConvID + ":" + other, Status: moderation.StatusOpen}, "not MESSAGE"},
		{"a report about an account", &moderation.Report{TargetType: moderation.TargetAccount, TargetID: "u2", Status: moderation.StatusOpen}, "not MESSAGE"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newMsgFixture()
			f.ops.report = tt.report
			code, _, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID)
			if code != 1 || !strings.Contains(stderr, tt.want) || len(f.mod.calls) != 0 || len(f.ops.resolved) != 0 {
				t.Fatalf("code=%d stderr=%q calls=%v resolved=%v", code, stderr, f.mod.calls, f.ops.resolved)
			}
		})
	}
	t.Run("an already resolved report warns and the action still applies", func(t *testing.T) {
		t.Parallel()
		f := newMsgFixture()
		f.ops.report.Status, f.ops.report.Resolution = moderation.StatusResolved, moderation.ResolutionDismissed
		code, out, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev", "--report", testReportID)
		if code != 0 || !strings.Contains(out, "already RESOLVED (DISMISSED)") || len(f.mod.calls) != 1 {
			t.Fatalf("code=%d out=%q stderr=%q calls=%v", code, out, stderr, f.mod.calls)
		}
	})
	t.Run("without --report no report is read", func(t *testing.T) {
		t.Parallel()
		f := newMsgFixture()
		f.ops.getErr = errors.New("must not be read")
		if code, _, stderr := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev"); code != 0 {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
	})
}

// A production project needs the typed project id first, exactly like every other opsctl command; a wrong answer writes
// nothing.
func TestMessagesTakedown_ProdNeedsTheTypedConfirmation(t *testing.T) {
	t.Parallel()
	f := newMsgFixture()
	code, _, stderr := f.run("nope\n", "messages", "takedown", testMsgTarget, "--project", "dzeroth-prod")
	if code != 1 || !strings.Contains(stderr, "confirmation did not match") || len(f.mod.calls) != 0 {
		t.Fatalf("wrong answer: code=%d stderr=%q calls=%v", code, stderr, f.mod.calls)
	}
	code, out, stderr := f.run("dzeroth-prod\n", "messages", "takedown", testMsgTarget, "--project", "dzeroth-prod")
	if code != 0 || len(f.mod.calls) != 1 || !strings.Contains(out, "PRODUCTION project") {
		t.Fatalf("typed project: code=%d out=%q stderr=%q calls=%v", code, out, stderr, f.mod.calls)
	}
}

// `opsctl reports show` prints a MESSAGE report as what it is, not as a post.
func TestReportsShow_MessageEvidence(t *testing.T) {
	t.Parallel()
	f := newMsgFixture()
	code, out, stderr := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	for _, want := range []string{"target   MESSAGE " + testMsgTarget + " (owner u2)", "evidence message from @mallory sent 1970-01-01T00:00:07Z (PRIVATE text, copied at report time): \"you are worthless\""} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "evidence post by") {
		t.Errorf("a message report printed as a post:\n%s", out)
	}
	// W7-36: the child document is gone (its TTL ran): say so, and never print an empty text as if it were the message.
	f.ops.report.Evidence.TextExpired, f.ops.report.Evidence.Text = true, ""
	if _, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); !strings.Contains(out, "evidence expired") || strings.Contains(out, "PRIVATE text") {
		t.Errorf("expired evidence:\n%s", out)
	}
	f.ops.report.Evidence = nil
	if _, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); !strings.Contains(out, "evidence none") {
		t.Errorf("no evidence:\n%s", out)
	}
}

func TestMessagesTakedown_ConversationHashIsKeyedNeverPlain(t *testing.T) {
	t.Setenv(cursorKeyEnv, "test-cursor-hmac-key")
	f := newMsgFixture()
	_, out, _ := f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev")
	if strings.Contains(out, "conversation_hash="+logger.HashUID(testConvID)) {
		t.Errorf("the audit line carries the plain conversation hash:\n%s", out)
	}
	t.Setenv(cursorKeyEnv, "")
	_, out, _ = f.run("", "messages", "takedown", testMsgTarget, "--project", "dzeroth-dev")
	if strings.Contains(out, logger.HashUID(testConvID)) || !strings.Contains(out, "conversation_hash=unavailable(set-CURSOR_HMAC_KEY)") {
		t.Errorf("without a key the audit line must say so, never print the plain hash:\n%s", out)
	}
}

// loghash needs no project and no Firestore, takes the key only from the environment, and prints exactly the hash.
func TestMessagesLogHash(t *testing.T) {
	t.Setenv(cursorKeyEnv, "test-cursor-hmac-key")
	f := newMsgFixture()
	code, out, stderr := f.run("", "messages", "loghash", testConvID)
	want := logger.HashConversation(testConvID)
	if code != 0 || out != want+"\n" || stderr != "" {
		t.Fatalf("code=%d out=%q stderr=%q, want exactly %q", code, out, stderr, want)
	}
	if len(want) != 16 || want == logger.HashUID(testConvID) {
		t.Errorf("hash %q must be 16 hex characters and differ from the plain hash %q", want, logger.HashUID(testConvID))
	}
	if len(f.mod.calls) != 0 {
		t.Errorf("loghash touched the moderator: %+v", f.mod.calls)
	}
	// A different key (another project, or a rotated secret) gives a different hash.
	t.Setenv(cursorKeyEnv, "another-key")
	if _, out2, _ := f.run("", "messages", "loghash", testConvID); out2 == out {
		t.Errorf("two keys gave the same hash %q", out2)
	}
	for _, tt := range []struct {
		name, key string
		args      []string
		want      string
	}{
		{"no key", "", []string{"messages", "loghash", testConvID}, "needs CURSOR_HMAC_KEY"},
		{"no id", "k", []string{"messages", "loghash"}, "needs CONVERSATION_ID"},
		{"short id", "k", []string{"messages", "loghash", "abc"}, "needs CONVERSATION_ID"},
		{"a message target", "k", []string{"messages", "loghash", testMsgTarget}, "needs CONVERSATION_ID"},
	} {
		t.Setenv(cursorKeyEnv, tt.key)
		if code, out, stderr := f.run("", tt.args...); code != 2 || out != "" || !strings.Contains(stderr, tt.want) {
			t.Errorf("%s: code=%d out=%q stderr=%q, want code 2 containing %q", tt.name, code, out, stderr, tt.want)
		}
	}
}

type fakeMigrator struct {
	pages  []messaging.PlaceholderPage
	calls  []string
	dryRun []bool
	err    error
}

func (f *fakeMigrator) MigratePlaceholder(_ context.Context, after string, dryRun bool) (messaging.PlaceholderPage, error) {
	f.calls = append(f.calls, after)
	f.dryRun = append(f.dryRun, dryRun)
	if f.err != nil {
		return messaging.PlaceholderPage{}, f.err
	}
	p := f.pages[0]
	f.pages = f.pages[1:]
	return p, nil
}

func runMigrate(m *fakeMigrator, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{placeholder: m, close: func() {}}, nil
	}
	code = run(context.Background(), append([]string{"messages", "migrate-placeholder"}, args...), strings.NewReader(""), &out, &errOut, open, time.Now)
	return code, out.String(), errOut.String()
}

func TestMessagesMigratePlaceholder(t *testing.T) {
	t.Parallel()
	pages := func() []messaging.PlaceholderPage {
		return []messaging.PlaceholderPage{
			{Last: "aa", More: true, Conversations: 50, Messages: 3, Entries: 2},
			{Last: "bb", More: false, Conversations: 4, Messages: 1, Entries: 1},
		}
	}
	for _, dry := range []bool{true, false} {
		m := &fakeMigrator{pages: pages()}
		args := []string{"--project", "dzeroth-dev"}
		if dry {
			args = append(args, "--dry-run")
		}
		code, out, stderr := runMigrate(m, args...)
		if code != 0 {
			t.Fatalf("dry=%v code=%d out=%q stderr=%q", dry, code, out, stderr)
		}
		if len(m.calls) != 2 || m.calls[0] != "" || m.calls[1] != "aa" {
			t.Errorf("dry=%v calls=%v dryRun=%v: want pages after \"\" then \"aa\" with the dry-run flag passed through", dry, m.calls, m.dryRun)
		}
		for _, d := range m.dryRun {
			if d != dry {
				t.Errorf("dry=%v but a call ran with dryRun=%v", dry, d)
			}
		}
		want := "conversations=54 messages=4 entries=3 rewritten"
		if dry {
			want = "conversations=54 messages=4 entries=3 would be rewritten (nothing written)"
		}
		if !strings.Contains(out, want) {
			t.Errorf("dry=%v output lacks %q:\n%s", dry, want, out)
		}
	}
}

func TestMessagesMigratePlaceholder_Refusals(t *testing.T) {
	t.Parallel()
	m := &fakeMigrator{}
	if code, _, stderr := runMigrate(m, "--project", "dzeroth-prod"); code != 2 || !strings.Contains(stderr, "dev only") || len(m.calls) != 0 {
		t.Errorf("prod: code=%d stderr=%q calls=%v, want exit 2, dev only, nothing opened", code, stderr, m.calls)
	}
	if code, _, stderr := runMigrate(m); code != 2 || !strings.Contains(stderr, "--project is required") {
		t.Errorf("no project: code=%d stderr=%q", code, stderr)
	}
	m.err = errors.New("boom")
	if code, _, _ := runMigrate(m, "--project", "dzeroth-dev"); code != 1 {
		t.Errorf("a failing page must exit 1, got %d", code)
	}
}
