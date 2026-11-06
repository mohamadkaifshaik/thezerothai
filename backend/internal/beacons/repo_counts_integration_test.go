//go:build integration

package beacons

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// TestRepo_Counts (PR 8 R44): Stats.Counts answers the five aggregate counts over beacons/ (open, full, cancelled,
// hidden, ended) from count aggregations, reads no document, and a hidden OPEN beacon is in both beacons_open and
// beacons_hidden (independent counters). A second call answers the same (nothing written).
func TestRepo_Counts(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	start := e.now.Add(time.Hour)
	var open []string
	for i, uid := range []string{"org-c1", "org-c1", "org-c2", "org-c2"} {
		open = append(open, e.create(t, uid, itKeyA+string(rune('a'+i)), e.beaconAt(uid, "", start)).Beacon.ID)
	}
	// One beacon with a single spot fills on the first accept.
	one := e.beaconAt("org-c3", "", start)
	one.OpenSpots = 1
	full := e.create(t, "org-c3", itKeyA, one).Beacon.ID
	e.mustRequest(t, "guest-c1", itKeyB, full)
	if res, err := e.respond("org-c3", itKeyB, full, "guest-c1", true, e.now); err != nil || res.Beacon.Status != StatusFull {
		t.Fatalf("accept into the one-spot beacon: %+v, %v", res, err)
	}
	for i, uid := range []string{"org-c4", "org-c5"} {
		id := e.create(t, uid, itKeyA, e.beaconAt(uid, "", start)).Beacon.ID
		res, err := e.repo.Cancel(ctx, CancelParams{
			UID: uid, BeaconID: id, IdemKey: idempotency.Key(uid, rpcCancelBeacon, itKeyB+string(rune('a'+i))),
			RequestHash: idempotency.HashRequest(id), Now: e.now,
		})
		if err != nil || res.Beacon.Status != StatusCancelled {
			t.Fatalf("cancel %s: %+v, %v", uid, res, err)
		}
	}
	var m Moderator = e.repo
	if changed, err := m.SetHidden(ctx, open[0], true, e.now); err != nil || !changed {
		t.Fatalf("hide: %v, %v", changed, err)
	}
	// Two plans whose end has passed at the repo clock: one still stored OPEN (ENDED is derived, never written) and
	// one cancelled. Both are in beacons_ended; the OPEN one is still in beacons_open (Review Focus 2: counters are
	// independent and documented as such).
	for i, uid := range []string{"org-c6", "org-c7"} {
		id := e.create(t, uid, itKeyA, e.beaconAt(uid, "", e.now.Add(-2*time.Hour))).Beacon.ID
		if i == 1 {
			res, err := e.repo.Cancel(ctx, CancelParams{
				UID: uid, BeaconID: id, IdemKey: idempotency.Key(uid, rpcCancelBeacon, itKeyB), RequestHash: idempotency.HashRequest(id),
				Now: e.now.Add(-3 * time.Hour), // before its end, so the cancel is not refused as ended
			})
			if err != nil || res.Beacon.Status != StatusCancelled {
				t.Fatalf("cancel the past plan: %+v, %v", res, err)
			}
		}
	}

	var s Stats = e.repo
	want := Counts{Open: 5, Full: 1, Cancelled: 3, Hidden: 1, Ended: 2}
	for _, call := range []string{"first", "second"} {
		got, err := s.Counts(ctx)
		if err != nil {
			t.Fatalf("%s Counts: %v", call, err)
		}
		if got != want {
			t.Fatalf("%s Counts = %+v, want %+v", call, got, want)
		}
	}
}
