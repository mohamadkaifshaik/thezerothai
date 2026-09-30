package graph

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// RemoveOwnArrayEntries implements Repo (ADR-0008 D10 refinement, T27): one ArrayRemove on the caller's OWN
// graph/{callerUID} for the given kind ("blocked" or "muted"), plus updatedAt. It is blind on purpose: no
// read, no transaction. ArrayRemove is idempotent and commutes with concurrent Mute/Unmute/Block, so a
// concurrent removal or a re-add of the same uid can't corrupt the array; the worst case for a uid that
// reappears in users/ between hydration and this write is that the caller's mute/block of it is dropped.
// Other users' documents are never touched (a blocked[] entry's counterpart blockedBy lives on the deleted
// user's graph doc, which the purge already removed). A missing graph doc (purged concurrently) is a no-op.
// Reads 0, writes 1 (0 when uids is empty or the doc is gone).
func (r *FirestoreRepo) RemoveOwnArrayEntries(ctx context.Context, callerUID, kind string, uids []string, now time.Time) error {
	if len(uids) == 0 {
		return nil
	}
	if kind != "blocked" && kind != "muted" {
		return fmt.Errorf("graph: remove own array entries: unsupported kind %q", kind)
	}
	vals := make([]interface{}, len(uids))
	for i, u := range uids {
		vals[i] = u
	}
	_, err := r.graphRef(callerUID).Update(ctx, []firestore.Update{
		{Path: kind, Value: firestore.ArrayRemove(vals...)},
		{Path: "updatedAt", Value: now},
	})
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil
		}
		return fmt.Errorf("graph: remove own array entries: %w", err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return nil
}
