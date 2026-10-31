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

const (
	okListID  = "1234567890123456789"
	listOwner = "uid-list-owner"
)

// fakeListLookup is a ListLookup that records its calls and answers from a script.
type fakeListLookup struct {
	list  ReportedList
	err   error
	calls []string
}

func (f *fakeListLookup) ReportableList(_ context.Context, callerUID, listID string) (ReportedList, error) {
	f.calls = append(f.calls, callerUID+"|"+listID)
	return f.list, f.err
}

func (f *fixture) listSvc(l ListLookup) Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, Lists: l,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

func listInput() ReportInput {
	return ReportInput{IdempotencyKey: okKey, TargetType: TargetList, TargetID: okListID, Reason: ReasonHate}
}

func TestReport_ListValidationDoesNoWork(t *testing.T) {
	t.Parallel()
	for name, id := range map[string]string{
		"empty":       "",
		"too short":   "12345",
		"letters":     "123456789012345678a",
		"message id":  okTarget,
		"account id":  author,
		"trailing nl": okListID + "\n",
		"twenty":      okListID + "0",
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeListLookup{}
			in := listInput()
			in.TargetID = id
			_, err := f.listSvc(l).Report(gctx(), reporter, in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
				t.Errorf("err = %v, want field target_id", err)
			}
			if len(l.calls) != 0 || len(f.repo.calls) != 0 {
				t.Error("a malformed list id did a read or a write")
			}
		})
	}
}

// A visible list is reported: the evidence is the owner's handle, the name and the description, and no member id.
func TestReport_ListVisibleStoresTheSnapshot(t *testing.T) {
	t.Parallel()
	f := newFixture()
	made := f.now.Add(-48 * time.Hour)
	l := &fakeListLookup{list: ReportedList{OwnerUID: listOwner, OwnerHandle: "mallory", Name: "targets", Description: "people to watch", CreatedAt: made}}
	res, err := f.listSvc(l).Report(gctx(), reporter, listInput())
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyReported || res.ReportID != ReportID(reporter, TargetList, okListID) {
		t.Fatalf("res = %+v", res)
	}
	if want := []string{reporter + "|" + okListID}; !reflect.DeepEqual(l.calls, want) {
		t.Errorf("lookup calls = %v, want %v (the caller from the token)", l.calls, want)
	}
	if len(f.repo.calls) != 1 || f.posts.n != 0 || f.accounts.n != 0 {
		t.Fatalf("creates %d, post reads %d, account reads %d", len(f.repo.calls), f.posts.n, f.accounts.n)
	}
	p := f.repo.calls[0]
	r := p.Report
	if r.TargetType != TargetList || r.TargetID != okListID || r.TargetOwnerID != listOwner || r.ReporterID != reporter || r.Status != StatusOpen {
		t.Errorf("report = %+v", r)
	}
	want := &Evidence{AuthorHandle: "mallory", ListName: "targets", ListDescription: "people to watch", PostCreatedAt: made}
	if !reflect.DeepEqual(r.Evidence, want) {
		t.Errorf("evidence = %+v, want %+v", r.Evidence, want)
	}
	if p.QuotaLimit != 20 {
		t.Errorf("QuotaLimit = %d, want the normal 20 (the existing reports quota)", p.QuotaLimit)
	}
}

func TestReport_ListNewAccountGetsTheLowerQuota(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.dir.profiles[reporter] = identity.Profile{UserID: reporter, CreatedAt: f.now.Add(-time.Hour)}
	if _, err := f.listSvc(&fakeListLookup{list: ReportedList{OwnerUID: listOwner}}).Report(gctx(), reporter, listInput()); err != nil {
		t.Fatal(err)
	}
	if got := f.repo.calls[0].QuotaLimit; got != 5 {
		t.Errorf("QuotaLimit = %d, want 5", got)
	}
}

func TestReport_ListOwnListIsValidationTargetID(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.listSvc(&fakeListLookup{err: fmt.Errorf("lookup: %w", ErrOwnList)}).Report(gctx(), reporter, listInput())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
		t.Errorf("err = %v, want field target_id", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("an own list must not be written")
	}
}

