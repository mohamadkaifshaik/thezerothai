package apiserver

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// rowEmitter stands in for the publish + fan-out: it fails the calls whose (1-based) index is in fail, and otherwise
// "creates" users/{recipient}/notifications/beacon_cancelled_{beacon} the way the fan-out does (a second create of the
// same id is AlreadyExists: no second row, no second push).
type rowEmitter struct {
	calls int
	fail  map[int]bool
	rows  map[string]int // recipient/notification id -> rows created
	push  int
}

func (r *rowEmitter) Emit(_ context.Context, e notifications.Event) error {
	r.calls++
	if r.fail[r.calls] {
		return errors.New("pubsub unavailable")
	}
	for _, uid := range e.RecipientIDs {
		k := uid + "/" + string(e.Type) + "_" + e.BeaconID
		if r.rows[k] == 0 {
			r.push++
		}
		r.rows[k] = 1
	}
	return nil
}

// participantList is a beacons.ParticipantLister over a fixed accepted list.
type participantList []beacons.Participant

func (p participantList) ListParticipants(_ context.Context, q beacons.ParticipantQuery) ([]beacons.Participant, error) {
	return p[:min(len(p), q.Limit)], nil
}

// TestBeaconCancelOutbox_ChunkFailureKeepsItemAndRerunIsExactlyOnce: a cancellation whose second chunk of 10 fails to
// publish reports an error (the outbox item stays); the sweep's re-run publishes every chunk again and each accepted
// participant ends with exactly one row and one push.
func TestBeaconCancelOutbox_ChunkFailureKeepsItemAndRerunIsExactlyOnce(t *testing.T) {
	for _, tc := range []struct {
		n    int
		fail map[int]bool
	}{
		{1, map[int]bool{1: true}}, {10, map[int]bool{1: true}}, {11, map[int]bool{2: true}}, {20, map[int]bool{2: true}}, {20, map[int]bool{1: true, 2: true}},
	} {
		t.Run(fmt.Sprintf("%d accepted, fail %v", tc.n, tc.fail), func(t *testing.T) {
			ctx := context.Background()
			rows := make(participantList, tc.n)
			for i := range rows {
				rows[i] = beacons.Participant{UID: fmt.Sprintf("p%02d", i), State: beacons.PStateAccepted}
			}
			em := &rowEmitter{fail: tc.fail, rows: map[string]int{}}
			h := beacons.NewCancelOutboxHandler(rows, beaconNotifier{slot: &emitterSlot{em: em}}, 20)
			entry, err := beacons.CancelEntry(beaconNotifID, "uid-o", time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if err := h(ctx, outbox.Item{Entry: entry}); err == nil {
				t.Fatal("a failed chunk must keep the item (error)")
			}
			for i := 0; i < 2; i++ { // the sweep re-runs it, then a lost Done re-runs it again
				if err := h(ctx, outbox.Item{Entry: entry}); err != nil {
					t.Fatalf("re-run %d: %v", i, err)
				}
			}
			if len(em.rows) != tc.n || em.push != tc.n {
				t.Fatalf("rows %d pushes %d, want %d each", len(em.rows), em.push, tc.n)
			}
		})
	}
}

// TestBeaconNotifier_CancelReportsErrors: Cancelled emits every chunk even when one fails, and reports the failure; an
// empty slot (notifications not wired) is not a failure.
func TestBeaconNotifier_CancelReportsErrors(t *testing.T) {
	uids := make([]string, 20)
	for i := range uids {
		uids[i] = fmt.Sprintf("p%02d", i)
	}
	ev := beacons.CancelEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUIDs: uids}
	em := &rowEmitter{fail: map[int]bool{1: true}, rows: map[string]int{}}
	if err := (beaconNotifier{slot: &emitterSlot{em: em}}).Cancelled(context.Background(), ev); err == nil {
		t.Fatal("want the chunk failure reported")
	}
	if em.calls != 2 || len(em.rows) != 10 {
		t.Fatalf("calls %d rows %d: the second chunk must still be emitted", em.calls, len(em.rows))
	}
	if err := (beaconNotifier{slot: &emitterSlot{}}).Cancelled(context.Background(), ev); err != nil {
		t.Fatalf("empty slot = %v", err)
	}
}
