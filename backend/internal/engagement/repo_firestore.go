// repo_firestore.go is the Firestore implementation of Repo (ADR-0018 D2, D3). Collections owned here:
// likes/{postId}_{uid}, reposts/{postId}_{uid} and userLikes/{uid} (bookmarks: repo_bookmarks.go). Every write that touches another module's
// document goes through that module's seam (posts.EngagementWriter, identity.Counters), appended to the batch or
// transaction this file commits.
//
// No query here has an ordering or a composite index: the like and repost docs are addressed by id.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	likesCollection     = "likes"
	repostsCollection   = "reposts"
	userLikesCollection = "userLikes"

	// txTimeout bounds one like/repost transaction (all attempts), like posts' createTxTimeout.
	txTimeout = 5 * time.Second
	// trimTimeout bounds the best-effort userLikes trim, which runs on a context detached from the request.
	trimTimeout = 2 * time.Second
	// maxTxRuns bounds the outer re-runs after the SDK's own attempts lost the lock race (a hot post, or ten
	// concurrent calls of one user): jittered, so concurrent callers de-synchronise.
	maxTxRuns          = 4
	txBackoff          = 20 * time.Millisecond
	maxBatchAttempts   = 4
	batchRetryBackoff  = 25 * time.Millisecond
	maxIDCollisionRuns = 2
)

// IDGenerator draws REPOST post ids (*snowflake.Node).
type IDGenerator interface{ Generate() string }

// WriteDeps are the collaborators of the write paths.
type WriteDeps struct {
	Quotas   *quota.Store
	Writer   posts.EngagementWriter
	Counters identity.Counters
	IDs      IDGenerator
	// Idempotency stores the idempotency docs of AddBookmark and RemoveBookmark (ADR-0023 D4); only they use it.
	Idempotency *idempotency.Store
}

// FirestoreRepo implements Repo (and Eraser, Exporter, the job's queries) against the shared client.
type FirestoreRepo struct {
	client *firestore.Client
	w      WriteDeps
	now    func() time.Time
	// Test seams for the batch retry loop; nil means the real commit and jittered wait.
	commitBatch func(ctx context.Context, b *store.FirestoreBatch) error
	backoff     func(ctx context.Context, ceiling time.Duration) error
}

// NewFirestoreRepo builds the repo.
func NewFirestoreRepo(client *firestore.Client, w WriteDeps) *FirestoreRepo {
	return &FirestoreRepo{client: client, w: w, now: time.Now}
}

var _ Repo = (*FirestoreRepo)(nil)

type likeDoc struct {
	PostID    string    `firestore:"postId"`
	UID       string    `firestore:"uid"`
	CreatedAt time.Time `firestore:"createdAt"`
}

type repostDoc struct {
	PostID       string    `firestore:"postId"`
	UID          string    `firestore:"uid"`
	RepostPostID string    `firestore:"repostPostId"`
	CreatedAt    time.Time `firestore:"createdAt"`
}

type userLikesDoc struct {
	Recent        []string `firestore:"recent"`
	RecentReposts []string `firestore:"recentReposts"`
	// Bookmarks is the complete bookmark set (ADR-0023 D3). Only repo_bookmarks.go writes it, always field-level.
	Bookmarks []string `firestore:"bookmarks"`
}

func docID(postID, uid string) string { return postID + "_" + uid }

func (r *FirestoreRepo) likeRef(postID, uid string) *firestore.DocumentRef {
	return r.client.Collection(likesCollection).Doc(docID(postID, uid))
}

func (r *FirestoreRepo) repostRef(postID, uid string) *firestore.DocumentRef {
	return r.client.Collection(repostsCollection).Doc(docID(postID, uid))
}

func (r *FirestoreRepo) userLikesRef(uid string) *firestore.DocumentRef {
	return r.client.Collection(userLikesCollection).Doc(uid)
}

func (r *FirestoreRepo) ready() error {
	if r.w.Quotas == nil || r.w.Writer == nil || r.w.Counters == nil || r.w.IDs == nil {
		return errors.New("engagement: repo has no writers configured")
	}
	return nil
}

// LoadUserLikes implements Repo. Reads 1.
func (r *FirestoreRepo) LoadUserLikes(ctx context.Context, uid string) (UserLikes, error) {
	snap, err := r.userLikesRef(uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return UserLikes{}, nil
		}
		return UserLikes{}, fmt.Errorf("engagement: get userLikes: %w", err)
	}
	var d userLikesDoc
	if err := snap.DataTo(&d); err != nil {
		return UserLikes{}, fmt.Errorf("engagement: decode userLikes: %w", err)
	}
	return UserLikes(d), nil
}

