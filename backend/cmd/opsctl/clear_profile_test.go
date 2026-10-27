package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// ADR-0024 Amendment 1 A3(a): `opsctl clear-profile-fields`, over fakes. The Firestore behaviour (one field-level
// update, skip empty, DELETING refused, 1 read / 1 write) is in internal/identity's integration test and the CLI end to
// end in clear_profile_integration_test.go.

const clearUID = "uid-victim"

type fakeClearer struct {
	calls []clearCall
	// cleared is what a non-dry call reports it cleared (the stored values); skipped is what it found empty.
	cleared []identity.ClearedField
	skipped []identity.ProfileField
	written bool
	err     error
}

type clearCall struct {
	uid    string
	fields []identity.ProfileField
	now    time.Time
	dryRun bool
}

func (f *fakeClearer) ClearProfileFields(_ context.Context, uid string, fields []identity.ProfileField, now time.Time, dryRun bool) (identity.ClearResult, error) {
	f.calls = append(f.calls, clearCall{uid: uid, fields: fields, now: now, dryRun: dryRun})
	if f.err != nil {
		return identity.ClearResult{}, f.err
	}
	return identity.ClearResult{Cleared: f.cleared, Skipped: f.skipped, Written: f.written && !dryRun && len(f.cleared) > 0}, nil
}

type clearFixture struct {
	clearer *fakeClearer
	ops     *fakeOps
	opened  int
}

func newClearFixture() *clearFixture {
	return &clearFixture{
		clearer: &fakeClearer{
			cleared: []identity.ClearedField{
				{Field: identity.ProfileFieldWebsite, Values: []string{"https://phish.example/login"}},
				{Field: identity.ProfileFieldBanner, Values: []string{"https://storage.googleapis.com/dzeroth-dev-media/m/123.webp", "https://storage.googleapis.com/dzeroth-dev-media/m/123_t.webp"}},
			},
			skipped: []identity.ProfileField{identity.ProfileFieldLocation},
			written: true,
		},
		// The default report is about this user (an ACCOUNT report), OPEN.
		ops: &fakeOps{report: &moderation.Report{TargetType: moderation.TargetAccount, TargetID: clearUID, TargetOwnerID: clearUID,
			Reason: moderation.ReasonOther, Status: moderation.StatusOpen}},
	}
}

func (c *clearFixture) run(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		c.opened++
		return &backends{reports: c.ops, profiles: c.clearer, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func clearArgs(extra ...string) []string {
	return append([]string{"clear-profile-fields", "--project", "dzeroth-dev", "--uid", clearUID}, extra...)
}

func TestClearProfileFields_UsageErrors(t *testing.T) {
	t.Parallel()
	const rid = testReportID
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no --fields", clearArgs(), "--fields is required"},
		{"empty --fields", clearArgs("--fields", ""), "--fields is required"},
		{"unknown field", clearArgs("--fields", "website,display_name"), `unknown field "display_name"`},
		{"the pin is not clearable here", clearArgs("--fields", "pin"), `unknown field "pin"`},
		{"repeated field", clearArgs("--fields", "website,bio,website"), `"website" is repeated`},
		{"empty item", clearArgs("--fields", "website,"), "unknown field"},
		{"bad report id", clearArgs("--fields", "website", "--report", "nope"), "--report must be a 32-character report id"},
		{"note without a report", clearArgs("--fields", "website", "--note", "x"), "--note"},
		{"--fields on another command", []string{"purge-graph", "--project", "dzeroth-dev", "--uid", clearUID, "--fields", "website"}, "--fields is not supported by purge-graph"},
		{"missing --uid", []string{"clear-profile-fields", "--project", "dzeroth-dev", "--fields", "website"}, "--uid is required"},
		{"bad --uid", []string{"clear-profile-fields", "--project", "dzeroth-dev", "--uid", "bad id!", "--fields", "website"}, "not a valid user id"},
		{"missing --project", []string{"clear-profile-fields", "--uid", clearUID, "--fields", "website"}, "--project is required"},
		{"unquoted note swallows flags", clearArgs("--fields", "website", "--report", rid, "--note", "two", "words", "--dry-run"), "unexpected argument"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newClearFixture()
			code, _, stderr := c.run("", tt.args...)
			if code != 2 {
				t.Fatalf("exit code = %d, want 2 (usage); stderr=%q", code, stderr)
			}
			if !strings.Contains(stderr, tt.want) {
				t.Errorf("stderr = %q, want it to contain %q", stderr, tt.want)
			}
			if c.opened != 0 || len(c.clearer.calls) != 0 {
				t.Errorf("a usage error must open nothing and write nothing: opened=%d calls=%v", c.opened, c.clearer.calls)
			}
		})
	}
}

