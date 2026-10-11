package moderation

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const (
	okKey    = "0123456789abcdef"
	okPostID = "0000000000000000042"
	reporter = "uid-reporter"
	author   = "uid-author"
)

type fakeRepo struct {
	calls    []CreateParams
	existing bool
	err      error
}

func (f *fakeRepo) Create(_ context.Context, p CreateParams) (CreateResult, error) {
	f.calls = append(f.calls, p)
	if f.err != nil {
		return CreateResult{}, f.err
	}
	return CreateResult{Existing: f.existing, Attempts: 1}, nil
}

type fakePosts struct {
	post *posts.Post
	err  error
	n    int
}

func (f *fakePosts) GetForViewer(_ context.Context, _, _ string) (*posts.Post, error) {
	f.n++
	return f.post, f.err
}

type fakeAccounts struct {
	prof identity.Profile
	err  error
	n    int
}

func (f *fakeAccounts) GetProfile(_ context.Context, _ string, _ identity.ProfileTarget) (identity.Profile, error) {
	f.n++
	return f.prof, f.err
}

type fakeDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
	err      error
}

func (f fakeDirectory) GetProfiles(_ context.Context, _ []string) (map[string]identity.Profile, error) {
	return f.profiles, f.err
}

type fixture struct {
	repo     *fakeRepo
	posts    *fakePosts
	accounts *fakeAccounts
	dir      fakeDirectory
	now      time.Time
}

func newFixture() *fixture {
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	return &fixture{
		repo: &fakeRepo{},
		posts: &fakePosts{post: &posts.Post{ID: okPostID, AuthorID: author, Text: "hello",
			Author: posts.AuthorSnapshot{Handle: "bob"}, CreatedAt: now.Add(-time.Hour)}},
		accounts: &fakeAccounts{prof: identity.Profile{UserID: author}},
		dir: fakeDirectory{profiles: map[string]identity.Profile{
			reporter: {UserID: reporter, CreatedAt: now.Add(-72 * time.Hour)},
		}},
		now: now,
	}
}

func (f *fixture) svc() Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

func gctx() context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
}

func okInput() ReportInput {
	return ReportInput{IdempotencyKey: okKey, TargetType: TargetPost, TargetID: okPostID, Reason: ReasonSpam}
}

func wantAPIErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Code != code || (reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED && ae.Reason != reason) {
		t.Fatalf("err code=%v reason=%v, want %v / %v", ae.Code, ae.Reason, code, reason)
	}
}

func TestReport_Validation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		mut  func(*ReportInput)
		self bool
	}{
		{name: "short key", mut: func(in *ReportInput) { in.IdempotencyKey = "short" }},
		{name: "bad key chars", mut: func(in *ReportInput) { in.IdempotencyKey = "0123456789abcde!" }},
		{name: "no target type", mut: func(in *ReportInput) { in.TargetType = "" }},
		{name: "no reason", mut: func(in *ReportInput) { in.Reason = "" }},
		{name: "post id not 19 digits", mut: func(in *ReportInput) { in.TargetID = "42" }},
		{name: "post id with slash", mut: func(in *ReportInput) { in.TargetID = "00000000000000/0042" }},
		{name: "account id with underscore", mut: func(in *ReportInput) { in.TargetType, in.TargetID = TargetAccount, "a_b" }},
		{name: "own account", mut: func(in *ReportInput) { in.TargetType, in.TargetID = TargetAccount, reporter }},
		{name: "note too long", mut: func(in *ReportInput) { in.Note = strings.Repeat("a", MaxNoteRunes+1) }},
		{name: "note control char", mut: func(in *ReportInput) { in.Note = "a\x07b" }},
		{name: "note bidi override", mut: func(in *ReportInput) { in.Note = "a" + string(rune(0x202e)) + "b" }},
		{name: "note invalid utf8", mut: func(in *ReportInput) { in.Note = "a\xffb" }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			in := okInput()
			tt.mut(&in)
			_, err := f.svc().Report(gctx(), reporter, in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
			if f.posts.n+f.accounts.n+len(f.repo.calls) != 0 {
				t.Error("an invalid request must do no reads or writes")
			}
		})
	}
}

