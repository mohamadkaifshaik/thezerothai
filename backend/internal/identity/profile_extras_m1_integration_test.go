//go:build integration

package identity_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-22 M-1 (ADR-0024 Amendment 1 A2 and A3) against the Firestore emulator: a clear costs 1 read / 1 write for a caller
// outside the cohort and under a globally pulled kill switch, and the operator's ClearProfileFields is one field-level
// update that skips empty fields.

// seedExtras writes the stored extras directly, as a caller inside the cohort once did through the API.
func seedExtras(t *testing.T, client *firestore.Client, uid string) {
	t.Helper()
	_, err := client.Collection("users").Doc(uid).Update(context.Background(), []firestore.Update{
		{Path: "bannerUrl", Value: "https://m/m/9.webp"}, {Path: "bannerThumbUrl", Value: "https://m/m/9_t.webp"},
		{Path: "location", Value: "Pune"}, {Path: "website", Value: "https://phish.example"}, {Path: "pinnedPostId", Value: itPin},
		{Path: "avatarUrl", Value: "https://m/m/7.webp"}, {Path: "avatarThumbUrl", Value: "https://m/m/7_t.webp"},
		{Path: "bio", Value: "buy now"},
	})
	if err != nil {
		t.Fatalf("seed extras: %v", err)
	}
}

func TestUpdateProfile_Integration_ClearOutsideTheCohortCostsOneReadOneWrite(t *testing.T) {
	// Off is the kill switch; an allowlist that does not list the caller and percent 0 are rollouts that leave the
	// caller outside the cohort. A clear must work in all three, at the price of a bio edit.
	for name, mode := range map[string]flags.Mode{"globally off": flags.Off, "allowlist, caller not listed": flags.Allowlist, "percent 0": flags.Percent} {
		t.Run(name, func(t *testing.T) {
			client, svc, _ := newExtrasService(t, mode)
			seedExtras(t, client, itUID)
			before := userData(t, client, itUID)

			// A set from this caller is refused for free...
			loc := "Delhi"
			ctx, counter := budget.WithCounter(context.Background())
			_, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Location: &loc})
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("set err = %v, want FEATURE_DISABLED", err)
			}
			budgettest.Assert(t, "UpdateProfile (set outside the cohort)", counter, budgettest.Budget{})

			// ... and a mixed request is refused whole.
			empty := ""
			ctx, counter = budget.WithCounter(context.Background())
			_, err = svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Website: &empty, Location: &loc})
			if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("mixed err = %v, want FEATURE_DISABLED", err)
			}
			budgettest.Assert(t, "UpdateProfile (mixed clear and set)", counter, budgettest.Budget{})
			if after := userData(t, client, itUID); after["location"] != "Pune" || after["website"] != "https://phish.example" {
				t.Fatalf("a refused request changed the document: %v", after)
			}

			// The clear: 1 read, 1 write, whatever the flag says.
			ctx, counter = budget.WithCounter(context.Background())
			got, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{
				IdempotencyKey: validKeyForIntegration, BannerMediaID: &empty, Location: &empty, Website: &empty, PinnedPostID: &empty,
			})
			if err != nil {
				t.Fatalf("clear: %v", err)
			}
			budgettest.Assert(t, "UpdateProfile (clear outside the cohort)", counter, budgettest.Budget{Reads: 1, Writes: 1})
			if counter.Reads() != 1 || counter.Writes() != 1 {
				t.Errorf("a clear: reads=%d writes=%d, want exactly 1 / 1 (the cost of a bio edit)", counter.Reads(), counter.Writes())
			}
			if got.BannerURL != "" || got.Location != "" || got.Website != "" || got.PinnedPostID != "" {
				t.Errorf("response after the clear: %+v", got)
			}
			after := userData(t, client, itUID)
			for _, field := range []string{"bannerUrl", "bannerThumbUrl", "location", "website", "pinnedPostId"} {
				if v, has := after[field]; has && v != "" {
					t.Errorf("users/%s.%s = %v after the clear", itUID, field, v)
				}
			}
			// Only the cleared fields moved: the avatar and bio the request did not name are intact.
			if after["avatarUrl"] != before["avatarUrl"] || after["bio"] != before["bio"] || after["handle"] != before["handle"] {
				t.Errorf("a clear touched other fields: before %v after %v", before, after)
			}
		})
	}
}

