package notifications

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	usersCollection         = "users"
	notificationsCollection = "notifications"
	devicesCollection       = "devices"
	deviceTokensCollection  = "deviceTokens"
)

// refreshInterval is how long a registration with an unchanged token and index is treated as fresh: a
// RegisterDevice inside it writes nothing (ADR-0017 D9: "once per app start" must not cost 2 writes each time).
const refreshInterval = 24 * time.Hour

// ListQuery is one ListNotifications page: rows strictly older than Before (when set) and strictly newer than
// After (when set), newest first, at most Limit.
type ListQuery struct {
	Before *cursor.Cursor
	After  *cursor.Cursor
	Limit  int
}

// Repo is the storage seam service.go and fanout.go depend on; FirestoreRepo is the implementation.
type Repo interface {
	// Create writes the row if it does not exist. created=false means it already existed (a redelivery, or the
	// next like of a collapsed row). Reads 0, writes 1 (a failed create is billed as 1 read).
	Create(ctx context.Context, recipientUID string, n Notification) (created bool, err error)
	// AddActor folds a further actor into a collapsed row and moves createdAt to at. A missing row is not an error.
	AddActor(ctx context.Context, recipientUID, id string, a Actor, at time.Time) error
	// List runs the query described by q. Reads: rows returned, minimum 1.
	List(ctx context.Context, uid string, q ListQuery) ([]Notification, error)
	// Devices returns up to limit registered devices of uid. Reads: rows returned, minimum 1.
	Devices(ctx context.Context, uid string, limit int) ([]Device, error)
	// RegisterDevice upserts d (transaction, see the method doc on FirestoreRepo).
	RegisterDevice(ctx context.Context, uid string, d Device, now time.Time) error
	// RemoveDevice deletes the device and, when the index still points at it, the token index. A non-empty
	// onlyIfToken makes it a no-op unless the stored token matches (a device that refreshed its token is kept).
	RemoveDevice(ctx context.Context, uid, deviceID, onlyIfToken string) error
}

// FirestoreRepo implements Repo, Eraser and Exporter against Firestore.
type FirestoreRepo struct {
	client *firestore.Client
}

// NewFirestoreRepo builds the repo. A nil client is allowed for wiring-only tests (no method may be called).
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo { return &FirestoreRepo{client: client} }

var (
	_ Repo     = (*FirestoreRepo)(nil)
	_ Eraser   = (*FirestoreRepo)(nil)
	_ Exporter = (*FirestoreRepo)(nil)
)

