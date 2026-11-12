//go:build integration

package identity_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// L-4: an UpdateProfile that changes nothing writes nothing on the real repo (it used to rewrite the whole
// users document every time). The first save and any later real change still write.
func TestUpdateProfile_Integration_NoOpSaveWritesNothing(t *testing.T) {
	client, svc, _ := newExtrasService(t, flags.On)
	bio, loc, site, pin := "hello", "Pune", "https://example.com", itPin
	full := identity.UpdateProfileParams{
		IdempotencyKey: validKeyForIntegration, Bio: &bio, Location: &loc, Website: &site, PinnedPostID: &pin,
	}

	save := func(name string, p identity.UpdateProfileParams) map[string]any {
		t.Helper()
		if _, err := svc.UpdateProfile(context.Background(), itUID, p); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return userData(t, client, itUID)
	}

	first := save("first save (everything new)", full)

	// The same values again: the document is not touched.
	again := save("identical save", full)
	if !reflect.DeepEqual(first, again) {
		t.Errorf("an identical save changed the document:\n before %v\n after  %v", first, again)
	}

	// Text-only identical fields, and an empty request leave it alone.
	textOnly := identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &bio, Location: &loc, Website: &site}
	if got := save("identical text fields", textOnly); !reflect.DeepEqual(first, got) {
		t.Errorf("identical text fields changed the document: %v", got)
	}
	if got := save("empty request", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration}); !reflect.DeepEqual(first, got) {
		t.Errorf("an empty request changed the document: %v", got)
	}

	// A real change after the no-ops writes once and moves updatedAt.
	newBio := "changed"
	after := save("real change", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &newBio})
	if after["bio"] != newBio {
		t.Errorf("bio = %v, want %q", after["bio"], newBio)
	}
	if reflect.DeepEqual(first["updatedAt"], after["updatedAt"]) {
		t.Errorf("a real change did not move updatedAt (%v)", after["updatedAt"])
	}
	for _, field := range []string{"pinnedPostId", "location", "website"} {
		if after[field] != first[field] {
			t.Errorf("a bio edit changed %s: %v -> %v", field, first[field], after[field])
		}
	}
}
