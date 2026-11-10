// beacons_wiring.go adapts beacons.Events to notifications.Emitter (docs/beacons-plan.md PR 5): the composition root
// is the one place that knows both the beacon seam and the notification types, like messaging_wiring.go.
package apiserver

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
)

// beaconNotifier implements beacons.Events: a join request notifies the organiser, an acceptance the requester, a
// cancellation and a change of start, duration or cost every accepted participant. beacons calls it only after a commit that wrote, except Cancelled, which the
// cancellation outbox also re-runs (sweep or replay); the deterministic row id makes that repeat a no-op per recipient.
type beaconNotifier struct{ slot *emitterSlot }

var _ beacons.Events = beaconNotifier{}

func (n beaconNotifier) JoinRequested(ctx context.Context, e beacons.ParticipationEvent) {
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeBeaconRequest, ActorID: e.ParticipantUID, RecipientIDs: []string{e.OrganiserUID}, BeaconID: e.BeaconID, At: e.At,
	})
}

func (n beaconNotifier) RequestAccepted(ctx context.Context, e beacons.ParticipationEvent) {
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeBeaconAccepted, ActorID: e.OrganiserUID, RecipientIDs: []string{e.ParticipantUID}, BeaconID: e.BeaconID, At: e.At,
	})
}

// Cancelled splits the accepted participants into events of at most notifications.MaxRecipientsPerEvent (R24): the
// emitter truncates a longer list silently and a beacon seats up to 20. Nobody accepted means no event. The type is
// exempt from the per-actor daily recipient cap (notifications.capExempt, B07), so no chunk is dropped for budget.
// Every chunk is emitted even when an earlier one failed; the error joins the failures, so the cancellation outbox
// item stays and a later run emits every chunk again. That re-run is harmless for the chunks that did go out: the row
// id is beacon_cancelled_<beacon> in each recipient's subtree, so the fan-out answers AlreadyExists (no second row and
// no second push).
func (n beaconNotifier) Cancelled(ctx context.Context, e beacons.CancelEvent) error {
	return n.chunked(ctx, notifications.TypeBeaconCancelled, e.BeaconID, e.OrganiserUID, e.ParticipantUIDs, e.At)
}

// Updated (F28) is Cancelled's shape for a change of start, duration or cost: chunks of at most MaxRecipientsPerEvent,
// cap-exempt like the cancellation. The row id is beacon_updated_<beacon>_<edit millis>, so a redelivered chunk is
// AlreadyExists while a later edit is a new row.
func (n beaconNotifier) Updated(ctx context.Context, e beacons.UpdateEvent) error {
	return n.chunked(ctx, notifications.TypeBeaconUpdated, e.BeaconID, e.OrganiserUID, e.ParticipantUIDs, e.At)
}

func (n beaconNotifier) chunked(ctx context.Context, t notifications.Type, beaconID, organiser string, uids []string, at time.Time) error {
	var errs []error
	for start := 0; start < len(uids); start += notifications.MaxRecipientsPerEvent {
		end := min(start+notifications.MaxRecipientsPerEvent, len(uids))
		if err := n.slot.emitErr(ctx, notifications.Event{
			Type: t, ActorID: organiser, RecipientIDs: slices.Clone(uids[start:end]), BeaconID: beaconID, At: at,
		}); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
