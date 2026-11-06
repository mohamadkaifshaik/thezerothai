//go:build integration

package beacons

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestRepo_SetHiddenIsIdempotentAndFieldLevel (Review Focus 5): hide writes `hidden` and `updatedAt` once, a repeat
// writes nothing, restore removes the field (absent means false) and nothing else on the document moves.
func TestRepo_SetHiddenIsIdempotentAndFieldLevel(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-h1", itKeyA, e.beaconAt("org-h1", "", e.now.Add(time.Hour))).Beacon
	var m Moderator = e.repo

	changed, err := m.SetHidden(ctx, b.ID, true, e.now.Add(time.Minute))
	if err != nil || !changed {
		t.Fatalf("hide = %v, %v, want changed", changed, err)
	}
	got, err := m.Get(ctx, b.ID)
	if err != nil || !got.Hidden || !got.UpdatedAt.Equal(e.now.Add(time.Minute)) || got.Title != "Coffee" {
		t.Fatalf("after hide = %+v, %v", got, err)
	}
	snap, _ := e.client.Collection(beaconsCollection).Doc(b.ID).Get(ctx)
	if snap.Data()["hidden"] != true {
		t.Fatalf("hidden field = %v, want true", snap.Data()["hidden"])
	}

	changed, err = m.SetHidden(ctx, b.ID, true, e.now.Add(2*time.Minute))
	if err != nil || changed {
		t.Fatalf("hide again = %v, %v, want unchanged", changed, err)
	}
	if got, _ := m.Get(ctx, b.ID); !got.UpdatedAt.Equal(e.now.Add(time.Minute)) {
		t.Fatalf("a no-op hide moved updatedAt to %v", got.UpdatedAt)
	}

	changed, err = m.SetHidden(ctx, b.ID, false, e.now.Add(3*time.Minute))
	if err != nil || !changed {
		t.Fatalf("restore = %v, %v, want changed", changed, err)
	}
	snap, _ = e.client.Collection(beaconsCollection).Doc(b.ID).Get(ctx)
	if _, present := snap.Data()["hidden"]; present {
		t.Fatal("restore left the hidden field in the document (absent means false)")
	}
	if got, _ := m.Get(ctx, b.ID); got.Hidden || got.Status != StatusOpen || got.OpenSpots != 3 {
		t.Fatalf("after restore = %+v", got)
	}
	if changed, err := m.SetHidden(ctx, b.ID, false, e.now.Add(4*time.Minute)); err != nil || changed {
		t.Fatalf("restore again = %v, %v, want unchanged", changed, err)
	}
	if _, err := m.SetHidden(ctx, e.node.Generate(), true, e.now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing beacon = %v, want ErrNotFound", err)
	}
}
