package identity

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-22 L-4: an UpdateProfile call that changes nothing must not rewrite users/{uid}. The service leaves UpdatedAt
// alone when no field really changed and the repo skips the write; the integration test pins the Firestore numbers
// (1 read, 0 writes). Over fakeRepo, which mirrors the repo's skip, a no-op is 0 writes and an unchanged UpdatedAt.

func boolp(b bool) *bool { return &b }

func TestUpdateProfile_NoOpWritesNothing(t *testing.T) {
	t1 := time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Hour)

	tests := []struct {
		name       string
		again      UpdateProfileParams // the second call; the first call (seed) stores bio, location, website, banner, pin
		wantWrites int                 // writes the second call made
	}{
		{"empty request", UpdateProfileParams{}, 0},
		{"same bio", UpdateProfileParams{Bio: strp("hello")}, 0},
		{"same bio with surrounding spaces", UpdateProfileParams{Bio: strp("  hello  ")}, 0},
		{"same display name", UpdateProfileParams{DisplayName: strp("Alice A.")}, 0},
		{"same location", UpdateProfileParams{Location: strp("Pune")}, 0},
		{"same website", UpdateProfileParams{Website: strp("https://example.com")}, 0},
		{"same banner", UpdateProfileParams{BannerMediaID: strp("0000000000000000202")}, 0},
		{"same pin", UpdateProfileParams{PinnedPostID: strp(pinID)}, 0},
		{"clearing an avatar that is not set", UpdateProfileParams{AvatarMediaID: strp("")}, 0},
		{"is_private=false on a public account", UpdateProfileParams{IsPrivate: boolp(false)}, 0},
		{"every field again, all identical", UpdateProfileParams{
			DisplayName: strp("Alice A."), Bio: strp("hello"), Location: strp("Pune"), Website: strp("https://example.com"),
			BannerMediaID: strp("0000000000000000202"), PinnedPostID: strp(pinID), IsPrivate: boolp(false), AvatarMediaID: strp(""),
		}, 0},
		{"new bio", UpdateProfileParams{Bio: strp("changed")}, 1},
		{"new display name", UpdateProfileParams{DisplayName: strp("Alice B.")}, 1},
		{"new location", UpdateProfileParams{Location: strp("Delhi")}, 1},
		{"location cleared", UpdateProfileParams{Location: strp("")}, 1},
		{"website cleared", UpdateProfileParams{Website: strp("")}, 1},
		{"banner removed", UpdateProfileParams{BannerMediaID: strp("")}, 1},
		{"pin changed", UpdateProfileParams{PinnedPostID: strp(otherPinID)}, 1},
		{"one new field among identical ones", UpdateProfileParams{Bio: strp("hello"), Location: strp("Pune"), Website: strp("https://example.org")}, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.On))
			clock := t1
			e.svc.now = func() time.Time { return clock }
			seed := UpdateProfileParams{
				Bio: strp("hello"), Location: strp("Pune"), Website: strp("https://example.com"),
				BannerMediaID: strp("0000000000000000202"), PinnedPostID: strp(pinID),
			}
			if _, err := e.update(context.Background(), seed); err != nil {
				t.Fatalf("seed: %v", err)
			}
			seeded := e.repo.profiles[extrasUID]
			if !seeded.UpdatedAt.Equal(t1) {
				t.Fatalf("seed UpdatedAt = %v, want %v", seeded.UpdatedAt, t1)
			}
			writesBefore := e.repo.updateWrites

			clock = t2
			got, err := e.update(context.Background(), tt.again)
			if err != nil {
				t.Fatalf("UpdateProfile: %v", err)
			}
			if w := e.repo.updateWrites - writesBefore; w != tt.wantWrites {
				t.Errorf("writes = %d, want %d", w, tt.wantWrites)
			}
			stored := e.repo.profiles[extrasUID]
			switch tt.wantWrites {
			case 0:
				if stored != seeded || got.UpdatedAt.Equal(t2) {
					t.Errorf("a no-op moved the profile: stored %+v, seeded %+v, response UpdatedAt %v", stored, seeded, got.UpdatedAt)
				}
			default:
				if !stored.UpdatedAt.Equal(t2) {
					t.Errorf("a real change left UpdatedAt = %v, want %v", stored.UpdatedAt, t2)
				}
			}
		})
	}
}
