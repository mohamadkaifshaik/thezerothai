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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const (
	okKey    = "0123456789abcdef"
	okPostID = "0000000000000000042"
	reporter = "uid-reporter"
	author   = "uid-author"
)

func (f *fakeRepo) IsOpen(_ context.Context, _ string) (bool, error) {
	f.lookups++
	return f.openExisting, nil
}

type fakeRepo struct {
	lookups      int
	openExisting bool
	calls        []CreateParams
	existing     bool
	reopened     bool
	err          error
}

func (f *fakeRepo) Create(_ context.Context, p CreateParams) (CreateResult, error) {
	f.calls = append(f.calls, p)
	if f.err != nil {
		return CreateResult{}, f.err
	}
	return CreateResult{Existing: f.existing, Reopened: f.reopened, Attempts: 1}, nil
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

func TestReport_EvidenceCarriesMediaIDs(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		media []posts.MediaRef
		want  []string
	}{
		{name: "text only", want: nil},
		{name: "two images", media: []posts.MediaRef{{ID: "m1"}, {ID: "m2"}}, want: []string{"m1", "m2"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.posts.post.Media = tt.media
			if _, err := f.svc().Report(gctx(), reporter, okInput()); err != nil {
				t.Fatal(err)
			}
			got := f.repo.calls[0].Report.Evidence.MediaIDs
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Errorf("MediaIDs = %v, want %v", got, tt.want)
			}
		})
	}
}

// A REPOST report carries the original post as evidence (from the embedded snapshot, no extra read); the report is
// still about the reposter. A tombstone or missing snapshot keeps the previous (empty) evidence, and a plain post
// is unchanged.
func TestReport_RepostEvidenceIsTheOriginal(t *testing.T) {
	t.Parallel()
	orig := time.Date(2026, 10, 9, 8, 0, 0, 0, time.UTC)
	emb := func(mut func(*posts.Embedded)) *posts.Embedded {
		e := &posts.Embedded{PostID: "1111111111111111111", Author: posts.AuthorSnapshot{UserID: "orig-uid", Handle: "carol"},
			Text: "original text", Media: []posts.MediaRef{{ID: "m9"}}, CreatedAt: orig}
		if mut != nil {
			mut(e)
		}
		return e
	}
	tests := []struct {
		name string
		kind posts.Kind
		emb  *posts.Embedded
		want *Evidence
	}{
		{name: "repost with snapshot", kind: posts.KindRepost, emb: emb(nil),
			want: &Evidence{Text: "original text", AuthorHandle: "carol", PostCreatedAt: orig, MediaIDs: []string{"m9"}, OriginalPostID: "1111111111111111111"}},
		{name: "repost tombstone", kind: posts.KindRepost, emb: emb(func(e *posts.Embedded) { e.Unavailable = true }),
			want: &Evidence{AuthorHandle: "reposter", PostCreatedAt: time.Time{}}},
		{name: "repost without snapshot", kind: posts.KindRepost,
			want: &Evidence{AuthorHandle: "reposter"}},
		{name: "quote keeps its own evidence", kind: posts.KindQuote, emb: emb(nil),
			want: &Evidence{Text: "quote text", AuthorHandle: "reposter"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			text := ""
			if tt.kind == posts.KindQuote {
				text = "quote text"
			}
			f.posts.post = &posts.Post{ID: okPostID, AuthorID: author, Kind: tt.kind, Text: text,
				Author: posts.AuthorSnapshot{Handle: "reposter"}, Embedded: tt.emb}
			res, err := f.svc().Report(gctx(), reporter, okInput())
			if err != nil || res.AlreadyReported || res.ReportID != ReportID(reporter, TargetPost, okPostID) {
				t.Fatalf("res=%+v err=%v", res, err)
			}
			if f.posts.n != 1 || len(f.repo.calls) != 1 {
				t.Fatalf("post reads=%d creates=%d, want 1/1", f.posts.n, len(f.repo.calls))
			}
			c := f.repo.calls[0]
			if c.Report.TargetOwnerID != author || c.Report.TargetID != okPostID || c.QuotaLimit != 20 {
				t.Errorf("report about=%q target=%q limit=%d", c.Report.TargetOwnerID, c.Report.TargetID, c.QuotaLimit)
			}
			got := c.Report.Evidence
			if got == nil || got.Text != tt.want.Text || got.AuthorHandle != tt.want.AuthorHandle || !got.PostCreatedAt.Equal(tt.want.PostCreatedAt) ||
				got.OriginalPostID != tt.want.OriginalPostID || strings.Join(got.MediaIDs, ",") != strings.Join(tt.want.MediaIDs, ",") {
				t.Errorf("evidence = %+v, want %+v", got, tt.want)
			}
		})
	}
}

