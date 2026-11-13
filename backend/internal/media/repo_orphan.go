// repo_orphan.go is the Firestore side of the orphan sweep (orphan_sweep.go) and of its one-off backfill
// (`opsctl backfill-media-orphans`). Everything is on media/{mediaId}; no new collection.
//
// Index map (no change to firebase/firestore.indexes.json or field-overrides.ack):
//
//	DueOrphans   orphanCheckAt <= now ORDER BY orphanCheckAt ASC LIMIT n   automatic single-field index (ascending) on
//	                                                                       orphanCheckAt; media exempts only blurhash
//	backfill     ORDER BY __name__ ASC LIMIT n (no filter)                  automatic (__name__)
//
// Every write is a field-level Update or a Delete with a LastUpdateTime precondition, never a Set: a write that lands after
// the account eraser cannot recreate the document, and a write that lost a race to an attach (Claim.Attach moves the
// UpdateTime) is refused as ErrConflict. Fields: orphanCheckAt and orphanedAt (SetOrphanState), and orphanDeletingAt, the
// permanent claim, written only by ClaimOrphan and never removed (no write here or in SetOrphanState can delete it). None
// is a TTL field.
package media

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// OrphanRepo is the orphan sweep's storage seam; *FirestoreRepo implements it.
type OrphanRepo interface {
	// DueOrphans reads up to limit documents whose orphanCheckAt is at or before now, oldest first. A document it cannot
	// decode is returned by id in Undecodable, never as an error.
	DueOrphans(ctx context.Context, now time.Time, limit int) (DuePage, error)
	// SetOrphanState writes orphanCheckAt and orphanedAt as st says (a zero time deletes the field), conditional on
	// updateTime (ErrConflict when the document changed or is gone), and returns the new UpdateTime. It never touches
	// orphanDeletingAt.
	SetOrphanState(ctx context.Context, id string, updateTime time.Time, st OrphanState) (time.Time, error)
	// ClaimOrphan is phase 2's claim: orphanDeletingAt = deletingAt (permanent) and orphanCheckAt = checkAt, orphanedAt
	// untouched, conditional on updateTime like SetOrphanState.
	ClaimOrphan(ctx context.Context, id string, updateTime, checkAt, deletingAt time.Time) (time.Time, error)
	// DeleteOrphan deletes the document conditional on updateTime: ErrConflict when it changed since; nil when it is already gone.
	DeleteOrphan(ctx context.Context, id string, updateTime time.Time) error
}

// DuePage is one DueOrphans read.
type DuePage struct {
	// Docs are the decoded due documents, oldest check first.
	Docs []*Doc
	// Read is every document the query returned, decodable or not: Read == limit means there may be more.
	Read int
	// Undecodable are the ids of documents that could not be decoded (skipped; logged by the sweep, id only).
	Undecodable []string
}

// OrphanState is the pair of sweep fields one SetOrphanState writes. A zero time deletes the field.
type OrphanState struct {
	CheckAt    time.Time
	OrphanedAt time.Time
}

var _ OrphanRepo = (*FirestoreRepo)(nil)

// DueOrphans implements OrphanRepo.
func (r *FirestoreRepo) DueOrphans(ctx context.Context, now time.Time, limit int) (DuePage, error) {
	if limit < 1 {
		return DuePage{}, fmt.Errorf("media: due orphans: limit %d", limit)
	}
	snaps, err := r.client.Collection(mediaCollection).Where("orphanCheckAt", "<=", now.UTC()).
		OrderBy("orphanCheckAt", firestore.Asc).Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return DuePage{}, fmt.Errorf("media: due orphans: %w", err)
	}
	p := DuePage{Docs: make([]*Doc, 0, len(snaps)), Read: len(snaps)}
	for _, s := range snaps {
		d, err := decode(s)
		if err != nil {
			// One bad document must not stall the queue: skip it (its id is logged by the sweep), sweep the rest.
			p.Undecodable = append(p.Undecodable, s.Ref.ID)
			continue
		}
		p.Docs = append(p.Docs, d)
	}
	return p, nil
}

func timeOrDelete(t time.Time) any {
	if t.IsZero() {
		return firestore.Delete
	}
	return t.UTC()
}

