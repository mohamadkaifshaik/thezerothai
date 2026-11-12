package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

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

// userDoc is the users/{uid} shape. PII stays out of this doc (email lives in Firebase Auth).
type userDoc struct {
	Handle               string    `firestore:"handle"`
	HandleLower          string    `firestore:"handleLower"`
	DisplayName          string    `firestore:"displayName"`
	Bio                  string    `firestore:"bio"`
	AvatarURL            string    `firestore:"avatarUrl"`
	AvatarThumbURL       string    `firestore:"avatarThumbUrl"`
	IsPrivate            bool      `firestore:"isPrivate"`
	Verified             bool      `firestore:"verified"`
	SubscriptionVerified bool      `firestore:"subscriptionVerified,omitempty"`
	Status               string    `firestore:"status"`
	FollowersCount       int64     `firestore:"followersCount"`
	FollowingCount       int64     `firestore:"followingCount"`
	PostsCount           int64     `firestore:"postsCount"`
	NotificationsSeenAt  time.Time `firestore:"notificationsSeenAt"`
	HandleChangedAt      time.Time `firestore:"handleChangedAt"`
	SnapshotVersion      int64     `firestore:"snapshotVersion"`
	CreatedAt            time.Time `firestore:"createdAt"`
	UpdatedAt            time.Time `firestore:"updatedAt"`
	// Profile extras: absent = none, never backfilled, index-exempt, not in the author snapshot.
	// omitempty keeps a whole-doc rewrite (ChangeHandle) from adding empty fields to a doc that has none. The removed
	// banner's bannerUrl and bannerThumbUrl are not decoded (a legacy document still decodes); a whole-doc rewrite drops
	// them, and `opsctl purge-banners` (repo_legacy_banner.go) removes the rest.
	Location     string `firestore:"location,omitempty"`
	Website      string `firestore:"website,omitempty"`
	PinnedPostID string `firestore:"pinnedPostId,omitempty"`
	// ReadReceipts (F3): absent = off. omitempty keeps a whole-doc rewrite from adding the field to a doc that does not have it.
	// Not part of the author snapshot.
	ReadReceipts bool `firestore:"readReceipts,omitempty"`
	// DMPolicy (F9): absent = everyone_requests. omitempty keeps a whole-doc rewrite from adding the field to a doc that
	// does not have it. Not part of the author snapshot.
	DMPolicy string `firestore:"dmPolicy,omitempty"`
	// HomeTabs: the pinned Home tabs, absent = none. In userDoc so a whole-document rewrite (UpdateProfile, ChangeHandle, the
	// privacy toggle) cannot drop it; only HomeTabsAdapter changes it, field-level.
	HomeTabs []HomeTab `firestore:"homeTabs,omitempty"`
	// AuthBaseline: hashes of the sign-up identity (auth_baseline.go), written once by CreateProfile. In userDoc so a
	// whole-document rewrite cannot drop it; absent for accounts created before it existed.
	AuthBaseline *AuthBaseline `firestore:"authBaseline,omitempty"`
	// Account-deletion job state: set once by DeleteAccount, absent for every live account. Pointers
	// with omitempty, so a normal profile write never stores them; Profile carries them so a whole-doc rewrite
	// (UpdateProfile) cannot drop them.
	DeletionRequestedAt *time.Time      `firestore:"deletionRequestedAt,omitempty"`
	DeletionJob         *deletionJobDoc `firestore:"deletionJob,omitempty"`
}

