package moderation

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

var (
	okConv   = strings.Repeat("a", 32)
	okMsg    = strings.Repeat("b", 32)
	okTarget = okConv + ":" + okMsg
	sender   = "uid-sender"
)

// fakeLookup is a MessageLookup that records its calls and answers from a script.
type fakeLookup struct {
	msg   ReportedMessage
	err   error
	calls []string
}

func (f *fakeLookup) ReportableMessage(_ context.Context, callerUID, convID, msgID string) (ReportedMessage, error) {
	f.calls = append(f.calls, callerUID+"|"+convID+"|"+msgID)
	return f.msg, f.err
}

func (f *fixture) msgSvc(l MessageLookup) Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, Messages: l,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

func msgInput() ReportInput {
	return ReportInput{IdempotencyKey: okKey, TargetType: TargetMessage, TargetID: okTarget, Reason: ReasonHarassment}
}

func TestParseMessageTarget(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		ok   bool
	}{
		{"valid", okTarget, true},
		{"no separator", okConv + okMsg, false},
		{"empty", "", false},
		{"two separators", okTarget + ":" + okMsg, false},
		{"upper case hex", strings.ToUpper(okTarget), false},
		{"short conversation", okConv[:31] + ":" + okMsg, false},
		{"long message", okConv + ":" + okMsg + "c", false},
		{"non hex", okConv + ":" + strings.Repeat("g", 32), false},
		{"slash", okConv + "/" + okMsg, false},
		{"trailing newline", okTarget + "\n", false},
		{"leading space", " " + okTarget, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c, m, ok := ParseMessageTarget(tt.in)
			if ok != tt.ok {
				t.Fatalf("ok = %v, want %v", ok, tt.ok)
			}
			if ok && (c != okConv || m != okMsg || MessageTargetID(c, m) != tt.in) {
				t.Errorf("got %q %q", c, m)
			}
			if !ok && (c != "" || m != "") {
				t.Errorf("a refusal returned ids %q %q", c, m)
			}
		})
	}
}

func TestReport_MessageValidationDoesNoWork(t *testing.T) {
	t.Parallel()
	for name, id := range map[string]string{
		"post id":   okPostID,
		"bad shape": okConv + ":" + "xyz",
		"empty":     "",
		"account":   author,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeLookup{}
			in := msgInput()
			in.TargetID = id
			_, err := f.msgSvc(l).Report(gctx(), reporter, in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
				t.Errorf("err = %v, want field target_id", err)
			}
			if len(l.calls) != 0 || len(f.repo.calls) != 0 || f.posts.n != 0 || f.accounts.n != 0 {
				t.Error("a malformed target id did a read or a write")
			}
		})
	}
}

func TestReport_MessageCopiesOnlyThatMessageAsEvidence(t *testing.T) {
	t.Parallel()
	f := newFixture()
	sent := f.now.Add(-2 * time.Hour)
	l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, SenderHandle: "mallory", Text: "you are worthless", CreatedAt: sent}}
	in := msgInput()
	in.Note = "  keeps coming back "
	res, err := f.msgSvc(l).Report(gctx(), reporter, in)
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyReported || res.ReportID != ReportID(reporter, TargetMessage, okTarget) {
		t.Fatalf("res = %+v", res)
	}
	if want := []string{reporter + "|" + okConv + "|" + okMsg}; !reflect.DeepEqual(l.calls, want) {
		t.Errorf("lookup calls = %v, want %v (the caller from the token, the ids from the target)", l.calls, want)
	}
	if len(f.repo.calls) != 1 || f.posts.n != 0 || f.accounts.n != 0 {
		t.Fatalf("creates %d, post reads %d, account reads %d", len(f.repo.calls), f.posts.n, f.accounts.n)
	}
	p := f.repo.calls[0]
	r := p.Report
	if r.TargetType != TargetMessage || r.TargetID != okTarget || r.TargetOwnerID != sender || r.ReporterID != reporter ||
		r.Status != StatusOpen || r.Reason != ReasonHarassment || r.Note != "keeps coming back" {
		t.Errorf("report = %+v", r)
	}
	want := &Evidence{Text: "you are worthless", AuthorHandle: "mallory", PostCreatedAt: sent}
	if !reflect.DeepEqual(r.Evidence, want) {
		t.Errorf("evidence = %+v, want %+v", r.Evidence, want)
	}
	if p.QuotaLimit != 20 {
		t.Errorf("QuotaLimit = %d, want the normal 20 (the existing reports quota)", p.QuotaLimit)
	}
}

