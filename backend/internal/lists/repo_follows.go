package lists

// Follow markers: listFollows/{listId}_{uid} and the lists/{id}.followerCount they keep (FEATURE_LIST_FOLLOWS).
//
// Invariant: a marker is created or deleted in the same transaction that moves followerCount by one, so the count equals
// the number of markers of the list (opsctl recount-list-follows repairs drift). Erasure: a follower's markers are removed
// with their counts by the lists eraser (PurgeFollowerPage); the markers of a list are removed when the list is deleted
// (deleteFollowMarkers, from DeleteList and from the owner's purge). The export writes the user's markers (FollowedBy).

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// followsCollection is listFollows/{listId}_{uid}. It has an erasure row in apiserver/lifecycle_collections_guard_test.go.
	followsCollection = "listFollows"
	// followPurgePage is the markers one eraser call touches (each marker also reads and writes its list in one transaction).
	followPurgePage = 100
	// followSweepPage is the markers one sweep batch deletes (a batch holds 500 writes).
	followSweepPage = 400
)

// followDoc is listFollows/{listId}_{uid}.
type followDoc struct {
	ListID    string    `firestore:"listId"`
	UID       string    `firestore:"uid"`
	CreatedAt time.Time `firestore:"createdAt"`
}

func (r *FirestoreRepo) followsCol() *firestore.CollectionRef {
	return r.client.Collection(followsCollection)
}

func (r *FirestoreRepo) followRef(listID, uid string) *firestore.DocumentRef {
	return r.followsCol().Doc(listID + "_" + uid)
}

// followHeader answers a replay of Follow or Unfollow: the list as it is now, read in tx WITHOUT the owner check (the caller
// need not own a list they follow). A list gone since is ErrNotFound.
func (r *FirestoreRepo) followHeader(tx *firestore.Transaction, id string) (Header, error) {
	snap, err := tx.Get(r.ref(id))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Header{}, ErrNotFound
		}
		return Header{}, fmt.Errorf("lists: follow replay read: %w", err)
	}
	var d listDoc
	if err := snap.DataTo(&d); err != nil {
		return Header{}, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), id)
	}
	return d.list(id).header(), nil
}

// countFollows counts uid's markers inside tx, stopping at max (n >= max means the cap is reached).
func (r *FirestoreRepo) countFollows(ctx context.Context, tx *firestore.Transaction, uid string, limit int) (int64, error) {
	return txCount(ctx, tx, r.followsCol().Where("uid", "==", uid).Limit(limit), "count follows")
}

// Follow implements Repo: one transaction. Reads, fresh and in this order: the idempotency document (a replay answers from the
// list as it is now), the list (visibility checked again: private, hidden or deleted => ErrNotFound), the caller's marker (an
// existing one is Unchanged), then the caller's marker count (at the cap => ErrFollowLimit). Writes: the marker (create),
// followerCount + 1 (FieldValue.Increment, the list's field only) and the idempotency document. Following a list the caller
// owns writes nothing (the service answers that before the transaction).
func (r *FirestoreRepo) Follow(ctx context.Context, p FollowParams) (FollowResult, error) {
	if err := r.ready(); err != nil {
		return FollowResult{}, err
	}
	var res FollowResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = FollowResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				h, herr := r.followHeader(tx, rec.Result["id"])
				if herr != nil {
					return herr
				}
				res = FollowResult{Outcome: Replayed, Header: h}
			}
			return err
		}
		snap, err := tx.Get(r.ref(p.ListID))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("lists: follow read list: %w", err)
		}
		var d listDoc
		if err := snap.DataTo(&d); err != nil {
			return logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), p.ListID)
		}
		l := d.list(p.ListID)
		h := l.header()
		h.FollowerCount = l.FollowerCount
		b := store.NewFirestoreTxBatch(tx)
		if l.OwnerID == p.UID {
			r.putIdem(b, p.UID, p.IdemKey, rpcFollowList, p.RequestHash, map[string]string{"id": p.ListID})
			if err := b.Err(); err != nil {
				return err
			}
			res = FollowResult{Outcome: Unchanged, Header: h}
			return nil
		}
		if l.IsPrivate || l.Hidden {
			return ErrNotFound
		}
		mSnap, err := tx.Get(r.followRef(p.ListID, p.UID))
		switch {
		case err == nil && mSnap.Exists():
			r.putIdem(b, p.UID, p.IdemKey, rpcFollowList, p.RequestHash, map[string]string{"id": p.ListID})
			if err := b.Err(); err != nil {
				return err
			}
			res = FollowResult{Outcome: Unchanged, Header: h}
			return nil
		case err != nil && status.Code(err) != codes.NotFound:
			return fmt.Errorf("lists: follow read marker: %w", err)
		}
		n, err := r.countFollows(ctx, tx, p.UID, p.MaxFollows)
		if err != nil {
			return err
		}
		if n >= int64(p.MaxFollows) {
			return ErrFollowLimit
		}
		b.Create(r.followRef(p.ListID, p.UID), followDoc{ListID: p.ListID, UID: p.UID, CreatedAt: r.now().UTC()})
		b.Update(r.ref(p.ListID), []firestore.Update{{Path: "followerCount", Value: firestore.Increment(1)}})
		r.putIdem(b, p.UID, p.IdemKey, rpcFollowList, p.RequestHash, map[string]string{"id": p.ListID})
		if err := b.Err(); err != nil {
			return err
		}
		h.FollowerCount = l.FollowerCount + 1
		res = FollowResult{Outcome: Written, Header: h}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}

