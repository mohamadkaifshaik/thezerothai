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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	okBeaconID      = "1234567890123456780"
	beaconOrganiser = "uid-beacon-organiser"
)

// fakeBeaconLookup is a BeaconLookup that records its calls and answers from a script.
type fakeBeaconLookup struct {
	beacon ReportedBeacon
	err    error
	calls  []string
}

func (f *fakeBeaconLookup) ReportableBeacon(_ context.Context, callerUID, beaconID string) (ReportedBeacon, error) {
	f.calls = append(f.calls, callerUID+"|"+beaconID)
	return f.beacon, f.err
}

func (f *fixture) beaconSvc(b BeaconLookup) Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, Beacons: b,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

func beaconInput() ReportInput {
	return ReportInput{IdempotencyKey: okKey, TargetType: TargetBeacon, TargetID: okBeaconID, Reason: ReasonHate}
}

func TestReport_BeaconValidationDoesNoWork(t *testing.T) {
	t.Parallel()
	for name, id := range map[string]string{
		"empty": "", "too short": "12345", "letters": "123456789012345678a", "account id": author, "twenty": okBeaconID + "0",
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeBeaconLookup{}
			in := beaconInput()
			in.TargetID = id
			_, err := f.beaconSvc(l).Report(gctx(), reporter, in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
				t.Errorf("err = %v, want field target_id", err)
			}
			if len(l.calls) != 0 || len(f.repo.calls) != 0 {
				t.Error("a malformed beacon id did a read or a write")
			}
		})
	}
}

// A visible beacon is reported: the evidence is the organiser's handle, the title, details and venue (R16), no participant.
func TestReport_BeaconVisibleStoresTheSnapshot(t *testing.T) {
	t.Parallel()
	f := newFixture()
	made := f.now.Add(-48 * time.Hour)
	l := &fakeBeaconLookup{beacon: ReportedBeacon{OrganiserUID: beaconOrganiser, OrganiserHandle: "mallory", Title: "Coffee", Details: "bring cash", Venue: "Hall", CreatedAt: made}}
	res, err := f.beaconSvc(l).Report(gctx(), reporter, beaconInput())
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyReported || res.ReportID != ReportID(reporter, TargetBeacon, okBeaconID) {
		t.Fatalf("res = %+v", res)
	}
	if want := []string{reporter + "|" + okBeaconID}; !reflect.DeepEqual(l.calls, want) {
		t.Errorf("lookup calls = %v, want %v", l.calls, want)
	}
	if len(f.repo.calls) != 1 || f.posts.n != 0 || f.accounts.n != 0 {
		t.Fatalf("creates %d, post reads %d, account reads %d", len(f.repo.calls), f.posts.n, f.accounts.n)
	}
	p := f.repo.calls[0]
	r := p.Report
	if r.TargetType != TargetBeacon || r.TargetID != okBeaconID || r.TargetOwnerID != beaconOrganiser || r.ReporterID != reporter || r.Status != StatusOpen {
		t.Errorf("report = %+v", r)
	}
	want := &Evidence{AuthorHandle: "mallory", BeaconTitle: "Coffee", BeaconDetails: "bring cash", BeaconVenue: "Hall", PostCreatedAt: made}
	if !reflect.DeepEqual(r.Evidence, want) {
		t.Errorf("evidence = %+v, want %+v", r.Evidence, want)
	}
	if p.QuotaLimit != 20 {
		t.Errorf("QuotaLimit = %d, want 20", p.QuotaLimit)
	}
}

func TestReport_BeaconOwnIsValidationTargetID(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.beaconSvc(&fakeBeaconLookup{err: fmt.Errorf("lookup: %w", ErrOwnBeacon)}).Report(gctx(), reporter, beaconInput())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
		t.Errorf("err = %v, want field target_id", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("an own beacon must not be written")
	}
}

// Hidden, blocked, non-member, missing: the lookup folds all into ErrBeaconNotFound and the answer is one NOT_FOUND
// with the same bytes whatever wrapped it.
func TestReport_BeaconNotFoundIsOneAnswer(t *testing.T) {
	t.Parallel()
	var first *apierr.Error
	for name, cause := range map[string]error{
		"bare":    ErrBeaconNotFound,
		"wrapped": fmt.Errorf("beacons adapter: %w", ErrBeaconNotFound),
	} {
		f := newFixture()
		_, err := f.beaconSvc(&fakeBeaconLookup{err: cause}).Report(gctx(), reporter, beaconInput())
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
			t.Errorf("%s: wrote a report for an unreportable beacon", name)
		}
	}
	if first.Message != "beacon not found" || len(first.Metadata) != 0 {
		t.Errorf("answer = %+v", first)
	}
}

func TestReport_BeaconInfrastructureErrorsAreRedacted(t *testing.T) {
	t.Parallel()
	f := newFixture()
	boom := fmt.Errorf("get beacons/%s for %s: deadline", okBeaconID, reporter)
	_, err := f.beaconSvc(&fakeBeaconLookup{err: boom}).Report(gctx(), reporter, beaconInput())
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want a redacted internal error", err)
	}
	for _, secret := range []string{okBeaconID, reporter} {
		if strings.Contains(err.Error(), secret) {
			t.Errorf("error leaks %q: %v", secret, err)
		}
	}
}

func TestReport_BeaconWithoutLookupIsInternal(t *testing.T) {
	t.Parallel()
	f := newFixture()
	_, err := f.beaconSvc(nil).Report(gctx(), reporter, beaconInput())
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want an internal error", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("wrote a report without a lookup")
	}
}

// beaconFlags is a FlagChecker with a per-flag mode, the shape of *flags.Registry.
type beaconFlags struct{ reports, beacons flags.Mode }

func (f beaconFlags) Enabled(_, name string) bool {
	switch name {
	case FlagName:
		return f.reports == flags.On
	case BeaconsFlagName:
		return f.beacons == flags.On
	}
	return false
}

func (f beaconFlags) GloballyOff(name string) bool {
	return name == BeaconsFlagName && f.beacons == flags.Off
}

// The flag matrix of a BEACON report (R19): `reports` must be on for the caller, `beacons` only not globally off.
func TestServer_BeaconReportFlagMatrix(t *testing.T) {
	t.Parallel()
	req := connect.NewRequest(&moderationv1.ReportContentRequest{
		IdempotencyKey: okKey, TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_BEACON, TargetId: okBeaconID,
		Reason: moderationv1.ReportReason_REPORT_REASON_HATE,
	})
	tests := []struct {
		name     string
		fc       FlagChecker
		disabled bool
		feature  string
	}{
		{"reports off", beaconFlags{reports: flags.Off, beacons: flags.On}, true, ""},
		{"beacons off globally", beaconFlags{reports: flags.On, beacons: flags.Off}, true, BeaconsFlagName},
		{"beacons allowlist without the caller", beaconFlags{reports: flags.On, beacons: flags.Allowlist}, false, ""},
		{"beacons on", beaconFlags{reports: flags.On, beacons: flags.On}, false, ""},
		{"nil checker", nil, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeBeaconLookup{beacon: ReportedBeacon{OrganiserUID: beaconOrganiser, Title: "t"}}
			ctx := authn.WithClaims(context.Background(), authn.Claims{UID: reporter, SignInProvider: authn.SignInProviderGoogle})
			res, err := NewServer(f.beaconSvc(l), tt.fc).ReportContent(ctx, req)
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
			if got := f.repo.calls[0].Report; got.TargetType != TargetBeacon || got.TargetID != okBeaconID {
				t.Errorf("enum conversion: %+v", got)
			}
		})
	}
}
