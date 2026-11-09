package beacons

// cancel_outbox.go makes a cancellation's notices durable (B07). CancelBeacon's transaction stages one outbox item
// (kind CancelOutboxKind, key = the beacon id, uid = the organiser) next to the status write, only when someone was
// accepted; after the commit DeliverCancelNotices runs inline and Done removes the item once every chunk was handed
// off. A lost hand-off, a crash between commit and delivery, or a failed Done leaves the item, and the outbox sweep
// (apiserver) runs DeliverCancelNotices again for it. A replayed (or already-cancelled) CancelBeacon re-runs a still
// present item at once (RunNow).
//
// Re-runs never duplicate a notice: the notifications row id is deterministic (beacon_cancelled_<beaconId> in each
// recipient's own subtree, notifications.notificationID), so a second hand-off of a participant is AlreadyExists in
// the fan-out: no second row and no second push. The payload holds no participant uid: the accepted list is read
// again at run time (stable after the cancel: Leave and Remove refuse a cancelled beacon), so the item, purged by the
// organiser's uid, never outlives a participant's own account deletion.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// CancelOutboxKind is the outbox kind of a cancellation whose notices are not yet all handed off.
const CancelOutboxKind = "beacon_cancelled"

// CancelOutbox makes the cancellation notices durable (*outbox.Outbox implements it).
type CancelOutbox interface {
	Stage(b store.Batch, e outbox.Entry) error
	Done(ctx context.Context, e outbox.Entry) error
	RunNow(ctx context.Context, e outbox.Entry) (found bool, err error)
}

// CancelWork is the outbox payload: which beacon was cancelled, by whom, when. Never a participant uid.
type CancelWork struct {
	BeaconID     string `json:"beaconId"`
	OrganiserUID string `json:"organiserUid"`
	AtMillis     int64  `json:"atMillis"`
}

func (w CancelWork) validate() error {
	if !ids.ValidBeaconID(w.BeaconID) || !ids.ValidUID(w.OrganiserUID) {
		return errors.New("beacons: cancel work: invalid beacon id or organiser uid")
	}
	return nil
}

// CancelEntry builds the outbox entry of a cancellation (deterministic id beacon_cancelled:<beaconId>).
func CancelEntry(beaconID, organiserUID string, at time.Time) (outbox.Entry, error) {
	w := CancelWork{BeaconID: beaconID, OrganiserUID: organiserUID, AtMillis: at.UnixMilli()}
	if err := w.validate(); err != nil {
		return outbox.Entry{}, err
	}
	data, err := json.Marshal(w)
	if err != nil {
		return outbox.Entry{}, fmt.Errorf("beacons: encode cancel work: %w", err)
	}
	e := outbox.Entry{Kind: CancelOutboxKind, Key: beaconID, UID: organiserUID, Payload: data}
	return e, e.Validate()
}

// DecodeCancelWork parses and validates an outbox payload written by CancelEntry.
func DecodeCancelWork(data []byte) (CancelWork, error) {
	var w CancelWork
	if err := json.Unmarshal(data, &w); err != nil {
		return w, fmt.Errorf("beacons: decode cancel work: %w", err)
	}
	return w, w.validate()
}

// ParticipantLister is the one Repo read DeliverCancelNotices needs.
type ParticipantLister interface {
	ListParticipants(ctx context.Context, q ParticipantQuery) ([]Participant, error)
}

// cancelReadAttempts bounds the accepted-list reads one DeliverCancelNotices makes before giving up (B07).
const cancelReadAttempts = 3

// ErrCancelNoticesDeferred wraps every DeliverCancelNotices failure: the notices were not all handed off and the run must
// be repeated (the outbox item stays).
var ErrCancelNoticesDeferred = errors.New("beacons: cancellation notices deferred")

// DeliverCancelNotices hands the cancellation w to events with the participants accepted now: one ListParticipants read
// (bounded by maxOpenSpots), retried up to cancelReadAttempts times while ctx is live; nobody accepted means no event.
// Its error (wrapping ErrCancelNoticesDeferred) means a run must be repeated. It is idempotent per participant (the
// notification row id is deterministic), so the inline attempt and any number of sweeps may all run it.
func DeliverCancelNotices(ctx context.Context, repo ParticipantLister, events Events, maxOpenSpots int, w CancelWork) error {
	if events == nil {
		return nil
	}
	q := ParticipantQuery{BeaconID: w.BeaconID, State: PStateAccepted, Limit: maxOpenSpots}
	var rows []Participant
	var err error
	attempts := 0
	for attempts < cancelReadAttempts {
		attempts++
		if rows, err = repo.ListParticipants(ctx, q); err == nil || ctx.Err() != nil {
			break
		}
	}
	if err != nil {
		slog.WarnContext(ctx, "beacon_cancel_participants_failed", "beacon_hash", logger.HashUID(w.BeaconID), "attempts", attempts,
			"err", logger.RedactErr(err, w.BeaconID, w.OrganiserUID).Error())
		return fmt.Errorf("%w: accepted list: %w", ErrCancelNoticesDeferred, logger.RedactErr(err, w.BeaconID, w.OrganiserUID))
	}
	if len(rows) == 0 {
		return nil
	}
	uids := make([]string, 0, len(rows))
	for _, p := range rows {
		uids = append(uids, p.UID)
	}
	if err := events.Cancelled(ctx, CancelEvent{BeaconID: w.BeaconID, OrganiserUID: w.OrganiserUID, ParticipantUIDs: uids, At: time.UnixMilli(w.AtMillis).UTC()}); err != nil {
		return fmt.Errorf("%w: hand-off: %w", ErrCancelNoticesDeferred, logger.RedactErr(err, append([]string{w.BeaconID, w.OrganiserUID}, uids...)...))
	}
	return nil
}

// NewCancelOutboxHandler is the outbox handler of CancelOutboxKind (registered by apiserver): it decodes the item and
// runs DeliverCancelNotices. A payload no retry can fix is logged and dropped (nil); a failed run keeps the item for the
// next backoff step. Idempotent per participant, like every run of DeliverCancelNotices.
func NewCancelOutboxHandler(repo ParticipantLister, events Events, maxOpenSpots int) outbox.Handler {
	return func(ctx context.Context, it outbox.Item) error {
		w, err := DecodeCancelWork(it.Payload)
		if err != nil {
			slog.WarnContext(ctx, "outbox_item_dropped", "kind", it.Kind, "reason", "malformed_payload", "uid_hash", logger.HashUID(it.UID))
			return nil
		}
		return DeliverCancelNotices(ctx, repo, events, maxOpenSpots, w)
	}
}
