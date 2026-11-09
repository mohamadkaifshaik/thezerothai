// beacons_wiring.go adapts beacons.Events to notifications.Emitter (docs/beacons-plan.md PR 5): the composition root
// is the one place that knows both the beacon seam and the notification types, like messaging_wiring.go.
package apiserver

import (
	"context"
	"errors"
	"slices"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
)

// beaconNotifier implements beacons.Events: a join request notifies the organiser, an acceptance the requester, a
// cancellation every accepted participant. beacons calls it only after a commit that wrote, except Cancelled, which the
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
	var errs []error
	for start := 0; start < len(e.ParticipantUIDs); start += notifications.MaxRecipientsPerEvent {
		end := min(start+notifications.MaxRecipientsPerEvent, len(e.ParticipantUIDs))
		if err := n.slot.emitErr(ctx, notifications.Event{
			Type: notifications.TypeBeaconCancelled, ActorID: e.OrganiserUID, RecipientIDs: slices.Clone(e.ParticipantUIDs[start:end]),
			BeaconID: e.BeaconID, At: e.At,
		}); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