// TokenKey is the deviceTokens document id: sha256 hex of the FCM token. The token itself is never a doc id or a
// log value.
func TokenKey(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

type actorDoc struct {
	UserID      string `firestore:"userId"`
	Handle      string `firestore:"handle"`
	DisplayName string `firestore:"displayName"`
	AvatarURL   string `firestore:"avatarUrl,omitempty"`
	Verified    bool   `firestore:"verified"`
}

type notificationDoc struct {
	Type      string    `firestore:"type"`
	Actor     actorDoc  `firestore:"actor"`
	ActorIDs  []string  `firestore:"actorIds"`
	PostID    string    `firestore:"postId,omitempty"`
	CreatedAt time.Time `firestore:"createdAt"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

type deviceDoc struct {
	Token     string    `firestore:"token"`
	Platform  string    `firestore:"platform"`
	CreatedAt time.Time `firestore:"createdAt"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

type tokenIndexDoc struct {
	UID       string    `firestore:"uid"`
	DeviceID  string    `firestore:"deviceId"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

func (d notificationDoc) toNotification(id string) Notification {
	return Notification{
		ID: id, Type: Type(d.Type), PostID: d.PostID, CreatedAt: d.CreatedAt.UTC(), ActorIDs: d.ActorIDs,
		Actor: Actor{UserID: d.Actor.UserID, Handle: d.Actor.Handle, DisplayName: d.Actor.DisplayName,
			AvatarURL: d.Actor.AvatarURL, Verified: d.Actor.Verified},
	}
}

func toActorDoc(a Actor) actorDoc {
	return actorDoc(a)
}

func (r *FirestoreRepo) notifications(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(notificationsCollection)
}

func (r *FirestoreRepo) devices(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(devicesCollection)
}

func (r *FirestoreRepo) tokenRef(token string) *firestore.DocumentRef {
	return r.client.Collection(deviceTokensCollection).Doc(TokenKey(token))
}

func readsFor(n int) int64 {
	if n == 0 {
		return 1
	}
	return int64(n)
}

// Create implements Repo.
func (r *FirestoreRepo) Create(ctx context.Context, recipientUID string, n Notification) (bool, error) {
	doc := notificationDoc{
		Type: string(n.Type), Actor: toActorDoc(n.Actor), ActorIDs: n.ActorIDs, PostID: n.PostID,
		CreatedAt: n.CreatedAt, ExpireAt: n.CreatedAt.Add(TTL),
	}
	_, err := r.notifications(recipientUID).Doc(n.ID).Create(ctx, doc)
	if err != nil {
		if status.Code(err) == codes.AlreadyExists {
			budget.FromContext(ctx).AddReads(1)
			return false, nil
		}
		return false, fmt.Errorf("notifications: create %s for %s: %w", n.ID, logger.HashUID(recipientUID), err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return true, nil
}

// AddActor implements Repo.
func (r *FirestoreRepo) AddActor(ctx context.Context, recipientUID, id string, a Actor, at time.Time) error {
	_, err := r.notifications(recipientUID).Doc(id).Update(ctx, []firestore.Update{
		{Path: "actorIds", Value: firestore.ArrayUnion(a.UserID)},
		{Path: "actor", Value: toActorDoc(a)},
		{Path: "createdAt", Value: at},
		{Path: "expireAt", Value: at.Add(TTL)},
	})
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil // expired or erased between the failed create and this update
		}
		return fmt.Errorf("notifications: fold actor into %s for %s: %w", id, logger.HashUID(recipientUID), err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return nil
}

// List implements Repo. Same ordering and bounds as the posts queries: (createdAt DESC, __name__ DESC).
func (r *FirestoreRepo) List(ctx context.Context, uid string, q ListQuery) ([]Notification, error) {
	query := r.notifications(uid).OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
	if q.Before != nil {
		query = query.StartAfter(q.Before.CreatedAt, r.notifications(uid).Doc(q.Before.DocID))
	}
	if q.After != nil {
		query = query.EndBefore(q.After.CreatedAt, r.notifications(uid).Doc(q.After.DocID))
	}
	docs, err := query.Limit(q.Limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(readsFor(len(docs)))
	if err != nil {
		return nil, fmt.Errorf("notifications: list for %s: %w", logger.HashUID(uid), err)
	}
	out := make([]Notification, 0, len(docs))
	for _, s := range docs {
		var d notificationDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("notifications: decode %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toNotification(s.Ref.ID))
	}
	return out, nil
}

// Devices implements Repo.
func (r *FirestoreRepo) Devices(ctx context.Context, uid string, limit int) ([]Device, error) {
	docs, err := r.devices(uid).Limit(limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(readsFor(len(docs)))
	if err != nil {
		return nil, fmt.Errorf("notifications: devices for %s: %w", logger.HashUID(uid), err)
	}
	out := make([]Device, 0, len(docs))
	for _, s := range docs {
		var d deviceDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("notifications: decode device %s: %w", s.Ref.ID, err)
		}
		out = append(out, Device{ID: s.Ref.ID, Token: d.Token, Platform: Platform(d.Platform), CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt})
	}
	return out, nil
}

// RegisterDevice upserts users/{uid}/devices/{d.ID} and deviceTokens/{sha256(token)} in one transaction.
//
// Reads (all before any write): the device doc, the token index, the previous owner's device when the index points
// elsewhere, and, only for a new device, the 5 least recently updated devices of uid (to enforce the cap). Worst
// case 8 reads, typical 2. Writes: the device and the index (2); worst case 5 (new device that also takes a token
// over from another account and evicts the oldest device, with that device's index). A call that finds the same
// token, the same index and an updatedAt younger than refreshInterval writes nothing.
//
// Invariant kept by every writer: deviceTokens/{h}.{uid,deviceId} names the one device whose token hashes to h, so
// deleting a device's index doc blindly (its own token) is safe.
func (r *FirestoreRepo) RegisterDevice(ctx context.Context, uid string, d Device, now time.Time) error {
	devRef := r.devices(uid).Doc(d.ID)
	idxRef := r.tokenRef(d.Token)
	counter := budget.FromContext(ctx)
	return r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		var reads, writes, deletes int64
		defer func() {
			counter.AddReads(reads)
			counter.AddWrites(writes)
			counter.AddDeletes(deletes)
		}()

		devSnap, err := tx.Get(devRef)
		reads++
		exists := true
		if err != nil {
			if status.Code(err) != codes.NotFound {
				return fmt.Errorf("notifications: read device: %w", err)
			}
			exists = false
		}
		idxSnap, err := tx.Get(idxRef)
		reads++
		idxExists := true
		if err != nil {
			if status.Code(err) != codes.NotFound {
				return fmt.Errorf("notifications: read token index: %w", err)
			}
			idxExists = false
		}

		var idx tokenIndexDoc
		if idxExists {
			if err := idxSnap.DataTo(&idx); err != nil {
				return fmt.Errorf("notifications: decode token index: %w", err)
			}
		}
		var cur deviceDoc
		if exists {
			if err := devSnap.DataTo(&cur); err != nil {
				return fmt.Errorf("notifications: decode device: %w", err)
			}
			if cur.Token == d.Token && idxExists && idx.UID == uid && idx.DeviceID == d.ID && now.Sub(cur.UpdatedAt) < refreshInterval {
				return nil // fresh: 0 writes
			}
		}

		// A token another account (or another installation of this account) registered: take it over.
		var takeOver *firestore.DocumentRef
		if idxExists && (idx.UID != uid || idx.DeviceID != d.ID) {
			prevRef := r.devices(idx.UID).Doc(idx.DeviceID)
			prevSnap, err := tx.Get(prevRef)
			reads++
			switch {
			case err == nil:
				var prev deviceDoc
				if err := prevSnap.DataTo(&prev); err != nil {
					return fmt.Errorf("notifications: decode previous owner device: %w", err)
				}
				if prev.Token == d.Token {
					takeOver = prevRef
				}
			case status.Code(err) != codes.NotFound:
				return fmt.Errorf("notifications: read previous owner device: %w", err)
			}
		}

		var evict *firestore.DocumentSnapshot
		if !exists {
			docs, err := tx.Documents(r.devices(uid).OrderBy("updatedAt", firestore.Asc).Limit(MaxDevicesPerUser)).GetAll()
			reads += readsFor(len(docs))
			if err != nil {
				return fmt.Errorf("notifications: list devices: %w", err)
			}
			count := len(docs)
			if takeOver != nil && idx.UID == uid {
				count-- // the same user's other installation is about to disappear
			}
			if count >= MaxDevicesPerUser {
				for _, s := range docs {
					if takeOver == nil || s.Ref.ID != takeOver.ID {
						evict = s
						break
					}
				}
			}
		}

		createdAt := now
		if exists && !cur.CreatedAt.IsZero() {
			createdAt = cur.CreatedAt
		}
		if err := tx.Set(devRef, deviceDoc{Token: d.Token, Platform: string(d.Platform), CreatedAt: createdAt, UpdatedAt: now}); err != nil {
			return err
		}
		writes++
		if err := tx.Set(idxRef, tokenIndexDoc{UID: uid, DeviceID: d.ID, UpdatedAt: now}); err != nil {
			return err
		}
		writes++
		if exists && cur.Token != d.Token {
			if err := tx.Delete(r.tokenRef(cur.Token)); err != nil {
				return err
			}
			deletes++
		}
		if takeOver != nil {
			if err := tx.Delete(takeOver); err != nil {
				return err
			}
			deletes++
		}
		if evict != nil {
			var ed deviceDoc
			if err := evict.DataTo(&ed); err == nil && ed.Token != "" {
				if err := tx.Delete(r.tokenRef(ed.Token)); err != nil {
					return err
				}
				deletes++
			}
			if err := tx.Delete(evict.Ref); err != nil {
				return err
			}
			deletes++
		}
		return nil
	})
}

// RemoveDevice implements Repo. Reads 2 (device, index), writes 0 or 1-2 (deletes).
func (r *FirestoreRepo) RemoveDevice(ctx context.Context, uid, deviceID, onlyIfToken string) error {
	devRef := r.devices(uid).Doc(deviceID)
	counter := budget.FromContext(ctx)
	return r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(devRef)
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return nil
			}
			return fmt.Errorf("notifications: read device: %w", err)
		}
		var d deviceDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("notifications: decode device: %w", err)
		}
		if onlyIfToken != "" && d.Token != onlyIfToken {
			return nil
		}
		idxRef := r.tokenRef(d.Token)
		idxSnap, err := tx.Get(idxRef)
		counter.AddReads(1)
		ownsIndex := false
		switch {
		case err == nil:
			var idx tokenIndexDoc
			if derr := idxSnap.DataTo(&idx); derr != nil {
				return fmt.Errorf("notifications: decode token index: %w", derr)
			}
			ownsIndex = idx.UID == uid && idx.DeviceID == deviceID
		case status.Code(err) != codes.NotFound:
			return fmt.Errorf("notifications: read token index: %w", err)
		}
		if err := tx.Delete(devRef); err != nil {
			return err
		}
		counter.AddDeletes(1)
		if ownsIndex {
			if err := tx.Delete(idxRef); err != nil {
				return err
			}
			counter.AddDeletes(1)
		}
		return nil
	})
}
