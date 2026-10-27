//go:build integration

package identity_test

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-6 (ADR-0024): UpdateProfile's profile extras and the pin clean-up step against the Firestore emulator, with the
// budget assertions of the ticket: 3 reads / 1 write worst (the transaction's read of users/{uid}, the banner's media
// doc, the pinned post), 0 / 0 when the flag is off, and 1 / 1 for ClearIfPinned.

// chargedBanners resolves like media.Library.ResolveBanner would: it charges the 1 read of the media doc.
type chargedBanners struct{}

func (chargedBanners) ResolveBanner(ctx context.Context, _, _ string) (identity.BannerRef, error) {
	budget.FromContext(ctx).AddReads(1)
	return identity.BannerRef{URL: "https://m/b.webp", ThumbURL: "https://m/b_t.webp"}, nil
}

// chargedPins checks like posts.PinChecker would cold: it charges the 1 read of the post.
type chargedPins struct{}

func (chargedPins) CanPin(ctx context.Context, _, _ string) (bool, error) {
	budget.FromContext(ctx).AddReads(1)
	return true, nil
}

const (
	itPin      = "0000000000000000301"
	itNewerPin = "0000000000000000302"
	itBannerID = "0000000000000000202"
	itUID      = "uid-1"
)

func newExtrasService(t *testing.T, mode flags.Mode) (*firestore.Client, identity.Service, *identity.FirestoreRepo) {
	t.Helper()
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	reg := flags.NewRegistry(flags.Spec{Name: identity.ProfileExtrasFlag, Mode: mode})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour,
		identity.WithBannerResolver(chargedBanners{}), identity.WithPinChecker(chargedPins{}), identity.WithExtrasFlags(reg))
	ctx, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return client, svc, repo
}

func userData(t *testing.T, client *firestore.Client, uid string) map[string]any {
	t.Helper()
	snap, err := client.Collection("users").Doc(uid).Get(context.Background())
	if err != nil {
		t.Fatalf("get users/%s: %v", uid, err)
	}
	return snap.Data()
}

