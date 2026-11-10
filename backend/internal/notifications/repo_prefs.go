package notifications

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

const (
	settingsCollection = "settings"
	// notificationPrefsDoc is the document id under users/{uid}/settings.
	notificationPrefsDoc = "notifications"
)

// prefsDoc is users/{uid}/settings/notifications. PushOff lists the switched-off groups, so an absent document, an
// empty list and a group added later all mean "on".
type prefsDoc struct {
	PushOff   []string  `firestore:"pushOff"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

var _ PrefsRepo = (*FirestoreRepo)(nil)

func (r *FirestoreRepo) prefsRef(uid string) (*firestore.DocumentRef, error) {
	if !ids.ValidUID(uid) {
		return nil, fmt.Errorf("notifications: invalid uid for prefs")
	}
	return r.client.Collection(usersCollection).Doc(uid).Collection(settingsCollection).Doc(notificationPrefsDoc), nil
}

// GetPrefs implements PrefsRepo.
func (r *FirestoreRepo) GetPrefs(ctx context.Context, uid string) (Prefs, error) {
	ref, err := r.prefsRef(uid)
	if err != nil {
		return Prefs{}, err
	}
	snap, err := ref.Get(ctx)
	if status.Code(err) == codes.NotFound {
		return DefaultPrefs(), nil
	}
	if err != nil {
		return Prefs{}, fmt.Errorf("notifications: get prefs: %w", err)
	}
	var d prefsDoc
	if err := snap.DataTo(&d); err != nil {
		return Prefs{}, fmt.Errorf("notifications: decode prefs: %w", err)
	}
	return PrefsFromOff(d.PushOff), nil
}

// SetPrefs implements PrefsRepo: a full replace, skipped when the stored value is already p.
func (r *FirestoreRepo) SetPrefs(ctx context.Context, uid string, p Prefs, now time.Time) (bool, error) {
	cur, err := r.GetPrefs(ctx, uid)
	if err != nil {
		return false, err
	}
	ref, err := r.prefsRef(uid)
	if err != nil {
		return false, err
	}
	if cur == p {
		// Defaults with no document stay a no-write: nothing to store either way.
		return false, nil
	}
	off := p.Off()
	if off == nil {
		off = []string{}
	}
	if _, err := ref.Set(ctx, prefsDoc{PushOff: off, UpdatedAt: now.UTC()}); err != nil {
		return false, fmt.Errorf("notifications: set prefs: %w", err)
	}
	return true, nil
}
