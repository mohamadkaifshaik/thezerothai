//go:build integration

package identity_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// The baseline is written with the new users document, read back with it, and survives a whole-document rewrite.
// Provider ids contain a dot ("google.com"), so this also proves they are safe as Firestore map keys.
func TestCreateProfile_Integration_AuthBaseline(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	ctx := context.Background()
	now := time.Now().UTC()
	// Only federated subjects are baselined; provider ids contain a dot, which this also exercises as a map key.
	want := &identity.AuthBaseline{
		Subjects: map[string][]string{"google.com": {"hash-g"}, "apple.com": {"hash-a"}},
	}

	if _, _, err := repo.CreateProfile(ctx, "uid-ab", "Ann", "ann", "Ann", now, func(context.Context) (*identity.AuthBaseline, error) { return want, nil }); err != nil {
		t.Fatal(err)
	}
	snap, err := client.Doc("users/uid-ab").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var raw struct {
		AuthBaseline identity.AuthBaseline `firestore:"authBaseline"`
	}
	if err := snap.DataTo(&raw); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(&raw.AuthBaseline, want) {
		t.Fatalf("stored baseline = %+v, want %+v", raw.AuthBaseline, want)
	}

	p, err := repo.GetProfile(ctx, "uid-ab")
	if err != nil || p.AuthBaselineEnc == "" {
		t.Fatalf("GetProfile baseline = %q err = %v", p.AuthBaselineEnc, err)
	}
	updated, err := repo.UpdateProfile(ctx, "uid-ab", func(p *identity.Profile) { p.Bio = "hello" })
	if err != nil {
		t.Fatal(err)
	}
	if updated.AuthBaselineEnc != p.AuthBaselineEnc {
		t.Fatalf("baseline changed by a profile rewrite: %q vs %q", updated.AuthBaselineEnc, p.AuthBaselineEnc)
	}
	again, err := repo.GetProfile(ctx, "uid-ab")
	if err != nil || again.AuthBaselineEnc != p.AuthBaselineEnc {
		t.Fatalf("baseline after rewrite = %q err = %v", again.AuthBaselineEnc, err)
	}

	// A password-only account has an EMPTY-but-present baseline (no federated subjects). This is the headline
	// attack's victim: a later federated link must read back as "known baseline, no subjects" so the sign-in warns,
	// which only holds if the empty map survives the Firestore round trip (not collapsed to an absent field / nil).
	empty := &identity.AuthBaseline{}
	if _, _, err := repo.CreateProfile(ctx, "uid-eb", "Em", "em", "Em", now, func(context.Context) (*identity.AuthBaseline, error) { return empty, nil }); err != nil {
		t.Fatal(err)
	}
	eb, err := repo.GetProfile(ctx, "uid-eb")
	if err != nil || eb.AuthBaselineEnc == "" {
		t.Fatalf("empty baseline must read back present, got %q err = %v", eb.AuthBaselineEnc, err)
	}
	ebUpdated, err := repo.UpdateProfile(ctx, "uid-eb", func(p *identity.Profile) { p.Bio = "hi" })
	if err != nil || ebUpdated.AuthBaselineEnc == "" {
		t.Fatalf("empty baseline lost on rewrite: %q err = %v", ebUpdated.AuthBaselineEnc, err)
	}

	// No authorize (or a nil baseline) stores no field at all.
	if _, _, err := repo.CreateProfile(ctx, "uid-nb", "Bo", "bo", "Bo", now, nil); err != nil {
		t.Fatal(err)
	}
	nb, err := repo.GetProfile(ctx, "uid-nb")
	if err != nil || nb.AuthBaselineEnc != "" {
		t.Fatalf("no-baseline profile = %q err = %v", nb.AuthBaselineEnc, err)
	}
	snap2, err := client.Doc("users/uid-nb").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, present := snap2.Data()["authBaseline"]; present {
		t.Error("authBaseline field must be absent when there is no baseline")
	}
}