func TestUpdateProfile_Integration_ExtrasBudget(t *testing.T) {
	client, svc, _ := newExtrasService(t, flags.On)
	before := userData(t, client, itUID)

	banner, loc, site, pin := itBannerID, "Pune", "https://example.com", itPin
	ctx, counter := budget.WithCounter(context.Background())
	got, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{
		IdempotencyKey: validKeyForIntegration, BannerMediaID: &banner, Location: &loc, Website: &site, PinnedPostID: &pin,
	})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if got.BannerURL != "https://m/b.webp" || got.Location != "Pune" || got.Website != "https://example.com" || got.PinnedPostID != itPin {
		t.Fatalf("unexpected profile: %+v", got)
	}
	// The ticket's worst case: 3 reads (users/{uid} in the transaction, the banner's media doc, the pinned post), 1 write.
	budgettest.Assert(t, "UpdateProfile (banner + location + website + pin)", counter, budgettest.Budget{Reads: 3, Writes: 1})
	if counter.Reads() != 3 || counter.Writes() != 1 {
		t.Errorf("reads=%d writes=%d, want exactly 3 / 1", counter.Reads(), counter.Writes())
	}

	// The stored document: the five absent-by-default fields, under the names the data model and the index
	// overrides use, and nothing else changed (no snapshot bump: the extras are not in the author snapshot).
	after := userData(t, client, itUID)
	for field, want := range map[string]string{
		"bannerUrl": "https://m/b.webp", "bannerThumbUrl": "https://m/b_t.webp", "location": "Pune",
		"website": "https://example.com", "pinnedPostId": itPin,
	} {
		if after[field] != want {
			t.Errorf("users/%s.%s = %v, want %q", itUID, field, after[field], want)
		}
	}
	for _, field := range []string{"snapshotVersion", "displayName", "handle", "followersCount", "createdAt", "status"} {
		if after[field] != before[field] {
			t.Errorf("users/%s.%s changed: %v -> %v", itUID, field, before[field], after[field])
		}
	}
	for _, field := range []string{"bannerUrl", "bannerThumbUrl", "location", "website", "pinnedPostId"} {
		if _, has := before[field]; has {
			t.Errorf("a new profile already has %s: %v", field, before[field])
		}
	}

	// A later bio edit rewrites the whole document and must keep the extras.
	bio := "hello"
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, err := svc.UpdateProfile(ctx2, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &bio}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "UpdateProfile (bio only)", counter2, budgettest.Budget{Reads: 1, Writes: 1})
	if kept := userData(t, client, itUID); kept["pinnedPostId"] != itPin || kept["bannerUrl"] != "https://m/b.webp" || kept["location"] != "Pune" || kept["website"] != "https://example.com" {
		t.Errorf("a bio edit dropped an extra: %v", kept)
	}
	// ... and so must a handle change.
	ctx3, _ := budget.WithCounter(context.Background())
	if _, err := svc.ChangeHandle(ctx3, itUID, validKeyForIntegration, "alice_two"); err != nil {
		t.Fatal(err)
	}
	if kept := userData(t, client, itUID); kept["pinnedPostId"] != itPin || kept["bannerThumbUrl"] != "https://m/b_t.webp" || kept["location"] != "Pune" {
		t.Errorf("a handle change dropped an extra: %v", kept)
	}

	// Clearing every extra resolves nothing: 1 read, 1 write; the fields become empty or absent.
	emptyStr := ""
	ctx4, counter4 := budget.WithCounter(context.Background())
	cleared, err := svc.UpdateProfile(ctx4, itUID, identity.UpdateProfileParams{
		IdempotencyKey: validKeyForIntegration, BannerMediaID: &emptyStr, Location: &emptyStr, Website: &emptyStr, PinnedPostID: &emptyStr,
	})
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "UpdateProfile (clear all)", counter4, budgettest.Budget{Reads: 1, Writes: 1})
	if cleared.BannerURL != "" || cleared.Location != "" || cleared.Website != "" || cleared.PinnedPostID != "" {
		t.Errorf("not cleared: %+v", cleared)
	}
	final := userData(t, client, itUID)
	for _, field := range []string{"bannerUrl", "bannerThumbUrl", "location", "website", "pinnedPostId"} {
		if v, has := final[field]; has && v != "" {
			t.Errorf("users/%s.%s = %v after the clear", itUID, field, v)
		}
	}
}

func TestUpdateProfile_Integration_ExtrasFlagOffCostsNothing(t *testing.T) {
	client, svc, _ := newExtrasService(t, flags.Off)
	before := userData(t, client, itUID)
	loc := "Pune"
	ctx, counter := budget.WithCounter(context.Background())
	_, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Location: &loc})
	if err == nil {
		t.Fatal("expected FEATURE_DISABLED")
	}
	budgettest.Assert(t, "UpdateProfile (profile_extras off)", counter, budgettest.Budget{})
	if counter.Reads() != 0 || counter.Writes() != 0 {
		t.Errorf("reads=%d writes=%d, want 0 / 0", counter.Reads(), counter.Writes())
	}
	if after := userData(t, client, itUID); after["updatedAt"] != before["updatedAt"] || after["location"] != nil {
		t.Errorf("a refused request changed the document: %v", after)
	}
}

