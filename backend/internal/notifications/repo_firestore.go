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

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	usersCollection         = "users"
	notificationsCollection = "notifications"
	devicesCollection       = "devices"
	deviceTokensCollection  = "deviceTokens"
)

// refreshInterval is how long a registration with an unchanged token and index is treated as fresh: a
// RegisterDevice inside it writes nothing ("once per app start" must not rewrite the documents each time).
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
	// next like of a collapsed row).
	Create(ctx context.Context, recipientUID string, n Notification) (created bool, err error)
	// AddActor folds a further actor into a collapsed row (actorIds capped at the last MaxActorIDs, actorCount
	// incremented) and moves createdAt to at; an actor already in the row writes nothing. A missing row is not an
	// error.
	AddActor(ctx context.Context, recipientUID, id string, a Actor, at time.Time) error
	// List runs the query described by q.
	List(ctx context.Context, uid string, q ListQuery) ([]Notification, error)
	// Devices returns up to limit registered devices of uid.
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
	// dir resolves the replacement display actor when a purge removes the displayed actor of a collapsed row. Nil
	// (unit tests, opsctl) makes such rows be deleted instead.
	dir Directory
}

// WithDirectory wires the identity seam used by Eraser step 2 and returns the repo.
func (r *FirestoreRepo) WithDirectory(d Directory) *FirestoreRepo {
	r.dir = d
	return r
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
	Type     string   `firestore:"type"`
	Actor    actorDoc `firestore:"actor"`
	ActorIDs []string `firestore:"actorIds"`
	// ActorCount is the distinct actors folded in so far; ActorIDs keeps only the last MaxActorIDs of them (the
	// hot-doc bound). Rows written before the field existed read 0 and fall back to len(ActorIDs).
	ActorCount int       `firestore:"actorCount"`
	PostID     string    `firestore:"postId,omitempty"`
	BeaconID   string    `firestore:"beaconId,omitempty"`
	CreatedAt  time.Time `firestore:"createdAt"`
	ExpireAt   time.Time `firestore:"expireAt"`
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
		ID: id, Type: Type(d.Type), PostID: d.PostID, BeaconID: d.BeaconID, CreatedAt: d.CreatedAt.UTC(), ActorIDs: d.ActorIDs, ActorCount: d.ActorCount,
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

// Create implements Repo.
func (r *FirestoreRepo) Create(ctx context.Context, recipientUID string, n Notification) (bool, error) {
	doc := notificationDoc{
		Type: string(n.Type), Actor: toActorDoc(n.Actor), ActorIDs: n.ActorIDs, ActorCount: max(n.ActorCount, len(n.ActorIDs)),
		PostID: n.PostID, BeaconID: n.BeaconID, CreatedAt: n.CreatedAt, ExpireAt: n.CreatedAt.Add(TTL),
	}
	_, err := r.notifications(recipientUID).Doc(n.ID).Create(ctx, doc)
	if err != nil {
		if status.Code(err) == codes.AlreadyExists {
			return false, nil
		}
		return false, fmt.Errorf("notifications: create %s for %s: %w", n.ID, logger.HashUID(recipientUID), err)
	}
	return true, nil
}

// foldActor returns ids with actorID as the newest entry, trimmed to the last MaxActorIDs, and whether anything
// changed (false when actorID is already present: a redelivery or a repeat like).
func foldActor(ids []string, actorID string) ([]string, bool) {
	for _, id := range ids {
		if id == actorID {
			return ids, false
		}
	}
	out := append(append(make([]string, 0, len(ids)+1), ids...), actorID)
	if len(out) > MaxActorIDs {
		out = out[len(out)-MaxActorIDs:]
	}
	return out, true
}

// AddActor implements Repo: one transaction that writes only when the actor is new to the row.
// actorIds is capped at the last MaxActorIDs (hot-doc bound) and actorCount keeps counting through
// firestore.Increment. A missing row is not an error (expired or erased between the failed create and this call).
func (r *FirestoreRepo) AddActor(ctx context.Context, recipientUID, id string, a Actor, at time.Time) error {
	ref := r.notifications(recipientUID).Doc(id)
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(ref)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return nil
			}
			return fmt.Errorf("read row: %w", err)
		}
		var cur notificationDoc
		if err := snap.DataTo(&cur); err != nil {
			return fmt.Errorf("decode row: %w", err)
		}
		ids, changed := foldActor(cur.ActorIDs, a.UserID)
		if !changed {
			return nil // already folded in: redelivery is write-free
		}
		if err := tx.Update(ref, []firestore.Update{
			{Path: "actorIds", Value: ids},
			{Path: "actorCount", Value: firestore.Increment(1)},
			{Path: "actor", Value: toActorDoc(a)},
			{Path: "createdAt", Value: at},
			{Path: "expireAt", Value: at.Add(TTL)},
		}); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("notifications: fold actor into %s for %s: %w", id, logger.HashUID(recipientUID), err)
	}
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

var _ UnreadStore = (*FirestoreRepo)(nil)

// unseen is the badge's base query: the caller's rows with createdAt > since. One inequality on createdAt is served
// by the automatic single-field index (createdAt is not exempted in firebase/firestore.indexes.json).
func (r *FirestoreRepo) unseen(uid string, since time.Time) firestore.Query {
	return r.notifications(uid).Where("createdAt", ">", since)
}