func TestClearProfileFields_RunClearsAndPrintsTheImageObjects(t *testing.T) {
	t.Parallel()
	c := newClearFixture()
	code, stdout, stderr := c.run("", clearArgs("--fields", "website,banner,location")...)
	if code != 0 {
		t.Fatalf("exit code = %d; stdout=%q stderr=%q", code, stdout, stderr)
	}
	if len(c.clearer.calls) != 1 {
		t.Fatalf("calls = %+v, want exactly one", c.clearer.calls)
	}
	call := c.clearer.calls[0]
	wantFields := []identity.ProfileField{identity.ProfileFieldWebsite, identity.ProfileFieldBanner, identity.ProfileFieldLocation}
	if call.uid != clearUID || !reflect.DeepEqual(call.fields, wantFields) || call.dryRun || !call.now.Equal(time.Unix(1_000_000, 0)) {
		t.Errorf("call = %+v", call)
	}
	for _, want := range []string{
		`website: cleared "https://phish.example/login"`,
		"banner: cleared ",
		"location: already empty, skipped",
		"2 field(s) cleared with one field-level update",
		"banner object (still public until deleted): m/123.webp in bucket dzeroth-dev-media",
		"banner object (still public until deleted): m/123_t.webp in bucket dzeroth-dev-media",
		"cost: reads=",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if len(c.ops.resolved) != 0 {
		t.Errorf("no --report: nothing may be resolved, got %v", c.ops.resolved)
	}
}

func TestClearProfileFields_DryRunWritesNothing(t *testing.T) {
	t.Parallel()
	c := newClearFixture()
	code, stdout, stderr := c.run("", clearArgs("--fields", "website,banner", "--report", testReportID, "--dry-run")...)
	if code != 0 {
		t.Fatalf("exit code = %d; stdout=%q stderr=%q", code, stdout, stderr)
	}
	if len(c.clearer.calls) != 1 || !c.clearer.calls[0].dryRun {
		t.Fatalf("calls = %+v, want one dry-run call", c.clearer.calls)
	}
	for _, want := range []string{`website: would clear "https://phish.example/login"`, "(nothing written)", "would resolve report " + testReportID + " as PROFILE_CLEARED"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "cleared with one field-level update") {
		t.Errorf("a dry run claimed a write:\n%s", stdout)
	}
	if len(c.ops.resolved) != 0 {
		t.Errorf("a dry run resolved a report: %v", c.ops.resolved)
	}
}

func TestClearProfileFields_NothingToClearWritesZeroAndStillResolvesTheReport(t *testing.T) {
	t.Parallel()
	c := newClearFixture()
	c.clearer.cleared, c.clearer.skipped = nil, []identity.ProfileField{identity.ProfileFieldWebsite}
	code, stdout, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID, "--note", "link already gone")...)
	if code != 0 {
		t.Fatalf("exit code = %d; stdout=%q stderr=%q", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "website: already empty, skipped") || !strings.Contains(stdout, "nothing to clear: 0 writes") {
		t.Errorf("stdout:\n%s", stdout)
	}
	if got := c.ops.resolved[testReportID]; got != moderation.ResolutionProfileCleared {
		t.Errorf("report resolution = %q, want PROFILE_CLEARED (the content is clear, so the report is done)", got)
	}
}

