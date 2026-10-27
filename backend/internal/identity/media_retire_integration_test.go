//go:build integration

package identity_test

import (
	"context"
	"io"
	"log/slog"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// ADR-0024 Amendment 1 A4 on the real repo: UpdateProfile's hand-over of a replaced or removed avatar or banner costs
// nothing on the request path (the budgets are the pre-A4 ones, 1 read and 1 write in the transaction plus the
// resolvers' reads), and ProfileImageURLs, the fresh users/{uid} read the media step checks, is 1 read.

// pickyImages resolves like media.Library would (1 read each) but returns whatever URL the test last set.
type pickyImages struct{ avatar, banner string }

func (p *pickyImages) ResolveAvatar(ctx context.Context, _, _ string) (identity.AvatarRef, error) {
	budget.FromContext(ctx).AddReads(1)
	return identity.AvatarRef{URL: p.avatar, ThumbURL: p.avatar + "_t"}, nil
}

func (p *pickyImages) ResolveBanner(ctx context.Context, _, _ string) (identity.BannerRef, error) {
	budget.FromContext(ctx).AddReads(1)
	return identity.BannerRef{URL: p.banner, ThumbURL: p.banner + "_t"}, nil
}

type recordedRetire struct {
	image         identity.ProfileImage
	url, thumbURL string
	at            time.Time
}

type recordingRetirer struct{ calls []recordedRetire }

func (r *recordingRetirer) RetireProfileImage(_ context.Context, _ string, image identity.ProfileImage, oldURL, oldThumbURL string, at time.Time) error {
	r.calls = append(r.calls, recordedRetire{image: image, url: oldURL, thumbURL: oldThumbURL, at: at})
	return nil
}

func TestUpdateProfile_Integration_RetireHandOverCostsNothingExtra(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	imgs, rec := &pickyImages{}, &recordingRetirer{}
	reg := flags.NewRegistry(flags.Spec{Name: identity.ProfileExtrasFlag, Mode: flags.On})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour,
		identity.WithAvatarResolver(imgs), identity.WithBannerResolver(imgs), identity.WithExtrasFlags(reg),
		identity.WithMediaRetirer(rec, slog.New(slog.NewJSONHandler(io.Discard, nil))))
	setup, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(setup, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	str := func(s string) *string { return &s }

	save := func(name string, p identity.UpdateProfileParams, want budgettest.Budget, wantWrites int64) {
		t.Helper()
		p.IdempotencyKey = validKeyForIntegration
		ctx, c := budget.WithCounter(context.Background())
		if _, err := svc.UpdateProfile(ctx, itUID, p); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		budgettest.Assert(t, name, c, want)
		if c.Writes() != wantWrites {
			t.Errorf("%s: writes = %d, want exactly %d", name, c.Writes(), wantWrites)
		}
		if c.Reads() != want.Reads {
			t.Errorf("%s: reads = %d, want exactly %d (the hand-over adds none)", name, c.Reads(), want.Reads)
		}
	}

	// First set of both images: tx read + the two resolvers = 3 reads, 1 write, nothing to retire.
	imgs.avatar, imgs.banner = "https://m/a1.webp", "https://m/b1.webp"
	save("first set", identity.UpdateProfileParams{AvatarMediaID: str("a1"), BannerMediaID: str("b1")}, budgettest.Budget{Reads: 3, Writes: 1}, 1)
	if len(rec.calls) != 0 {
		t.Fatalf("a first-time set handed over %+v", rec.calls)
	}

	// Replace the avatar, remove the banner: tx read + the avatar resolver = 2 reads, 1 write; both old images handed over.
	imgs.avatar = "https://m/a2.webp"
	before := time.Now()
	save("replace avatar, remove banner", identity.UpdateProfileParams{AvatarMediaID: str("a2"), BannerMediaID: str("")}, budgettest.Budget{Reads: 2, Writes: 1}, 1)
	want := []recordedRetire{
		{image: identity.ProfileImageAvatar, url: "https://m/a1.webp", thumbURL: "https://m/a1.webp_t"},
		{image: identity.ProfileImageBanner, url: "https://m/b1.webp", thumbURL: "https://m/b1.webp_t"},
	}
	if len(rec.calls) != 2 {
		t.Fatalf("hand-overs = %+v, want 2", rec.calls)
	}
	for i, w := range want {
		g := rec.calls[i]
		if g.image != w.image || g.url != w.url || g.thumbURL != w.thumbURL || g.at.Before(before.Add(-time.Second)) || g.at.After(time.Now().Add(time.Second)) {
			t.Errorf("hand-over %d = %+v, want %+v at about now", i, g, w)
		}
	}
	stored := userData(t, client, itUID)
	if banner, _ := stored["bannerUrl"].(string); stored["avatarUrl"] != "https://m/a2.webp" || banner != "" {
		t.Errorf("stored images = %v / %v (a removed banner is an absent or empty field)", stored["avatarUrl"], stored["bannerUrl"])
	}

	// The same request again changes nothing: 1 read for the avatar resolver + tx read, 0 writes, nothing handed over.
	rec.calls = nil
	save("identical save", identity.UpdateProfileParams{AvatarMediaID: str("a2"), BannerMediaID: str("")}, budgettest.Budget{Reads: 2}, 0)
	if len(rec.calls) != 0 {
		t.Errorf("a no-op save handed over %+v", rec.calls)
	}

	// Removing the avatar: tx read only, 1 write, one hand-over of the avatar that is now current.
	save("remove avatar", identity.UpdateProfileParams{AvatarMediaID: str("")}, budgettest.Budget{Reads: 1, Writes: 1}, 1)
	if len(rec.calls) != 1 || rec.calls[0].image != identity.ProfileImageAvatar || rec.calls[0].url != "https://m/a2.webp" {
		t.Errorf("hand-overs = %+v, want the second avatar", rec.calls)
	}
}

// TestProfileImageURLs_Integration: one fresh read of users/{uid}; empty fields are omitted; a missing user is not an
// error. It bypasses the identity cache by construction (it is the repo's own read).
func TestProfileImageURLs_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	setup, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(setup, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}

	read := func(uid string) ([]string, bool) {
		t.Helper()
		ctx, c := budget.WithCounter(context.Background())
		urls, found, err := repo.ProfileImageURLs(ctx, uid)
		if err != nil {
			t.Fatalf("ProfileImageURLs(%s): %v", uid, err)
		}
		budgettest.Assert(t, "ProfileImageURLs", c, budgettest.Budget{Reads: 1})
		if c.Reads() != 1 || c.Writes() != 0 {
			t.Errorf("reads=%d writes=%d, want 1 / 0", c.Reads(), c.Writes())
		}
		return urls, found
	}

	if urls, found := read(itUID); !found || len(urls) != 0 {
		t.Errorf("a profile without images = %v, found %v; want none, found", urls, found)
	}
	if _, err := client.Collection("users").Doc(itUID).Update(context.Background(), []firestore.Update{
		{Path: "avatarUrl", Value: "https://m/a.webp"}, {Path: "avatarThumbUrl", Value: "https://m/a_t.webp"},
		{Path: "bannerUrl", Value: "https://m/b.webp"}, {Path: "bannerThumbUrl", Value: ""},
	}); err != nil {
		t.Fatal(err)
	}
	if urls, found := read(itUID); !found || !reflect.DeepEqual(urls, []string{"https://m/a.webp", "https://m/a_t.webp", "https://m/b.webp"}) {
		t.Errorf("urls = %v, found %v; want the three non-empty ones in avatar, thumb, banner order", urls, found)
	}
	if urls, found := read("uid-nobody"); found || len(urls) != 0 {
		t.Errorf("a missing user = %v, found %v; want none, not found, no error", urls, found)
	}
}
