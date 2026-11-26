package notifications

// push_drop.go: the push registrations of an account are dropped when a REMOTE device removal cuts its sessions
// (removal-server design Q9, Plan 6 lane D PR 5), so a lost or stolen phone stops receiving notifications. keys calls it
// through keys.PushRegistrations, filled by the composition root; keys never imports this package.

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// dropPage is the device page of DropPushRegistrations: well above MaxDevicesPerUser (the cap is kept by every
// registration), so one page is the normal case, and at most 2*dropPage writes per batch.
const dropPage = 50

// errDropRaced reports a drop batch whose preconditions lost a race with a concurrent registration.
var errDropRaced = errors.New("notifications: drop push registrations: a registration changed during the drop")

// The stages a DropError names (keys.PushDropReasoner): fixed words a log line may carry instead of the error text.
const (
	DropStageQuery      = "query"
	DropStageTokenIndex = "token_index"
	DropStageCommit     = "commit"
	DropStageRaced      = "raced"
)

// DropError is a DropPushRegistrations failure with the stage it failed at. Its text names no uid, token or device id;
// the cause (a Firestore error, with its gRPC status) stays in the chain.
type DropError struct {
	Stage string
	Err   error
}

func (e *DropError) Error() string {
	return "notifications: drop push registrations: " + e.Stage + ": " + e.Err.Error()
}

func (e *DropError) Unwrap() error { return e.Err }

// PushDropReason implements keys.PushDropReasoner (keys never imports this package; the method is matched by shape).
func (e *DropError) PushDropReason() string { return e.Stage }

// DropPushRegistrations implements keys.PushRegistrations: it deletes every users/{uid}/devices document and the
// deviceTokens entries that still name uid (a token another account took over is theirs and is kept), page by page, and
// answers how many devices it deleted. The push preferences (users/{uid}/settings/notifications) are kept: they are the
// user's choice, not a device's. Idempotent: no registrations is 0, nil.
//
// Reads: one devices query per page (Limit dropPage, no index: a plain subcollection listing) and one GetAll of the
// pages' token entries. Writes: one batch per page, every delete conditioned on the update time it read, so a concurrent
// registration (a token taken over, a device refreshed) fails the batch instead of being clobbered: one inline re-read,
// then an error (the caller logs it and a retry of the removal tries again). Errors carry no uid, token or device id.
func (r *FirestoreRepo) DropPushRegistrations(ctx context.Context, uid string) (int, error) {
	total := 0
	for {
		n, more, err := r.dropDevicePage(ctx, uid)
		if errors.Is(err, errDropRaced) {
			n, more, err = r.dropDevicePage(ctx, uid)
		}
		total += n
		if errors.Is(err, errDropRaced) {
			return total, &DropError{Stage: DropStageRaced, Err: err}
		}
		if err != nil {
			return total, err
		}
		if !more {
			return total, nil
		}
	}
}

// dropDevicePage deletes one page of uid's devices and their owned token entries; more is true when the page was full.
func (r *FirestoreRepo) dropDevicePage(ctx context.Context, uid string) (int, bool, error) {
	docs, err := r.devices(uid).Limit(dropPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, false, &DropError{Stage: DropStageQuery, Err: err}
	}
	if len(docs) == 0 {
		return 0, false, nil
	}
	owned, err := r.ownedTokenIndex(ctx, uid, docs)
	if err != nil {
		return 0, false, &DropError{Stage: DropStageTokenIndex, Err: err}
	}
	committed, err := r.commitPurge(ctx, func(b store.Batch) {
		for _, s := range owned {
			b.Delete(s.Ref, firestore.LastUpdateTime(s.UpdateTime))
		}
		for _, s := range docs {
			b.Delete(s.Ref, firestore.LastUpdateTime(s.UpdateTime))
		}
	})
	if err != nil {
		return 0, false, &DropError{Stage: DropStageCommit, Err: err}
	}
	if !committed {
		return 0, false, errDropRaced
	}
	return len(docs), len(docs) == dropPage, nil
}

// ownedTokenIndex reads the deviceTokens entries of docs' tokens (one GetAll) and returns those that exist and still name
// uid: a token another account took over is theirs now.
func (r *FirestoreRepo) ownedTokenIndex(ctx context.Context, uid string, docs []*firestore.DocumentSnapshot) ([]*firestore.DocumentSnapshot, error) {
	refs := make([]*firestore.DocumentRef, 0, len(docs))
	for _, s := range docs {
		var d deviceDoc
		if err := s.DataTo(&d); err == nil && d.Token != "" {
			refs = append(refs, r.tokenRef(d.Token))
		}
	}
	if len(refs) == 0 {
		return nil, nil
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("token index: %w", err)
	}
	out := make([]*firestore.DocumentSnapshot, 0, len(snaps))
	for _, s := range snaps {
		if !s.Exists() {
			continue
		}
		var idx tokenIndexDoc
		if err := s.DataTo(&idx); err == nil && idx.UID == uid {
			out = append(out, s)
		}
	}
	return out, nil
}