func TestReport_OwnPostIsValidationError(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.posts.post.AuthorID = reporter
	_, err := f.svc().Report(gctx(), reporter, okInput())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if len(f.repo.calls) != 0 {
		t.Error("own post must not be written")
	}
}

func TestReport_PostCopiesEvidenceAndSurvivesNoteNormalisation(t *testing.T) {
	t.Parallel()
	f := newFixture()
	in := okInput()
	in.Note = "  line1\r\nline2\t "
	res, err := f.svc().Report(gctx(), reporter, in)
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyReported || res.ReportID != ReportID(reporter, TargetPost, okPostID) {
		t.Fatalf("res = %+v", res)
	}
	if len(f.repo.calls) != 1 {
		t.Fatalf("calls = %d", len(f.repo.calls))
	}
	p := f.repo.calls[0]
	r := p.Report
	if r.Evidence == nil || r.Evidence.Text != "hello" || r.Evidence.AuthorHandle != "bob" {
		t.Errorf("evidence = %+v", r.Evidence)
	}
	if r.TargetOwnerID != author || r.ReporterID != reporter || r.Status != StatusOpen || r.Note != "line1\nline2" {
		t.Errorf("report = %+v", r)
	}
	if p.QuotaLimit != 20 {
		t.Errorf("QuotaLimit = %d, want 20", p.QuotaLimit)
	}
}

func TestReport_AccountTarget(t *testing.T) {
	t.Parallel()
	f := newFixture()
	in := ReportInput{IdempotencyKey: okKey, TargetType: TargetAccount, TargetID: author, Reason: ReasonImpersonation}
	if _, err := f.svc().Report(gctx(), reporter, in); err != nil {
		t.Fatal(err)
	}
	r := f.repo.calls[0].Report
	if r.Evidence != nil || r.TargetOwnerID != author || r.TargetType != TargetAccount {
		t.Errorf("report = %+v", r)
	}
	if f.posts.n != 0 || f.accounts.n != 1 {
		t.Errorf("post reads %d, profile reads %d", f.posts.n, f.accounts.n)
	}
}

func TestReport_TargetNotVisibleIsTheSameNotFound(t *testing.T) {
	t.Parallel()
	nf := apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "post not found")
	f := newFixture()
	f.posts.err, f.posts.post = nf, nil
	_, err := f.svc().Report(gctx(), reporter, okInput())
	if !errors.Is(err, nf) {
		t.Fatalf("err = %v, want the viewer's NOT_FOUND unchanged", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("nothing may be written for an invisible target")
	}
	f = newFixture()
	f.accounts.err = nf
	_, err = f.svc().Report(gctx(), reporter, ReportInput{IdempotencyKey: okKey, TargetType: TargetAccount, TargetID: author, Reason: ReasonOther})
	if !errors.Is(err, nf) || len(f.repo.calls) != 0 {
		t.Fatalf("account: err = %v calls=%d", err, len(f.repo.calls))
	}
}

func TestReport_NewAccountGetsTheLowerQuota(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.dir.profiles[reporter] = identity.Profile{UserID: reporter, CreatedAt: f.now.Add(-time.Hour)}
	if _, err := f.svc().Report(gctx(), reporter, okInput()); err != nil {
		t.Fatal(err)
	}
	if got := f.repo.calls[0].QuotaLimit; got != 5 {
		t.Errorf("QuotaLimit = %d, want 5", got)
	}
}

func TestReport_RepoOutcomes(t *testing.T) {
	t.Parallel()
	quota := apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit")
	tests := []struct {
		name     string
		existing bool
		err      error
		wantDup  bool
		wantCode connect.Code
	}{
		{name: "created"},
		{name: "duplicate is a no-op", existing: true, wantDup: true},
		{name: "quota exceeded passes through", err: quota, wantCode: connect.CodeResourceExhausted},
		{name: "storage failure is internal", err: errors.New("boom"), wantCode: connect.CodeInternal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.repo.existing, f.repo.err = tt.existing, tt.err
			res, err := f.svc().Report(gctx(), reporter, okInput())
			if tt.err != nil {
				if err == nil {
					t.Fatal("want an error")
				}
				if tt.wantCode == connect.CodeResourceExhausted {
					wantAPIErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
				}
				if tt.wantCode == connect.CodeInternal && strings.Contains(err.Error(), reporter) {
					t.Errorf("error leaks the reporter uid: %v", err)
				}
				return
			}
			if err != nil || res.AlreadyReported != tt.wantDup {
				t.Fatalf("res=%+v err=%v", res, err)
			}
		})
	}
}

