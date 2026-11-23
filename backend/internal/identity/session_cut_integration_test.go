//go:build integration

package identity_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestSessionCut_Integration: the session cut on users/{uid} keeps the maximum (an earlier time writes nothing), survives
// a whole-document rewrite (UpdateProfile), never re-creates a missing document, and opsctl's ClearSessionCut removes the
// field (a repeat writes nothing).
func TestSessionCut_Integration(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	sfx := fmt.Sprintf("%d", time.Now().UnixNano())
	uid := "uid-cut-" + sfx
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, _, err := repo.CreateProfile(ctx, uid, "cut"+sfx[len(sfx)-8:], "cut"+sfx[len(sfx)-8:], "Cut", "", now, nil); err != nil {
		t.Fatal(err)
	}
	t1 := now.Add(time.Minute).Truncate(time.Second)
	stored := func() *time.Time {
		t.Helper()
		snap, err := client.Collection("users").Doc(uid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		v, err := snap.DataAt("sessionsValidAfter")
		if err != nil {
			return nil // absent
		}
		tv := v.(time.Time)
		return &tv
	}
	if stored() != nil {
		t.Fatal("a new profile must carry no cut")
	}

	p, wrote, err := repo.EndSessionsBefore(ctx, uid, t1)
	if err != nil || !wrote || !p.SessionsValidAfter.Equal(t1) {
		t.Fatalf("first cut = %v, wrote %v, %v; want %v, true", p.SessionsValidAfter, wrote, err, t1)
	}
	if _, wrote, err := repo.EndSessionsBefore(ctx, uid, t1.Add(-time.Hour)); err != nil || wrote {
		t.Errorf("an earlier cut wrote %v (%v), want nothing", wrote, err)
	}
	if got := stored(); got == nil || !got.Equal(t1) {
		t.Errorf("stored cut = %v, want %v", got, t1)
	}

	// A whole-document rewrite keeps it.
	if _, err := repo.UpdateProfile(ctx, uid, func(p *identity.Profile) { p.Bio = "kept" }); err != nil {
		t.Fatal(err)
	}
	if got := stored(); got == nil || !got.Equal(t1) {
		t.Errorf("after UpdateProfile the cut = %v, want %v", got, t1)
	}
	if got, err := repo.GetProfile(ctx, uid); err != nil || !got.SessionsValidAfter.Equal(t1) {
		t.Errorf("GetProfile cut = %v, %v; want %v", got.SessionsValidAfter, err, t1)
	}

	cleared, err := repo.ClearSessionCut(ctx, uid)
	if err != nil || !cleared.Equal(t1) {
		t.Fatalf("ClearSessionCut = %v, %v; want %v", cleared, err, t1)
	}
	if stored() != nil {
		t.Error("the field must be gone after ClearSessionCut")
	}
	if cleared, err := repo.ClearSessionCut(ctx, uid); err != nil || !cleared.IsZero() {
		t.Errorf("a repeat = %v, %v; want zero (nothing written)", cleared, err)
	}

	missing := "uid-cut-missing-" + sfx
	if _, _, err := repo.EndSessionsBefore(ctx, missing, t1); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("missing document = %v, want ErrNotFound", err)
	}
	if _, err := repo.ClearSessionCut(ctx, missing); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("clear on a missing document = %v, want ErrNotFound", err)
	}
	if _, err := client.Collection("users").Doc(missing).Get(ctx); err == nil {
		t.Error("the missing document was created")
	}
}
