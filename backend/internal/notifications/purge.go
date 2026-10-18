// purge.go implements Eraser and Exporter on FirestoreRepo (ADR-0017 D10): the right-to-delete and
// right-to-access paths for users/{uid}/notifications, users/{uid}/devices and deviceTokens.
package notifications

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// opsPage is the ops page size and the batch bound (Firestore's 500 writes). CLAUDE.md rule 5's maximum of 50
// governs RPC pagination only (the same reading as posts/purge.go).
const opsPage = 500

// Contention retry for one purge batch (store.CommitWithRetry).
const (
	purgeCommitAttempts = 3
	purgeCommitBackoff  = 50 * time.Millisecond
)

// Exporter writes one user's notification data as the manual data export (ADR-0003 "Deletes & privacy").
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

// PurgeUser implements Eraser. One call does one bounded unit of work and returns the next step:
//
//	step 0: the user's devices and their deviceTokens docs (<= MaxDevicesPerUser, one call);
//	step 1: the user's own notification rows, a page of <= 500 per call;
//	step 2: rows in other users' lists that name the user in actorIds (collection-group array-contains query,
//	        needs the notifications.actorIds COLLECTION_GROUP index override), a page of <= 500 per call. A row
//	        the user is the only actor of is deleted; a collapsed row with other actors keeps them (ArrayRemove,
//	        actorCount decremented) and, when the user was the displayed actor, is repointed at the newest
//	        remaining actor (one Directory.GetProfiles per page; deleted instead when that actor is gone or no
//	        Directory is wired).
//
// Updated and deleted documents drop out of the next page, so every step is self-resuming after a crash. Reads:
// one per document returned (1 for an empty page), plus one per device for its token index, plus the
// GetProfiles cache misses of a step 2 page; deletes: one per deleted document, writes one per repointed row.
func (r *FirestoreRepo) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	switch cp.Step {
	case 0:
		return r.purgeDevices(ctx, uid, cp)
	case 1:
		return r.withRaceRetry(ctx, uid, cp, r.purgeOwnRows)
	case 2:
		return r.withRaceRetry(ctx, uid, cp, r.purgeActorRows)
	default:
		return cp, false, fmt.Errorf("notifications: purge: unknown checkpoint step %d", cp.Step)
	}
}

// errPurgeRaced reports a batch whose preconditions lost a race with a concurrent writer.
var errPurgeRaced = errors.New("notifications: purge: precondition lost a race")

// withRaceRetry runs one purge step; when its batch loses a precondition race it re-queries and retries once
// inline (graph/purge.go pattern), then returns an error so the job's step-error budget and backoff apply
// instead of an unbounded immediate re-run that burns reads.
func (r *FirestoreRepo) withRaceRetry(ctx context.Context, uid string, cp Checkpoint,
	step func(context.Context, string, Checkpoint) (Checkpoint, bool, error)) (Checkpoint, bool, error) {
	next, done, err := step(ctx, uid, cp)
	if !errors.Is(err, errPurgeRaced) {
		return next, done, err
	}
	next, done, err = step(ctx, uid, cp)
	if errors.Is(err, errPurgeRaced) {
		return cp, false, fmt.Errorf("notifications: purge %s step %d: rows kept changing: %w", logger.HashUID(uid), cp.Step, err)
	}
	return next, done, err
}