func TestClearProfileFields_ReportResolvedAsProfileCleared(t *testing.T) {
	t.Parallel()
	c := newClearFixture()
	code, stdout, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID, "--note", "phishing link")...)
	if code != 0 {
		t.Fatalf("exit code = %d; stdout=%q stderr=%q", code, stdout, stderr)
	}
	if got := c.ops.resolved[testReportID]; got != moderation.ResolutionProfileCleared {
		t.Errorf("resolution = %q, want PROFILE_CLEARED", got)
	}
	if got := c.ops.notes[testReportID]; got != "phishing link" {
		t.Errorf("resolution note = %q", got)
	}
	if !strings.Contains(stdout, "report "+testReportID+": RESOLVED (PROFILE_CLEARED)") {
		t.Errorf("stdout:\n%s", stdout)
	}
}

func TestClearProfileFields_ReportChecks(t *testing.T) {
	t.Parallel()
	t.Run("a report about someone else is refused before any write", func(t *testing.T) {
		t.Parallel()
		c := newClearFixture()
		c.ops.report.TargetOwnerID = "uid-someone-else"
		code, _, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID)...)
		if code != 1 || !strings.Contains(stderr, "about another user's content") {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if len(c.clearer.calls) != 0 || len(c.ops.resolved) != 0 {
			t.Errorf("nothing may be written: clear calls=%v resolved=%v", c.clearer.calls, c.ops.resolved)
		}
	})
	t.Run("an unknown report is refused before any write", func(t *testing.T) {
		t.Parallel()
		c := newClearFixture()
		c.ops.getErr = moderation.ErrNotFound
		code, _, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID)...)
		if code != 1 || !strings.Contains(stderr, "--report") {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if len(c.clearer.calls) != 0 {
			t.Errorf("cleared despite an unknown report: %v", c.clearer.calls)
		}
	})
	t.Run("an already resolved report only warns", func(t *testing.T) {
		t.Parallel()
		c := newClearFixture()
		c.ops.report.Status, c.ops.report.Resolution = moderation.StatusResolved, moderation.ResolutionDismissed
		code, stdout, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID)...)
		if code != 0 || !strings.Contains(stdout, "already RESOLVED") {
			t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
		}
		if len(c.clearer.calls) != 1 {
			t.Errorf("the clear must still apply: %v", c.clearer.calls)
		}
	})
}

func TestClearProfileFields_RuntimeErrorsAreExit1(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		err  error
		want string
	}{
		{"no such user", identity.ErrNotFound, "no such user"},
		{"DELETING is refused", identity.ErrStatusConflict, "DELETING: refusing to change it"},
		{"a Firestore error", errors.New("firestore down"), "firestore down"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newClearFixture()
			c.clearer.err = fmt.Errorf("wrapped: %w", tt.err)
			code, _, stderr := c.run("", clearArgs("--fields", "website", "--report", testReportID)...)
			if code != 1 || !strings.Contains(stderr, tt.want) {
				t.Fatalf("code=%d stderr=%q, want exit 1 and %q", code, stderr, tt.want)
			}
			if len(c.ops.resolved) != 0 {
				t.Errorf("a failed clear resolved the report: %v", c.ops.resolved)
			}
		})
	}
}

func TestClearProfileFields_ProdNeedsTheTypedConfirmationDryRunIncluded(t *testing.T) {
	t.Parallel()
	for _, dry := range []bool{false, true} {
		for _, tt := range []struct {
			name, stdin string
			wantCode    int
		}{
			{"typed project id", "dzeroth-prod\n", 0},
			{"wrong text", "yes\n", 1},
			{"eof", "", 1},
		} {
			t.Run(fmt.Sprintf("dry-run=%v/%s", dry, tt.name), func(t *testing.T) {
				t.Parallel()
				c := newClearFixture()
				args := []string{"clear-profile-fields", "--project", "dzeroth-prod", "--uid", clearUID, "--fields", "website"}
				if dry {
					args = append(args, "--dry-run")
				}
				code, _, _ := c.run(tt.stdin, args...)
				if code != tt.wantCode {
					t.Fatalf("code = %d, want %d", code, tt.wantCode)
				}
				if tt.wantCode != 0 && (c.opened != 0 || len(c.clearer.calls) != 0) {
					t.Errorf("without the confirmation nothing may be opened or written: opened=%d calls=%v", c.opened, c.clearer.calls)
				}
				if tt.wantCode == 0 && (len(c.clearer.calls) != 1 || c.clearer.calls[0].dryRun != dry) {
					t.Errorf("calls = %+v", c.clearer.calls)
				}
			})
		}
	}
}