func (d userDoc) toProfile(uid string) Profile {
	return Profile{
		UserID:               uid,
		Handle:               d.Handle,
		HandleLower:          d.HandleLower,
		DisplayName:          d.DisplayName,
		Bio:                  d.Bio,
		AvatarURL:            d.AvatarURL,
		AvatarThumbURL:       d.AvatarThumbURL,
		Location:             d.Location,
		Website:              d.Website,
		PinnedPostID:         d.PinnedPostID,
		ReadReceipts:         d.ReadReceipts,
		DMPolicy:             DMPolicy(d.DMPolicy),
		HomeTabsEnc:          encodeHomeTabs(d.HomeTabs),
		AuthBaselineEnc:      encodeAuthBaseline(d.AuthBaseline),
		IsPrivate:            d.IsPrivate,
		Verified:             d.Verified,
		SubscriptionVerified: d.SubscriptionVerified,
		Status:               statusFromString(d.Status),
		FollowersCount:       d.FollowersCount,
		FollowingCount:       d.FollowingCount,
		PostsCount:           d.PostsCount,
		NotificationsSeenAt:  d.NotificationsSeenAt,
		HandleChangedAt:      d.HandleChangedAt,
		SnapshotVersion:      d.SnapshotVersion,
		CreatedAt:            d.CreatedAt,
		UpdatedAt:            d.UpdatedAt,
		DeletionRequestedAt:  derefTime(d.DeletionRequestedAt),
		DeletionJob:          d.DeletionJob.toDomain(),
	}
}