func TestReport_MessageNewAccountGetsTheLowerQuota(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.dir.profiles[reporter] = identity.Profile{UserID: reporter, CreatedAt: f.now.Add(-time.Hour)}
	if _, err := f.msgSvc(&fakeLookup{msg: ReportedMessage{SenderUID: sender}}).Report(gctx(), reporter, msgInput()); err != nil {
		t.Fatal(err)
	}
	if got := f.repo.calls[0].QuotaLimit; got != 5 {
		t.Errorf("QuotaLimit = %d, want 5", got)
	}
}

func TestReport_MessageEmptyHandleIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture()
	l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, Text: "hi"}}
	if _, err := f.msgSvc(l).Report(gctx(), reporter, msgInput()); err != nil {
		t.Fatal(err)
	}
	if got := f.repo.calls[0].Report.Evidence; got == nil || got.AuthorHandle != "" || got.Text != "hi" {
		t.Errorf("evidence = %+v", got)
	}
}

func TestReport_MessageOwnMessageIsValidationTargetID(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.msgSvc(&fakeLookup{err: fmt.Errorf("lookup: %w", ErrOwnMessage)}).Report(gctx(), reporter, msgInput())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
		t.Errorf("err = %v, want field target_id", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("an own message must not be written")
	}
}

// Every cause the lookup folds into ErrMessageNotFound is the one NOT_FOUND, with the same code, reason, text and metadata:
// nothing says which rule refused (ADR-0027 D11).
func TestReport_MessageNotFoundIsOneAnswer(t *testing.T) {
	t.Parallel()
	var first *apierr.Error
	for name, cause := range map[string]error{
		"bare":                ErrMessageNotFound,
		"wrapped":             fmt.Errorf("messaging adapter: %w", ErrMessageNotFound),
		"wrapped twice":       fmt.Errorf("a: %w", fmt.Errorf("b: %w", ErrMessageNotFound)),
		"joined with another": errors.Join(errors.New("x"), ErrMessageNotFound),
	} {
		f := newFixture()
		_, err := f.msgSvc(&fakeLookup{err: cause}).Report(gctx(), reporter, msgInput())
		wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		var ae *apierr.Error
		if !errors.As(err, &ae) {
			t.Fatalf("%s: err = %v", name, err)
		}
		if first == nil {
			first = ae
		} else if !reflect.DeepEqual(first, ae) {
			t.Errorf("%s: %+v differs from %+v", name, ae, first)
		}
		if len(f.repo.calls) != 0 {
			t.Errorf("%s: wrote a report for an unreportable message", name)
		}
	}
	if first.Message != "message not found" || len(first.Metadata) != 0 {
		t.Errorf("answer = %+v", first)
	}
}

func TestReport_MessageInfrastructureErrorsAreRedacted(t *testing.T) {
	t.Parallel()
	f := newFixture()
	boom := fmt.Errorf("get conversations/%s/messages/%s for %s: deadline", okConv, okMsg, reporter)
	_, err := f.msgSvc(&fakeLookup{err: boom}).Report(gctx(), reporter, msgInput())
	if err == nil {
		t.Fatal("want an error")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("an infrastructure error became a client answer: %+v", ae)
	}
	for _, secret := range []string{okConv, okMsg, reporter} {
		if strings.Contains(err.Error(), secret) {
			t.Errorf("error leaks %q: %v", secret, err)
		}
	}
}

func TestReport_MessageWithoutLookupIsInternal(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.msgSvc(nil).Report(gctx(), reporter, msgInput())
	if err == nil {
		t.Fatal("want an error")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("err = %+v, want an internal error", ae)
	}
	if len(f.repo.calls) != 0 {
		t.Error("wrote a report without a lookup")
	}
}

func TestReport_MessageRepeatIsAlreadyReported(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.repo.existing = true
	res, err := f.msgSvc(&fakeLookup{msg: ReportedMessage{SenderUID: sender, Text: "x"}}).Report(gctx(), reporter, msgInput())
	if err != nil || !res.AlreadyReported || res.ReportID != ReportID(reporter, TargetMessage, okTarget) {
		t.Fatalf("res = %+v err = %v", res, err)
	}
}