func TestReport_RequiresProfileAndVerifiedEmail(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.dir.profiles = map[string]identity.Profile{}
	_, err := f.svc().Report(gctx(), reporter, okInput())
	wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)

	f = newFixture()
	svc := New(Deps{Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, ReportsPerDay: 20,
		NewAccountReportsPerDay: 5, NewAccountWindow: time.Hour, Now: func() time.Time { return f.now }})
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderPassword, EmailVerified: false})
	_, err = svc.Report(ctx, reporter, okInput())
	wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)
	if len(f.repo.calls) != 0 {
		t.Error("unverified caller must not write")
	}
}

func TestReportID_IsStableAndSeparatesInputs(t *testing.T) {
	t.Parallel()
	a := ReportID("u1", TargetPost, "42")
	if a != ReportID("u1", TargetPost, "42") || len(a) != 32 {
		t.Fatalf("id = %q", a)
	}
	for _, other := range []string{ReportID("u2", TargetPost, "42"), ReportID("u1", TargetAccount, "42"), ReportID("u1", TargetPost, "43")} {
		if other == a {
			t.Error("distinct inputs share an id")
		}
	}
}

func TestResolution_Valid(t *testing.T) {
	t.Parallel()
	for r, want := range map[Resolution]bool{ResolutionNoAction: true, ResolutionDismissed: true, ResolutionTakedown: true,
		ResolutionSuspended: true, "": false, "BAN": false} {
		if r.Valid() != want {
			t.Errorf("Valid(%q) = %v", r, !want)
		}
	}
}

func TestServer_FlagOffAnswersFeatureDisabledWithNoWork(t *testing.T) {
	t.Parallel()
	f := newFixture()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST, TargetId: okPostID,
		Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
	})
	for name, fc := range map[string]FlagChecker{"nil registry": nil, "disabled": fakeFlags(false)} {
		_, err := NewServer(f.svc(), fc).ReportContent(ctx, req)
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if f.posts.n != 0 || len(f.repo.calls) != 0 {
			t.Fatalf("%s: flag-off call did work", name)
		}
	}
	res, err := NewServer(f.svc(), fakeFlags(true)).ReportContent(ctx, req)
	if err != nil || res.Msg.GetReportId() == "" || res.Msg.GetAlreadyReported() {
		t.Fatalf("res=%v err=%v", res, err)
	}
	if got := f.repo.calls[0].Report; got.Reason != ReasonSpam || got.TargetType != TargetPost {
		t.Errorf("enum conversion: %+v", got)
	}
}

func TestServer_UnauthenticatedAndUnknownEnums(t *testing.T) {
	t.Parallel()
	f := newFixture()
	srv := NewServer(f.svc(), fakeFlags(true))
	_, err := srv.ReportContent(context.Background(), connect.NewRequest(&moderationv1.ReportContentRequest{}))
	wantAPIErr(t, err, connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)

	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
	_, err = srv.ReportContent(ctx, connect.NewRequest(&moderationv1.ReportContentRequest{IdempotencyKey: okKey, TargetId: okPostID}))
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestEnumConversions(t *testing.T) {
	t.Parallel()
	for r := range moderationv1.ReportReason_name {
		rr := moderationv1.ReportReason(r)
		got := reasonFromProto(rr)
		if rr == moderationv1.ReportReason_REPORT_REASON_UNSPECIFIED {
			if got != "" {
				t.Errorf("UNSPECIFIED -> %q", got)
			}
			continue
		}
		if got == "" || !strings.HasSuffix(rr.String(), string(got)) {
			t.Errorf("%v -> %q", rr, got)
		}
	}
}

type fakeFlags bool

func (f fakeFlags) Enabled(_, name string) bool { return bool(f) && name == FlagName }
