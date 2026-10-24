// moderate.go implements Moderator on FirestoreRepo (ADR-0016 D3, D4): the writes behind opsctl takedown-post,
// restore-post, suspend-user and unsuspend-user. It sets or clears posts/{id}.moderation (+ moderatedAt) and writes
// the postRemovals log entry (ADR-0016 D10, removals_firestore.go) in the same transaction or batch, nothing else:
// counters, createdAt and every other field stay, so a restore is exact.
//
// HideAuthor pages Q-E (authorId == uid ORDER BY createdAt DESC, __name__ DESC, the existing index) with a
// StartAfter position. RestoreAuthor queries (authorId == uid AND moderation == SUSPENDED_AUTHOR) with no
// ordering: equality filters only, served by the built-in single-field indexes (no firestore.indexes.json change).
package posts

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

var _ Moderator = (*FirestoreRepo)(nil)

const fieldModeration = "moderation"

// hidePage is the page of HideAuthor and RestoreAuthor: each post in it costs two batch operations (the moderation
// update and its removal-log entry), and a batch holds at most 500.
const hidePage = opsPage / 2

// Takedown implements Moderator. One transaction: 1 read, 2 writes (the post and its removal-log entry; 0 when already TAKEN_DOWN).
// A REPOST is removed instead (issue #153): the transaction only reads it (1 read), then one batch deletes the doc and
// its reposts record, decrements the original's repostCount and the reposter's postsCount and writes the REMOVED
// log entry (writes: 2 + 1 for the counters, 1 for the log entry, deletes: 2; fewer counters when the original or the
// reposter's users doc is gone). Restore of a removed REPOST is ErrNotFound: the user can repost again.
func (r *FirestoreRepo) Takedown(ctx context.Context, postID string, now time.Time) (ModerationResult, error) {
	res, row, err := r.setModerationX(ctx, postID, func(cur Moderation) (Moderation, bool) {
		return ModerationTakenDown, cur != ModerationTakenDown
	}, now, true)
	if err != nil || row == nil {
		return res, err
	}
	ok, err := r.removeOneRepostWith(ctx, *row, true, func(b store.Batch) {
		r.setRemoval(b, row.id, row.authorID, RemovalRemoved, now)
	})
	if err != nil {
		return ModerationResult{}, err
	}
	if !ok {
		return ModerationResult{}, ErrNotFound // deleted concurrently
	}
	res.After, res.RepostReleased = ModerationTakenDown, true
	return res, nil
}

// Restore implements Moderator. One transaction: 1 read, 2 writes (post + RESTORED log entry; 0 unless the post is TAKEN_DOWN).
// now is the operator's clock; it only sets the log entry's expireAt.
func (r *FirestoreRepo) Restore(ctx context.Context, postID string, now time.Time) (ModerationResult, error) {
	return r.setModeration(ctx, postID, func(cur Moderation) (Moderation, bool) {
		return ModerationNone, cur == ModerationTakenDown
	}, now)
}

func (r *FirestoreRepo) setModeration(ctx context.Context, postID string, decide func(Moderation) (Moderation, bool), now time.Time) (ModerationResult, error) {
	out, _, err := r.setModerationX(ctx, postID, decide, now, false)
	return out, err
}

// setModerationX is setModeration; with interceptRepost, a REPOST is only read and returned as a repostRow for the
// caller to remove (nothing is written in the transaction).
func (r *FirestoreRepo) setModerationX(ctx context.Context, postID string, decide func(Moderation) (Moderation, bool), now time.Time, interceptRepost bool) (ModerationResult, *repostRow, error) {
	if postID == "" {
		return ModerationResult{}, nil, ErrInvalidID
	}
	var out ModerationResult
	var repost *repostRow
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.ref(postID))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("posts: moderate get %s: %w", postID, err)
		}
		var d postDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("posts: moderate decode %s: %w", postID, err)
		}
		cur := Moderation(d.Moderation)
		out = ModerationResult{AuthorID: d.AuthorID, Before: cur, After: cur}
		repost = nil
		if interceptRepost && Kind(d.Kind) == KindRepost && d.RepostOfID != "" {
			repost = &repostRow{id: postID, authorID: d.AuthorID, originalID: d.RepostOfID}
			return nil
		}
		next, change := decide(cur)
		if !change {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.ref(postID), moderationUpdates(next, now))
		r.setRemoval(b, postID, d.AuthorID, removalStateFor(next), now)
		if err := b.Err(); err != nil {
			return err
		}
		out.After = next
		return nil
	})
	if err != nil {
		return ModerationResult{}, nil, err
	}
	return out, repost, nil
}

// removalStateFor is the log state a moderation transition to next writes: any hide is REMOVED, a clear is RESTORED.
func removalStateFor(next Moderation) RemovalState {
	if next == ModerationNone {
		return RemovalRestored
	}
	return RemovalRemoved
}

// expiryBase is the instant a log entry's retention counts from: the operator's now. A zero now (a caller that did
// not pass a clock) falls back to the wall clock rather than writing an expireAt in year 1, which Firestore's TTL
// would delete at once.
func expiryBase(now time.Time) time.Time {
	if now.IsZero() {
		return time.Now()
	}
	return now
}

