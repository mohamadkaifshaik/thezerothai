package identity

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ErrProtectedSetFull is returned by the protect transaction when privacy/protectedAuthors already holds
// PROTECTED_AUTHORS_MAX uids (ADR-0025 D2). The service maps it to LIMIT_REACHED limit=private_accounts.
var ErrProtectedSetFull = errors.New("identity: protected set is full")

// PrivacyToggle says what a UpdateProfileWithPrivacy transaction did to is_private.
type PrivacyToggle int

const (
	// PrivacyNoop: is_private was absent from the change or equal to the stored value (no quota, no set read or write).
	PrivacyNoop PrivacyToggle = iota
	// PrivacyOn: the account became protected.
	PrivacyOn
	// PrivacyOff: the account became public.
	PrivacyOff
)

// PrivacyLimits are the config values the toggle transaction enforces (rule 11: config, not literals).
type PrivacyLimits struct {
	// TogglesPerDay is QUOTA_PRIVACY_TOGGLES_PER_DAY.
	TogglesPerDay int64
	// SetMax is PROTECTED_AUTHORS_MAX.
	SetMax int
}

// PrivacyUpdate is the outcome of UpdateProfileWithPrivacy.
type PrivacyUpdate struct {
	Profile Profile
	Toggle  PrivacyToggle
	// Attempts is the number of transaction attempts (the privacy_toggle_attempts hot-doc signal, ADR-0025 D3).
	Attempts int
	// SetUIDs is the protected set as read inside the committing attempt, plus this uid; set only when Toggle is
	// PrivacyOn (the doc is read fresh only when protecting). The service installs it in the loader.
	SetUIDs []string
}

// PrivacyRepo is the storage seam of the is_private toggle (W3-26a). *FirestoreRepo implements it.
type PrivacyRepo interface {
	// UpdateProfileWithPrivacy behaves like Repo.UpdateProfile and additionally, when mutate changes IsPrivate,
	// runs the D8 transaction (reads: users fresh, quotas, and for a protect the set doc; writes: users, the set doc,
	// quotas). A request whose is_private equals the stored value costs what Repo.UpdateProfile costs and charges no
	// quota. It returns the quota.ExceededError (QUOTA_EXCEEDED privacy_toggles) or ErrProtectedSetFull with 0 writes.
	UpdateProfileWithPrivacy(ctx context.Context, uid string, mutate func(*Profile), lim PrivacyLimits) (PrivacyUpdate, error)
}

var (
	_ PrivacyRepo        = (*FirestoreRepo)(nil)
	_ ProtectedSetSource = (*FirestoreRepo)(nil)
)

type protectedSetDoc struct {
	UIDs      []string  `firestore:"uids"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

func (r *FirestoreRepo) protectedSetRef() *firestore.DocumentRef {
	return r.client.Collection(privacyCollection).Doc(protectedAuthorsDoc)
}

// LoadProtectedSet implements ProtectedSetSource: 1 read; a missing doc is an empty set.
func (r *FirestoreRepo) LoadProtectedSet(ctx context.Context) ([]string, error) {
	snap, err := r.protectedSetRef().Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("identity: get protected set: %w", err)
	}
	var d protectedSetDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("identity: decode protected set: %w", err)
	}
	return d.UIDs, nil
}

// UpdateProfileWithPrivacy implements PrivacyRepo.
//
// Worst case, one transaction: protect 3 reads (users, quotas, set doc) and 3 writes (users, set doc, quotas);
// unprotect 2 reads (users, quotas) and 3 writes; equal value or no is_private 1 read and 0 or 1 write. Quota or cap
// refusal: the same reads, 0 writes.
func (r *FirestoreRepo) UpdateProfileWithPrivacy(ctx context.Context, uid string, mutate func(*Profile), lim PrivacyLimits) (PrivacyUpdate, error) {
	var out PrivacyUpdate
	attempts, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		out = PrivacyUpdate{} // the transaction may run more than once
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
		before := profile
		mutate(&profile)
		out.Profile = profile
		if profile == before {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		if profile.IsPrivate == before.IsPrivate {
			b.Set(r.userRef(uid), profileToDoc(profile))
			return b.Err()
		}

		// is_private changes: all reads first (quotas, then the set doc for a protect), then the checks, then the writes.
		qs := quota.New(r.client)
		rec, err := qs.Get(ctx, tx, uid)
		if err != nil {
			return err
		}
		var uids []string
		if profile.IsPrivate {
			sd, serr := tx.Get(r.protectedSetRef())
			counter.AddReads(1)
			switch {
			case serr == nil:
				var psd protectedSetDoc
				if err := sd.DataTo(&psd); err != nil {
					return fmt.Errorf("identity: decode protected set: %w", err)
				}
				uids = psd.UIDs
			case status.Code(serr) == codes.NotFound:
				// The first protect creates the doc below.
			default:
				return fmt.Errorf("identity: get protected set: %w", serr)
			}
		}
		now := time.Now().UTC()
		b.Set(r.userRef(uid), profileToDoc(profile))
		if err := quota.CheckAndReserve(b, qs.Ref(uid), rec, quota.PrivacyToggles, lim.TogglesPerDay); err != nil {
			return err // QUOTA_EXCEEDED; nothing was applied (the tx commits no writes on error)
		}
		if profile.IsPrivate {
			if !slices.Contains(uids, uid) && len(uids) >= lim.SetMax {
				return ErrProtectedSetFull
			}
			b.Set(r.protectedSetRef(), map[string]any{"uids": firestore.ArrayUnion(uid), "updatedAt": now}, firestore.MergeAll)
			out.Toggle = PrivacyOn
			out.SetUIDs = uids
			if !slices.Contains(uids, uid) {
				out.SetUIDs = append(slices.Clone(uids), uid)
			}
		} else {
			b.Set(r.protectedSetRef(), map[string]any{"uids": firestore.ArrayRemove(uid), "updatedAt": now}, firestore.MergeAll)
			out.Toggle = PrivacyOff
		}
		return b.Err()
	})
	out.Attempts = attempts
	if err != nil {
		return PrivacyUpdate{Attempts: attempts}, err
	}
	return out, nil
}

// RemoveFromProtectedSet is the identity eraser step's clean-up (ADR-0025 D11): one field-level Update with
// ArrayRemove(uid) on privacy/protectedAuthors, 0 reads, at most 1 write. Idempotent. NotFound (no set doc yet) is
// success and never creates the doc. Unconditional on users.isPrivate so a drifted entry cannot outlive the account.
func (r *FirestoreRepo) RemoveFromProtectedSet(ctx context.Context, uid string) error {
	_, err := r.protectedSetRef().Update(ctx, []firestore.Update{
		{Path: "uids", Value: firestore.ArrayRemove(uid)},
		{Path: "updatedAt", Value: time.Now().UTC()},
	})
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil
		}
		return logger.RedactErr(fmt.Errorf("identity: remove from protected set: %w", err), uid)
	}
	budget.FromContext(ctx).AddWrites(1)
	return nil
}
