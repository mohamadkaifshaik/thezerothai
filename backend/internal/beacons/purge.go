// purge.go is the right-to-delete path of the beacons data (R4). Deleting users/{uid} removes none of beacons/{id}, its
// beaconParticipants docs or users/{uid}/beaconMemberships, so the `beacons` account-deletion step (Eraser, registered
// BeforeIdentity after `communities`) deletes the user's organised beacons with their participant docs, then every
// participant doc the user's membership rows name, then the membership rows. Never flag-gated: documents outlive the flag.
package beacons

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// purgeOrganisedPage is the most organised beacons one eraser call deletes; each beacon is its own batch (the beacon,
	// up to MaxBeaconOpenSpotsCeiling participant docs and the organiser's membership row stay under 500 writes).
	purgeOrganisedPage = 100
	// purgeMembershipPage is the most membership rows one eraser call processes: two deletes each, one batch of <= 500.
	purgeMembershipPage = 250
	// participantsPageLimit bounds the participant docs read under one beacon (the cap is 50; the limit is a backstop).
	participantsPageLimit = 500

	phaseOrganised   = ""
	phaseMemberships = "memberships"
)

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// PurgeOrganisedPage deletes up to purgeOrganisedPage of uid's organised beacons, each with its beaconParticipants
	// docs and the organiser's own membership row, one batch per beacon, and reports how many beacons. Deleted beacons
	// leave the next page, so repeating the call is self-resuming. Other users' membership rows pointing at the beacon
	// are left to dangle (they hold no uid, R3).
	PurgeOrganisedPage(ctx context.Context, uid string) (deleted int, err error)
	// PurgeMembershipPage deletes up to purgeMembershipPage of users/{uid}/beaconMemberships rows and, for each row whose
	// role is not organiser, the beacons/{beaconId}/beaconParticipants/{uid} doc it names, in one batch, and reports how
	// many rows. Deleted rows leave the next page.
	PurgeMembershipPage(ctx context.Context, uid string) (deleted int, err error)
}

var _ PagePurger = (*FirestoreRepo)(nil)

// PurgeOrganisedPage implements PagePurger.
func (r *FirestoreRepo) PurgeOrganisedPage(ctx context.Context, uid string) (int, error) {
	docs, err := r.col().Where("organiserId", "==", uid).Select().Limit(purgeOrganisedPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: query: %w", logger.HashUID(uid), err), uid)
	}
	for _, d := range docs {
		parts, err := d.Ref.Collection(participantsSubcollection).Select().Limit(participantsPageLimit).Documents(ctx).GetAll()
		if err != nil {
			return 0, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: participants: %w", logger.HashUID(uid), err), uid, d.Ref.ID)
		}
		b := store.NewFirestoreBatch(r.client)
		for _, p := range parts {
			b.Delete(p.Ref)
		}
		b.Delete(d.Ref)
		b.Delete(r.membershipRef(uid, d.Ref.ID))
		if err := b.Commit(ctx); err != nil {
			return 0, logger.RedactErr(fmt.Errorf("beacons: purge organised %s: %w", logger.HashUID(uid), err), uid, d.Ref.ID)
		}
	}
	return len(docs), nil
}

// PurgeMembershipPage implements PagePurger.
func (r *FirestoreRepo) PurgeMembershipPage(ctx context.Context, uid string) (int, error) {
	rows, err := r.client.Collection(usersCollection).Doc(uid).Collection(membershipsSubcollection).Limit(purgeMembershipPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, row := range rows {
		var m membershipDoc
		if err := row.DataTo(&m); err != nil {
			return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships decode: %w", err), uid, row.Ref.ID)
		}
		if m.Role != RoleOrganiser && m.BeaconID != "" {
			b.Delete(r.ref(m.BeaconID).Collection(participantsSubcollection).Doc(uid))
		}
		b.Delete(row.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, logger.RedactErr(fmt.Errorf("beacons: purge memberships %s: %w", logger.HashUID(uid), err), uid)
	}
	return len(rows), nil
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
// page per phase, no writes); a repeat after completion is the same two empty pages.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Phase == phaseOrganised {
		n, err := e.repo.PurgeOrganisedPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Phase: phaseOrganised, Deleted: cp.Deleted + n}
		if n < purgeOrganisedPage {
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