// Unfollow implements Repo: one transaction. Reads: the idempotency document, the caller's marker, then (only when the marker
// exists) the list, which need not be visible. Writes: the marker deleted; followerCount - 1 only when the list still exists
// (a gone list loses its marker alone); the idempotency document. No marker is a success with the idempotency document only.
func (r *FirestoreRepo) Unfollow(ctx context.Context, p UnfollowParams) (UnfollowResult, error) {
	if err := r.ready(); err != nil {
		return UnfollowResult{}, err
	}
	var res UnfollowResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = UnfollowResult{}
		_, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = UnfollowResult{Outcome: Replayed}
			}
			return err
		}
		mRef := r.followRef(p.ListID, p.UID)
		mSnap, err := tx.Get(mRef)
		if err != nil && status.Code(err) != codes.NotFound {
			return fmt.Errorf("lists: unfollow read marker: %w", err)
		}
		exists := err == nil && mSnap.Exists()
		b := store.NewFirestoreTxBatch(tx)
		outcome := Unchanged
		if exists {
			lRef := r.ref(p.ListID)
			lSnap, lerr := tx.Get(lRef)
			if lerr != nil && status.Code(lerr) != codes.NotFound {
				return fmt.Errorf("lists: unfollow read list: %w", lerr)
			}
			if lerr == nil && lSnap.Exists() {
				b.Update(lRef, []firestore.Update{{Path: "followerCount", Value: firestore.Increment(-1)}})
			}
			b.Delete(mRef)
			outcome = Written
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcUnfollowList, p.RequestHash, map[string]string{"id": p.ListID})
		if err := b.Err(); err != nil {
			return err
		}
		res = UnfollowResult{Outcome: outcome}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}

// FollowedPage implements Repo: uid's markers ordered by createdAt descending (the index chore(firestore) on listFollows).
// before, when set, starts strictly after that marker. A marker created in the same instant as the cursor's is not repeated by a
// later page; the only ties are two follows by one account at the same timestamp.
func (r *FirestoreRepo) FollowedPage(ctx context.Context, viewer string, before *FollowAnchor, limit int) ([]FollowRow, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	q := r.followsCol().Where("uid", "==", viewer).OrderBy("createdAt", firestore.Desc)
	if before != nil {
		q = q.StartAfter(before.CreatedAt)
	}
	docs, err := q.Limit(min(max(limit, 1), 50)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("lists: followed page: %w", err), viewer)
	}
	out := make([]FollowRow, 0, len(docs))
	for _, s := range docs {
		var d followDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: decode follow: %w", err), viewer)
		}
		out = append(out, FollowRow{ListID: d.ListID, CreatedAt: d.CreatedAt})
	}
	return out, nil
}