func profileToDoc(p Profile) userDoc {
	return userDoc{
		Handle:               p.Handle,
		HandleLower:          p.HandleLower,
		DisplayName:          p.DisplayName,
		Bio:                  p.Bio,
		AvatarURL:            p.AvatarURL,
		AvatarThumbURL:       p.AvatarThumbURL,
		Location:             p.Location,
		Website:              p.Website,
		PinnedPostID:         p.PinnedPostID,
		ReadReceipts:         p.ReadReceipts,
		DMPolicy:             string(p.DMPolicy),
		HomeTabs:             decodeHomeTabs(p.HomeTabsEnc),
		AuthBaseline:         decodeAuthBaseline(p.AuthBaselineEnc),
		IsPrivate:            p.IsPrivate,
		Verified:             p.Verified,
		SubscriptionVerified: p.SubscriptionVerified,
		Status:               statusToString(p.Status),
		FollowersCount:       p.FollowersCount,
		FollowingCount:       p.FollowingCount,
		PostsCount:           p.PostsCount,
		NotificationsSeenAt:  p.NotificationsSeenAt,
		HandleChangedAt:      p.HandleChangedAt,
		SnapshotVersion:      p.SnapshotVersion,
		CreatedAt:            p.CreatedAt,
		UpdatedAt:            p.UpdatedAt,
		DeletionRequestedAt:  ptrTime(p.DeletionRequestedAt),
		DeletionJob:          deletionJobToDoc(p.DeletionJob),
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

// handleDoc is the handles/{handleLower} shape: uniqueness by transactional Create.
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

// GetProfile reads users/{uid}.
func (r *FirestoreRepo) GetProfile(ctx context.Context, uid string) (Profile, error) {
	snap, err := r.userRef(uid).Get(ctx)
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

// ProfileInTx implements TxProfiles: one read through the caller's transaction, never cached, status unfiltered. The
// errors carry no uid (the caller scrubs Firestore's own text, which names the document path).
func (r *FirestoreRepo) ProfileInTx(ctx context.Context, tx *firestore.Transaction, uid string) (Profile, error) {
	snap, err := tx.Get(r.userRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Profile{}, ErrNotFound
		}
		return Profile{}, fmt.Errorf("identity: get profile in transaction: %w", err)
	}
	var d userDoc
	if err := snap.DataTo(&d); err != nil {
		return Profile{}, fmt.Errorf("identity: decode profile in transaction: %w", err)
	}
	return d.toProfile(uid), nil
}

var _ TxProfiles = (*FirestoreRepo)(nil)

// ResolveHandle reads handles/{handleLower}.
func (r *FirestoreRepo) ResolveHandle(ctx context.Context, handleLower string) (string, error) {
	snap, err := r.handleRef(handleLower).Get(ctx)
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

// ResolveHandles: one GetAll on handles/{lower} for every id in handleLowers (the service caps it at
// MaxResolveHandles). Handles with no
// document are absent from the result (not an error).
func (r *FirestoreRepo) ResolveHandles(ctx context.Context, handleLowers []string) (map[string]string, error) {
	out := make(map[string]string, len(handleLowers))
	if len(handleLowers) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, len(handleLowers))
	for i, h := range handleLowers {
		refs[i] = r.handleRef(h)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("identity: resolve %d handles: %w", len(handleLowers), err)
	}
	for i, snap := range snaps {
		if !snap.Exists() {
			continue
		}
		var d handleDoc
		if err := snap.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode handle %s: %w", handleLowers[i], err)
		}
		out[handleLowers[i]] = d.UID
	}
	return out, nil
}

// CreateProfile writes users, handles and the graph doc in one transaction; a replay (users/{uid} already exists)
// writes nothing. authorize adds no Firestore operations; the baseline it returns (nil = none) is stored on the new
// users document.
func (r *FirestoreRepo) CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time, authorize func(context.Context) (*AuthBaseline, error)) (Profile, bool, error) {
	var result Profile
	replay := false
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {

		userSnap, err := tx.Get(r.userRef(uid))
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

		var baseline *AuthBaseline
		if authorize != nil {
			var aerr error
			if baseline, aerr = authorize(ctx); aerr != nil {
				return aerr
			}
		}

		handleSnap, herr := tx.Get(r.handleRef(handleLower))
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
			Handle:       handle,
			HandleLower:  handleLower,
			DisplayName:  displayName,
			Status:       statusToString(AccountStatusActive),
			CreatedAt:    now,
			UpdatedAt:    now,
			AuthBaseline: baseline,
		}
		b := store.NewFirestoreTxBatch(tx)
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

// UpdateProfile reads and rewrites the whole document in one transaction (the extras are in userDoc, so they survive
// it), or writes nothing when mutate leaves the profile exactly as it was read (L-4: a save of unchanged values must
// not rewrite the document, so the service moves UpdatedAt only when something changed).
func (r *FirestoreRepo) UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error) {
	var result Profile
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(r.userRef(uid))
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
		before := profile // Profile is comparable: a mutation that changed nothing leaves it == before
		mutate(&profile)
		if profile == before {
			result = profile
			return nil
		}

		b := store.NewFirestoreTxBatch(tx)
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

// ClearIfPinned implements Pins: it reads users/{uid} fresh inside the transaction and writes at most once.
// The write is a field-level Update of pinnedPostId to "" and happens only when the stored pin is exactly postID, so a
// newer pin is never touched and a purged users doc is never recreated (a missing doc is "nothing to clear"). It is
// not flag-gated: the clean-up must run whatever profile_extras says.
func (r *FirestoreRepo) ClearIfPinned(ctx context.Context, uid, postID string) (bool, error) {
	cleared := false
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		cleared = false
		snap, err := tx.Get(r.userRef(uid))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return nil
			}
			return fmt.Errorf("identity: get user for pin clean-up: %w", err)
		}
		var d struct {
			PinnedPostID string `firestore:"pinnedPostId"`
		}
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for pin clean-up: %w", err)
		}
		if postID == "" || d.PinnedPostID != postID {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.userRef(uid), []firestore.Update{{Path: "pinnedPostId", Value: ""}})
		if b.Err() != nil {
			return b.Err()
		}
		cleared = true
		return nil
	})
	if err != nil {
		return false, err
	}
	return cleared, nil
}

var _ Pins = (*FirestoreRepo)(nil)