// runTx runs fn in a transaction with correct budget accounting, re-running it a bounded number of times when
// Firestore reports contention (Aborted) after its own attempts. It returns the number of body runs.
func (r *FirestoreRepo) runTx(ctx context.Context, fn store.TxnFunc) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	total := 0
	var err error
	for run := 0; run < maxTxRuns; run++ {
		if run > 0 {
			if werr := store.Wait(ctx, txBackoff<<(run-1)); werr != nil {
				return total, werr
			}
		}
		var n int
		n, err = store.RunTransaction(ctx, r.client, fn)
		total += n
		if !store.IsContention(err) {
			break
		}
	}
	return total, err
}

// Like implements Repo: one transaction, 1 read (quotas) and 4 writes (like doc, likeCount, userLikes, quota).
func (r *FirestoreRepo) Like(ctx context.Context, p LikeParams) (bool, error) {
	if err := r.ready(); err != nil {
		return false, err
	}
	attempts, err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		rec, err := r.w.Quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("engagement: quota lookup: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.UID), rec, quota.Likes, p.QuotaLimit); err != nil {
			return err
		}
		now := r.now().UTC()
		b.Create(r.likeRef(p.PostID, p.UID), likeDoc{PostID: p.PostID, UID: p.UID, CreatedAt: now})
		r.w.Writer.StageLikeCount(b, p.PostID, 1)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"recent": firestore.ArrayUnion(p.PostID), "updatedAt": now,
		}, firestore.MergeAll)
		return b.Err()
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	switch status.Code(err) {
	case codes.OK:
		return false, nil
	case codes.AlreadyExists:
		return true, nil // the like exists: a replay, nothing was written
	case codes.NotFound:
		return false, ErrPostGone // the Update of likeCount found no post
	default:
		return false, err
	}
}

func (r *FirestoreRepo) newBatch(c *budget.Counter) *store.FirestoreBatch {
	return store.NewFirestoreBatch(r.client, c)
}

func (r *FirestoreRepo) retryConfig() store.RetryConfig {
	return store.RetryConfig{MaxAttempts: maxBatchAttempts, Backoff: batchRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff}
}

// Unlike implements Repo: one blind batch (Delete with Exists, likeCount -1, ArrayRemove). A failed
// precondition is ambiguous (the like is absent, or the post is gone), so it is retried once without the
// counter; failing again is the correct 0-write no-op.
func (r *FirestoreRepo) Unlike(ctx context.Context, uid, postID string) (bool, error) {
	if err := r.ready(); err != nil {
		return false, err
	}
	remove := func(b store.Batch) {
		b.Set(r.userLikesRef(uid), map[string]any{
			"recent": firestore.ArrayRemove(postID), "updatedAt": r.now().UTC(),
		}, firestore.MergeAll)
	}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Delete(r.likeRef(postID, uid), firestore.Exists)
		r.w.Writer.StageLikeCount(b, postID, -1)
		remove(b)
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
	if err != nil {
		return false, fmt.Errorf("engagement: unlike: %w", err)
	}
	if res.Committed {
		return true, nil
	}
	res, err = store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Delete(r.likeRef(postID, uid), firestore.Exists)
		remove(b)
	})
	if err != nil {
		return false, fmt.Errorf("engagement: unlike (post gone): %w", err)
	}
	return res.Committed, nil
}

// Repost implements Repo: one transaction, 1 read (quotas) and 6 writes (reposts doc, REPOST post, repostCount,
// postsCount, userLikes, quota). The REPOST id is drawn inside every attempt (the settle watermark, ADR-0010 D13).
func (r *FirestoreRepo) Repost(ctx context.Context, p RepostParams) (RepostResult, error) {
	if err := r.ready(); err != nil {
		return RepostResult{}, err
	}
	var err error
	for try := 0; try <= maxIDCollisionRuns; try++ {
		var post *posts.Post
		var attempts int
		attempts, err = r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
			post = nil
			rec, err := r.w.Quotas.Get(ctx, tx, p.UID)
			if err != nil {
				return fmt.Errorf("engagement: quota lookup: %w", err)
			}
			id := r.w.IDs.Generate()
			createdAt, err := snowflake.Time(id)
			if err != nil {
				return fmt.Errorf("engagement: %w", err)
			}
			np := posts.NewRepostPost(id, createdAt, p.Author, p.SnapshotVersion, p.Original)
			b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
			if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.UID), rec, quota.Posts, p.QuotaLimit); err != nil {
				return err
			}
			b.Create(r.repostRef(p.Original.ID, p.UID), repostDoc{PostID: p.Original.ID, UID: p.UID, RepostPostID: id, CreatedAt: createdAt.UTC()})
			r.w.Writer.StageRepost(b, np)
			r.w.Writer.StageRepostCount(b, p.Original.ID, 1)
			r.w.Counters.AddPostsCount(b, p.UID, 1)
			b.Set(r.userLikesRef(p.UID), map[string]any{
				"recentReposts": firestore.ArrayUnion(p.Original.ID), "updatedAt": createdAt.UTC(),
			}, firestore.MergeAll)
			if err := b.Err(); err != nil {
				return err
			}
			post = np
			return nil
		})
		store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
		switch status.Code(err) {
		case codes.OK:
			return RepostResult{Post: post}, nil
		case codes.NotFound:
			return RepostResult{}, ErrPostGone
		case codes.AlreadyExists:
			// Either the reposts doc exists (a replay: return the repost it points to) or the drawn REPOST id
			// collided (practically never: draw again).
			snap, gerr := r.repostRef(p.Original.ID, p.UID).Get(ctx)
			budget.FromContext(ctx).AddReads(1)
			if gerr == nil {
				var d repostDoc
				if derr := snap.DataTo(&d); derr != nil {
					return RepostResult{}, fmt.Errorf("engagement: decode repost: %w", derr)
				}
				return RepostResult{ReplayPostID: d.RepostPostID}, nil
			}
			if status.Code(gerr) != codes.NotFound {
				return RepostResult{}, fmt.Errorf("engagement: get repost: %w", gerr)
			}
			continue
		default:
			return RepostResult{}, err
		}
	}
	return RepostResult{}, fmt.Errorf("engagement: repost id collided %d times: %w", maxIDCollisionRuns+1, err)
}

