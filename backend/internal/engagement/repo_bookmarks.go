// repo_bookmarks.go is the Firestore implementation of BookmarkRepo. Collections owned here:
// users/{uid}/bookmarks/{postId} = {createdAt} (a thin doc: no copy of the post, its text, media or author) and the
// `bookmarks` array of userLikes/{uid}, the complete set of the caller's bookmarked ids (viewer state at 0 extra reads).
//
// Every userLikes write is field-level: a Set with MergeAll and ArrayUnion/ArrayRemove, never a whole-document write.
// A whole-document Set would silently empty the set (a known class of bug).
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

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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

// bookmarksReady is ready() for the bookmark paths: they need the idempotency store, not the
// like/repost writers, so a wiring that lacks one family fails only the paths that use it.
func (r *FirestoreRepo) bookmarksReady() error {
	if r.w.Idempotency == nil {
		return errors.New("engagement: repo has no bookmark writers configured")
	}
	return nil
}

// bookmarkSet reads userLikes/{uid}.bookmarks inside tx (a missing doc is an empty set).
func (r *FirestoreRepo) bookmarkSet(ctx context.Context, tx *firestore.Transaction, uid string) ([]string, error) {
	snap, err := tx.Get(r.userLikesRef(uid))
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
	b := store.NewFirestoreBatch(r.client)
	r.putIdem(b, uid, key, rpc, requestHash, st)
	if err := b.Commit(ctx); err != nil && status.Code(err) != codes.AlreadyExists {
		return fmt.Errorf("engagement: record %s no-op: %w", rpc, err)
	}
	return nil
}

func resultMap(st BookmarkState) map[string]string {
	return map[string]string{"postId": st.PostID, "bookmarked": fmt.Sprint(st.Bookmarked)}
}

// Add implements BookmarkRepo: one transaction. Reads, fresh and in this order: idempotency/{hash}
// (a replay returns here), userLikes/{uid} (the array length is the cap check, so the
// cap is exact). Writes: Create the bookmark, Create the idempotency doc, ArrayUnion on
// userLikes.bookmarks. A bookmark already in the set, or whose doc already exists (AlreadyExists at commit, which is
// also a concurrent duplicate of the same key), is success; only the idempotency doc is written,
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
		set, err := r.bookmarkSet(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		if slices.Contains(set, p.PostID) {
			// Already bookmarked: success before the cap check. Only the idempotency doc is
			// written, so a late retry of this key replays instead of re-adding a bookmark removed since.
			b := store.NewFirestoreTxBatch(tx)
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
		b := store.NewFirestoreTxBatch(tx)
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
		// idempotency doc first. Either way the post is bookmarked; record the key (AlreadyExists = done).
		if rerr := r.recordNoop(ctx, p.UID, p.IdemKey, rpcAddBookmark, p.RequestHash, want); rerr != nil {
			return BookmarkResult{}, rerr
		}
		return BookmarkResult{Outcome: BookmarkUnchanged, State: want}, nil
	default:
		return BookmarkResult{}, err
	}
}

// Remove implements BookmarkRepo: one transaction. It reads idempotency/{hash} (a replay returns here), then
// Delete(bookmark, Exists), Create the idempotency doc and ArrayRemove on userLikes.bookmarks. A
// missing bookmark fails the Exists precondition at commit, which rolls the whole transaction back; the key is then
// recorded on its own (recordNoop): the no-op writes only the idempotency doc, so a late retry of the
// key replays. No visibility check.
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
		b := store.NewFirestoreTxBatch(tx)
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
		// a late retry replays instead of removing a bookmark added since (one write, no extra read).
		if rerr := r.recordNoop(ctx, p.UID, p.IdemKey, rpcRemoveBookmark, p.RequestHash, want); rerr != nil {
			return BookmarkResult{}, rerr
		}
		return BookmarkResult{Outcome: BookmarkUnchanged, State: want}, nil
	default:
		return BookmarkResult{}, err
	}
}

// ListPage implements BookmarkRepo: the one bookmark query (pageBookmarks), clamped to MaxListPage. Reads: one per
// document, minimum 1; the path is built from uid, never from the request.
func (r *FirestoreRepo) ListPage(ctx context.Context, uid string, after *posts.Position, limit int) ([]ExportedBookmark, error) {
	return r.pageBookmarks(ctx, "list", uid, after, min(max(limit, 1), MaxListPage))
}

// Prune implements BookmarkRepo (the ListBlockedUsers precedent): one batch holding a blind Delete of
// each bookmark doc and one field-level update of userLikes.bookmarks (Set with MergeAll + ArrayRemove, so the
// liked and reposted sets are untouched and a missing doc is created holding only the empty set, as RemoveBookmark
// does). It is one update and a delete per id. Blind on purpose: an Exists precondition would fail the whole batch
// when a concurrent prune already deleted one row, leaving the others for the next open. Snowflake ids are never
// reused, so a pruned id cannot name a new post.
func (r *FirestoreRepo) Prune(ctx context.Context, uid string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	if len(ids) > MaxListPage {
		return fmt.Errorf("engagement: prune %d bookmarks exceeds %d", len(ids), MaxListPage)
	}
	b := store.NewFirestoreBatch(r.client)
	args := make([]any, len(ids))
	for i, id := range ids {
		b.Delete(r.bookmarkRef(uid, id))
		args[i] = id
	}
	b.Set(r.userLikesRef(uid), map[string]any{
		"bookmarks": firestore.ArrayRemove(args...), "updatedAt": r.now().UTC(),
	}, firestore.MergeAll)
	if err := b.Commit(ctx); err != nil {
		return fmt.Errorf("engagement: prune bookmarks %s: %w", logger.HashUID(uid), err)
	}
	return nil
}
