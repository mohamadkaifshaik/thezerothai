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
	okCommunityID  = "9234567890123456789"
	communityOwner = "uid-community-owner"
)

// fakeCommunityLookup is a CommunityLookup that records its calls and answers from a script.
type fakeCommunityLookup struct {
	c     ReportedCommunity
	err   error
	calls []string
}

func (f *fakeCommunityLookup) ReportableCommunity(_ context.Context, callerUID, communityID string) (ReportedCommunity, error) {
	f.calls = append(f.calls, callerUID+"|"+communityID)
	return f.c, f.err
}

func (f *fixture) communitySvc(l CommunityLookup) Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, Communities: l,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

func communityInput() ReportInput {
	return ReportInput{IdempotencyKey: okKey, TargetType: TargetCommunity, TargetID: okCommunityID, Reason: ReasonHate}
}

func TestTargetTypeFromProto_Community(t *testing.T) {
	t.Parallel()
	if got := targetTypeFromProto(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_COMMUNITY); got != TargetCommunity {
		t.Fatalf("targetTypeFromProto(COMMUNITY) = %q", got)
	}
}

func TestReport_CommunityValidationDoesNoWork(t *testing.T) {
	t.Parallel()
	for name, id := range map[string]string{
		"empty":       "",
		"too short":   "12345",
		"letters":     "123456789012345678a",
		"message id":  okTarget,
		"account id":  author,
		"trailing nl": okCommunityID + "\n",
		"twenty":      okCommunityID + "0",
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeCommunityLookup{}
			in := communityInput()
			in.TargetID = id
			_, err := f.communitySvc(l).Report(gctx(), reporter, in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
				t.Errorf("err = %v, want field target_id", err)
			}
			if len(l.calls) != 0 || len(f.repo.calls) != 0 {
				t.Error("a malformed community id did a read or a write")
			}
		})
	}
}

// A community is reported: the evidence is the owner's handle, the name, the description and the rules, and no member id.
func TestReport_CommunityStoresTheSnapshot(t *testing.T) {
	t.Parallel()
	f := newFixture()
	made := f.now.Add(-72 * time.Hour)
	rules := []CommunityRule{{Title: "Be kind", Text: "No insults."}, {Title: "On topic", Text: ""}}
	l := &fakeCommunityLookup{c: ReportedCommunity{OwnerUID: communityOwner, OwnerHandle: "mallory", Name: "targets", Description: "people to watch", Rules: rules, CreatedAt: made}}
	res, err := f.communitySvc(l).Report(gctx(), reporter, communityInput())
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyReported || res.ReportID != ReportID(reporter, TargetCommunity, okCommunityID) {
		t.Fatalf("res = %+v", res)
	}
	if want := []string{reporter + "|" + okCommunityID}; !reflect.DeepEqual(l.calls, want) {
		t.Errorf("lookup calls = %v, want %v (the caller from the token)", l.calls, want)
	}
	if len(f.repo.calls) != 1 || f.posts.n != 0 || f.accounts.n != 0 {
		t.Fatalf("creates %d, post reads %d, account reads %d", len(f.repo.calls), f.posts.n, f.accounts.n)
	}
	p := f.repo.calls[0]
	r := p.Report
	if r.TargetType != TargetCommunity || r.TargetID != okCommunityID || r.TargetOwnerID != communityOwner || r.ReporterID != reporter || r.Status != StatusOpen {
		t.Errorf("report = %+v", r)
	}
	want := &Evidence{AuthorHandle: "mallory", CommunityName: "targets", CommunityDescription: "people to watch", CommunityRules: rules, PostCreatedAt: made}
	if !reflect.DeepEqual(r.Evidence, want) {
		t.Errorf("evidence = %+v, want %+v", r.Evidence, want)
	}
	if p.QuotaLimit != 20 {
		t.Errorf("QuotaLimit = %d, want the normal 20 (the existing reports quota)", p.QuotaLimit)
	}
}

// An ARCHIVED community has no owner: the target owner and the handle are empty and the report is still filed.
func TestReport_ArchivedCommunityHasNoOwner(t *testing.T) {
	t.Parallel()
	f := newFixture()
	l := &fakeCommunityLookup{c: ReportedCommunity{Name: "old", CreatedAt: f.now}}
	if _, err := f.communitySvc(l).Report(gctx(), reporter, communityInput()); err != nil {
		t.Fatal(err)
	}
	r := f.repo.calls[0].Report
	if r.TargetOwnerID != "" || r.Evidence.AuthorHandle != "" || r.Evidence.CommunityName != "old" {
		t.Errorf("report = %+v evidence = %+v", r, r.Evidence)
	}
}

func TestReport_CommunityNewAccountGetsTheLowerQuota(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.dir.profiles[reporter] = identity.Profile{UserID: reporter, CreatedAt: f.now.Add(-time.Hour)}
	if _, err := f.communitySvc(&fakeCommunityLookup{c: ReportedCommunity{OwnerUID: communityOwner}}).Report(gctx(), reporter, communityInput()); err != nil {
		t.Fatal(err)
	}
	if got := f.repo.calls[0].QuotaLimit; got != 5 {
		t.Errorf("QuotaLimit = %d, want 5", got)
	}
}

