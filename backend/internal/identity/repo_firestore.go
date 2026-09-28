package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	usersCollection            = "users"
	handlesCollection          = "handles"
	notificationsSubcollection = "notifications"
)

// ErrNotFound and ErrHandleTaken are the sentinel errors service.go maps to Connect codes/ErrorReasons.
var (
	ErrNotFound    = errors.New("identity: not found")
	ErrHandleTaken = errors.New("identity: handle taken")
)

// ErrHandleChangeCooldown is returned by FirestoreRepo.ChangeHandle when uid's HandleChangedAt, read
// fresh inside the transaction, is within the configured cooldown (M4: never checked against a
// potentially-stale cached copy). RetryAfter is how much longer the caller must wait.
type ErrHandleChangeCooldown struct {
	RetryAfter time.Duration
}

func (e *ErrHandleChangeCooldown) Error() string {
	return "identity: handle change cooldown active"
}

// userDoc is the users/{uid} shape (ADR-0003). PII stays out of this doc (email lives in Firebase Auth).
type userDoc struct {
	Handle              string    `firestore:"handle"`
	HandleLower         string    `firestore:"handleLower"`
	DisplayName         string    `firestore:"displayName"`
	Bio                 string    `firestore:"bio"`
	AvatarURL           string    `firestore:"avatarUrl"`
	AvatarThumbURL      string    `firestore:"avatarThumbUrl"`
	IsPrivate           bool      `firestore:"isPrivate"`
	Verified            bool      `firestore:"verified"`
	Status              string    `firestore:"status"`
	FollowersCount      int64     `firestore:"followersCount"`
	FollowingCount      int64     `firestore:"followingCount"`
	PostsCount          int64     `firestore:"postsCount"`
	NotificationsSeenAt time.Time `firestore:"notificationsSeenAt"`
	HandleChangedAt     time.Time `firestore:"handleChangedAt"`
	SnapshotVersion     int64     `firestore:"snapshotVersion"`
	CreatedAt           time.Time `firestore:"createdAt"`
	UpdatedAt           time.Time `firestore:"updatedAt"`
}

func (d userDoc) toProfile(uid string) Profile {
	return Profile{
		UserID:              uid,
		Handle:              d.Handle,
		HandleLower:         d.HandleLower,
		DisplayName:         d.DisplayName,
		Bio:                 d.Bio,
		AvatarURL:           d.AvatarURL,
		AvatarThumbURL:      d.AvatarThumbURL,
		IsPrivate:           d.IsPrivate,
		Verified:            d.Verified,
		Status:              statusFromString(d.Status),
		FollowersCount:      d.FollowersCount,
		FollowingCount:      d.FollowingCount,
		PostsCount:          d.PostsCount,
		NotificationsSeenAt: d.NotificationsSeenAt,
		HandleChangedAt:     d.HandleChangedAt,
		SnapshotVersion:     d.SnapshotVersion,
		CreatedAt:           d.CreatedAt,
		UpdatedAt:           d.UpdatedAt,
	}
}

func profileToDoc(p Profile) userDoc {
	return userDoc{
		Handle:              p.Handle,
		HandleLower:         p.HandleLower,
		DisplayName:         p.DisplayName,
		Bio:                 p.Bio,
		AvatarURL:           p.AvatarURL,
		AvatarThumbURL:      p.AvatarThumbURL,
		IsPrivate:           p.IsPrivate,
		Verified:            p.Verified,
		Status:              statusToString(p.Status),
		FollowersCount:      p.FollowersCount,
		FollowingCount:      p.FollowingCount,
		PostsCount:          p.PostsCount,
		NotificationsSeenAt: p.NotificationsSeenAt,
		HandleChangedAt:     p.HandleChangedAt,
		SnapshotVersion:     p.SnapshotVersion,
		CreatedAt:           p.CreatedAt,
		UpdatedAt:           p.UpdatedAt,
	}
}

func statusFromString(s string) AccountStatus {
	switch s {
	case "ACTIVE":
		return AccountStatusActive
	case "SUSPENDED":
		return AccountStatusSuspended
	case "DELETING":
		return AccountStatusDeleting
	default:
		return AccountStatusUnspecified
	}
}