// SetOrphanState implements OrphanRepo.
func (r *FirestoreRepo) SetOrphanState(ctx context.Context, id string, updateTime time.Time, st OrphanState) (time.Time, error) {
	return r.updateAt(ctx, id, []firestore.Update{
		{Path: "orphanCheckAt", Value: timeOrDelete(st.CheckAt)},
		{Path: "orphanedAt", Value: timeOrDelete(st.OrphanedAt)},
	}, updateTime, "set orphan state")
}

// ClaimOrphan implements OrphanRepo.
func (r *FirestoreRepo) ClaimOrphan(ctx context.Context, id string, updateTime, checkAt, deletingAt time.Time) (time.Time, error) {
	if deletingAt.IsZero() || checkAt.IsZero() {
		return time.Time{}, errors.New("media: claim orphan: zero time")
	}
	return r.updateAt(ctx, id, []firestore.Update{
		{Path: "orphanCheckAt", Value: checkAt.UTC()},
		{Path: "orphanDeletingAt", Value: deletingAt.UTC()},
	}, updateTime, "claim orphan")
}

// DeleteOrphan implements OrphanRepo.
func (r *FirestoreRepo) DeleteOrphan(ctx context.Context, id string, updateTime time.Time) error {
	_, err := r.ref(id).Delete(ctx, firestore.LastUpdateTime(updateTime))
	switch status.Code(err) {
	case codes.OK, codes.NotFound:
		return nil
	case codes.FailedPrecondition:
		// Firestore answers a precondition on a missing document the same way; the caller reads it as "moved on", and a
		// gone document is simply never due again.
		return ErrConflict
	}
	return fmt.Errorf("media: delete orphan: %w", err)
}

// OrphanBackfillPage is one page of BackfillOrphanChecks.
type OrphanBackfillPage struct {
	// Scanned is the number of documents read; Eligible those that needed the field; Set those written (0 in a dry run);
	// Conflicts those that changed between the read and the write (left for a re-run).
	Scanned, Eligible, Set, Conflicts int
	// Last is the id of the last document read, the --after checkpoint of the next page ("" when the page was empty).
	Last string
}

// needsOrphanCheck reports whether a document predating the sweep should become a candidate: published, unattached,
// not retired, and carrying no sweep field yet.
func needsOrphanCheck(d *Doc) bool {
	return d.Published() && d.PostID == "" && d.RetiredAt == nil && d.OrphanCheckAt == nil && d.OrphanedAt == nil && d.OrphanDeletingAt == nil
}

// BackfillOrphanChecks reads one page (<= limit) of media documents after the id `after`, in id order, and sets
// orphanCheckAt = checkAt on each that needsOrphanCheck (one preconditioned Update each; none in a dry run). It is how
// documents published before the sweep existed become candidates. Re-running is harmless: a document that has the field
// is skipped. Reads: the page; writes: one per eligible document.
func (r *FirestoreRepo) BackfillOrphanChecks(ctx context.Context, after string, limit int, checkAt time.Time, dryRun bool) (OrphanBackfillPage, error) {
	if limit < 1 {
		return OrphanBackfillPage{}, fmt.Errorf("media: backfill orphan checks: limit %d", limit)
	}
	q := r.client.Collection(mediaCollection).OrderBy(firestore.DocumentID, firestore.Asc).Limit(limit)
	if after != "" {
		q = q.StartAfter(after)
	}
	snaps, err := q.Documents(ctx).GetAll()
	if err != nil {
		return OrphanBackfillPage{}, fmt.Errorf("media: backfill orphan checks: %w", err)
	}
	var p OrphanBackfillPage
	for _, s := range snaps {
		d, err := decode(s)
		if err != nil {
			return p, err
		}
		p.Scanned++
		p.Last = d.ID
		if !needsOrphanCheck(d) {
			continue
		}
		p.Eligible++
		if dryRun {
			continue
		}
		_, err = r.updateAt(ctx, d.ID, []firestore.Update{{Path: "orphanCheckAt", Value: checkAt.UTC()}}, d.UpdateTime, "backfill orphan check")
		switch {
		case err == nil:
			p.Set++
		case errors.Is(err, ErrConflict):
			p.Conflicts++
		default:
			return p, err
		}
	}
	return p, nil
}