func TestClearProfileFields_Integration(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	newRepo := func(t *testing.T) (*firestore.Client, *identity.FirestoreRepo) {
		client, _, repo := newExtrasService(t, flags.On)
		seedExtras(t, client, itUID)
		return client, repo
	}
	all := []identity.ProfileField{identity.ProfileFieldWebsite, identity.ProfileFieldLocation, identity.ProfileFieldBanner, identity.ProfileFieldAvatar, identity.ProfileFieldBio}

	t.Run("dry run reads once, writes nothing and reports the stored values", func(t *testing.T) {
		client, repo := newRepo(t)
		before := userData(t, client, itUID)
		cctx, counter := budget.WithCounter(ctx)
		res, err := repo.ClearProfileFields(cctx, itUID, all, now, true)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "ClearProfileFields (dry run)", counter, budgettest.Budget{Reads: 1})
		if res.Written || len(res.Cleared) != 5 || len(res.Skipped) != 0 {
			t.Fatalf("result = %+v", res)
		}
		if res.Cleared[0].Field != identity.ProfileFieldWebsite || res.Cleared[0].Values[0] != "https://phish.example" {
			t.Errorf("the dry run must report the stored website: %+v", res.Cleared[0])
		}
		if res.Cleared[2].Field != identity.ProfileFieldBanner || len(res.Cleared[2].Values) != 2 || res.Cleared[2].Values[1] != "https://m/m/9_t.webp" {
			t.Errorf("banner values = %+v, want the full URL then the thumbnail URL", res.Cleared[2])
		}
		after := userData(t, client, itUID)
		for k, v := range before {
			if after[k] != v {
				t.Errorf("the dry run changed users/%s.%s: %v -> %v", itUID, k, v, after[k])
			}
		}
	})

	t.Run("one field-level update clears the named fields, a rerun writes nothing", func(t *testing.T) {
		client, repo := newRepo(t)
		before := userData(t, client, itUID)
		cctx, counter := budget.WithCounter(ctx)
		res, err := repo.ClearProfileFields(cctx, itUID, all, now, false)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "ClearProfileFields (5 fields)", counter, budgettest.Budget{Reads: 1, Writes: 1})
		if !res.Written || len(res.Cleared) != 5 {
			t.Fatalf("result = %+v", res)
		}
		after := userData(t, client, itUID)
		for _, f := range []string{"website", "location", "bannerUrl", "bannerThumbUrl", "avatarUrl", "avatarThumbUrl", "bio"} {
			if v, has := after[f]; !has || v != "" {
				t.Errorf("users/%s.%s = %v (present %v), want the empty string (a field-level Update, not a delete)", itUID, f, v, has)
			}
		}
		if got, _ := after["updatedAt"].(time.Time); !got.Equal(now) {
			t.Errorf("updatedAt = %v, want %v", after["updatedAt"], now)
		}
		// Nothing else moved: the pin (not clearable here), the handle and display name, the snapshot version, the counters.
		for _, f := range []string{"pinnedPostId", "handle", "handleLower", "displayName", "snapshotVersion", "followersCount", "postsCount", "status", "createdAt"} {
			if after[f] != before[f] {
				t.Errorf("users/%s.%s changed: %v -> %v", itUID, f, before[f], after[f])
			}
		}

		cctx, counter = budget.WithCounter(ctx)
		res, err = repo.ClearProfileFields(cctx, itUID, all, now.Add(time.Hour), false)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "ClearProfileFields (rerun)", counter, budgettest.Budget{Reads: 1})
		if res.Written || len(res.Cleared) != 0 || len(res.Skipped) != 5 {
			t.Fatalf("rerun result = %+v, want everything skipped and nothing written", res)
		}
		if got, _ := userData(t, client, itUID)["updatedAt"].(time.Time); !got.Equal(now) {
			t.Errorf("a rerun moved updatedAt to %v", got)
		}
	})

	t.Run("only the named fields change, and a half-set image counts as set", func(t *testing.T) {
		client, repo := newRepo(t)
		// Leave only the avatar thumbnail set, as a half-written image would be.
		if _, err := client.Collection("users").Doc(itUID).Update(ctx, []firestore.Update{{Path: "avatarUrl", Value: ""}}); err != nil {
			t.Fatal(err)
		}
		cctx, counter := budget.WithCounter(ctx)
		res, err := repo.ClearProfileFields(cctx, itUID, []identity.ProfileField{identity.ProfileFieldAvatar, identity.ProfileFieldLocation}, now, false)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "ClearProfileFields (2 fields)", counter, budgettest.Budget{Reads: 1, Writes: 1})
		if len(res.Cleared) != 2 {
			t.Fatalf("result = %+v, want the thumbnail-only avatar cleared too", res)
		}
		after := userData(t, client, itUID)
		if after["avatarThumbUrl"] != "" || after["location"] != "" {
			t.Errorf("not cleared: %v", after)
		}
		if after["website"] != "https://phish.example" || after["bannerUrl"] != "https://m/m/9.webp" || after["bio"] != "buy now" {
			t.Errorf("a field that was not named changed: %v", after)
		}
	})

	t.Run("a missing user is NotFound and is never recreated", func(t *testing.T) {
		client, repo := newRepo(t)
		cctx, counter := budget.WithCounter(ctx)
		_, err := repo.ClearProfileFields(cctx, "gone-1", all, now, false)
		if !errors.Is(err, identity.ErrNotFound) {
			t.Fatalf("err = %v, want ErrNotFound", err)
		}
		budgettest.Assert(t, "ClearProfileFields (missing user)", counter, budgettest.Budget{Reads: 1})
		if snap, err := client.Collection("users").Doc("gone-1").Get(ctx); err == nil {
			t.Errorf("users/gone-1 was created: %v", snap.Data())
		}
	})

	t.Run("a DELETING account is refused and left alone", func(t *testing.T) {
		client, repo := newRepo(t)
		if _, err := client.Collection("users").Doc(itUID).Update(ctx, []firestore.Update{{Path: "status", Value: "DELETING"}}); err != nil {
			t.Fatal(err)
		}
		before := userData(t, client, itUID)
		cctx, counter := budget.WithCounter(ctx)
		_, err := repo.ClearProfileFields(cctx, itUID, all, now, false)
		if !errors.Is(err, identity.ErrStatusConflict) {
			t.Fatalf("err = %v, want ErrStatusConflict", err)
		}
		budgettest.Assert(t, "ClearProfileFields (DELETING)", counter, budgettest.Budget{Reads: 1})
		after := userData(t, client, itUID)
		for k, v := range before {
			if after[k] != v {
				t.Errorf("users/%s.%s changed on a refused clear: %v -> %v", itUID, k, v, after[k])
			}
		}
	})

	t.Run("a SUSPENDED account can be cleared", func(t *testing.T) {
		client, repo := newRepo(t)
		if _, err := client.Collection("users").Doc(itUID).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
			t.Fatal(err)
		}
		res, err := repo.ClearProfileFields(ctx, itUID, []identity.ProfileField{identity.ProfileFieldWebsite}, now, false)
		if err != nil || !res.Written {
			t.Fatalf("ClearProfileFields = %+v, %v", res, err)
		}
		if after := userData(t, client, itUID); after["status"] != "SUSPENDED" || after["website"] != "" {
			t.Errorf("document = %v", after)
		}
	})

	t.Run("no fields is an error", func(t *testing.T) {
		_, repo := newRepo(t)
		if _, err := repo.ClearProfileFields(ctx, itUID, nil, now, false); err == nil {
			t.Fatal("expected an error")
		}
	})
}
