// repo_firestore.go is the Firestore implementation of Repo. Collections owned here:
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
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
	Writer   posts.EngagementWriter
	Counters identity.Counters
	IDs      IDGenerator
	// Idempotency stores the idempotency docs of AddBookmark and RemoveBookmark; only they use it.
	Idempotency *idempotency.Store
	// Views stages a view's shard increment and rollup marker (posts owns them); only RecordImpressions uses it.
	Views posts.ViewWriter
	// Stats stages the post author's creator stats (F2, identity owns users/{uid}/dailyStats): +1 engagement per like or
	// repost received on the cold path, -1 per undo, in the same unit of work as the counter. Nil stages nothing.
	Stats identity.StatsWriter
}

// stageEngagementStat stages delta on author's engagements for today when the counter write took the cold path (a
// hot write's engagement is staged by the counter rollup when it folds the shard, never here too) and the actor is
// not the author. It must share the unit of work of the counter's Exists-preconditioned Update (identity.StatsWriter).
func (r *FirestoreRepo) stageEngagementStat(b store.Batch, author, actor string, delta, known int64) {
	if r.w.Stats == nil || author == "" || author == actor || r.w.Writer.Hot(known) {
		return
	}
	// The actor's uid picks the author day's shard, so a like and its unlike land on the same doc.
	r.w.Stats.StageDaily(b, author, identity.StatsDay(r.now()), actor, identity.DailyDelta{Engagements: delta})
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
	// Bookmarks is the complete bookmark set. Only repo_bookmarks.go writes it, always field-level.
	Bookmarks []string `firestore:"bookmarks"`
	// PollVotes is the viewer's poll choices, absent on documents written before polls.
	PollVotes []string `firestore:"pollVotes"`
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
	if r.w.Writer == nil || r.w.Counters == nil || r.w.IDs == nil {
		return errors.New("engagement: repo has no writers configured")
	}
	return nil
}

// LoadUserLikes implements Repo.
func (r *FirestoreRepo) LoadUserLikes(ctx context.Context, uid string) (UserLikes, error) {
	snap, err := r.userLikesRef(uid).Get(ctx)
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

// runTx runs fn in a transaction, re-running it a bounded number of times when
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

// Like implements Repo: one transaction that writes the like doc, likeCount and userLikes. On a hot post
// (p.Known at or above HOT_COUNTER_THRESHOLD) the count goes to the post's shards, which carry no precondition, so the
// transaction first reads the post (GuardHot): a post that is gone is still ErrPostGone with nothing written.
func (r *FirestoreRepo) Like(ctx context.Context, p LikeParams) (bool, error) {
	if err := r.ready(); err != nil {
		return false, err
	}
	var committed func()
	attempts, err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		committed = nil
		if err := r.w.Writer.GuardHot(tx, p.PostID, p.Known); err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		now := r.now().UTC()
		b.Create(r.likeRef(p.PostID, p.UID), likeDoc{PostID: p.PostID, UID: p.UID, CreatedAt: now})
		done := r.w.Writer.StageLikeCount(b, p.PostID, 1, p.Known)
		r.stageEngagementStat(b, p.AuthorID, p.UID, 1, p.Known)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"recent": firestore.ArrayUnion(p.PostID), "updatedAt": now,
		}, firestore.MergeAll)
		if err := b.Err(); err != nil {
			return err
		}
		committed = done
		return nil
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	if errors.Is(err, posts.ErrNotFound) {
		return false, ErrPostGone // the hot path's read found no post
	}
	switch status.Code(err) {
	case codes.OK:
		committed()
		return false, nil
	case codes.AlreadyExists:
		return true, nil // the like exists: a replay, nothing was written
	case codes.NotFound:
		return false, ErrPostGone // the Update of likeCount found no post
	default:
		return false, err
	}
}

func (r *FirestoreRepo) newBatch() *store.FirestoreBatch {
	return store.NewFirestoreBatch(r.client)
}

func (r *FirestoreRepo) retryConfig() store.RetryConfig {
	return store.RetryConfig{MaxAttempts: maxBatchAttempts, Backoff: batchRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff}
}