func statusToString(s AccountStatus) string {
	switch s {
	case AccountStatusActive:
		return "ACTIVE"
	case AccountStatusSuspended:
		return "SUSPENDED"
	case AccountStatusDeleting:
		return "DELETING"
	default:
		return ""
	}
}

// handleDoc is the handles/{handleLower} shape (ADR-0003): uniqueness by transactional Create.
type handleDoc struct {
	UID       string    `firestore:"uid"`
	CreatedAt time.Time `firestore:"createdAt"`
}

// FirestoreRepo is the Firestore implementation of Repo.
type FirestoreRepo struct {
	client *firestore.Client
	graph  GraphInitializer
}

// NewFirestoreRepo builds a Repo. graphInit is the seam used only by CreateProfile (see api.go).
func NewFirestoreRepo(client *firestore.Client, graphInit GraphInitializer) *FirestoreRepo {
	return &FirestoreRepo{client: client, graph: graphInit}
}

func (r *FirestoreRepo) userRef(uid string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid)
}

func (r *FirestoreRepo) handleRef(handleLower string) *firestore.DocumentRef {
	return r.client.Collection(handlesCollection).Doc(handleLower)
}

// GetProfile: 1 read.
func (r *FirestoreRepo) GetProfile(ctx context.Context, uid string) (Profile, error) {
	snap, err := r.userRef(uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Profile{}, ErrNotFound
		}
		return Profile{}, fmt.Errorf("identity: get profile %s: %w", uid, err)
	}
	var d userDoc
	if err := snap.DataTo(&d); err != nil {
		return Profile{}, fmt.Errorf("identity: decode profile %s: %w", uid, err)
	}
	return d.toProfile(uid), nil
}

// ResolveHandle: 1 read.
func (r *FirestoreRepo) ResolveHandle(ctx context.Context, handleLower string) (string, error) {
	snap, err := r.handleRef(handleLower).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return "", ErrNotFound
		}
		return "", fmt.Errorf("identity: resolve handle %s: %w", handleLower, err)
	}
	var d handleDoc
	if err := snap.DataTo(&d); err != nil {
		return "", fmt.Errorf("identity: decode handle %s: %w", handleLower, err)
	}
	return d.UID, nil
}

// CreateProfile: worst case reads 2 (users, handles), writes 3 (users, handles, graph); a replay
// (users/{uid} already exists) is reads 1, writes 0 (ADR-0003, proto comment).
func (r *FirestoreRepo) CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time) (Profile, bool, error) {
	var result Profile
	replay := false
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)

		userSnap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		switch {
		case err == nil:
			var d userDoc
			if derr := userSnap.DataTo(&d); derr != nil {
				return fmt.Errorf("identity: decode user %s: %w", uid, derr)
			}
			result = d.toProfile(uid)
			replay = true
			return nil
		case status.Code(err) != codes.NotFound:
			return fmt.Errorf("identity: get user %s: %w", uid, err)
		}

		handleSnap, herr := tx.Get(r.handleRef(handleLower))
		counter.AddReads(1)
		// handleOwnedByCaller is the "shouldn't happen" benign race noted below: handles/{h} already
		// exists and already points at uid, even though users/{uid} itself doesn't exist yet. Previously
		// this fell through to b.Create() on the handle doc regardless, which fails with AlreadyExists and
		// surfaces as a generic Internal error instead of succeeding (minor fix, phase0 code review
		// repo_firestore.go:205-211) — skip re-creating it instead.
		handleOwnedByCaller := false
		if herr == nil {
			var hd handleDoc
			if derr := handleSnap.DataTo(&hd); derr == nil && hd.UID == uid {
				handleOwnedByCaller = true
			} else {
				return ErrHandleTaken
			}
		} else if status.Code(herr) != codes.NotFound {
			return fmt.Errorf("identity: get handle %s: %w", handleLower, herr)
		}

		doc := userDoc{
			Handle:      handle,
			HandleLower: handleLower,
			DisplayName: displayName,
			Status:      statusToString(AccountStatusActive),
			CreatedAt:   now,
			UpdatedAt:   now,
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Create(r.userRef(uid), doc)
		if !handleOwnedByCaller {
			b.Create(r.handleRef(handleLower), handleDoc{UID: uid, CreatedAt: now})
		}
		r.graph.InitGraph(b, uid, now)
		if b.Err() != nil {
			return b.Err()
		}

		result = doc.toProfile(uid)
		replay = false
		return nil
	})
	if err != nil {
		return Profile{}, false, err
	}
	return result, replay, nil
}