// A report reopened after RESOLVED is a new report to the caller (AlreadyReported false), not a dropped duplicate.
func TestReport_ReopenedIsNotAlreadyReported(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.repo.reopened = true
	res, err := f.svc().Report(gctx(), reporter, okInput())
	if err != nil || res.AlreadyReported {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

// Once a uid is found out of quota, further calls until the IST midnight cost one read (the replay lookup) and 0 transactions; the
// limit lifting (new-account window over, day rollover) makes the instance ask again.
func TestReport_ExhaustedQuotaIsRememberedUntilMidnight(t *testing.T) {
	t.Parallel()
	exceeded := quotaExceeded()
	t.Run("same day answers from memory", func(t *testing.T) {
		t.Parallel()
		f := newFixture()
		f.repo.err = exceeded
		svc := f.svc()
		_, err := svc.Report(gctx(), reporter, okInput())
		wantAPIErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		postReads, calls := f.posts.n, len(f.repo.calls)
		f.now = f.now.Add(2 * time.Hour)
		f.repo.err = nil // would succeed if asked
		_, err = svc.Report(gctx(), reporter, okInput())
		wantAPIErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		if f.posts.n != postReads || len(f.repo.calls) != calls || f.repo.lookups != 1 {
			t.Errorf("remembered rejection: post reads %d->%d, transactions %d->%d, lookups %d (want 1)", postReads, f.posts.n, calls, len(f.repo.calls), f.repo.lookups)
		}
	})
	t.Run("a replay of an open report is AlreadyReported, not QUOTA_EXCEEDED", func(t *testing.T) {
		t.Parallel()
		f := newFixture()
		f.repo.err = exceeded
		svc := f.svc()
		_, _ = svc.Report(gctx(), reporter, okInput())
		f.repo.openExisting = true
		res, err := svc.Report(gctx(), reporter, okInput())
		if err != nil || !res.AlreadyReported || res.ReportID != ReportID(reporter, TargetPost, okPostID) {
			t.Fatalf("res=%+v err=%v", res, err)
		}
		if len(f.repo.calls) != 1 {
			t.Errorf("transactions = %d, want 1 (the replay must not open one)", len(f.repo.calls))
		}
	})
	t.Run("next IST day asks again", func(t *testing.T) {
		t.Parallel()
		f := newFixture() // 12:00 UTC = 17:30 IST
		f.repo.err = exceeded
		svc := f.svc()
		_, _ = svc.Report(gctx(), reporter, okInput())
		f.now = f.now.Add(7 * time.Hour) // 00:30 IST next day
		f.repo.err = nil
		if _, err := svc.Report(gctx(), reporter, okInput()); err != nil {
			t.Fatalf("after midnight: %v", err)
		}
		if len(f.repo.calls) != 2 {
			t.Errorf("transactions = %d, want 2", len(f.repo.calls))
		}
	})
	t.Run("new-account window ending raises the limit", func(t *testing.T) {
		t.Parallel()
		f := newFixture()
		f.dir.profiles[reporter] = identity.Profile{UserID: reporter, CreatedAt: f.now.Add(-23*time.Hour - 50*time.Minute)} // window ends in 10 min
		f.repo.err = exceeded
		svc := f.svc()
		_, _ = svc.Report(gctx(), reporter, okInput())
		if got := f.repo.calls[0].QuotaLimit; got != 5 {
			t.Fatalf("QuotaLimit = %d, want 5", got)
		}
		f.now = f.now.Add(11 * time.Minute) // window over, still the same IST day (17:41 IST)
		f.repo.err = nil
		if _, err := svc.Report(gctx(), reporter, okInput()); err != nil {
			t.Fatalf("window over: %v", err)
		}
		if got := f.repo.calls[len(f.repo.calls)-1].QuotaLimit; got != 20 {
			t.Errorf("QuotaLimit = %d, want 20", got)
		}
	})
	t.Run("other users are unaffected", func(t *testing.T) {
		t.Parallel()
		f := newFixture()
		f.repo.err = exceeded
		svc := f.svc()
		_, _ = svc.Report(gctx(), reporter, okInput())
		f.repo.err = nil
		other := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-other", SignInProvider: authn.SignInProviderGoogle})
		f.dir.profiles["uid-other"] = identity.Profile{UserID: "uid-other", CreatedAt: f.now.Add(-72 * time.Hour)}
		if _, err := svc.Report(other, "uid-other", okInput()); err != nil {
			t.Fatal(err)
		}
	})
}

func quotaExceeded() error {
	return quota.ExceededError(quota.Reports, time.Now())
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
	exceeded := apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit")
	tests := []struct {
		name     string
		existing bool
		err      error
		wantDup  bool
		wantCode connect.Code
	}{
		{name: "created"},
		{name: "duplicate is a no-op", existing: true, wantDup: true},
		{name: "reopened is a new report", existing: false},
		{name: "quota exceeded passes through", err: exceeded, wantCode: connect.CodeResourceExhausted},
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
