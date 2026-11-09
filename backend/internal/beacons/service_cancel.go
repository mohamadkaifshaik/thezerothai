package beacons

import (
	"context"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fieldCancelRetrigger is the request-line field of a replayed or no-op cancel: what it did with a still-present
// cancellation outbox item (none, ran or failed).
const fieldCancelRetrigger = "cancel_retrigger"

// CancelBeacon implements Service: validation, visibility and organiser, then one transaction. With the outbox wired the
// transaction also stages the cancellation's notice item (only when someone was accepted); after a Written commit the
// notices run inline and the item is removed once all were handed off. A Replayed or Unchanged cancel re-runs a still
// present item (a client retrying a cancel whose notices were lost gets them now, never twice).
func (s *service) CancelBeacon(ctx context.Context, uid, key, beaconID string) error {
	begin(ctx, "cancel")
	if err := validateKey(key); err != nil {
		return mapErr(ctx, "cancel", uid, beaconID, err)
	}
	if err := validateBeaconID(beaconID); err != nil {
		return mapErr(ctx, "cancel", uid, beaconID, err)
	}
	if _, err := s.organised(ctx, uid, beaconID); err != nil {
		return mapErr(ctx, "cancel", uid, beaconID, err)
	}
	now := s.now()
	params := CancelParams{
		UID: uid, BeaconID: beaconID, IdemKey: idempotency.Key(uid, rpcCancelBeacon, key), RequestHash: cancelHash(beaconID), Now: now,
	}
	entry, durable := s.cancelEntry(ctx, uid, beaconID, now)
	var staged bool
	var stageErr error
	if durable {
		params.Stage = func(b store.Batch, before Beacon) {
			staged, stageErr = before.AcceptedCount > 0, nil
			if staged {
				stageErr = s.d.Outbox.Stage(b, entry)
			}
		}
	}
	res, err := s.d.Repo.Cancel(ctx, params)
	if err != nil {
		return mapErr(ctx, "cancel", uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	switch res.Outcome {
	case Written:
		if stageErr != nil {
			// Unreachable (the entry was validated and Stage's only error is validation); logged, never silent.
			slog.ErrorContext(ctx, "beacon_cancel_outbox_stage_failed", "beacon_hash", logger.HashUID(beaconID),
				"err", logger.RedactErr(stageErr, beaconID, uid).Error())
			staged = false
		}
		s.notifyCancelled(ctx, beaconID, res, now, entry, durable && staged)
	case Replayed, Unchanged:
		if durable {
			s.retriggerCancel(ctx, beaconID, uid, entry)
		}
	}
	return nil
}

// cancelEntry is the outbox entry of uid's cancellation of beaconID, and whether CancelBeacon stages one (only when both
// the outbox and the Events seam are wired: an item nobody can deliver would only wait for its TTL).
func (s *service) cancelEntry(ctx context.Context, uid, beaconID string, now time.Time) (outbox.Entry, bool) {
	if s.d.Outbox == nil || s.d.Events == nil {
		return outbox.Entry{}, false
	}
	e, err := CancelEntry(beaconID, uid, now)
	if err != nil {
		// Never fails the cancel: it falls back to the best-effort notice.
		slog.ErrorContext(ctx, "beacon_cancel_outbox_entry_invalid", "beacon_hash", logger.HashUID(beaconID))
		return outbox.Entry{}, false
	}
	return e, true
}

// notifyCancelled hands a cancel that wrote to the Events seam with the participants accepted at that moment (R23),
// skipped when nobody was accepted (DeliverCancelNotices: one bounded, retried accepted-list read). The cancel already
// committed, so a failure never fails the RPC: durable (the item was staged) it stays for the outbox sweep; otherwise
// the notice is lost and logged. A durable success removes the item.
func (s *service) notifyCancelled(ctx context.Context, beaconID string, res CancelResult, now time.Time, entry outbox.Entry, durable bool) {
	if s.d.Events == nil || res.Beacon.AcceptedCount <= 0 {
		return
	}
	w := CancelWork{BeaconID: beaconID, OrganiserUID: res.Beacon.OrganiserID, AtMillis: now.UnixMilli()}
	if err := DeliverCancelNotices(ctx, s.d.Repo, s.d.Events, s.d.Limits.MaxOpenSpots, w); err != nil {
		msg := "beacon_cancel_notices_failed"
		if durable {
			msg = "beacon_cancel_notices_deferred" // the outbox item stays; the sweep delivers it
		}
		slog.WarnContext(ctx, msg, "beacon_hash", logger.HashUID(beaconID), "err", err.Error())
		return
	}
	if !durable {
		return
	}
	if err := s.d.Outbox.Done(ctx, entry); err != nil {
		// Every notice was handed off; a sweep hands them off again, which the deterministic row id makes a no-op.
		slog.WarnContext(ctx, "beacon_cancel_outbox_done_failed", "beacon_hash", logger.HashUID(beaconID),
			"err", logger.RedactErr(err, beaconID, res.Beacon.OrganiserID).Error())
	}
}

// retriggerCancel runs a replayed cancel's still-present outbox item now (one read when there is none). A failure leaves
// the item for the sweep and never fails the RPC.
func (s *service) retriggerCancel(ctx context.Context, beaconID, uid string, entry outbox.Entry) {
	found, err := s.d.Outbox.RunNow(ctx, entry)
	logger.SetRequestField(ctx, fieldCancelRetrigger, retriggerOutcome(found, err))
	if err != nil {
		slog.WarnContext(ctx, "beacon_cancel_retrigger_failed", "beacon_hash", logger.HashUID(beaconID),
			"err", logger.RedactErr(err, beaconID, uid).Error())
	}
}

func retriggerOutcome(found bool, err error) string {
	switch {
	case err != nil:
		return "failed"
	case found:
		return "ran"
	}
	return "none"
}