// Unlike implements Repo: one blind batch (Delete with Exists, likeCount -1, ArrayRemove). A failed
// precondition is ambiguous (the like is absent, or the post is gone), so it is retried once without the
// counter; failing again is the correct 0-write no-op. On a hot post (known) the -1 is a shard write with no
// precondition, so the like's Exists is the batch's only one: a failure means the like is absent, the retry fails the
// same way (the 0-write no-op). A hot unlike of a post that is gone still commits: the like is deleted, and a shard -1
// plus a counter marker are written under the gone post; the next rollup tick finds the post gone through that marker
// and deletes its shards (the gone path), so nothing is left behind.
//
// authorID is the post's author ("" when it was not found): their engagements for today move by -1 with the counter,
// and the retry without the counter drops the stat too.
func (r *FirestoreRepo) Unlike(ctx context.Context, uid, postID string, known int64, authorID string) (bool, error) {
	if err := r.ready(); err != nil {
		return false, err
	}
	remove := func(b store.Batch) {
		b.Set(r.userLikesRef(uid), map[string]any{
			"recent": firestore.ArrayRemove(postID), "updatedAt": r.now().UTC(),
		}, firestore.MergeAll)
	}
	committed := func() {}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Delete(r.likeRef(postID, uid), firestore.Exists)
		committed = r.w.Writer.StageLikeCount(b, postID, -1, known)
		r.stageEngagementStat(b, authorID, uid, -1, known)
		remove(b)
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
	if err != nil {
		return false, fmt.Errorf("engagement: unlike: %w", err)
	}
	if res.Committed {
		committed()
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

// Repost implements Repo: one transaction that writes the reposts doc, REPOST post, repostCount,
// postsCount and userLikes. The REPOST id is drawn inside every attempt (the settle watermark).
func (r *FirestoreRepo) Repost(ctx context.Context, p RepostParams) (RepostResult, error) {
	if err := r.ready(); err != nil {
		return RepostResult{}, err
	}
	var err error
	for try := 0; try <= maxIDCollisionRuns; try++ {
		var post *posts.Post
		var committed func()
		var attempts int
		attempts, err = r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
			post, committed = nil, nil
			id := r.w.IDs.Generate()
			createdAt, err := snowflake.Time(id)
			if err != nil {
				return fmt.Errorf("engagement: %w", err)
			}
			np := posts.NewRepostPost(id, createdAt, p.Author, p.SnapshotVersion, p.Original)
			// A hot original's repostCount goes to its shards: read it first (before any write) so a gone one is
			// still ErrPostGone with nothing written.
			if err := r.w.Writer.GuardHot(tx, p.Original.ID, p.Original.RepostCount); err != nil {
				return err
			}
			b := store.NewFirestoreTxBatch(tx)
			b.Create(r.repostRef(p.Original.ID, p.UID), repostDoc{PostID: p.Original.ID, UID: p.UID, RepostPostID: id, CreatedAt: createdAt.UTC()})
			r.w.Writer.StageRepost(b, np)
			done := r.w.Writer.StageRepostCount(b, p.Original.ID, 1, p.Original.RepostCount)
			r.stageEngagementStat(b, p.Original.AuthorID, p.UID, 1, p.Original.RepostCount)
			r.w.Counters.AddPostsCount(b, p.UID, 1)
			b.Set(r.userLikesRef(p.UID), map[string]any{
				"recentReposts": firestore.ArrayUnion(p.Original.ID), "updatedAt": createdAt.UTC(),
			}, firestore.MergeAll)
			if err := b.Err(); err != nil {
				return err
			}
			post, committed = np, done
			return nil
		})
		store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
		if errors.Is(err, posts.ErrNotFound) {
			return RepostResult{}, ErrPostGone
		}
		switch status.Code(err) {
		case codes.OK:
			committed()
			return RepostResult{Post: post}, nil
		case codes.NotFound:
			return RepostResult{}, ErrPostGone
		case codes.AlreadyExists:
			// Either the reposts doc exists (a replay: return the repost it points to) or the drawn REPOST id
			// collided (practically never: draw again).
			snap, gerr := r.repostRef(p.Original.ID, p.UID).Get(ctx)
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

// UndoRepost implements Repo: it reads reposts/{id}, then commits one batch. The reposts doc's
// Exists precondition is the batch's only guard; the REPOST post is deleted blind. authorID is the original's author
// ("" when it was not found): their engagements for today move by -1 with the repostCount, never in the retry without it.
func (r *FirestoreRepo) UndoRepost(ctx context.Context, uid, originalID, authorID string) (UndoResult, error) {
	if err := r.ready(); err != nil {
		return UndoResult{}, err
	}
	snap, err := r.repostRef(originalID, uid).Get(ctx)
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
				r.w.Writer.StageRepostCount(b, originalID, -1, 0) // cold: no count was read (repost removals stay plain)
				r.stageEngagementStat(b, authorID, uid, -1, 0)
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
	b := store.NewFirestoreBatch(r.client)
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
		b := store.NewFirestoreBatch(r.client)
		if withCount {
			r.w.Writer.StageRepostCount(b, originalID, -1, 0) // cold: a release reads no count
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
