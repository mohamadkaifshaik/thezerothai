// purge.go is the right-to-delete path of the beacons data (R4). Deleting users/{uid} removes none of beacons/{id}, its
// beaconParticipants docs or users/{uid}/beaconMemberships, so the `beacons` account-deletion step (Eraser, registered
// BeforeIdentity after `communities`) deletes the user's organised beacons with their participant docs, then every
// participant doc the user's membership rows name, then the membership rows. Never flag-gated: documents outlive the flag.
package beacons

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// purgeOrganisedPage is the most organised beacons one eraser call touches; each beacon is its own batch.
	purgeOrganisedPage = 100
	// purgeMembershipPage is the most membership rows one eraser call processes: two deletes each, one batch of <= 500.
	purgeMembershipPage = 250
	// participantsPage is the most participant docs deleted under one beacon per batch: with the beacon and the
	// organiser's membership row that is exactly Firestore's 500-write limit. A beacon with more (every REQUESTED,
	// DECLINED or WITHDRAWN row ever, no per-beacon cap) is deleted across calls: participant pages first, the beacon
	// only once a page comes back short, so no participant doc is left under a deleted parent.
	participantsPage = 498

	phaseOrganised   = ""
	phaseMemberships = "memberships"
)

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// PurgeOrganisedPage works through up to purgeOrganisedPage of uid's organised beacons, one batch per beacon: up to
	// participantsPage of its beaconParticipants docs, and, when that page was short, the beacon and the organiser's own
	// membership row. It reports how many beacons were deleted and whether more work remains (a full page of beacons, or
	// a beacon whose participant docs did not fit one batch and which stays for the next call). Deleted documents leave
	// the next page, so repeating the call is self-resuming. Other users' membership rows pointing at the beacon are
	// left to dangle (they hold no uid, R3).
	PurgeOrganisedPage(ctx context.Context, uid string) (deleted int, more bool, err error)
	// PurgeMembershipPage deletes up to purgeMembershipPage of users/{uid}/beaconMemberships rows and, for each row whose
	// role is not organiser, the beacons/{beaconId}/beaconParticipants/{uid} doc it names, in one batch, and reports how
	// many rows. Deleted rows leave the next page.
	PurgeMembershipPage(ctx context.Context, uid string) (deleted int, err error)
}

var _ PagePurger = (*FirestoreRepo)(nil)

// PurgeOrganisedPage implements PagePurger.
func (r *FirestoreRepo) PurgeOrganisedPage(ctx context.Context, uid string) (int, bool, error) {
	docs, err := r.col().Where("organiserId", "==", uid).Select().Limit(purgeOrganisedPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, false, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: query: %w", logger.HashUID(uid), err), uid)
	}
	deleted, partial := 0, false
	for _, d := range docs {
		parts, err := d.Ref.Collection(participantsSubcollection).Select().Limit(participantsPage).Documents(ctx).GetAll()
		if err != nil {
			return deleted, true, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: participants: %w", logger.HashUID(uid), err), uid, d.Ref.ID)
		}
		b := store.NewFirestoreBatch(r.client)
		for _, p := range parts {
			b.Delete(p.Ref)
		}
		full := len(parts) == participantsPage
		if !full {
			b.Delete(d.Ref)
			b.Delete(r.membershipRef(uid, d.Ref.ID))
		}
		if err := b.Commit(ctx); err != nil {
			return deleted, true, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: %w", logger.HashUID(uid), err), uid, d.Ref.ID)
		}
		if full {
			partial = true // the beacon stays; the next call reads its remaining participant docs
			continue
		}
		deleted++
	}
	return deleted, partial || len(docs) == purgeOrganisedPage, nil
}