func TestClearIfPinned_Integration(t *testing.T) {
	client, svc, repo := newExtrasService(t, flags.On)
	pin := itPin
	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.UpdateProfile(ctx0, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, PinnedPostID: &pin}); err != nil {
		t.Fatal(err)
	}

	t.Run("a different post leaves the pin alone: 1 read, 0 writes", func(t *testing.T) {
		ctx, counter := budget.WithCounter(context.Background())
		cleared, err := repo.ClearIfPinned(ctx, itUID, itNewerPin)
		if err != nil || cleared {
			t.Fatalf("ClearIfPinned = %v, %v", cleared, err)
		}
		budgettest.Assert(t, "ClearIfPinned (not the pin)", counter, budgettest.Budget{Reads: 1})
		if counter.Reads() != 1 || counter.Writes() != 0 {
			t.Errorf("reads=%d writes=%d, want 1 / 0", counter.Reads(), counter.Writes())
		}
		if got := userData(t, client, itUID)["pinnedPostId"]; got != itPin {
			t.Errorf("pinnedPostId = %v, the pin must stay", got)
		}
	})

	t.Run("the pinned post: 1 read, 1 write, field-level", func(t *testing.T) {
		before := userData(t, client, itUID)
		ctx, counter := budget.WithCounter(context.Background())
		cleared, err := repo.ClearIfPinned(ctx, itUID, itPin)
		if err != nil || !cleared {
			t.Fatalf("ClearIfPinned = %v, %v", cleared, err)
		}
		budgettest.Assert(t, "ClearIfPinned (the pin)", counter, budgettest.Budget{Reads: 1, Writes: 1})
		if counter.Reads() != 1 || counter.Writes() != 1 {
			t.Errorf("reads=%d writes=%d, want 1 / 1", counter.Reads(), counter.Writes())
		}
		after := userData(t, client, itUID)
		if after["pinnedPostId"] != "" {
			t.Errorf("pinnedPostId = %v, want cleared", after["pinnedPostId"])
		}
		for _, field := range []string{"displayName", "handle", "followersCount", "postsCount", "snapshotVersion", "updatedAt", "createdAt"} {
			if after[field] != before[field] {
				t.Errorf("ClearIfPinned touched %s: %v -> %v", field, before[field], after[field])
			}
		}
	})

	t.Run("a redelivery after the clear is a noop: 1 read, 0 writes", func(t *testing.T) {
		ctx, counter := budget.WithCounter(context.Background())
		cleared, err := repo.ClearIfPinned(ctx, itUID, itPin)
		if err != nil || cleared {
			t.Fatalf("ClearIfPinned = %v, %v", cleared, err)
		}
		if counter.Reads() != 1 || counter.Writes() != 0 {
			t.Errorf("reads=%d writes=%d, want 1 / 0", counter.Reads(), counter.Writes())
		}
	})

	t.Run("a newer pin survives the clean-up of the older post", func(t *testing.T) {
		newer := itNewerPin
		ctx0, _ := budget.WithCounter(context.Background())
		if _, err := svc.UpdateProfile(ctx0, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, PinnedPostID: &newer}); err != nil {
			t.Fatal(err)
		}
		ctx, _ := budget.WithCounter(context.Background())
		if cleared, err := repo.ClearIfPinned(ctx, itUID, itPin); err != nil || cleared {
			t.Fatalf("ClearIfPinned(old post) = %v, %v", cleared, err)
		}
		if got := userData(t, client, itUID)["pinnedPostId"]; got != itNewerPin {
			t.Errorf("pinnedPostId = %v, want the newer pin kept", got)
		}
	})

	t.Run("a purged users document is never recreated", func(t *testing.T) {
		if _, err := client.Collection("users").Doc("gone-1").Get(context.Background()); err == nil {
			t.Fatal("setup: gone-1 exists")
		}
		ctx, counter := budget.WithCounter(context.Background())
		cleared, err := repo.ClearIfPinned(ctx, "gone-1", itPin)
		if err != nil || cleared {
			t.Fatalf("ClearIfPinned = %v, %v", cleared, err)
		}
		if counter.Writes() != 0 {
			t.Errorf("writes = %d, want 0", counter.Writes())
		}
		if snap, err := client.Collection("users").Doc("gone-1").Get(context.Background()); err == nil {
			t.Errorf("users/gone-1 was recreated: %v", snap.Data())
		}
	})

	t.Run("an empty post id never clears anything", func(t *testing.T) {
		ctx, counter := budget.WithCounter(context.Background())
		cleared, err := repo.ClearIfPinned(ctx, itUID, "")
		if err != nil || cleared || counter.Writes() != 0 {
			t.Fatalf("ClearIfPinned = %v, %v (writes %d)", cleared, err, counter.Writes())
		}
	})
}
