// purge_requests.go is the right-to-delete path of followRequests (ADR-0025 D11, ticket W3-32): the `follow_requests`
// account-deletion step. It is its own step, appended after `bookmarks` and before `identity`, because step names are
// persisted in users/{uid}.deletionJob.step; it never joins graph's Checkpoint (the ADR-0023 D6 precedent).
//
// followRequests/{followerId}_{followeeId} holds {followerId, followeeId, createdAt} (invariant I-R: the doc exists
// exactly when followeeId is in graph/{followerId}.requested). The account under purge appears on either side:
//
//   - outgoing (followerId == uid): delete the doc. graph/{uid}, which carries the matching `requested` entries, is
//     already gone (the `graph` step runs earlier), so nothing else is written.
//   - incoming (followeeId == uid): delete the doc and remove uid from the requester's graph/{requester}.requested in
//     the same batch (I-R). A requester whose graph doc no longer exists is skipped and logged
//     (purge_missing_counterpart); the doc is never recreated (Update only, never Set).
//
// Both passes are self-resuming: a processed page no longer matches its query, so a crash or a redelivery just
// re-queries. Deletes carry no Exists precondition (deleting a missing doc succeeds), so the only failed-batch cause
// is a missing counterpart graph doc.
//
// Cost per account deletion: 1 read per doc, minimum 2 (one empty query per side). Outgoing: 1 delete per doc.
// Incoming: 1 delete + 1 update per doc, +1 read per doc only on the fallback after a missing counterpart.
package graph

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const followRequestsCollection = "followRequests"

// Request purge phases (RequestCheckpoint.Phase), in execution order.
const (
	requestPhaseOutgoing = 1 // followRequests where followerId == uid
	requestPhaseIncoming = 2 // followRequests where followeeId == uid
)

// Page sizes keep every batch within Firestore's 500 operations: 1 op per outgoing doc, 2 per incoming doc.
const (
	requestOutgoingPage = 500
	requestIncomingPage = 250
)

// requestDoc is the followRequests/{followerId}_{followeeId} shape (ADR-0025 D2).
type requestDoc struct {
	FollowerID string    `firestore:"followerId"`
	FolloweeID string    `firestore:"followeeId"`
	CreatedAt  time.Time `firestore:"createdAt"`
}

// RequestCheckpoint is the `follow_requests` step's resume state (0 = start). It is the step's own type: the step
// name is persisted in deletionJob.step and is never folded into Checkpoint.
type RequestCheckpoint struct {
	Phase int
}

// RequestEraser is the `follow_requests` account-deletion step (ADR-0025 D11).
type RequestEraser struct{ r *FirestoreRepo }

// NewRequestEraser binds the step to the graph repo (its client and counters).
func NewRequestEraser(r *FirestoreRepo) *RequestEraser { return &RequestEraser{r: r} }

// PurgeUser does one bounded unit of work (one batch of at most 500 operations) and returns the next checkpoint;
// call again until done. Safe to replay.
func (e *RequestEraser) PurgeUser(ctx context.Context, uid string, cp RequestCheckpoint) (RequestCheckpoint, bool, error) {
	switch cp.Phase {
	case 0, requestPhaseOutgoing:
		docs, err := e.r.queryRequests(ctx, uid, true, requestOutgoingPage)
		if err != nil {
			return RequestCheckpoint{}, false, err
		}
		if len(docs) == 0 {
			return RequestCheckpoint{Phase: requestPhaseIncoming}, false, nil
		}
		if err := e.r.deleteRequests(ctx, uid, docs, true); err != nil {
			return RequestCheckpoint{}, false, err
		}
		slog.Info("graph_purge_follow_requests", "uid_hash", logger.HashUID(uid), "phase", "outgoing", "requests", len(docs))
		if len(docs) < requestOutgoingPage {
			return RequestCheckpoint{Phase: requestPhaseIncoming}, false, nil
		}
		return RequestCheckpoint{Phase: requestPhaseOutgoing}, false, nil
	case requestPhaseIncoming:
		docs, err := e.r.queryRequests(ctx, uid, false, requestIncomingPage)
		if err != nil {
			return RequestCheckpoint{}, false, err
		}
		if len(docs) == 0 {
			return RequestCheckpoint{}, true, nil
		}
		if err := e.r.deleteRequests(ctx, uid, docs, false); err != nil {
			return RequestCheckpoint{}, false, err
		}
		slog.Info("graph_purge_follow_requests", "uid_hash", logger.HashUID(uid), "phase", "incoming", "requests", len(docs))
		if len(docs) < requestIncomingPage {
			return RequestCheckpoint{}, true, nil
		}
		return RequestCheckpoint{Phase: requestPhaseIncoming}, false, nil
	default:
		return RequestCheckpoint{}, false, fmt.Errorf("graph: purge follow requests %s: unknown checkpoint phase %d", logger.HashUID(uid), cp.Phase)
	}
}

