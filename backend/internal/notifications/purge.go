// purge.go implements Eraser and Exporter on FirestoreRepo (ADR-0017 D10): the right-to-delete and
// right-to-access paths for users/{uid}/notifications, users/{uid}/devices and deviceTokens.
package notifications

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// opsPage is the ops page size and the batch bound (Firestore's 500 writes). CLAUDE.md rule 5's maximum of 50
// governs RPC pagination only (the same reading as posts/purge.go).
const opsPage = 500

// Exporter writes one user's notification data as the manual data export (ADR-0003 "Deletes & privacy").
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

// PurgeUser implements Eraser. One call does one bounded unit of work and returns the next step:
//
//	step 0: the user's devices and their deviceTokens docs (<= MaxDevicesPerUser, one call);
//	step 1: the user's own notification rows, a page of <= 500 per call;
//	step 2: rows in other users' lists that name the user in actorIds (collection-group array-contains query,
//	        needs the notifications.actorIds COLLECTION_GROUP index override), a page of <= 500 per call.
//
// Deleted documents drop out of the next page, so every step is self-resuming after a crash. Reads: one per
// document returned (1 for an empty page), plus one per device for its token index; deletes: one per document.
func (r *FirestoreRepo) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	counter := budget.FromContext(ctx)
	switch cp.Step {
	case 0:
		return r.purgeDevices(ctx, uid, cp)
	case 1, 2:
		var q firestore.Query
		if cp.Step == 1 {
			q = r.notifications(uid).Select().Limit(opsPage)
		} else {
			q = r.client.CollectionGroup(notificationsCollection).Where("actorIds", "array-contains", uid).Select().Limit(opsPage)
		}
		docs, err := q.Documents(ctx).GetAll()
		counter.AddReads(readsFor(len(docs)))
		if err != nil {
			return cp, false, fmt.Errorf("notifications: purge %s step %d: query: %w", logger.HashUID(uid), cp.Step, err)
		}
		if len(docs) > 0 {
			b := store.NewFirestoreBatch(r.client, counter)
			for _, d := range docs {
				b.Delete(d.Ref)
			}
			if err := b.Commit(ctx); err != nil {
				return cp, false, fmt.Errorf("notifications: purge %s step %d: %w", logger.HashUID(uid), cp.Step, err)
			}
		}
		next := Checkpoint{Step: cp.Step, Deleted: cp.Deleted + len(docs)}
		slog.InfoContext(ctx, "notifications_purge_batch", "uid_hash", logger.HashUID(uid), "step", cp.Step, "docs", len(docs), "deleted_total", next.Deleted)
		if len(docs) < opsPage {
			if cp.Step == 2 {
				return next, true, nil
			}
			next.Step = 2
		}
		return next, false, nil
	default:
		return cp, false, fmt.Errorf("notifications: purge: unknown checkpoint step %d", cp.Step)
	}
}

func (r *FirestoreRepo) purgeDevices(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	counter := budget.FromContext(ctx)
	docs, err := r.devices(uid).Limit(opsPage).Documents(ctx).GetAll()
	counter.AddReads(readsFor(len(docs)))
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

type exportedNotification struct {
	ID          string    `json:"id"`
	Type        string    `json:"type"`
	ActorHandle string    `json:"actorHandle"`
	PostID      string    `json:"postId,omitempty"`
	CreatedAt   time.Time `json:"createdAt"`
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
	counter.AddReads(readsFor(len(devDocs)))
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
		counter.AddReads(readsFor(len(docs)))
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
			if err := enc.Encode(exportedNotification{ID: s.Ref.ID, Type: d.Type, ActorHandle: d.Actor.Handle, PostID: d.PostID, CreatedAt: d.CreatedAt.UTC()}); err != nil {
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
