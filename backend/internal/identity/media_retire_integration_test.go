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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// On the real repo: UpdateProfile hands over a replaced or removed avatar for retirement, and ProfileImageURLs is the
// fresh users/{uid} read the media step checks.

// pickyImages resolves like media.Library would but returns whatever URL the test last set.
type pickyImages struct{ avatar string }

func (p *pickyImages) ResolveAvatar(ctx context.Context, _, _ string) (identity.AvatarRef, error) {
	return identity.AvatarRef{URL: p.avatar, ThumbURL: p.avatar + "_t"}, nil
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

func TestUpdateProfile_Integration_RetireHandOver(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	imgs, rec := &pickyImages{}, &recordingRetirer{}
	reg := flags.NewRegistry(flags.Spec{Name: identity.ProfileExtrasFlag, Mode: flags.On})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour,
		identity.WithAvatarResolver(imgs), identity.WithExtrasFlags(reg),
		identity.WithMediaRetirer(rec, slog.New(slog.NewJSONHandler(io.Discard, nil))))
	setup := context.Background()
	if _, err := svc.CreateProfile(setup, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	str := func(s string) *string { return &s }

	save := func(name string, p identity.UpdateProfileParams) {
		t.Helper()
		p.IdempotencyKey = validKeyForIntegration
		if _, err := svc.UpdateProfile(context.Background(), itUID, p); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}

	// First set: nothing to retire.
	imgs.avatar = "https://m/a1.webp"
	save("first set", identity.UpdateProfileParams{AvatarMediaID: str("a1")})
	if len(rec.calls) != 0 {
		t.Fatalf("a first-time set handed over %+v", rec.calls)
	}

	// Replace the avatar; the old image is handed over.
	imgs.avatar = "https://m/a2.webp"
	before := time.Now()
	save("replace avatar", identity.UpdateProfileParams{AvatarMediaID: str("a2")})
	want := []recordedRetire{
		{image: identity.ProfileImageAvatar, url: "https://m/a1.webp", thumbURL: "https://m/a1.webp_t"},
	}
	if len(rec.calls) != 1 {
		t.Fatalf("hand-overs = %+v, want 1", rec.calls)
	}
	for i, w := range want {
		g := rec.calls[i]
		if g.image != w.image || g.url != w.url || g.thumbURL != w.thumbURL || g.at.Before(before.Add(-time.Second)) || g.at.After(time.Now().Add(time.Second)) {
			t.Errorf("hand-over %d = %+v, want %+v at about now", i, g, w)
		}
	}
	stored := userData(t, client, itUID)
	if stored["avatarUrl"] != "https://m/a2.webp" {
		t.Errorf("stored avatar = %v", stored["avatarUrl"])
	}

	// The same request again changes nothing: the document is not rewritten and nothing is handed over.
	rec.calls = nil
	savedDoc := userData(t, client, itUID)
	save("identical save", identity.UpdateProfileParams{AvatarMediaID: str("a2")})
	if len(rec.calls) != 0 {
		t.Errorf("a no-op save handed over %+v", rec.calls)
	}
	if after := userData(t, client, itUID); !mapsEqualAny(savedDoc, after) {
		t.Errorf("a no-op save rewrote the user document: %v -> %v", savedDoc, after)
	}

	// Removing the avatar: one hand-over of the avatar that is now current.
	save("remove avatar", identity.UpdateProfileParams{AvatarMediaID: str("")})
	if len(rec.calls) != 1 || rec.calls[0].image != identity.ProfileImageAvatar || rec.calls[0].url != "https://m/a2.webp" {
		t.Errorf("hand-overs = %+v, want the second avatar", rec.calls)
	}
}

// TestProfileImageURLs_Integration: a fresh read of users/{uid}; empty fields are omitted; a missing user is not an
// error. It bypasses the identity cache by construction (it is the repo's own read).
func TestProfileImageURLs_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	setup := context.Background()
	if _, err := svc.CreateProfile(setup, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}

	read := func(uid string) ([]string, bool) {
		t.Helper()
		ctx := context.Background()
		urls, found, err := repo.ProfileImageURLs(ctx, uid)
		if err != nil {
			t.Fatalf("ProfileImageURLs(%s): %v", uid, err)
		}
		return urls, found
	}

	if urls, found := read(itUID); !found || len(urls) != 0 {
		t.Errorf("a profile without images = %v, found %v; want none, found", urls, found)
	}
	if _, err := client.Collection("users").Doc(itUID).Update(context.Background(), []firestore.Update{
		{Path: "avatarUrl", Value: "https://m/a.webp"}, {Path: "avatarThumbUrl", Value: "https://m/a_t.webp"},
		// A legacy banner (the removed feature) on the document is not a profile image any more and still decodes.
		{Path: "bannerUrl", Value: "https://m/b.webp"}, {Path: "bannerThumbUrl", Value: ""},
	}); err != nil {
		t.Fatal(err)
	}
	if urls, found := read(itUID); !found || !reflect.DeepEqual(urls, []string{"https://m/a.webp", "https://m/a_t.webp"}) {
		t.Errorf("urls = %v, found %v; want the avatar and its thumbnail only", urls, found)
	}
	if urls, found := read("uid-nobody"); found || len(urls) != 0 {
		t.Errorf("a missing user = %v, found %v; want none, not found, no error", urls, found)
	}
}
