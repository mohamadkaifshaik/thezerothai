// repo_bookmarks.go is the Firestore implementation of BookmarkRepo (ADR-0023 D2, D3, D4). Collections owned here:
// users/{uid}/bookmarks/{postId} = {createdAt} (a thin doc: no copy of the post, its text, media or author) and the
// `bookmarks` array of userLikes/{uid}, the complete set of the caller's bookmarked ids (viewer state at 0 extra reads).
//
// Every userLikes write is field-level: a Set with MergeAll and ArrayUnion/ArrayRemove, never a whole-document write.
// A whole-document Set would silently empty the set (the ADR-0021 I-3 class of bug), and it is why the quota record
// carries its Bookmarks field.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	usersCollection     = "users"
	bookmarksCollection = "bookmarks"

	// rpcAddBookmark and rpcRemoveBookmark are the rpc names the idempotency doc id is hashed with.
	rpcAddBookmark    = "AddBookmark"
	rpcRemoveBookmark = "RemoveBookmark"
)

var _ BookmarkRepo = (*FirestoreRepo)(nil)

// bookmarkDoc is users/{uid}/bookmarks/{postId}: the post id is the doc id, createdAt the bookmark time (list order).
type bookmarkDoc struct {
	CreatedAt time.Time `firestore:"createdAt"`
}

func (r *FirestoreRepo) bookmarkRef(uid, postID string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(bookmarksCollection).Doc(postID)
}

// bookmarksReady is ready() for the bookmark paths: they need the quota store and the idempotency store, not the
// like/repost writers, so a wiring that lacks one family fails only the paths that use it.
func (r *FirestoreRepo) bookmarksReady() error {
	if r.w.Quotas == nil || r.w.Idempotency == nil {
		return errors.New("engagement: repo has no bookmark writers configured")
	}
	return nil
}

// bookmarkSet reads userLikes/{uid}.bookmarks inside tx (1 read; a missing doc is an empty set, still 1 read).
func (r *FirestoreRepo) bookmarkSet(ctx context.Context, tx *firestore.Transaction, uid string) ([]string, error) {
	snap, err := tx.Get(r.userLikesRef(uid))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("engagement: get userLikes: %w", err)
	}
	var d userLikesDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("engagement: decode userLikes: %w", err)
	}
	return d.Bookmarks, nil
}

// storedState is the state a replayed idempotency record carries, or ErrIdempotencyKeyReused when the record belongs
// to another request. A record without a result falls back to the requested id and the rpc's own state.
func storedState(rec idempotency.Record, requestHash, postID string, bookmarked bool) (BookmarkState, error) {
	if rec.RequestHash != requestHash {
		return BookmarkState{}, ErrIdempotencyKeyReused
	}
	st := BookmarkState{PostID: postID, Bookmarked: bookmarked}
	if id := rec.Result["postId"]; id != "" {
		st.PostID = id
	}
	if v, ok := rec.Result["bookmarked"]; ok {
		st.Bookmarked = v == "true"
	}
	return st, nil
}

// putIdem appends the TTL'd idempotency doc of rpc, holding the state it answered, to b.
func (r *FirestoreRepo) putIdem(b store.Batch, uid, key, rpc, requestHash string, st BookmarkState) {
	r.w.Idempotency.Put(b, key, idempotency.Record{
		UID: uid, RPC: rpc, RequestHash: requestHash, Result: resultMap(st), ExpireAt: r.now().UTC().Add(idempotency.TTL),
	})
}

// recordNoop stores the idempotency doc of a call that changed nothing, in a batch of its own (no read). An existing
// doc (AlreadyExists: a concurrent request with the same key recorded it first) is done.
func (r *FirestoreRepo) recordNoop(ctx context.Context, uid, key, rpc, requestHash string, st BookmarkState) error {
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	r.putIdem(b, uid, key, rpc, requestHash, st)
	if err := b.Commit(ctx); err != nil && status.Code(err) != codes.AlreadyExists {
		return fmt.Errorf("engagement: record %s no-op: %w", rpc, err)
	}
	return nil
}

func resultMap(st BookmarkState) map[string]string {
	return map[string]string{"postId": st.PostID, "bookmarked": fmt.Sprint(st.Bookmarked)}
}