// purgeOwnRows is step 1: a page of the user's own notification rows.
func (r *FirestoreRepo) purgeOwnRows(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	counter := budget.FromContext(ctx)
	docs, err := r.notifications(uid).Select().Limit(opsPage).Documents(ctx).GetAll()
	counter.AddQueryReads(len(docs))
	if err != nil {
		return cp, false, fmt.Errorf("notifications: purge %s step 1: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) > 0 {
		committed, err := r.commitPurge(ctx, func(b store.Batch) {
			for _, d := range docs {
				b.Delete(d.Ref)
			}
		})
		if err != nil {
			return cp, false, fmt.Errorf("notifications: purge %s step 1: %w", logger.HashUID(uid), err)
		}
		if !committed {
			return cp, false, errPurgeRaced // a precondition lost a race; withRaceRetry re-queries once
		}
	}
	next := Checkpoint{Step: 1, Deleted: cp.Deleted + len(docs)}
	slog.InfoContext(ctx, "notifications_purge_batch", "uid_hash", logger.HashUID(uid), "step", 1, "docs", len(docs), "deleted_total", next.Deleted)
	if len(docs) < opsPage {
		next.Step = 2
	}
	return next, false, nil
}

// purgeActorRows is step 2: rows in other users' lists that name uid in actorIds.
func (r *FirestoreRepo) purgeActorRows(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	counter := budget.FromContext(ctx)
	docs, err := r.client.CollectionGroup(notificationsCollection).Where("actorIds", "array-contains", uid).
		Select("actorIds", "actor.userId", "actorCount").Limit(opsPage).Documents(ctx).GetAll()
	counter.AddQueryReads(len(docs))
	if err != nil {
		return cp, false, fmt.Errorf("notifications: purge %s step 2: query: %w", logger.HashUID(uid), err)
	}
	type fold struct {
		snap   *firestore.DocumentSnapshot
		doc    notificationDoc
		remain []string
	}
	var folds []fold
	var deletes []*firestore.DocumentSnapshot
	for _, s := range docs {
		var d notificationDoc
		if err := s.DataTo(&d); err != nil {
			return cp, false, fmt.Errorf("notifications: purge %s step 2: decode: %w", logger.HashUID(uid), err)
		}
		remain := make([]string, 0, len(d.ActorIDs))
		for _, id := range d.ActorIDs {
			if id != uid {
				remain = append(remain, id)
			}
		}
		if len(remain) == 0 {
			deletes = append(deletes, s)
			continue
		}
		folds = append(folds, fold{snap: s, doc: d, remain: remain})
	}
	// One lookup for the replacement display actors of the whole page (cache first).
	var profiles map[string]identity.Profile
	if r.dir != nil {
		var need []string
		seen := map[string]bool{}
		for _, f := range folds {
			if f.doc.Actor.UserID == uid {
				if n := f.remain[len(f.remain)-1]; !seen[n] {
					seen[n] = true
					need = append(need, n)
				}
			}
		}
		if len(need) > 0 {
			if profiles, err = r.dir.GetProfiles(ctx, need); err != nil {
				return cp, false, fmt.Errorf("notifications: purge %s step 2: profiles: %w", logger.HashUID(uid), err)
			}
		}
	}
	// Every write is conditioned on the update time the query saw: a concurrent AddActor (a like folding in)
	// makes the commit fail its precondition instead of clobbering it. The step is retried once from a fresh
	// query; a second loss is an error so the job's step-error budget and backoff apply.
	// CommitWithRetry counts writes only for the attempt that commits.
	if len(docs) > 0 {
		committed, err := r.commitPurge(ctx, func(b store.Batch) {
			for _, d := range deletes {
				b.Delete(d.Ref, firestore.LastUpdateTime(d.UpdateTime))
			}
			for _, f := range folds {
				ups := []firestore.Update{{Path: "actorIds", Value: firestore.ArrayRemove(uid)}}
				if f.doc.ActorCount > 0 {
					ups = append(ups, firestore.Update{Path: "actorCount", Value: firestore.Increment(-1)})
				} else {
					ups = append(ups, firestore.Update{Path: "actorCount", Value: len(f.remain)})
				}
				if f.doc.Actor.UserID == uid {
					p, ok := profiles[f.remain[len(f.remain)-1]]
					if !ok {
						b.Delete(f.snap.Ref, firestore.LastUpdateTime(f.snap.UpdateTime)) // the newest remaining actor is gone too (or no Directory): no one to show
						continue
					}
					ups = append(ups, firestore.Update{Path: "actor", Value: toActorDoc(actorFromProfile(p))})
				}
				b.Update(f.snap.Ref, ups, firestore.LastUpdateTime(f.snap.UpdateTime))
			}
		})
		if err != nil {
			return cp, false, fmt.Errorf("notifications: purge %s step 2: %w", logger.HashUID(uid), err)
		}
		if !committed {
			return cp, false, errPurgeRaced
		}
	}
	next := Checkpoint{Step: 2, Deleted: cp.Deleted + len(docs)}
	slog.InfoContext(ctx, "notifications_purge_batch", "uid_hash", logger.HashUID(uid), "step", 2, "docs", len(docs), "deleted_total", next.Deleted)
	return next, len(docs) < opsPage, nil
}

// commitPurge builds and commits one purge batch with store.CommitWithRetry: bounded jittered retry on
// contention, writes counted only for the committing attempt, committed=false (nil error) when a precondition
// failed.
func (r *FirestoreRepo) commitPurge(ctx context.Context, build func(store.Batch)) (bool, error) {
	res, err := store.CommitWithRetry(ctx,
		func(c *budget.Counter) *store.FirestoreBatch { return store.NewFirestoreBatch(r.client, c) },
		store.RetryConfig{MaxAttempts: purgeCommitAttempts, Backoff: purgeCommitBackoff},
		build)
	return res.Committed, err
}

func (r *FirestoreRepo) purgeDevices(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	counter := budget.FromContext(ctx)
	docs, err := r.devices(uid).Limit(opsPage).Documents(ctx).GetAll()
	counter.AddQueryReads(len(docs))
	if err != nil {
		return cp, false, fmt.Errorf("notifications: purge %s devices: query: %w", logger.HashUID(uid), err)
	}
	b := store.NewFirestoreBatch(r.client, counter)
	if len(docs) > 0 {
		idxRefs := make([]*firestore.DocumentRef, 0, len(docs))
		for _, s := range docs {
			var d deviceDoc
			if err := s.DataTo(&d); err == nil && d.Token != "" {
				idxRefs = append(idxRefs, r.tokenRef(d.Token))
			}
		}
		if len(idxRefs) > 0 {
			snaps, err := r.client.GetAll(ctx, idxRefs)
			counter.AddReads(int64(len(idxRefs)))
			if err != nil {
				return cp, false, fmt.Errorf("notifications: purge %s devices: token index: %w", logger.HashUID(uid), err)
			}
			for _, s := range snaps {
				if !s.Exists() {
					continue
				}
				var idx tokenIndexDoc
				// Only the index entries this user owns: a token another account took over is theirs now.
				if err := s.DataTo(&idx); err == nil && idx.UID == uid {
					b.Delete(s.Ref)
				}
			}
		}
		for _, s := range docs {
			b.Delete(s.Ref)
		}
		if err := b.Commit(ctx); err != nil {
			return cp, false, fmt.Errorf("notifications: purge %s devices: %w", logger.HashUID(uid), err)
		}
	}
	next := Checkpoint{Step: cp.Step, Deleted: cp.Deleted + len(docs)}
	if len(docs) < opsPage {
		next.Step = 1
	}
	return next, false, nil
}

// exportedNotification is one row of the user's export. It deliberately has no id: row ids embed other users' uids
// (follow_{actorUid}, repost_{postId}_{actorUid}), and an export is the user's own data, not a directory of
// strangers' account identifiers (N-3). The actor is identified by the handle the user already sees in the app.
type exportedNotification struct {
	Type        string    `json:"type"`
	ActorHandle string    `json:"actorHandle"`
	PostID      string    `json:"postId,omitempty"`
	CreatedAt   time.Time `json:"createdAt"`
}

// exportRow maps a stored row to its export form (pure, so the no-uid-leak rule is unit-testable).
func exportRow(d notificationDoc) exportedNotification {
	return exportedNotification{Type: d.Type, ActorHandle: d.Actor.Handle, PostID: d.PostID, CreatedAt: d.CreatedAt.UTC()}
}

type exportedDevice struct {
	Platform  string    `json:"platform"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// ExportUser implements Exporter: it streams {"userId", "devices": [...], "notifications": [...]} to w, newest
// notifications first in pages of opsPage. Never a token, never another user's id. Reads: one per row, minimum 1
// per query.
func (r *FirestoreRepo) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	counter := budget.FromContext(ctx)
	devDocs, err := r.devices(uid).Limit(opsPage).Documents(ctx).GetAll()
	counter.AddQueryReads(len(devDocs))
	if err != nil {
		return fmt.Errorf("notifications: export %s devices: %w", logger.HashUID(uid), err)
	}
	devices := make([]exportedDevice, 0, len(devDocs))
	for _, s := range devDocs {
		var d deviceDoc
		if err := s.DataTo(&d); err != nil {
			return fmt.Errorf("notifications: export decode device: %w", err)
		}
		devices = append(devices, exportedDevice{Platform: d.Platform, CreatedAt: d.CreatedAt.UTC(), UpdatedAt: d.UpdatedAt.UTC()})
	}
	devJSON, err := json.Marshal(devices)
	if err != nil {
		return fmt.Errorf("notifications: export encode devices: %w", err)
	}
	if _, err := fmt.Fprintf(w, `{"userId":%q,"devices":%s,"notifications":[`, uid, devJSON); err != nil {
		return fmt.Errorf("notifications: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	var last *firestore.DocumentSnapshot
	for {
		q := r.notifications(uid).OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(opsPage)
		if last != nil {
			q = q.StartAfter(last)
		}
		docs, err := q.Documents(ctx).GetAll()
		counter.AddQueryReads(len(docs))
		if err != nil {
			return fmt.Errorf("notifications: export %s: query: %w", logger.HashUID(uid), err)
		}
		for _, s := range docs {
			var d notificationDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("notifications: export decode %s: %w", s.Ref.ID, err)
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("notifications: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(exportRow(d)); err != nil {
				return fmt.Errorf("notifications: write export: %w", err)
			}
			last = s
		}
		if len(docs) < opsPage {
			break
		}
	}
	if _, err := io.WriteString(w, "]}"); err != nil {
		return fmt.Errorf("notifications: write export: %w", err)
	}
	return nil
}
