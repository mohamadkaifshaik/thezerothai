//go:build integration

package identity_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-22 L-4: an UpdateProfile that changes nothing is 1 read and 0 writes on the real repo (it used to rewrite the whole
// users document every time). The first save and any later real change still cost the documented 1 write.
func TestUpdateProfile_Integration_NoOpSaveWritesNothing(t *testing.T) {
	client, svc, _ := newExtrasService(t, flags.On)
	bio, loc, site, banner, pin := "hello", "Pune", "https://example.com", itBannerID, itPin
	full := identity.UpdateProfileParams{
		IdempotencyKey: validKeyForIntegration, Bio: &bio, Location: &loc, Website: &site, BannerMediaID: &banner, PinnedPostID: &pin,
	}

	save := func(name string, p identity.UpdateProfileParams, b budgettest.Budget, exactWrites int64) map[string]any {
		t.Helper()
		ctx, c := budget.WithCounter(context.Background())
		if _, err := svc.UpdateProfile(ctx, itUID, p); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		budgettest.Assert(t, name, c, b)
		if c.Writes() != exactWrites {
			t.Errorf("%s: writes = %d, want exactly %d", name, c.Writes(), exactWrites)
		}
		return userData(t, client, itUID)
	}

	first := save("first save (everything new)", full, budgettest.Budget{Reads: 3, Writes: 1}, 1)

	// The same values again: the resolvers still charge their reads (banner, pin), the document is not touched.
	again := save("identical save", full, budgettest.Budget{Reads: 3}, 0)
	if !reflect.DeepEqual(first, again) {
		t.Errorf("an identical save changed the document:\n before %v\n after  %v", first, again)
	}

	// Text-only identical fields, and an empty request: 1 read, 0 writes.
	textOnly := identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &bio, Location: &loc, Website: &site}
	if got := save("identical text fields", textOnly, budgettest.Budget{Reads: 1}, 0); !reflect.DeepEqual(first, got) {
		t.Errorf("identical text fields changed the document: %v", got)
	}
	if got := save("empty request", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration}, budgettest.Budget{Reads: 1}, 0); !reflect.DeepEqual(first, got) {
		t.Errorf("an empty request changed the document: %v", got)
	}

	// A real change after the no-ops writes once and moves updatedAt.
	newBio := "changed"
	after := save("real change", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &newBio}, budgettest.Budget{Reads: 1, Writes: 1}, 1)
	if after["bio"] != newBio {
		t.Errorf("bio = %v, want %q", after["bio"], newBio)
	}
	if reflect.DeepEqual(first["updatedAt"], after["updatedAt"]) {
		t.Errorf("a real change did not move updatedAt (%v)", after["updatedAt"])
	}
	for _, field := range []string{"pinnedPostId", "bannerUrl", "location", "website"} {
		if after[field] != first[field] {
			t.Errorf("a bio edit changed %s: %v -> %v", field, first[field], after[field])
		}
	}
}