// Add implements BookmarkRepo: one transaction (ADR-0023 D4, rule 4). Reads, fresh and in this order: idempotency/{hash}
// (a replay returns here: 1 read), quotas/{uid}, userLikes/{uid} (3 reads; the array length is the cap check, so the
// cap is exact). Writes 4: Create the bookmark, Create the idempotency doc, the quota record, ArrayUnion on
// userLikes.bookmarks. A bookmark already in the set, or whose doc already exists (AlreadyExists at commit, which is
// also a concurrent duplicate of the same key), is success with no quota charge and 1 write: only the idempotency doc,
// so a late retry of the key replays instead of re-adding a bookmark removed since.
func (r *FirestoreRepo) Add(ctx context.Context, p AddBookmarkParams) (BookmarkResult, error) {
	if err := r.bookmarksReady(); err != nil {
		return BookmarkResult{}, err
	}
	want := BookmarkState{PostID: p.PostID, Bookmarked: true}
	var res BookmarkResult
	attempts, err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = BookmarkResult{}
		rec, err := r.w.Idempotency.Get(ctx, tx, p.IdemKey)
		switch {
		case err == nil:
			st, serr := storedState(rec, p.RequestHash, p.PostID, true)
			if serr != nil {
				return serr
			}
			res = BookmarkResult{Outcome: BookmarkReplayed, State: st}
			return nil
		case !errors.Is(err, idempotency.ErrNotFound):
			return fmt.Errorf("engagement: idempotency lookup: %w", err)
		}
		qrec, err := r.w.Quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("engagement: quota lookup: %w", err)
		}
		set, err := r.bookmarkSet(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		if slices.Contains(set, p.PostID) {
			// Already bookmarked: success before the cap and quota checks, nothing charged. Only the idempotency doc is
			// written (1 write), so a late retry of this key replays instead of re-adding a bookmark removed since.
			b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
			r.putIdem(b, p.UID, p.IdemKey, rpcAddBookmark, p.RequestHash, want)
			if err := b.Err(); err != nil {
				return err
			}
			res = BookmarkResult{Outcome: BookmarkUnchanged, State: want}
			return nil
		}
		if len(set) >= p.MaxPerUser {
			return ErrBookmarkLimit
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.UID), qrec, quota.Bookmarks, p.QuotaLimit); err != nil {
			return err
		}
		now := r.now().UTC()
		b.Create(r.bookmarkRef(p.UID, p.PostID), bookmarkDoc{CreatedAt: now})
		r.putIdem(b, p.UID, p.IdemKey, rpcAddBookmark, p.RequestHash, want)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"bookmarks": firestore.ArrayUnion(p.PostID), "updatedAt": now,
		}, firestore.MergeAll)
		if err := b.Err(); err != nil {
			return err
		}
		res = BookmarkResult{Outcome: BookmarkWritten, State: want}
		return nil
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	switch status.Code(err) {
	case codes.OK:
		return res, nil
	case codes.AlreadyExists:
		// The bookmark doc exists (the array had lost it), or a concurrent request with the same key created the
		// idempotency doc first. Either way the post is bookmarked; record the key (1 write, AlreadyExists = done).
		if rerr := r.recordNoop(ctx, p.UID, p.IdemKey, rpcAddBookmark, p.RequestHash, want); rerr != nil {
			return BookmarkResult{}, rerr
		}
		return BookmarkResult{Outcome: BookmarkUnchanged, State: want}, nil
	default:
		return BookmarkResult{}, err
	}
}

// Remove implements BookmarkRepo: one transaction. It reads idempotency/{hash} (1 read; a replay returns here), then
// Delete(bookmark, Exists), Create the idempotency doc and ArrayRemove on userLikes.bookmarks: 2 writes + 1 delete. A
// missing bookmark fails the Exists precondition at commit, which rolls the whole transaction back; the key is then
// recorded on its own (recordNoop): the no-op costs 1 read and 1 write (the idempotency doc), so a late retry of the
// key replays. No visibility check and no quota.
func (r *FirestoreRepo) Remove(ctx context.Context, p RemoveBookmarkParams) (BookmarkResult, error) {
	if err := r.bookmarksReady(); err != nil {
		return BookmarkResult{}, err
	}
	want := BookmarkState{PostID: p.PostID, Bookmarked: false}
	var res BookmarkResult
	attempts, err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = BookmarkResult{}
		rec, err := r.w.Idempotency.Get(ctx, tx, p.IdemKey)
		switch {
		case err == nil:
			st, serr := storedState(rec, p.RequestHash, p.PostID, false)
			if serr != nil {
				return serr
			}
			res = BookmarkResult{Outcome: BookmarkReplayed, State: st}
			return nil
		case !errors.Is(err, idempotency.ErrNotFound):
			return fmt.Errorf("engagement: idempotency lookup: %w", err)
		}
		now := r.now().UTC()
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Delete(r.bookmarkRef(p.UID, p.PostID), firestore.Exists)
		r.putIdem(b, p.UID, p.IdemKey, rpcRemoveBookmark, p.RequestHash, want)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"bookmarks": firestore.ArrayRemove(p.PostID), "updatedAt": now,
		}, firestore.MergeAll)
		if err := b.Err(); err != nil {
			return err
		}
		res = BookmarkResult{Outcome: BookmarkWritten, State: want}
		return nil
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	switch {
	case err == nil:
		return res, nil
	case status.Code(err) == codes.AlreadyExists:
		// A concurrent request with the same key created the idempotency doc first: it is recorded, nothing to write.
		return BookmarkResult{Outcome: BookmarkUnchanged, State: want}, nil
	case store.IsPreconditionFailed(err):
		// The bookmark is not there (the Exists precondition failed and the transaction rolled back). Record the key so
		// a late retry replays instead of removing a bookmark added since (1 write, no extra read).
		if rerr := r.recordNoop(ctx, p.UID, p.IdemKey, rpcRemoveBookmark, p.RequestHash, want); rerr != nil {
			return BookmarkResult{}, rerr
		}
		return BookmarkResult{Outcome: BookmarkUnchanged, State: want}, nil
	default:
		return BookmarkResult{}, err
	}
}