func TestObjectName(t *testing.T) {
	t.Parallel()
	tests := []struct{ in, want string }{
		{"https://storage.googleapis.com/dzeroth-dev-media/m/123.webp", "m/123.webp"},
		{"https://storage.googleapis.com/dzeroth-dev-media/m/123_t.webp", "m/123_t.webp"},
		{"https://cdn.example.com/media/m/9.jpg?v=1", "m/9.jpg"},
		{"https://m/m/9_t.webp", "m/9_t.webp"},
		{"https://example.com/other/123.webp", ""},
		{"https://example.com/m/", ""},
		{"https://example.com/m/a/b.webp", ""},
		{"", ""},
		{"%zz", ""},
	}
	for _, tt := range tests {
		if got := objectName(tt.in); got != tt.want {
			t.Errorf("objectName(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestClearProfileFields_UnderivableObjectNameIsSaid(t *testing.T) {
	t.Parallel()
	var out bytes.Buffer
	printImageObjects(&out, "dzeroth-dev", []identity.ClearedField{
		{Field: identity.ProfileFieldAvatar, Values: []string{"https://elsewhere.example/a.webp", ""}},
		{Field: identity.ProfileFieldBio, Values: []string{"https://x.example/m/1.webp"}}, // not an image field: never listed
	})
	got := out.String()
	if !strings.Contains(got, `avatar object (still public until deleted): could not derive the object name from "https://elsewhere.example/a.webp"`) {
		t.Errorf("output:\n%s", got)
	}
	if strings.Contains(got, "bio") {
		t.Errorf("a text field was listed as an object:\n%s", got)
	}
}

// ACCOUNT report evidence in `reports show` (A3(b)).
func TestReportsShow_AccountEvidence(t *testing.T) {
	t.Parallel()
	t.Run("the profile as the reporter saw it", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetAccount, TargetID: clearUID, TargetOwnerID: clearUID, Reason: moderation.ReasonImpersonation,
			Status: moderation.StatusOpen, Evidence: &moderation.Evidence{AuthorHandle: "Mallory", DisplayName: "Mal", Bio: "click here",
				Location: "Pune", Website: "https://phish.example/login", AvatarURL: "https://m/m/1.webp", BannerURL: "https://m/m/2.webp"}}
		code, stdout, stderr := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
		if code != 0 {
			t.Fatalf("exit code = %d; stderr=%q", code, stderr)
		}
		for _, want := range []string{"evidence profile @Mallory", `display name "Mal"`, `bio "click here"`, `location "Pune"`,
			`website "https://phish.example/login"`, `avatar "https://m/m/1.webp"`, `banner "https://m/m/2.webp"`} {
			if !strings.Contains(stdout, want) {
				t.Errorf("stdout missing %q:\n%s", want, stdout)
			}
		}
		if strings.Contains(stdout, "evidence post by") {
			t.Errorf("an account report printed post evidence:\n%s", stdout)
		}
	})
	t.Run("an account report filed before evidence was kept", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetAccount, TargetID: clearUID, TargetOwnerID: clearUID, Status: moderation.StatusOpen}
		code, stdout, _ := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
		if code != 0 || !strings.Contains(stdout, "evidence none") {
			t.Fatalf("code=%d stdout=%q", code, stdout)
		}
	})
	t.Run("a post report still prints post evidence", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, stdout, _ := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
		if code != 0 || !strings.Contains(stdout, `evidence post by @bob`) || strings.Contains(stdout, "evidence profile") {
			t.Fatalf("code=%d stdout=%q", code, stdout)
		}
	})
}

func TestReportsResolve_ProfileClearedIsNotAManualResolution(t *testing.T) {
	t.Parallel()
	f := newModFixture()
	code, _, stderr := f.run("", "reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "PROFILE_CLEARED")
	if code != 2 || !strings.Contains(stderr, "PROFILE_CLEARED are set by") {
		t.Fatalf("code=%d stderr=%q: PROFILE_CLEARED is set by clear-profile-fields --report only", code, stderr)
	}
	if len(f.ops.resolved) != 0 {
		t.Errorf("resolved %v", f.ops.resolved)
	}
}