// PurgeMembershipPage implements PagePurger. An ACCEPTED participant row is released in its own transaction (R12): the
// beacon's acceptedCount drops and a FULL beacon reopens, with the participant doc and the membership row deleted in
// the same transaction, so a retry after a failure finds no row and never decrements twice. Every other row is a plain
// delete of the participant doc it names and the row itself, in one batch.
func (r *FirestoreRepo) PurgeMembershipPage(ctx context.Context, uid string) (int, error) {
	rows, err := r.client.Collection(usersCollection).Doc(uid).Collection(membershipsSubcollection).Limit(purgeMembershipPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	batched := 0
	for _, row := range rows {
		var m membershipDoc
		if err := row.DataTo(&m); err != nil {
			return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships decode: %w", err), uid, row.Ref.ID)
		}
		beaconID := m.BeaconID
		if beaconID == "" {
			beaconID = row.Ref.ID
		}
		if m.Role == RoleParticipant && m.State == PStateAccepted {
			if err := r.releaseSeat(ctx, uid, beaconID, row.Ref); err != nil {
				return 0, err
			}
			continue
		}
		if m.Role != RoleOrganiser {
			b.Delete(r.participantRef(beaconID, uid))
		}
		b.Delete(row.Ref)
		batched++
	}
	if batched > 0 {
		if err := b.Commit(ctx); err != nil {
			return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships %s: %w", logger.HashUID(uid), err), uid)
		}
	}
	return len(rows), nil
}

// releaseSeat is one transaction of the erasure: the beacon (when it still exists) loses one accepted seat and
// recomputes OPEN/FULL, the participant doc and the membership row are deleted.
func (r *FirestoreRepo) releaseSeat(ctx context.Context, uid, beaconID string, rowRef *firestore.DocumentRef) error {
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		d, err := r.getBeacon(ctx, tx, beaconID)
		exists := err == nil
		if err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		if exists {
			count := max(d.AcceptedCount-1, 0)
			status := d.Status
			if status != string(StatusCancelled) { // a cancelled beacon keeps its status: only the count moves
				status = string(liveStatus(count, d.OpenSpots))
			}
			b.Update(r.ref(beaconID), []firestore.Update{
				{Path: "acceptedCount", Value: count},
				{Path: "status", Value: status},
				{Path: "updatedAt", Value: r.now().UTC()},
			})
		}
		b.Delete(r.participantRef(beaconID, uid))
		b.Delete(rowRef)
		return b.Err()
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	if err != nil {
		return logger.RedactErr(fmt.Errorf("beacons: purge memberships %s: release seat: %w", logger.HashUID(uid), err), uid, beaconID)
	}
	return nil
}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning. Deleted documents drop out
// of the next page, so the purge is self-resuming and the count is only for logging.
type Checkpoint struct {
	// Phase is "" while the user's organised beacons are being deleted and "memberships" while the membership rows (and
	// the participant docs they name) are.
	Phase   string `json:"phase,omitempty"`
	Deleted int    `json:"deleted,omitempty"`
}

// Eraser is the `beacons` account-deletion step. Phase 1 deletes the organised beacons (participant docs included), phase
// 2 the membership rows with the participant docs they name. One page per call; never flag-gated.
type Eraser struct {
	repo PagePurger
}

// NewEraser builds the step on a PagePurger (FirestoreRepo in production).
func NewEraser(repo PagePurger) *Eraser { return &Eraser{repo: repo} }

// PurgeUser runs one page and reports whether the step is finished. An account with no beacons takes two calls (an empty
// page per phase, no writes); a rerun from a zero checkpoint after completion is the same two empty pages, and a rerun
// from the persisted memberships checkpoint is one.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Phase == phaseOrganised {
		n, more, err := e.repo.PurgeOrganisedPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Phase: phaseOrganised, Deleted: cp.Deleted + n}
		if !more {
			next.Phase = phaseMemberships
		}
		slog.InfoContext(ctx, "beacons_purge", "uid_hash", logger.HashUID(uid), "phase", "organised", "docs", n, "deleted_total", next.Deleted)
		return next, false, nil
	}
	n, err := e.repo.PurgeMembershipPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := Checkpoint{Phase: phaseMemberships, Deleted: cp.Deleted + n}
	slog.InfoContext(ctx, "beacons_purge", "uid_hash", logger.HashUID(uid), "phase", "memberships", "docs", n, "deleted_total", next.Deleted)
	return next, n < purgeMembershipPage, nil
}
