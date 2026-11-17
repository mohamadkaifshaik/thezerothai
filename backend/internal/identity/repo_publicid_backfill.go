package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

var _ PublicIDBackfillStore = (*FirestoreRepo)(nil)

// publicIDScanDoc is the part of users/{uid} the walk reads (a Select projection).
type publicIDScanDoc struct {
	PublicID string `firestore:"publicId"`
	Status   string `firestore:"status"`
}

// ScanPublicIDs implements PublicIDBackfillStore: one query on users ordered by document id (no composite index: the
// default __name__ order), projected to publicId and status, then one GetAll of the lookups of the well-formed stored
// ids (an undecodable lookup is reported as existing with no owner, so the page goes on). Cost: one read per users document plus one per lookup (a missing document still counts as a read).
func (r *FirestoreRepo) ScanPublicIDs(ctx context.Context, after string, limit int) ([]PublicIDScanRow, error) {
	if limit < 1 || limit > PublicIDBackfillPage {
		return nil, fmt.Errorf("identity: scan public ids: limit %d out of 1..%d", limit, PublicIDBackfillPage)
	}
	q := r.client.Collection(usersCollection).Select("publicId", "status").OrderBy(firestore.DocumentID, firestore.Asc).Limit(limit)
	if after != "" {
		q = q.StartAfter(after)
	}
	snaps, err := q.Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("identity: scan users: %w", err)
	}
	rows := make([]PublicIDScanRow, 0, len(snaps))
	var ids []string
	for i, s := range snaps {
		var d publicIDScanDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode users entry %d: %w", i, err)
		}
		rows = append(rows, PublicIDScanRow{UID: s.Ref.ID, PublicID: d.PublicID, Status: statusFromString(d.Status)})
		if ValidPublicID(d.PublicID) {
			ids = append(ids, d.PublicID)
		}
	}
	if len(ids) == 0 {
		return rows, nil
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = r.publicIDRef(id)
	}
	lookups, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("identity: read %d publicIds: %w", len(ids), err)
	}
	type lookup struct {
		exists bool
		owner  string
	}
	found := make(map[string]lookup, len(ids))
	for i, snap := range lookups {
		if !snap.Exists() {
			continue
		}
		var l handleDoc
		if snap.DataTo(&l) != nil {
			l.UID = "" // undecodable: exists, owner unknown (a conflict, never repaired)
		}
		found[ids[i]] = lookup{exists: true, owner: l.UID}
	}
	for i := range rows {
		if l, ok := found[rows[i].PublicID]; ok && ValidPublicID(rows[i].PublicID) {
			rows[i].LookupExists, rows[i].LookupOwner = true, l.owner
		}
	}
	return rows, nil
}

// backfillUserInTx reads users/{uid} in tx and classifies its status: ok is false with the outcome to report when the
// account must not be written (gone, DELETING, or neither ACTIVE nor SUSPENDED).
func (r *FirestoreRepo) backfillUserInTx(tx *firestore.Transaction, uid string) (userDoc, PublicIDTxResult, bool, error) {
	snap, err := tx.Get(r.userRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return userDoc{}, PublicIDTxGone, false, nil
		}
		return userDoc{}, 0, false, fmt.Errorf("identity: get user for public id backfill: %w", err)
	}
	var d userDoc
	if err := snap.DataTo(&d); err != nil {
		return userDoc{}, 0, false, fmt.Errorf("identity: decode user for public id backfill: %w", err)
	}
	switch statusFromString(d.Status) {
	case AccountStatusActive, AccountStatusSuspended:
		return d, 0, true, nil
	case AccountStatusDeleting:
		return d, PublicIDTxDeleting, false, nil
	default:
		return d, PublicIDTxOtherStatus, false, nil
	}
}

// MintPublicIDForBackfill implements PublicIDBackfillStore: 1 read (users/{uid}), plus 2 writes when it mints (the
// create-only lookup and the field-level users/{uid}.publicId update; never a whole-document rewrite). Unlike GetMe's
// lazy mint (EnsurePublicID, ACTIVE only) it mints SUSPENDED accounts too; it never mints a DELETING one.
func (r *FirestoreRepo) MintPublicIDForBackfill(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	if !ValidPublicID(publicID) {
		return 0, errors.New("identity: backfill mint: malformed public id")
	}
	var out PublicIDTxResult
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		d, skip, ok, err := r.backfillUserInTx(tx, uid)
		if err != nil {
			return err
		}
		switch {
		case !ok:
			out = skip
			return nil
		case d.PublicID != "":
			out = PublicIDTxAlreadyOK
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Create(r.publicIDRef(publicID), handleDoc{UID: uid, CreatedAt: now})
		b.Update(r.userRef(uid), []firestore.Update{{Path: "publicId", Value: publicID}})
		if b.Err() != nil {
			return b.Err()
		}
		out = PublicIDTxWrote
		return nil
	})
	switch {
	case err == nil:
		return out, nil
	case status.Code(err) == codes.AlreadyExists:
		return 0, ErrPublicIDCollision // the lookup is the transaction's only create
	}
	return 0, fmt.Errorf("identity: backfill mint: %w", err)
}

// RepairPublicIDLookup implements PublicIDBackfillStore: 2 reads (users/{uid} and publicIds/{publicID}), plus 1 write
// (the create-only lookup, same id) when the account is ACTIVE or SUSPENDED, still carries publicID, and the lookup is
// absent. A lookup naming another uid is PublicIDTxForeign and nothing is written.
func (r *FirestoreRepo) RepairPublicIDLookup(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	if !ValidPublicID(publicID) {
		return 0, errors.New("identity: backfill repair: malformed public id")
	}
	var out PublicIDTxResult
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		d, skip, ok, err := r.backfillUserInTx(tx, uid)
		if err != nil {
			return err
		}
		switch {
		case !ok:
			out = skip
			return nil
		case d.PublicID != publicID:
			out = PublicIDTxGone // the id the page read is not the account's (ids are immutable: should not happen)
			return nil
		}
		snap, err := tx.Get(r.publicIDRef(publicID))
		switch {
		case err == nil:
			var l handleDoc
			if derr := snap.DataTo(&l); derr == nil && l.UID == uid {
				out = PublicIDTxAlreadyOK
			} else {
				out = PublicIDTxForeign
			}
			return nil
		case status.Code(err) != codes.NotFound:
			return fmt.Errorf("identity: get public id lookup: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Create(r.publicIDRef(publicID), handleDoc{UID: uid, CreatedAt: now})
		if b.Err() != nil {
			return b.Err()
		}
		out = PublicIDTxWrote
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("identity: backfill repair: %w", err)
	}
	return out, nil
}