// UpdateProfile: 1 read, 1 write.
func (r *FirestoreRepo) UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error) {
	var result Profile
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user %s: %w", uid, err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user %s: %w", uid, err)
		}
		profile := d.toProfile(uid)
		mutate(&profile)

		b := store.NewFirestoreTxBatch(tx, counter)
		b.Set(r.userRef(uid), profileToDoc(profile))
		if b.Err() != nil {
			return b.Err()
		}
		result = profile
		return nil
	})
	if err != nil {
		return Profile{}, err
	}
	return result, nil
}

// ChangeHandle: 2 reads (users, new handle) worst case, matching the proto doc comment; see api.go's Repo
// interface doc comment for the full no-op/case-only/cooldown/idempotent-retry decision table (M4). Every
// check runs against userSnap/handleSnap read fresh in *this* transaction — never a value the caller
// (service.go) cached earlier, which could be stale relative to a change another Cloud Run instance just
// committed.
func (r *FirestoreRepo) ChangeHandle(ctx context.Context, uid, newHandle, newHandleLower string, now time.Time, cooldown time.Duration) (profile Profile, invalidateOldHandleLower string, err error) {
	err = r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)

		userSnap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user %s: %w", uid, err)
		}
		var d userDoc
		if err := userSnap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user %s: %w", uid, err)
		}

		if d.HandleLower == newHandleLower {
			if d.Handle == newHandle {
				// True no-op: already exactly this handle (e.g. an idempotent retry that reaches this
				// instance after the change already committed elsewhere). 0 writes.
				profile = d.toProfile(uid)
				return nil
			}
			// Case-only rename (e.g. "alice" -> "Alice"): the uniqueness key (handleLower) is unchanged,
			// so handles/{} and the cooldown are not touched — only the display form and updatedAt change.
			d.Handle = newHandle
			d.UpdatedAt = now
			b := store.NewFirestoreTxBatch(tx, counter)
			b.Set(r.userRef(uid), d)
			if b.Err() != nil {
				return b.Err()
			}
			profile = d.toProfile(uid)
			return nil
		}

		if !d.HandleChangedAt.IsZero() {
			if elapsed := now.Sub(d.HandleChangedAt); elapsed < cooldown {
				return &ErrHandleChangeCooldown{RetryAfter: cooldown - elapsed}
			}
		}

		handleSnap, herr := tx.Get(r.handleRef(newHandleLower))
		counter.AddReads(1)
		// handleOwnedByCaller: handles/{new} already points at uid (e.g. a retried ChangeHandle whose
		// earlier attempt got far enough to write the new handle doc before the caller saw a response) —
		// treat as a successful idempotent retry rather than ErrHandleTaken.
		handleOwnedByCaller := false
		switch {
		case herr == nil:
			var hd handleDoc
			if derr := handleSnap.DataTo(&hd); derr != nil {
				return fmt.Errorf("identity: decode handle %s: %w", newHandleLower, derr)
			}
			if hd.UID != uid {
				return ErrHandleTaken
			}
			handleOwnedByCaller = true
		case status.Code(herr) != codes.NotFound:
			return fmt.Errorf("identity: get handle %s: %w", newHandleLower, herr)
		}

		oldHandleLower := d.HandleLower
		d.Handle = newHandle
		d.HandleLower = newHandleLower
		d.HandleChangedAt = now
		d.UpdatedAt = now

		b := store.NewFirestoreTxBatch(tx, counter)
		if handleOwnedByCaller {
			b.Set(r.handleRef(newHandleLower), handleDoc{UID: uid, CreatedAt: now})
		} else {
			b.Create(r.handleRef(newHandleLower), handleDoc{UID: uid, CreatedAt: now})
		}
		b.Delete(r.handleRef(oldHandleLower))
		b.Set(r.userRef(uid), d)
		if b.Err() != nil {
			return b.Err()
		}
		profile = d.toProfile(uid)
		invalidateOldHandleLower = oldHandleLower
		return nil
	})
	if err != nil {
		return Profile{}, "", err
	}
	return profile, invalidateOldHandleLower, nil
}