// DiscoverPage implements Repo: public lists ordered by followerCount descending, then document id ascending (the index
// chore(firestore) on lists: isPrivate ASC, followerCount DESC). Lists without the followerCount field are not returned (a list
// created before the field needs a recount or a first follow). hidden, owner status and blocks are filtered by the service.
func (r *FirestoreRepo) DiscoverPage(ctx context.Context, after *DiscoverAnchor, limit int) ([]List, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	q := r.col().Where("isPrivate", "==", false).OrderBy("followerCount", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.FollowerCount, r.ref(after.ListID))
	}
	docs, err := q.Limit(min(max(limit, 1), 50)).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("lists: discover page: %w", err)
	}
	out := make([]List, 0, len(docs))
	for _, s := range docs {
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), s.Ref.ID)
		}
		out = append(out, d.list(s.Ref.ID))
	}
	return out, nil
}

// FollowedAmong implements Repo: one batched read of the viewer's markers for listIDs (at most 50 ids, the caller's page).
func (r *FirestoreRepo) FollowedAmong(ctx context.Context, viewer string, listIDs []string) (map[string]bool, error) {
	out := make(map[string]bool, len(listIDs))
	if len(listIDs) == 0 {
		return out, nil
	}
	if err := r.readable(); err != nil {
		return nil, err
	}
	refs := make([]*firestore.DocumentRef, len(listIDs))
	for i, id := range listIDs {
		refs[i] = r.followRef(id, viewer)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("lists: followed among: %w", err), viewer)
	}
	for i, s := range snaps {
		if s != nil && s.Exists() {
			out[listIDs[i]] = true
		}
	}
	return out, nil
}

// FollowedBy implements Repo (the export's view): the viewer's markers newest first, at most limit.
func (r *FirestoreRepo) FollowedBy(ctx context.Context, uid string, limit int) ([]FollowRow, error) {
	return r.FollowedPage(ctx, uid, nil, limit)
}

// PurgeFollowerPage implements PagePurger: removes up to followPurgePage of uid's markers (the account is being erased). One
// transaction per page: reads the lists the markers name, then decrements followerCount on each list that still exists and
// deletes the markers. Repeating the call resumes: the markers that were deleted leave the next page.
func (r *FirestoreRepo) PurgeFollowerPage(ctx context.Context, uid string) (MemberPage, error) {
	if err := r.readable(); err != nil {
		return MemberPage{}, err
	}
	docs, err := r.followsCol().Where("uid", "==", uid).Limit(followPurgePage).Documents(ctx).GetAll()
	if err != nil {
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge follows %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return MemberPage{}, nil
	}
	var lRefs []*firestore.DocumentRef
	var mRefs []*firestore.DocumentRef
	for _, d := range docs {
		var f followDoc
		if err := d.DataTo(&f); err != nil {
			return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: decode follow: %w", err), uid)
		}
		lRefs = append(lRefs, r.ref(f.ListID))
		mRefs = append(mRefs, d.Ref)
	}
	_, err = r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		lSnaps, err := tx.GetAll(lRefs)
		if err != nil {
			return fmt.Errorf("lists: purge follows: read lists: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx)
		for i, s := range lSnaps {
			if s.Exists() {
				b.Update(lRefs[i], []firestore.Update{{Path: "followerCount", Value: firestore.Increment(-1)}})
			}
		}
		for _, m := range mRefs {
			b.Delete(m)
		}
		return b.Err()
	})
	if err != nil {
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge follows %s: %w", logger.HashUID(uid), err), uid)
	}
	return MemberPage{Scanned: len(docs), Updated: len(docs)}, nil
}