// CountUnread implements UnreadStore: one count() aggregation, Limit limit (billed as one read).
func (r *FirestoreRepo) CountUnread(ctx context.Context, uid string, since time.Time, limit int) (int64, error) {
	q := r.unseen(uid, since).Limit(limit)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("notifications: count unread for %s: %w", logger.HashUID(uid), err)
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("notifications: decode unread count for %s: %w", logger.HashUID(uid), err)
	}
	return out.Count, nil
}

// UnreadActors implements UnreadStore: the newest limit unseen rows, projected to actor.userId (one read per row
// returned, one when none).
func (r *FirestoreRepo) UnreadActors(ctx context.Context, uid string, since time.Time, limit int) ([]string, error) {
	docs, err := r.unseen(uid, since).OrderBy("createdAt", firestore.Desc).Select("actor.userId").Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("notifications: unread actors for %s: %w", logger.HashUID(uid), err)
	}
	out := make([]string, 0, len(docs))
	for _, s := range docs {
		var d struct {
			Actor struct {
				UserID string `firestore:"userId"`
			} `firestore:"actor"`
		}
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("notifications: decode unread actor %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.Actor.UserID)
	}
	return out, nil
}

// Devices implements Repo.
func (r *FirestoreRepo) Devices(ctx context.Context, uid string, limit int) ([]Device, error) {
	docs, err := r.devices(uid).Limit(limit).Documents(ctx).GetAll()
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
// elsewhere, and, only for a new device, the 5 least recently updated devices of uid (to enforce the cap).
// Writes: the device and the index; a new device that also takes a token over from another account and evicts the
// oldest device writes more (with that device's index). A call that finds the same
// token, the same index and an updatedAt younger than refreshInterval writes nothing.
//
// Invariant kept by every writer: deviceTokens/{h}.{uid,deviceId} names the one device whose token hashes to h, so
// deleting a device's index doc blindly (its own token) is safe.
func (r *FirestoreRepo) RegisterDevice(ctx context.Context, uid string, d Device, now time.Time) error {
	devRef := r.devices(uid).Doc(d.ID)
	idxRef := r.tokenRef(d.Token)
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		defer func() {
		}()

		devSnap, err := tx.Get(devRef)
		exists := true
		if err != nil {
			if status.Code(err) != codes.NotFound {
				return fmt.Errorf("notifications: read device: %w", err)
			}
			exists = false
		}
		idxSnap, err := tx.Get(idxRef)
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
				return nil // fresh: nothing to write
			}
		}

		// A token another account (or another installation of this account) registered: take it over.
		var takeOver *firestore.DocumentRef
		if idxExists && (idx.UID != uid || idx.DeviceID != d.ID) {
			prevRef := r.devices(idx.UID).Doc(idx.DeviceID)
			prevSnap, err := tx.Get(prevRef)
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
		var evictIdx *firestore.DocumentRef // set only when the index still names the evicted device
		if !exists {
			docs, err := tx.Documents(r.devices(uid).OrderBy("updatedAt", firestore.Asc).Limit(MaxDevicesPerUser)).GetAll()
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
			// The evicted device's index entry is deleted only when it still names that device: a token another
			// account took over is theirs now (one more read, before any write).
			if evict != nil {
				var ed deviceDoc
				if err := evict.DataTo(&ed); err == nil && ed.Token != "" && ed.Token != d.Token {
					ref := r.tokenRef(ed.Token)
					snap, err := tx.Get(ref)
					switch {
					case err == nil:
						var eidx tokenIndexDoc
						if derr := snap.DataTo(&eidx); derr != nil {
							return fmt.Errorf("notifications: decode evicted token index: %w", derr)
						}
						if eidx.UID == uid && eidx.DeviceID == evict.Ref.ID {
							evictIdx = ref
						}
					case status.Code(err) != codes.NotFound:
						return fmt.Errorf("notifications: read evicted token index: %w", err)
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
		if err := tx.Set(idxRef, tokenIndexDoc{UID: uid, DeviceID: d.ID, UpdatedAt: now}); err != nil {
			return err
		}
		if exists && cur.Token != d.Token {
			if err := tx.Delete(r.tokenRef(cur.Token)); err != nil {
				return err
			}
		}
		if takeOver != nil {
			if err := tx.Delete(takeOver); err != nil {
				return err
			}
		}
		if evictIdx != nil {
			if err := tx.Delete(evictIdx); err != nil {
				return err
			}
		}
		if evict != nil {
			if err := tx.Delete(evict.Ref); err != nil {
				return err
			}
		}
		return nil
	})
	return err
}

// RemoveDevice implements Repo. It reads the device and the index, and deletes only what is there to remove.
func (r *FirestoreRepo) RemoveDevice(ctx context.Context, uid, deviceID, onlyIfToken string) error {
	devRef := r.devices(uid).Doc(deviceID)
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(devRef)
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
		if ownsIndex {
			if err := tx.Delete(idxRef); err != nil {
				return err
			}
		}
		return nil
	})
	return err
}
