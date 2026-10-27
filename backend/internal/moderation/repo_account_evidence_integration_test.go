//go:build integration

package moderation

import (
	"context"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// ADR-0024 Amendment 1 A3(b) against the Firestore emulator: an ACCOUNT report keeps the profile the reporter saw as
// evidence, at no extra read and the same two writes, and PROFILE_CLEARED is a storable resolution.

func accountEvidence(website string) *Evidence {
	return &Evidence{AuthorHandle: "Mallory", DisplayName: "Mal", Bio: "click here", Location: "Pune", Website: website,
		AvatarURL: "https://m/m/1.webp", BannerURL: "https://m/m/2.webp"}
}

func TestRepo_AccountEvidenceRoundTripAndPostReportsKeepTheirShape(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	t0 := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)

	acct := sampleReport("u-rep", TargetAccount, "u-mal", "u-mal", t0)
	acct.Evidence = accountEvidence("https://phish.example/login")
	ctx, c := counted()
	if _, err := repo.Create(ctx, CreateParams{Report: acct, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "Create account report with evidence", c, budgettest.Budget{Reads: 2, Writes: 2})
	got, err := repo.Get(context.Background(), acct.ID)
	if err != nil || got.Evidence == nil {
		t.Fatalf("stored = %+v err=%v", got, err)
	}
	want := *accountEvidence("https://phish.example/login")
	// The list and the time are not part of an account's evidence (an empty list and the zero time are stored).
	gotCopy := *got.Evidence
	gotCopy.MediaIDs, gotCopy.PostCreatedAt = nil, time.Time{}
	if len(got.Evidence.MediaIDs) != 0 || !reflect.DeepEqual(gotCopy, want) {
		t.Fatalf("evidence = %+v, want %+v", *got.Evidence, want)
	}
	// The zero postCreatedAt of an account report is stored and read back without error.
	if !got.Evidence.PostCreatedAt.IsZero() {
		t.Errorf("postCreatedAt = %v, want the zero time", got.Evidence.PostCreatedAt)
	}

	// A post report's document is unchanged in shape: none of the account fields is written.
	post := sampleReport("u-rep", TargetPost, pidN(31), "u-bob", t0)
	if _, err := repo.Create(context.Background(), CreateParams{Report: post, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	snap, err := client.Collection("reports").Doc(post.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ev, _ := snap.Data()["evidence"].(map[string]any)
	for _, f := range []string{"displayName", "bio", "location", "website", "avatarUrl", "bannerUrl"} {
		if _, has := ev[f]; has {
			t.Errorf("a POST report's evidence carries %q: %v", f, ev)
		}
	}

	// PROFILE_CLEARED is storable, retention starts at the resolve like any other resolution.
	res, err := repo.Resolve(context.Background(), acct.ID, ResolutionProfileCleared, "website removed", t0.Add(time.Hour))
	if err != nil || res.Status != StatusResolved || res.Resolution != ResolutionProfileCleared || res.ResolutionNote != "website removed" {
		t.Fatalf("resolve = %+v err=%v", res, err)
	}
	if !res.ExpireAt.Equal(t0.Add(time.Hour + Retention)) {
		t.Errorf("expireAt = %v, want resolvedAt + 90 days", res.ExpireAt)
	}

	// A reopened report refreshes the evidence with what the reporter sees now.
	again := sampleReport("u-rep", TargetAccount, "u-mal", "u-mal", t0.Add(48*time.Hour))
	again.Evidence = accountEvidence("https://other.example")
	if res, err := repo.Create(context.Background(), CreateParams{Report: again, QuotaLimit: 5}); err != nil || !res.Reopened {
		t.Fatalf("reopen: res=%+v err=%v", res, err)
	}
	got, err = repo.Get(context.Background(), acct.ID)
	if err != nil || got.Evidence == nil || got.Evidence.Website != "https://other.example" {
		t.Fatalf("after reopen = %+v err=%v", got, err)
	}
}

// TestReportContent_AccountEvidenceIsThePresentedProfile drives ReportContent over the real identity service: the
// evidence is the profile the reporter saw, so while profile_extras is globally off it has no website, and a report
// costs the same reads with or without evidence.
func TestReportContent_AccountEvidenceIsThePresentedProfile(t *testing.T) {
	for _, tt := range []struct {
		name        string
		mode        flags.Mode
		wantWebsite string
	}{
		{"profile_extras on keeps the website", flags.On, "https://phish.example/login"},
		{"profile_extras globally off keeps none", flags.Off, ""},
		{"an allowlist (a rollout, not the switch) keeps it", flags.Allowlist, "https://phish.example/login"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			client := newTestClient(t)
			graphRepo := graph.NewFirestoreRepo(client)
			identityRepo := identity.NewFirestoreRepo(client, graphRepo)
			graphRepo.SetCounters(identityRepo)
			graphRepo.SetProfiles(identityRepo)
			reg := flags.NewRegistry(flags.Spec{Name: identity.ProfileExtrasFlag, Mode: tt.mode})
			newSvc := func() Service { // a cold instance every time
				g := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, NewAccountWindow: time.Nanosecond})
				i := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithExtrasFlags(reg))
				g.SetDirectory(i.(identity.Directory))
				return New(Deps{
					Repo: NewFirestoreRepo(client, quota.New(client)), Posts: nil, Accounts: i, Directory: i.(identity.Directory),
					ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: time.Nanosecond,
				})
			}
			idSvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithExtrasFlags(reg))
			for uid, h := range map[string]string{"uid-alice": "alice", "uid-mal": "mallory"} {
				if _, err := idSvc.CreateProfile(context.Background(), uid, "0123456789abcdef", h, "N"); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := client.Collection("users").Doc("uid-mal").Update(context.Background(), []firestore.Update{
				{Path: "website", Value: "https://phish.example/login"}, {Path: "location", Value: "Pune"}, {Path: "bio", Value: "click here"},
				{Path: "bannerUrl", Value: "https://m/m/2.webp"}, {Path: "bannerThumbUrl", Value: "https://m/m/2_t.webp"},
			}); err != nil {
				t.Fatal(err)
			}

			claims := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
			in := ReportInput{IdempotencyKey: "0123456789abcdef", TargetType: TargetAccount, TargetID: "uid-mal", Reason: ReasonOther}
			ctx, c := budget.WithCounter(claims)
			res, err := newSvc().Report(ctx, "uid-alice", in)
			if err != nil || res.AlreadyReported {
				t.Fatalf("report: res=%+v err=%v", res, err)
			}
			// Documented ReportContent ACCOUNT cost: reporter users 1, target users 1, report doc 1, quotas 1 (+ graph).
			// The evidence adds no read: it is copied from the profile already loaded.
			budgettest.Assert(t, "ReportContent (account, cold)", c, budgettest.Budget{Reads: 6, Writes: 2})
			if c.Writes() != 2 {
				t.Errorf("writes = %d, want 2 (report doc, quotas)", c.Writes())
			}
			stored, err := NewFirestoreRepo(client, nil).Get(context.Background(), res.ReportID)
			if err != nil || stored.Evidence == nil {
				t.Fatalf("stored = %+v err=%v", stored, err)
			}
			e := stored.Evidence
			if e.AuthorHandle != "mallory" || e.Bio != "click here" || e.Location != "Pune" || e.BannerURL != "https://m/m/2.webp" || e.Website != tt.wantWebsite {
				t.Errorf("evidence = %+v, want website %q", e, tt.wantWebsite)
			}
			if stored.TargetOwnerID != "uid-mal" {
				t.Errorf("target owner = %q", stored.TargetOwnerID)
			}
		})
	}
}