// queryRequests reads up to limit requests on one side of uid. The outgoing side uses the automatic single-field
// index on followerId; the incoming side the composite `followeeId ASC, createdAt DESC` (ADR-0025 D15).
func (r *FirestoreRepo) queryRequests(ctx context.Context, uid string, outgoing bool, limit int) ([]requestDoc, error) {
	q := r.client.Collection(followRequestsCollection).Where("followerId", "==", uid)
	if !outgoing {
		q = r.client.Collection(followRequestsCollection).Where("followeeId", "==", uid).OrderBy("createdAt", firestore.Desc)
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(snaps))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("graph: purge follow requests query: %w", err), uid)
	}
	out := make([]requestDoc, 0, len(snaps))
	for _, s := range snaps {
		var d requestDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("graph: purge decode follow request %s: %w", logger.HashUID(s.Ref.ID), err), uid)
		}
		out = append(out, d)
	}
	return out, nil
}

// deleteRequests commits one atomic batch. Incoming requests also remove uid from the requester's `requested`
// (I-R); if that Update hits a missing graph doc the batch fails, and the retry reads which requester graph docs
// exist and skips the missing ones.
func (r *FirestoreRepo) deleteRequests(ctx context.Context, uid string, docs []requestDoc, outgoing bool) error {
	err := r.commitRequestBatch(ctx, uid, docs, outgoing, nil)
	if err == nil || outgoing || !store.IsPreconditionFailed(err) {
		return err
	}
	refs := make([]*firestore.DocumentRef, len(docs))
	for i, d := range docs {
		refs[i] = r.graphRef(d.FollowerID)
	}
	snaps, gerr := r.client.GetAll(ctx, refs)
	budget.FromContext(ctx).AddReads(int64(len(refs)))
	if gerr != nil {
		ids := []string{uid}
		for _, d := range docs {
			ids = append(ids, d.FollowerID)
		}
		return logger.RedactErr(fmt.Errorf("graph: purge follow requests: requester graphs: %w", gerr), ids...)
	}
	exists := make(map[string]bool, len(docs))
	for i, s := range snaps {
		exists[docs[i].FollowerID] = s.Exists()
	}
	return r.commitRequestBatch(ctx, uid, docs, outgoing, exists)
}

// commitRequestBatch builds and commits the batch. exists == nil means "assume every counterpart graph doc exists".
func (r *FirestoreRepo) commitRequestBatch(ctx context.Context, uid string, docs []requestDoc, outgoing bool, exists map[string]bool) error {
	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	ids := []string{uid}
	for _, d := range docs {
		ref, err := r.requestRef(d.FollowerID, d.FolloweeID)
		if err != nil {
			return err
		}
		b.Delete(ref)
		ids = append(ids, d.FollowerID, d.FolloweeID)
		if outgoing {
			continue
		}
		if exists != nil && !exists[d.FollowerID] {
			slog.Warn("purge_missing_counterpart", "uid_hash", logger.HashUID(uid), "counterpart_hash", logger.HashUID(d.FollowerID), "collection", followRequestsCollection)
			continue
		}
		b.Update(r.graphRef(d.FollowerID), []firestore.Update{{Path: "requested", Value: firestore.ArrayRemove(uid)}})
	}
	if err := b.Commit(ctx); err != nil {
		// Firestore's message names the documents, so every uid in the batch is hashed.
		return logger.RedactErr(fmt.Errorf("graph: purge follow requests: %w", err), ids...)
	}
	c := budget.FromContext(ctx)
	c.AddWrites(scratch.Writes())
	c.AddDeletes(scratch.Deletes())
	return nil
}

// requestRef builds followRequests/{followerId}_{followeeId} through edgeID, the one place a composite id is built.
func (r *FirestoreRepo) requestRef(followerUID, followeeUID string) (*firestore.DocumentRef, error) {
	id, err := edgeID(followerUID, followeeUID)
	if err != nil {
		return nil, err
	}
	return r.client.Collection(followRequestsCollection).Doc(id), nil
}