func TestReport_CommunityOwnIsValidationTargetID(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.communitySvc(&fakeCommunityLookup{err: fmt.Errorf("lookup: %w", ErrOwnCommunity)}).Report(gctx(), reporter, communityInput())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
		t.Errorf("err = %v, want field target_id", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("an own community must not be written")
	}
}

// A missing and a SUSPENDED community both fold into ErrCommunityNotFound and answer one NOT_FOUND with the bytes of
// communities.NotFoundError ("community not found", reason UNSPECIFIED, no metadata).
func TestReport_CommunityNotFoundIsOneAnswer(t *testing.T) {
	t.Parallel()
	var first *apierr.Error
	for name, cause := range map[string]error{
		"bare":          ErrCommunityNotFound,
		"wrapped":       fmt.Errorf("communities adapter: %w", ErrCommunityNotFound),
		"wrapped twice": fmt.Errorf("a: %w", fmt.Errorf("b: %w", ErrCommunityNotFound)),
	} {
		f := newFixture()
		_, err := f.communitySvc(&fakeCommunityLookup{err: cause}).Report(gctx(), reporter, communityInput())
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
			t.Errorf("%s: wrote a report for an unreportable community", name)
		}
	}
	if first.Message != "community not found" || len(first.Metadata) != 0 {
		t.Errorf("answer = %+v", first)
	}
}

func TestReport_CommunityInfrastructureErrorsAreRedacted(t *testing.T) {
	t.Parallel()
	f := newFixture()
	boom := fmt.Errorf("get communities/%s for %s: deadline", okCommunityID, reporter)
	_, err := f.communitySvc(&fakeCommunityLookup{err: boom}).Report(gctx(), reporter, communityInput())
	if err == nil {
		t.Fatal("want an error")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("an infrastructure error became a client answer: %+v", ae)
	}
	for _, secret := range []string{okCommunityID, reporter} {
		if strings.Contains(err.Error(), secret) {
			t.Errorf("error leaks %q: %v", secret, err)
		}
	}
}

func TestReport_CommunityWithoutLookupIsInternal(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.communitySvc(nil).Report(gctx(), reporter, communityInput())
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want an internal error", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("wrote a report without a lookup")
	}
}

func TestReport_CommunityRepeatIsAlreadyReported(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.repo.existing = true
	res, err := f.communitySvc(&fakeCommunityLookup{c: ReportedCommunity{OwnerUID: communityOwner}}).Report(gctx(), reporter, communityInput())
	if err != nil || !res.AlreadyReported || res.ReportID != ReportID(reporter, TargetCommunity, okCommunityID) {
		t.Fatalf("res = %+v err = %v", res, err)
	}
}

// The target type is part of the report id: a community, a list and a post that share an id never collide.
func TestReportID_SeparatesCommunityTargets(t *testing.T) {
	t.Parallel()
	c := ReportID(reporter, TargetCommunity, okCommunityID)
	if c == ReportID(reporter, TargetPost, okCommunityID) || c == ReportID(reporter, TargetList, okCommunityID) {
		t.Error("a COMMUNITY report shares a report id with another target type")
	}
}

// communityFlags is a FlagChecker with a per-flag mode, the shape of *flags.Registry.
type communityFlags struct{ reports, communities flags.Mode }

func (f communityFlags) Enabled(_, name string) bool {
	switch name {
	case FlagName:
		return f.reports == flags.On
	case CommunitiesFlagName:
		return f.communities == flags.On
	}
	return false
}

func (f communityFlags) GloballyOff(name string) bool {
	return name == CommunitiesFlagName && f.communities == flags.Off
}

// The flag matrix of a COMMUNITY report: `reports` must be on for the caller, `communities` only not globally off (off, allowlist,
// percent, on).
func TestServer_CommunityReportFlagMatrix(t *testing.T) {
	t.Parallel()
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_COMMUNITY, TargetId: okCommunityID,
		Reason: moderationv1.ReportReason_REPORT_REASON_HATE,
	})
	tests := []struct {
		name     string
		fc       FlagChecker
		disabled bool
		feature  string
	}{
		{"reports off", communityFlags{reports: flags.Off, communities: flags.On}, true, ""},
		{"communities off globally", communityFlags{reports: flags.On, communities: flags.Off}, true, CommunitiesFlagName},
		{"communities allowlist without the caller", communityFlags{reports: flags.On, communities: flags.Allowlist}, false, ""},
		{"communities percent 0", communityFlags{reports: flags.On, communities: flags.Percent}, false, ""},
		{"communities on", communityFlags{reports: flags.On, communities: flags.On}, false, ""},
		{"nil checker", nil, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeCommunityLookup{c: ReportedCommunity{OwnerUID: communityOwner, Name: "n"}}
			ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
			res, err := NewServer(f.communitySvc(l), tt.fc).ReportContent(ctx, req)
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
			if got := f.repo.calls[0].Report; got.TargetType != TargetCommunity || got.TargetID != okCommunityID {
				t.Errorf("enum conversion: %+v", got)
			}
		})
	}
}

// A POST report never looks at the communities flag.
func TestServer_PostReportIgnoresTheCommunitiesFlag(t *testing.T) {
	t.Parallel()
	f := newFixture()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST, TargetId: okPostID,
		Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
	})
	if _, err := NewServer(f.svc(), communityFlags{reports: flags.On, communities: flags.Off}).ReportContent(ctx, req); err != nil {
		t.Fatalf("a POST report with communities off: %v", err)
	}
}