// UndoRepost implements Repo: 1 read of reposts/{id}, then one batch (3 writes, 2 deletes). The reposts doc's
// Exists precondition is the batch's only guard; the REPOST post is deleted blind.
func (r *FirestoreRepo) UndoRepost(ctx context.Context, uid, originalID string) (UndoResult, error) {
	if err := r.ready(); err != nil {
		return UndoResult{}, err
	}
	snap, err := r.repostRef(originalID, uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return UndoResult{}, nil
		}
		return UndoResult{}, fmt.Errorf("engagement: get repost: %w", err)
	}
	var d repostDoc
	if err := snap.DataTo(&d); err != nil {
		return UndoResult{}, fmt.Errorf("engagement: decode repost: %w", err)
	}
	run := func(withCount bool) (bool, error) {
		res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
			b.Delete(r.repostRef(originalID, uid), firestore.Exists)
			r.w.Writer.StageDelete(b, d.RepostPostID, false)
			if withCount {
				r.w.Writer.StageRepostCount(b, originalID, -1)
			}
			r.w.Counters.AddPostsCount(b, uid, -1)
			b.Set(r.userLikesRef(uid), map[string]any{
				"recentReposts": firestore.ArrayRemove(originalID), "updatedAt": r.now().UTC(),
			}, firestore.MergeAll)
		})
		store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
		return res.Committed, err
	}
	ok, err := run(true)
	if err != nil {
		return UndoResult{}, fmt.Errorf("engagement: undo repost: %w", err)
	}
	if !ok {
		// Ambiguous: a concurrent undo won, or the original is gone. Retry without its counter.
		if ok, err = run(false); err != nil {
			return UndoResult{}, fmt.Errorf("engagement: undo repost (original gone): %w", err)
		}
	}
	return UndoResult{Removed: ok, RepostPostID: d.RepostPostID}, nil
}

// TrimLikes implements Repo: one write, no read (D8).
func (r *FirestoreRepo) TrimLikes(ctx context.Context, uid string, recent, reposts []string) error {
	upd := map[string]any{"updatedAt": r.now().UTC()}
	if len(recent) > 0 {
		upd["recent"] = firestore.ArrayRemove(toAny(recent)...)
	}
	if len(reposts) > 0 {
		upd["recentReposts"] = firestore.ArrayRemove(toAny(reposts)...)
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	b.Set(r.userLikesRef(uid), upd, firestore.MergeAll)
	if err := b.Commit(ctx); err != nil {
		return fmt.Errorf("engagement: trim userLikes: %w", err)
	}
	return nil
}

func toAny(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

// StageRelease appends the blind delete of reposts/{originalID}_{uid} to a DeletePost batch (posts.RepostLinks).
func (r *FirestoreRepo) StageRelease(b store.Batch, originalID, uid string) {
	b.Delete(r.repostRef(originalID, uid))
}

// release is the post-commit half of DeletePost(REPOST): repostCount -1 on the original and ArrayRemove on
// userLikes.recentReposts in one batch. An original that is gone fails the batch with NotFound, so the
// userLikes part is retried alone. Best effort: the caller logs a failure.
func (r *FirestoreRepo) release(ctx context.Context, originalID, uid string) error {
	if err := r.ready(); err != nil {
		return err
	}
	upd := map[string]any{"recentReposts": firestore.ArrayRemove(originalID), "updatedAt": r.now().UTC()}
	for _, withCount := range []bool{true, false} {
		b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
		if withCount {
			r.w.Writer.StageRepostCount(b, originalID, -1)
		}
		b.Set(r.userLikesRef(uid), upd, firestore.MergeAll)
		err := b.Commit(ctx)
		if err == nil {
			return nil
		}
		if !withCount || status.Code(err) != codes.NotFound {
			return fmt.Errorf("engagement: release repost: %w", err)
		}
	}
	return nil
}
