package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// sessionsValidAfterField is the users/{uid} field of the session cut.
const sessionsValidAfterField = "sessionsValidAfter"

var _ SessionCuts = (*service)(nil)

// EndSessionsBefore implements SessionCuts.
func (s *service) EndSessionsBefore(ctx context.Context, uid string, t time.Time) error {
	if t.IsZero() {
		return errors.New("identity: end sessions: zero cut time")
	}
	_, _, err := s.repo.EndSessionsBefore(ctx, uid, t.UTC())
	// Dropped whatever the outcome: a failed or ambiguous commit must not leave this instance answering from a stale copy.
	s.cache.InvalidateProfile(uid)
	switch {
	case errors.Is(err, ErrNotFound):
		return nil
	case err != nil:
		return logger.RedactErr(fmt.Errorf("identity: end sessions: %w", err), uid)
	}
	return nil
}

// SessionsValidAfter implements SessionCuts from the cached profile (getProfileCached, as AccountStatus).
func (s *service) SessionsValidAfter(ctx context.Context, uid string) (time.Time, error) {
	p, err := s.getProfileCached(ctx, uid)
	if err != nil {
		var ae *apierr.Error
		if errors.As(err, &ae) && ae.Code == connect.CodeNotFound {
			return time.Time{}, nil
		}
		return time.Time{}, err
	}
	return p.SessionsValidAfter, nil
}

// EndSessionsBefore implements Repo: one transaction, the users/{uid} read and, only when t is after the stored cut, a
// field-level update of sessionsValidAfter (a concurrent whole-document rewrite conflicts with it, so neither loses the
// other's write). A missing document is ErrNotFound and is never re-created.
func (r *FirestoreRepo) EndSessionsBefore(ctx context.Context, uid string, t time.Time) (Profile, bool, error) {
	var (
		out   Profile
		wrote bool
	)
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		wrote = false
		snap, err := tx.Get(r.userRef(uid))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user: %w", err)
		}
		out = d.toProfile(uid)
		if !t.After(out.SessionsValidAfter) {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.userRef(uid), []firestore.Update{{Path: sessionsValidAfterField, Value: t}})
		if b.Err() != nil {
			return b.Err()
		}
		out.SessionsValidAfter = t
		wrote = true
		return nil
	})
	if err != nil {
		return Profile{}, false, err
	}
	return out, wrote, nil
}

// ClearSessionCut removes users/{uid}.sessionsValidAfter (`opsctl identity sessions clear-cut`, for a lockout bug): one
// transaction, the read and, only when the field is set, a field-level delete. It returns the cut it removed (zero, and
// nothing written, when there was none). ErrNotFound when the document is absent. API instances keep serving their
// cached profile, and with it the cut, for up to 60 s.
func (r *FirestoreRepo) ClearSessionCut(ctx context.Context, uid string) (time.Time, error) {
	var cleared time.Time
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		cleared = time.Time{}
		snap, err := tx.Get(r.userRef(uid))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user: %w", err)
		}
		if d.SessionsValidAfter == nil {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.userRef(uid), []firestore.Update{{Path: sessionsValidAfterField, Value: firestore.Delete}})
		if b.Err() != nil {
			return b.Err()
		}
		cleared = *d.SessionsValidAfter
		return nil
	})
	if err != nil {
		return time.Time{}, err
	}
	return cleared, nil
}