// A private list the caller cannot see, a hidden one, a missing one: the lookup folds all into ErrListNotFound and the
// answer is one NOT_FOUND with the same bytes whatever wrapped it.
func TestReport_ListNotFoundIsOneAnswer(t *testing.T) {
	t.Parallel()
	var first *apierr.Error
	for name, cause := range map[string]error{
		"bare":          ErrListNotFound,
		"wrapped":       fmt.Errorf("lists adapter: %w", ErrListNotFound),
		"wrapped twice": fmt.Errorf("a: %w", fmt.Errorf("b: %w", ErrListNotFound)),
	} {
		f := newFixture()
		_, err := f.listSvc(&fakeListLookup{err: cause}).Report(gctx(), reporter, listInput())
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
			t.Errorf("%s: wrote a report for an unreportable list", name)
		}
	}
	if first.Message != "list not found" || len(first.Metadata) != 0 {
		t.Errorf("answer = %+v", first)
	}
}

func TestReport_ListInfrastructureErrorsAreRedacted(t *testing.T) {
	t.Parallel()
	f := newFixture()
	boom := fmt.Errorf("get lists/%s for %s: deadline", okListID, reporter)
	_, err := f.listSvc(&fakeListLookup{err: boom}).Report(gctx(), reporter, listInput())
	if err == nil {
		t.Fatal("want an error")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("an infrastructure error became a client answer: %+v", ae)
	}
	for _, secret := range []string{okListID, reporter} {
		if strings.Contains(err.Error(), secret) {
			t.Errorf("error leaks %q: %v", secret, err)
		}
	}
}

func TestReport_ListWithoutLookupIsInternal(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.listSvc(nil).Report(gctx(), reporter, listInput())
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want an internal error", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("wrote a report without a lookup")
	}
}

func TestReport_ListRepeatIsAlreadyReported(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.repo.existing = true
	res, err := f.listSvc(&fakeListLookup{list: ReportedList{OwnerUID: listOwner}}).Report(gctx(), reporter, listInput())
	if err != nil || !res.AlreadyReported || res.ReportID != ReportID(reporter, TargetList, okListID) {
		t.Fatalf("res = %+v err = %v", res, err)
	}
}

// The target type is part of the report id: a list and a post that share an id never collide.
func TestReportID_SeparatesListTargets(t *testing.T) {
	t.Parallel()
	if ReportID(reporter, TargetList, okListID) == ReportID(reporter, TargetPost, okListID) {
		t.Error("a LIST and a POST report with the same id share a report id")
	}
}

// listFlags is a FlagChecker with a per-flag mode, the shape of *flags.Registry.
type listFlags struct{ reports, lists flags.Mode }

func (f listFlags) Enabled(_, name string) bool {
	switch name {
	case FlagName:
		return f.reports == flags.On
	case ListsFlagName:
		return f.lists == flags.On
	}
	return false
}

func (f listFlags) GloballyOff(name string) bool {
	return name == ListsFlagName && f.lists == flags.Off
}

// The flag matrix of a LIST report: `reports` must be on for the caller, `lists` only not globally off (off, allowlist,
// percent, on).
func TestServer_ListReportFlagMatrix(t *testing.T) {
	t.Parallel()
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_LIST, TargetId: okListID,
		Reason: moderationv1.ReportReason_REPORT_REASON_HATE,
	})
	tests := []struct {
		name     string
		fc       FlagChecker
		disabled bool
		feature  string
	}{
		{"reports off", listFlags{reports: flags.Off, lists: flags.On}, true, ""},
		{"lists off globally", listFlags{reports: flags.On, lists: flags.Off}, true, ListsFlagName},
		{"lists allowlist without the caller", listFlags{reports: flags.On, lists: flags.Allowlist}, false, ""},
		{"lists percent 0", listFlags{reports: flags.On, lists: flags.Percent}, false, ""},
		{"lists on", listFlags{reports: flags.On, lists: flags.On}, false, ""},
		{"nil checker", nil, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeListLookup{list: ReportedList{OwnerUID: listOwner, Name: "n"}}
			ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
			res, err := NewServer(f.listSvc(l), tt.fc).ReportContent(ctx, req)
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
			if got := f.repo.calls[0].Report; got.TargetType != TargetList || got.TargetID != okListID {
				t.Errorf("enum conversion: %+v", got)
			}
		})
	}
}

// A POST report never looks at the lists flag.
func TestServer_PostReportIgnoresTheListsFlag(t *testing.T) {
	t.Parallel()
	f := newFixture()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST, TargetId: okPostID,
		Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
	})
	if _, err := NewServer(f.svc(), listFlags{reports: flags.On, lists: flags.Off}).ReportContent(ctx, req); err != nil {
		t.Fatalf("a POST report with lists off: %v", err)
	}
}
