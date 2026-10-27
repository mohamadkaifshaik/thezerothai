// repo_moderation.go is the one write path moderation uses on users/{uid}: moving an account between ACTIVE and
// SUSPENDED (ADR-0016 D4, P7). It changes status and updatedAt only, through identity's own repo, and never
// touches Firebase Auth (IAM control C2: authadmin_guard_test.go). The status interceptor and Directory read the
// status from users/{uid}, so a suspended caller gets ACCOUNT_RESTRICTED once the 60 s identity cache expires.
package identity

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ErrStatusConflict is returned by SetAccountStatus when the account is in neither the expected nor the target
// status (for example DELETING): a moderator action must never resurrect or override a deletion.
var ErrStatusConflict = errors.New("identity: account status does not allow this change")

// SetAccountStatus moves users/{uid} from `from` to `to`, where the pair is ACTIVE/SUSPENDED in either direction.
// It returns changed=false (0 writes) when the account is already in `to`. Any other current status is
// ErrStatusConflict; a missing user is ErrNotFound. One transaction: 1 read, 1 write (0 on no-op).
func (r *FirestoreRepo) SetAccountStatus(ctx context.Context, uid string, from, to AccountStatus, now time.Time) (changed bool, err error) {
	valid := (from == AccountStatusActive && to == AccountStatusSuspended) ||
		(from == AccountStatusSuspended && to == AccountStatusActive)
	if !valid {
		return false, fmt.Errorf("identity: unsupported status change %d -> %d", from, to)
	}
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		changed = false
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user for status change: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for status change: %w", err)
		}
		switch cur := statusFromString(d.Status); cur {
		case to:
			return nil
		case from:
		default:
			return ErrStatusConflict
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.userRef(uid), []firestore.Update{
			{Path: "status", Value: statusToString(to)},
			{Path: "updatedAt", Value: now},
		})
		if err := b.Err(); err != nil {
			return err
		}
		changed = true
		return nil
	})
	if err != nil {
		return false, err
	}
	return changed, nil
}

// ProfileField names a profile field an operator can clear with `opsctl clear-profile-fields` (ADR-0024 Amendment 1
// A3). The display name (it must stay 1-50 characters) and the pin are deliberately not here: a bad name is
// suspend-user, and a bad pinned post is takedown-post.
type ProfileField string

// The five clearable fields. Banner and avatar each own two stored fields (the full image and its thumbnail).
const (
	ProfileFieldWebsite  ProfileField = "website"
	ProfileFieldLocation ProfileField = "location"
	ProfileFieldBanner   ProfileField = "banner"
	ProfileFieldAvatar   ProfileField = "avatar"
	ProfileFieldBio      ProfileField = "bio"
)

// storedPaths are the users/{uid} field paths a ProfileField clears, in print order (the full image first).
func (f ProfileField) storedPaths() []string {
	switch f {
	case ProfileFieldWebsite:
		return []string{"website"}
	case ProfileFieldLocation:
		return []string{"location"}
	case ProfileFieldBanner:
		return []string{"bannerUrl", "bannerThumbUrl"}
	case ProfileFieldAvatar:
		return []string{"avatarUrl", "avatarThumbUrl"}
	case ProfileFieldBio:
		return []string{"bio"}
	}
	return nil
}

// ParseProfileFields parses the comma-separated --fields list: one or more of website, location, banner, avatar and
// bio. An empty list, an empty item, an unknown name or a repeated name is an error (a usage error for the caller).
// The order given is kept.
func ParseProfileFields(list string) ([]ProfileField, error) {
	if list == "" {
		return nil, errors.New("--fields is required: one or more of website, location, banner, avatar, bio")
	}
	var out []ProfileField
	seen := map[ProfileField]bool{}
	for _, name := range strings.Split(list, ",") {
		f := ProfileField(name)
		if len(f.storedPaths()) == 0 {
			return nil, fmt.Errorf("--fields: unknown field %q (want website, location, banner, avatar, bio)", name)
		}
		if seen[f] {
			return nil, fmt.Errorf("--fields: %q is repeated", name)
		}
		seen[f] = true
		out = append(out, f)
	}
	return out, nil
}

// ClearedField is one requested field that holds a value: Values are the stored values it clears (for banner and
// avatar the full URL, then the thumbnail URL; either may be empty).
type ClearedField struct {
	Field  ProfileField
	Values []string
}

// ClearResult is what ClearProfileFields found (and, unless it was a dry run, wrote). Cleared is the requested fields
// that held a value, in the order requested; Skipped is the requested fields that were already empty.
type ClearResult struct {
	Cleared []ClearedField
	Skipped []ProfileField
	// Written is true when the update was committed: never on a dry run, and never when nothing needed clearing.
	Written bool
}

// ClearProfileFields is the operator's narrow lever on users/{uid} (ADR-0024 Amendment 1 A3, opsctl
// clear-profile-fields). One transaction reads the STORED document (never the presented view): a missing one is
// ErrNotFound and a DELETING one is ErrStatusConflict, because the deletion job's UpdateTime-preconditioned
// checkpoints must not race an operator write. It then writes one field-level Update that sets each requested field
// that holds a value to "" plus updatedAt (banner and avatar clear both their URLs; either one set counts as set).
// Fields that are already empty are skipped, so nothing to clear writes nothing and a rerun writes 0. It never uses
// Set, so it cannot recreate a purged document, and it does not touch snapshotVersion (none of these fields is part
// of the author snapshot, as in UpdateProfile) or enqueue any job. dryRun reads and reports the same plan and writes
// nothing. Reads 1, writes 1 (0 when nothing to clear, on a dry run, and on an error). The caches of running API
// instances keep the old values for up to CACHE_TTL (60 s): a separate process cannot evict them.
func (r *FirestoreRepo) ClearProfileFields(ctx context.Context, uid string, fields []ProfileField, now time.Time, dryRun bool) (ClearResult, error) {
	if len(fields) == 0 {
		return ClearResult{}, errors.New("identity: no fields to clear")
	}
	var res ClearResult
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		res = ClearResult{}
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user for field clear: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for field clear: %w", err)
		}
		if statusFromString(d.Status) == AccountStatusDeleting {
			return ErrStatusConflict
		}
		stored := map[string]string{
			"website": d.Website, "location": d.Location, "bio": d.Bio,
			"bannerUrl": d.BannerURL, "bannerThumbUrl": d.BannerThumbURL,
			"avatarUrl": d.AvatarURL, "avatarThumbUrl": d.AvatarThumbURL,
		}
		var updates []firestore.Update
		for _, f := range fields {
			cf := ClearedField{Field: f}
			for _, p := range f.storedPaths() {
				cf.Values = append(cf.Values, stored[p])
			}
			if !slices.ContainsFunc(cf.Values, func(v string) bool { return v != "" }) {
				res.Skipped = append(res.Skipped, f)
				continue
			}
			res.Cleared = append(res.Cleared, cf)
			for _, p := range f.storedPaths() {
				updates = append(updates, firestore.Update{Path: p, Value: ""})
			}
		}
		if len(updates) == 0 || dryRun {
			return nil
		}
		updates = append(updates, firestore.Update{Path: "updatedAt", Value: now})
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.userRef(uid), updates)
		if err := b.Err(); err != nil {
			return err
		}
		res.Written = true
		return nil
	})
	if err != nil {
		return ClearResult{}, err
	}
	return res, nil
}