// The target type is part of the report id, so the same two ids as a POST or ACCOUNT target never collide.
func TestReportID_SeparatesMessageTargets(t *testing.T) {
	t.Parallel()
	a := ReportID(reporter, TargetMessage, okTarget)
	if a == ReportID(reporter, TargetPost, okTarget) || a == ReportID(reporter, TargetAccount, okTarget) || a == ReportID(reporter, TargetMessage, okConv+":"+strings.Repeat("c", 32)) {
		t.Error("distinct targets share a report id")
	}
}

// messagingFlags is a FlagChecker with a per-flag mode, the shape of *flags.Registry: Enabled is the per-caller answer,
// GloballyOff the kill switch.
type messagingFlags struct{ reports, messaging flags.Mode }

func (f messagingFlags) Enabled(_, name string) bool {
	switch name {
	case FlagName:
		return f.reports == flags.On
	case MessagingFlagName:
		return f.messaging == flags.On
	}
	return false
}

func (f messagingFlags) GloballyOff(name string) bool {
	return name == MessagingFlagName && f.messaging == flags.Off
}

// plainFlags has no GloballyOff, so a MESSAGE report falls back to the per-caller answer.
type plainFlags struct{ reports, messaging bool }

func (f plainFlags) Enabled(_, name string) bool {
	return (name == FlagName && f.reports) || (name == MessagingFlagName && f.messaging)
}

// The flag matrix of a MESSAGE report (ADR-0027 D6, F6): `reports` must be on for the caller, `messaging` only not globally
// off. A checker that cannot tell the two apart answers per caller.
func TestServer_MessageReportFlagMatrix(t *testing.T) {
	t.Parallel()
	req := func(tt moderationv1.ReportTargetType, target string) *connect.Request[moderationv1.ReportContentRequest] {
		return connect.NewRequest(&moderationv1.ReportContentRequest{
			IdempotencyKey: okKey, TargetType: tt, TargetId: target, Reason: moderationv1.ReportReason_REPORT_REASON_HARASSMENT,
		})
	}
	msgReq := func() *connect.Request[moderationv1.ReportContentRequest] {
		return req(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_MESSAGE, okTarget)
	}
	tests := []struct {
		name     string
		fc       FlagChecker
		disabled bool
		feature  string // metadata feature of the refusal ("" = none)
	}{
		{"reports off", messagingFlags{reports: flags.Off, messaging: flags.On}, true, ""},
		{"reports allowlist without the caller", messagingFlags{reports: flags.Allowlist, messaging: flags.On}, true, ""},
		{"messaging off globally", messagingFlags{reports: flags.On, messaging: flags.Off}, true, MessagingFlagName},
		{"messaging allowlist without the caller", messagingFlags{reports: flags.On, messaging: flags.Allowlist}, false, ""},
		{"messaging percent 0", messagingFlags{reports: flags.On, messaging: flags.Percent}, false, ""},
		{"messaging on", messagingFlags{reports: flags.On, messaging: flags.On}, false, ""},
		{"no GloballyOff, messaging on for the caller", plainFlags{reports: true, messaging: true}, false, ""},
		{"no GloballyOff, messaging not on for the caller", plainFlags{reports: true}, true, MessagingFlagName},
		{"nil checker", nil, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, Text: "x"}}
			ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
			res, err := NewServer(f.msgSvc(l), tt.fc).ReportContent(ctx, msgReq())
			if tt.disabled {
				wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["feature"] != tt.feature {
					t.Errorf("err = %v, want feature %q", err, tt.feature)
				}
				if len(l.calls) != 0 || len(f.repo.calls) != 0 || f.repo.lookups != 0 {
					t.Error("a disabled call did work")
				}
				return
			}
			if err != nil || res.Msg.GetReportId() == "" {
				t.Fatalf("res = %v err = %v", res, err)
			}
			if got := f.repo.calls[0].Report; got.TargetType != TargetMessage || got.TargetID != okTarget {
				t.Errorf("enum conversion: %+v", got)
			}
		})
	}
}

// A POST report never looks at the messaging flag.
func TestServer_PostReportIgnoresTheMessagingFlag(t *testing.T) {
	t.Parallel()
	f := newFixture()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST, TargetId: okPostID,
		Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
	})
	if _, err := NewServer(f.svc(), messagingFlags{reports: flags.On, messaging: flags.Off}).ReportContent(ctx, req); err != nil {
		t.Fatalf("a POST report with messaging off: %v", err)
	}
}
