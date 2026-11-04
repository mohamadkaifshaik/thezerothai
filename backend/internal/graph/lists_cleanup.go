package graph

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// RemoveOwnArrayEntries implements Repo (refinement): one ArrayRemove on the caller's OWN
// graph/{callerUID} for the given kind ("blocked" or "muted"), plus updatedAt. It is blind on purpose: no
// read, no transaction. ArrayRemove is idempotent and commutes with concurrent Mute/Unmute/Block, so a
// concurrent removal or a re-add of the same uid can't corrupt the array; the worst case for a uid that
// reappears in users/ between hydration and this write is that the caller's mute/block of it is dropped.
// Other users' documents are never touched. For a blocked[] entry the counterpart blockedBy[caller] sits on
// the deleted user's graph doc; that is NOT guaranteed to be gone (under --skip-start-gate
// path users/B can be deleted while graph/B, with blockedBy[A], remains). Purge steps 4/5 are idempotent
// and finish the counterpart whenever they run. A missing graph doc (purged concurrently) is a no-op.
// It reads nothing and writes once (not at all when uids is empty or the doc is gone).
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
	return nil
}