// AddPostsCount, AddFollowersCount and AddFollowingCount implement Counters: an atomic
// FieldValue.Increment appended to a batch/transaction another module already opened (ADR-0002
// unit-of-work seam). 0 extra reads; 1 write each, counted by the caller's own Batch.

func (r *FirestoreRepo) AddPostsCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "postsCount", Value: firestore.Increment(delta)}})
}

func (r *FirestoreRepo) AddFollowersCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "followersCount", Value: firestore.Increment(delta)}})
}

func (r *FirestoreRepo) AddFollowingCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "followingCount", Value: firestore.Increment(delta)}})
}

// AddCounts combines both counter deltas into one Update() call (ADR-0008 D3: "combined per doc") so a
// caller changing both on the same uid pays for one write, not two. A zero delta is omitted; if both are
// zero, nothing is appended to b at all.
func (r *FirestoreRepo) AddCounts(b store.Batch, uid string, followingDelta, followersDelta int64) {
	var updates []firestore.Update
	if followingDelta != 0 {
		updates = append(updates, firestore.Update{Path: "followingCount", Value: firestore.Increment(followingDelta)})
	}
	if followersDelta != 0 {
		updates = append(updates, firestore.Update{Path: "followersCount", Value: firestore.Increment(followersDelta)})
	}
	if len(updates) == 0 {
		return
	}
	b.Update(r.userRef(uid), updates)
}

// GetProfiles batch-reads uids via one GetAll (ADR-0008 T6; CLAUDE.md rule 6: "batch known IDs with GetAll
// after checking the cache"). Callers are responsible for capping len(uids) at 50 (identity.Directory's
// caller, graph, only ever passes misses from its own cache-first pass). Missing docs are silently omitted,
// not an error (Firestore's GetAll returns a non-existent snapshot for them, never a NotFound error).
func (r *FirestoreRepo) GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error) {
	out := make(map[string]Profile, len(uids))
	if len(uids) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, len(uids))
	for i, uid := range uids {
		refs[i] = r.userRef(uid)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	budget.FromContext(ctx).AddReads(int64(len(uids)))
	if err != nil {
		return nil, fmt.Errorf("identity: get profiles: %w", err)
	}
	for i, snap := range snaps {
		if !snap.Exists() {
			continue
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode profile %s: %w", uids[i], err)
		}
		out[uids[i]] = d.toProfile(uids[i])
	}
	return out, nil
}

// unreadNotificationCountCap bounds UnreadNotificationCount's query (rule 5: "every query has a Limit") so
// a very prolific account's unread count can never cost more than the 1 read documented below — Firestore
// bills a count() aggregation as 1 read per ~1,000 matched docs, so without a cap a heavy notification
// volume would silently cost more. The client shows "99+" once this cap is hit.
const unreadNotificationCountCap = 100

// UnreadNotificationCount: 1 read (an aggregation query, capped at unreadNotificationCountCap matches).
func (r *FirestoreRepo) UnreadNotificationCount(ctx context.Context, uid string, since time.Time) (int64, error) {
	q := r.client.Collection(usersCollection).Doc(uid).Collection(notificationsSubcollection).
		Where("createdAt", ">", since).
		Limit(unreadNotificationCountCap)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		return 0, fmt.Errorf("identity: count notifications for %s: %w", uid, err)
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("identity: decode notification count for %s: %w", uid, err)
	}
	return out.Count, nil
}