// ProfileImageURLs returns, from one fresh read of users/{uid} that bypasses every cache, the image URLs the
// profile holds right now: the avatar and its thumbnail, empty ones omitted. found is false
// when the document does not exist (not an error). It is what the media module's profile_media_retired step checks
// before it retires an image: a job never acts on a message's word alone. It implements
// media.ProfileImages, which apiserver and opsctl bind to this repo.
func (r *FirestoreRepo) ProfileImageURLs(ctx context.Context, uid string) (urls []string, found bool, err error) {
	p, err := r.GetProfile(ctx, uid)
	switch {
	case errors.Is(err, ErrNotFound):
		return nil, false, nil
	case err != nil:
		return nil, false, err
	}
	for _, u := range []string{p.AvatarURL, p.AvatarThumbURL} {
		if u != "" {
			urls = append(urls, u)
		}
	}
	return urls, true, nil
}

// ChangeHandle reads users and the new handle doc; see api.go's Repo
// interface doc comment for the full no-op/case-only/cooldown/idempotent-retry decision table (M4). Every
// check runs against userSnap/handleSnap read fresh in *this* transaction — never a value the caller
// (service.go) cached earlier, which could be stale relative to a change another Cloud Run instance just
// committed.
func (r *FirestoreRepo) ChangeHandle(ctx context.Context, uid, newHandle, newHandleLower string, now time.Time, cooldown time.Duration) (profile Profile, invalidateOldHandleLower string, err error) {
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {

		userSnap, err := tx.Get(r.userRef(uid))
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
				// instance after the change already committed elsewhere). Nothing is written.
				profile = d.toProfile(uid)
				return nil
			}
			// Case-only rename (e.g. "alice" -> "Alice"): the uniqueness key (handleLower) is unchanged,
			// so handles/{} and the cooldown are not touched — only the display form and updatedAt change.
			d.Handle = newHandle
			d.SnapshotVersion++ // the handle's case is part of the author snapshot posts carry (P2)
			d.UpdatedAt = now
			b := store.NewFirestoreTxBatch(tx)
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
		d.SnapshotVersion++ // posts carry the handle in their author snapshot
		d.UpdatedAt = now

		b := store.NewFirestoreTxBatch(tx)
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
// FieldValue.Increment appended to a batch/transaction another module already opened (unit-of-work seam).
// The caller's own Batch carries the write; no extra read.

func (r *FirestoreRepo) AddPostsCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "postsCount", Value: firestore.Increment(delta)}})
}

func (r *FirestoreRepo) AddFollowersCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "followersCount", Value: firestore.Increment(delta)}})
}

func (r *FirestoreRepo) AddFollowingCount(b store.Batch, uid string, delta int64) {
	b.Update(r.userRef(uid), []firestore.Update{{Path: "followingCount", Value: firestore.Increment(delta)}})
}

// AddCounts combines both counter deltas into one Update() call ("combined per doc") so a
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

// GetProfiles batch-reads uids via one GetAll (batch known IDs after checking the cache).
// Callers are responsible for capping len(uids) at 50 (identity.Directory's
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
// a very prolific account's unread count stays one bounded aggregation however much notification volume it has.
// The client shows "99+" once this cap is hit.
const unreadNotificationCountCap = 100

// UnreadNotificationCount is one aggregation query, capped at unreadNotificationCountCap matches.
func (r *FirestoreRepo) UnreadNotificationCount(ctx context.Context, uid string, since time.Time) (int64, error) {
	q := r.client.Collection(usersCollection).Doc(uid).Collection(notificationsSubcollection).
		Where("createdAt", ">", since).
		Limit(unreadNotificationCountCap)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
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

// MarkNotificationsSeen sets users/{uid}.notificationsSeenAt = at, with no read. identity
// owns the field, so the notifications module reaches it through this method (notifications.SeenStore) instead of
// writing users/* itself. A field-level Update never clobbers a concurrent profile edit; a missing profile is
// ErrNotFound.
func (r *FirestoreRepo) MarkNotificationsSeen(ctx context.Context, uid string, at time.Time) error {
	_, err := r.userRef(uid).Update(ctx, []firestore.Update{{Path: "notificationsSeenAt", Value: at}})
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return ErrNotFound
		}
		return fmt.Errorf("identity: mark notifications seen for %s: %w", uid, err)
	}
	return nil
}
