// moderate.go implements Moderator on FirestoreRepo (ADR-0016 D3, D4): the writes behind opsctl takedown-post,
// restore-post, suspend-user and unsuspend-user. It sets or clears posts/{id}.moderation (+ moderatedAt) and
// nothing else: counters, createdAt and every other field stay, so a restore is exact.
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

// Takedown implements Moderator. One transaction: 1 read, 1 write (0 when already TAKEN_DOWN).
func (r *FirestoreRepo) Takedown(ctx context.Context, postID string, now time.Time) (ModerationResult, error) {
	return r.setModeration(ctx, postID, func(cur Moderation) (Moderation, bool) {
		return ModerationTakenDown, cur != ModerationTakenDown
	}, now)
}

// Restore implements Moderator. One transaction: 1 read, 1 write (0 unless the post is TAKEN_DOWN).
func (r *FirestoreRepo) Restore(ctx context.Context, postID string) (ModerationResult, error) {
	return r.setModeration(ctx, postID, func(cur Moderation) (Moderation, bool) {
		return ModerationNone, cur == ModerationTakenDown
	}, time.Time{})
}

func (r *FirestoreRepo) setModeration(ctx context.Context, postID string, decide func(Moderation) (Moderation, bool), now time.Time) (ModerationResult, error) {
	if postID == "" {
		return ModerationResult{}, ErrInvalidID
	}
	var out ModerationResult
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
		next, change := decide(cur)
		out = ModerationResult{AuthorID: d.AuthorID, Before: cur, After: cur}
		if !change {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.ref(postID), moderationUpdates(next, now))
		if err := b.Err(); err != nil {
			return err
		}
		out.After = next
		return nil
	})
	if err != nil {
		return ModerationResult{}, err
	}
	return out, nil
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

// HideAuthor implements Moderator. One call: one query page (<= opsPage posts) and one batch of updates for the
// posts that are still visible. Reads: one per post in the page (1 for an empty page); writes: one per change.
func (r *FirestoreRepo) HideAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (ModerationCheckpoint, bool, error) {
	q := r.authorQuery(uid)
	if cp.After != nil {
		q = q.StartAfter(cp.After.CreatedAt, r.ref(cp.After.ID))
	}
	docs, err := q.Limit(opsPage).Documents(ctx).GetAll()
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
		b.Update(s.Ref, moderationUpdates(ModerationSuspendedAuthor, now))
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
	return next, len(docs) < opsPage, nil
}

// RestoreAuthor implements Moderator. Reads one per post returned (1 for an empty page), writes one per post.
func (r *FirestoreRepo) RestoreAuthor(ctx context.Context, uid string, cp ModerationCheckpoint) (ModerationCheckpoint, bool, error) {
	docs, err := r.client.Collection(postsCollection).
		Where("authorId", "==", uid).
		Where(fieldModeration, "==", string(ModerationSuspendedAuthor)).
		Select().Limit(opsPage).Documents(ctx).GetAll()
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
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, s := range docs {
		b.Update(s.Ref, moderationUpdates(ModerationNone, time.Time{}))
	}
	if err := b.Commit(ctx); err != nil {
		return cp, false, fmt.Errorf("posts: restore %s: %w", logger.HashUID(uid), err)
	}
	next := ModerationCheckpoint{Changed: cp.Changed + len(docs)}
	slog.InfoContext(ctx, "posts_restore_batch", "uid_hash", logger.HashUID(uid), "restored", len(docs), "restored_total", next.Changed)
	return next, len(docs) < opsPage, nil
}