// moderationUpdates is the field update for state next: set (with moderatedAt) or clear (delete both fields).
func moderationUpdates(next Moderation, now time.Time) []firestore.Update {
	if next == ModerationNone {
		return []firestore.Update{
			{Path: fieldModeration, Value: firestore.Delete},
			{Path: "moderatedAt", Value: firestore.Delete},
		}
	}
	return []firestore.Update{
		{Path: fieldModeration, Value: string(next)},
		{Path: "moderatedAt", Value: now.UTC()},
	}
}

// HideAuthor implements Moderator. One call: one query page (<= hidePage = 250 posts) and one batch for the posts
// that are still visible: each change is the moderation update plus its removal-log entry, in the same atomic batch
// (a crash cannot hide a post without logging it; a re-run skips posts that are already hidden, which are already
// logged). Reads: one per post in the page (1 for an empty page); writes: two per change.
// Each update carries the LastUpdateTime of the snapshot it was decided from, so a post that changed between the
// read and the commit (a concurrent takedown, an author delete) fails the batch instead of being overwritten; the
// caller re-runs the page. opsctl's driveLoop retries a failed call up to maxConsecutiveErrors (5) times without
// backoff, which is enough at Stage 0; once P5 likes put a counter increment on every popular post, a hot post can
// fail a whole page repeatedly and the loop will need jittered backoff (ADR-0016 notes).
func (r *FirestoreRepo) HideAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (ModerationCheckpoint, bool, error) {
	q := r.authorQuery(uid)
	if !cp.Since.IsZero() {
		q = q.Where("createdAt", ">=", cp.Since.UTC())
	}
	if cp.After != nil {
		q = q.StartAfter(cp.After.CreatedAt, r.ref(cp.After.ID))
	}
	docs, err := q.Limit(hidePage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return cp, false, fmt.Errorf("posts: hide %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	if r.moderationReadHook != nil {
		r.moderationReadHook()
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	changed := 0
	for _, s := range docs {
		var d struct {
			Moderation string `firestore:"moderation"`
		}
		if err := s.DataTo(&d); err != nil {
			return cp, false, fmt.Errorf("posts: hide decode %s: %w", s.Ref.ID, err)
		}
		if d.Moderation != "" {
			continue // already hidden (TAKEN_DOWN stays TAKEN_DOWN; SUSPENDED_AUTHOR is a re-run)
		}
		b.Update(s.Ref, moderationUpdates(ModerationSuspendedAuthor, now), firestore.LastUpdateTime(s.UpdateTime))
		r.setRemoval(b, s.Ref.ID, uid, RemovalRemoved, now)
		changed++
	}
	if changed > 0 {
		if err := b.Commit(ctx); err != nil {
			return cp, false, fmt.Errorf("posts: hide %s: %w", logger.HashUID(uid), err)
		}
	}
	last := docs[len(docs)-1]
	var ld struct {
		CreatedAt time.Time `firestore:"createdAt"`
	}
	if err := last.DataTo(&ld); err != nil {
		return cp, false, fmt.Errorf("posts: hide decode %s: %w", last.Ref.ID, err)
	}
	next := ModerationCheckpoint{Changed: cp.Changed + changed, After: &Position{CreatedAt: ld.CreatedAt.UTC(), ID: last.Ref.ID}}
	slog.InfoContext(ctx, "posts_hide_batch", "uid_hash", logger.HashUID(uid), "paged", len(docs), "hidden", changed, "hidden_total", next.Changed)
	return next, len(docs) < hidePage, nil
}

// RestoreAuthor implements Moderator. Reads one per post returned (1 for an empty page), writes two per post (update + RESTORED log entry, same batch).
func (r *FirestoreRepo) RestoreAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (ModerationCheckpoint, bool, error) {
	docs, err := r.client.Collection(postsCollection).
		Where("authorId", "==", uid).
		Where(fieldModeration, "==", string(ModerationSuspendedAuthor)).
		Select().Limit(hidePage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return cp, false, fmt.Errorf("posts: restore %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	if r.moderationReadHook != nil {
		r.moderationReadHook()
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, s := range docs {
		// Select() keeps UpdateTime, so a post a moderator took down meanwhile fails the batch (and is re-read).
		b.Update(s.Ref, moderationUpdates(ModerationNone, now), firestore.LastUpdateTime(s.UpdateTime))
		r.setRemoval(b, s.Ref.ID, uid, RemovalRestored, now)
	}
	if err := b.Commit(ctx); err != nil {
		return cp, false, fmt.Errorf("posts: restore %s: %w", logger.HashUID(uid), err)
	}
	next := ModerationCheckpoint{Changed: cp.Changed + len(docs)}
	slog.InfoContext(ctx, "posts_restore_batch", "uid_hash", logger.HashUID(uid), "restored", len(docs), "restored_total", next.Changed)
	return next, len(docs) < hidePage, nil
}