// deleteFollowMarkers removes every marker of listID (the list is gone, or is being deleted by its owner). Each batch is
// followSweepPage markers; the counts are not touched (the list no longer exists). Returns how many were removed. Idempotent:
// a repeat finds nothing.
func (r *FirestoreRepo) deleteFollowMarkers(ctx context.Context, listID string) (int, error) {
	total := 0
	for {
		docs, err := r.followsCol().Where("listId", "==", listID).Limit(followSweepPage).Documents(ctx).GetAll()
		if err != nil {
			return total, logger.RedactErr(fmt.Errorf("lists: sweep follows: query: %w", err), listID)
		}
		if len(docs) == 0 {
			return total, nil
		}
		b := store.NewFirestoreBatch(r.client)
		for _, d := range docs {
			b.Delete(d.Ref)
		}
		if err := b.Commit(ctx); err != nil {
			return total, logger.RedactErr(fmt.Errorf("lists: sweep follows: %w", err), listID)
		}
		total += len(docs)
		if len(docs) < followSweepPage {
			return total, nil
		}
	}
}

// FollowRecount is the outcome of RecountFollowers: the stored followerCount and the count of markers. Missing is true when
// the list document has no followerCount field at all (a list created before the field existed); Stored is then 0.
type FollowRecount struct {
	Stored  int64
	Counted int64
	Missing bool
	Written bool
}

// InStep reports whether the stored count is present and equals the marker count, so a write would change nothing.
func (r FollowRecount) InStep() bool { return !r.Missing && r.Stored == r.Counted }

// hasFollowerCount reports whether the list document stores a followerCount field. DataTo decodes a missing field as 0,
// which would look in step with zero markers, yet DiscoverLists orders by followerCount and so never returns such a list.
func hasFollowerCount(snap *firestore.DocumentSnapshot) bool {
	_, err := snap.DataAt("followerCount")
	return err == nil
}

// RecountFollowers compares lists/{listID}.followerCount with the number of its markers. With write it sets the stored count
// to the counted value in one transaction (the list read and the markers counted inside it, so a concurrent follow conflicts
// and retries), also when the field is missing. Without write it only reads.
func (r *FirestoreRepo) RecountFollowers(ctx context.Context, listID string, write bool) (FollowRecount, error) {
	if err := r.readable(); err != nil {
		return FollowRecount{}, err
	}
	countIn := func(ctx context.Context, tx *firestore.Transaction) (int64, error) {
		q := r.followsCol().Where("listId", "==", listID)
		aq := q.NewAggregationQuery().WithCount("n")
		var res firestore.AggregationResult
		var err error
		if tx != nil {
			res, err = aq.Transaction(tx).Get(ctx)
		} else {
			res, err = aq.Get(ctx)
		}
		if err != nil {
			return 0, fmt.Errorf("lists: recount: count: %w", err)
		}
		var agg struct {
			N int64 `firestore:"n"`
		}
		if err := res.DataTo(&agg); err != nil {
			return 0, fmt.Errorf("lists: recount: decode: %w", err)
		}
		return agg.N, nil
	}
	if !write {
		snap, err := r.ref(listID).Get(ctx)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return FollowRecount{}, ErrNotFound
			}
			return FollowRecount{}, logger.RedactErr(fmt.Errorf("lists: recount read: %w", err), listID)
		}
		var d listDoc
		if err := snap.DataTo(&d); err != nil {
			return FollowRecount{}, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), listID)
		}
		n, err := countIn(ctx, nil)
		if err != nil {
			return FollowRecount{}, logger.RedactErr(err, listID)
		}
		return FollowRecount{Stored: d.FollowerCount, Counted: n, Missing: !hasFollowerCount(snap)}, nil
	}
	var out FollowRecount
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(r.ref(listID))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("lists: recount read: %w", err)
		}
		var d listDoc
		if err := snap.DataTo(&d); err != nil {
			return logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), listID)
		}
		n, err := countIn(ctx, tx)
		if err != nil {
			return err
		}
		out = FollowRecount{Stored: d.FollowerCount, Counted: n, Missing: !hasFollowerCount(snap)}
		if out.InStep() {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.ref(listID), []firestore.Update{{Path: "followerCount", Value: n}})
		if err := b.Err(); err != nil {
			return err
		}
		out.Written = true
		return nil
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return out, err
		}
		return out, logger.RedactErr(fmt.Errorf("lists: recount: %w", err), listID)
	}
	return out, nil
}
