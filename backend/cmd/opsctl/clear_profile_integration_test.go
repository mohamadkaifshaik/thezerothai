//go:build integration

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// End-to-end emulator test of `opsctl clear-profile-fields` (ADR-0024 Amendment 1 A3): the real run() flag handling and
// output over the real identity and moderation repos. The opener wires only what the commands use (openFirestore also
// needs the Auth Admin client, which these commands do not).

func runClearCLI(t *testing.T, client *firestore.Client, stdin string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{
			reports:  moderation.NewFirestoreRepo(client, quota.New(client)),
			profiles: identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client)),
			close:    func() {},
		}, nil
	}
	var out, errOut bytes.Buffer
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, func() time.Time { return time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC) })
	return code, out.String(), errOut.String()
}

func TestClearProfileFields_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const uid, victim = "uid-mal", "uid-victim"
	seedUser := func(id, status string, extra map[string]any) {
		doc := map[string]any{
			"handle": "mallory", "handleLower": "mallory", "displayName": "Mal", "bio": "click here", "status": status,
			"location": "Pune", "website": "https://phish.example/login", "pinnedPostId": "0000000000000000301", "snapshotVersion": int64(3),
			"bannerUrl": "https://storage.googleapis.com/" + project + "-media/m/222.webp", "bannerThumbUrl": "https://storage.googleapis.com/" + project + "-media/m/222_t.webp",
			"avatarUrl": "https://storage.googleapis.com/" + project + "-media/m/111.webp", "avatarThumbUrl": "https://storage.googleapis.com/" + project + "-media/m/111_t.webp",
			"createdAt": time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), "updatedAt": time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC),
		}
		for k, v := range extra {
			doc[k] = v
		}
		if _, err := client.Collection("users").Doc(id).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	stored := func(id string) map[string]any {
		s, err := client.Collection("users").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return s.Data()
	}
	seedUser(uid, "ACTIVE", nil)

	// An ACCOUNT report of that user, with the evidence ReportContent would keep.
	modRepo := moderation.NewFirestoreRepo(client, quota.New(client))
	rep := moderation.Report{
		ID: moderation.ReportID("u-reporter", moderation.TargetAccount, uid), ReporterID: "u-reporter", TargetType: moderation.TargetAccount,
		TargetID: uid, TargetOwnerID: uid, Reason: moderation.ReasonOther, Status: moderation.StatusOpen, CreatedAt: time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC),
		Evidence: &moderation.Evidence{AuthorHandle: "mallory", DisplayName: "Mal", Bio: "click here", Location: "Pune", Website: "https://phish.example/login",
			AvatarURL: "https://x/m/111.webp", BannerURL: "https://x/m/222.webp"},
	}
	if _, err := modRepo.Create(ctx, moderation.CreateParams{Report: rep, QuotaLimit: 20}); err != nil {
		t.Fatal(err)
	}

	// reports show prints the evidence of an ACCOUNT report.
	code, stdout, stderr := runClearCLI(t, client, "", "reports", "show", "--project", project, "--id", rep.ID)
	if code != 0 || !strings.Contains(stdout, `evidence profile @mallory: display name "Mal", bio "click here", location "Pune", website "https://phish.example/login"`) {
		t.Fatalf("reports show: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}

	// Dry run: the plan and the stored values, nothing written, the report untouched.
	before := stored(uid)
	code, stdout, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", uid, "--fields", "website,banner,avatar", "--report", rep.ID, "--dry-run")
	if code != 0 {
		t.Fatalf("dry run: code=%d stderr=%q", code, stderr)
	}
	t.Logf("dry run output:\n%s", stdout)
	for _, want := range []string{`website: would clear "https://phish.example/login"`, "dry-run: 3 field(s) to clear, 0 already empty (nothing written)",
		"banner object (still public until deleted): m/222.webp in bucket " + project + "-media", "avatar object (still public until deleted): m/111_t.webp",
		"would resolve report " + rep.ID + " as PROFILE_CLEARED", "cost: reads=2 writes=0"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("dry run stdout missing %q", want)
		}
	}
	for k, v := range before {
		if stored(uid)[k] != v {
			t.Errorf("the dry run changed users/%s.%s", uid, k)
		}
	}
	if r, err := modRepo.Get(ctx, rep.ID); err != nil || r.Status != moderation.StatusOpen {
		t.Fatalf("the dry run touched the report: %+v err=%v", r, err)
	}

	// The real run: one field-level update, the report resolved.
	code, stdout, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", uid, "--fields", "website,banner,avatar,location", "--report", rep.ID, "--note", "phishing link and image")
	if code != 0 {
		t.Fatalf("run: code=%d stderr=%q", code, stderr)
	}
	t.Logf("run output:\n%s", stdout)
	for _, want := range []string{"4 field(s) cleared with one field-level update", "report " + rep.ID + ": RESOLVED (PROFILE_CLEARED)",
		"banner object (still public until deleted): m/222.webp in bucket " + project + "-media", "cost: reads=3 writes=2"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("run stdout missing %q", want)
		}
	}
	after := stored(uid)
	for _, f := range []string{"website", "location", "bannerUrl", "bannerThumbUrl", "avatarUrl", "avatarThumbUrl"} {
		if v, has := after[f]; !has || v != "" {
			t.Errorf("users/%s.%s = %v (present %v), want the empty string", uid, f, v, has)
		}
	}
	if got, _ := after["updatedAt"].(time.Time); !got.Equal(time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("updatedAt = %v", after["updatedAt"])
	}
	for _, f := range []string{"bio", "displayName", "handle", "pinnedPostId", "snapshotVersion", "status"} {
		if after[f] != before[f] {
			t.Errorf("users/%s.%s changed: %v -> %v (it was not named)", uid, f, before[f], after[f])
		}
	}
	r, err := modRepo.Get(ctx, rep.ID)
	if err != nil || r.Status != moderation.StatusResolved || r.Resolution != moderation.ResolutionProfileCleared || r.ResolutionNote != "phishing link and image" || r.ExpireAt.IsZero() {
		t.Fatalf("report after the run = %+v err=%v", r, err)
	}

	// A rerun writes nothing at all: every field is empty, the report is already resolved (a warning, no second write).
	code, stdout, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", uid, "--fields", "website,banner,avatar,location", "--report", rep.ID)
	if code != 0 || !strings.Contains(stdout, "nothing to clear: 0 writes") || !strings.Contains(stdout, "cost: reads=3 writes=0") || !strings.Contains(stdout, "already RESOLVED") {
		t.Fatalf("rerun: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
	if got, _ := stored(uid)["updatedAt"].(time.Time); !got.Equal(time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("the rerun moved updatedAt to %v", got)
	}

	// A report about another user is refused before any write.
	seedUser(victim, "ACTIVE", nil)
	code, _, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", victim, "--fields", "website", "--report", rep.ID)
	if code != 1 || !strings.Contains(stderr, "about another user's content") {
		t.Fatalf("mismatched report: code=%d stderr=%q", code, stderr)
	}
	if stored(victim)["website"] != "https://phish.example/login" {
		t.Error("a refused run changed the victim's profile")
	}

	// DELETING is refused and left alone; a missing user is an error; both are exit 1.
	seedUser("uid-deleting", "DELETING", nil)
	code, _, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", "uid-deleting", "--fields", "website")
	if code != 1 || !strings.Contains(stderr, "DELETING: refusing to change it") || stored("uid-deleting")["website"] != "https://phish.example/login" {
		t.Fatalf("DELETING: code=%d stderr=%q", code, stderr)
	}
	code, _, stderr = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", "uid-gone", "--fields", "website")
	if code != 1 || !strings.Contains(stderr, "no such user") {
		t.Fatalf("missing user: code=%d stderr=%q", code, stderr)
	}
	if _, err := client.Collection("users").Doc("uid-gone").Get(ctx); err == nil {
		t.Fatal("a clear recreated a missing users document")
	}

	// A usage error is exit 2.
	code, _, _ = runClearCLI(t, client, "", "clear-profile-fields", "--project", project, "--uid", uid, "--fields", "website,website")
	if code != 2 {
		t.Fatalf("repeated field: code=%d, want 2", code)
	}
}
