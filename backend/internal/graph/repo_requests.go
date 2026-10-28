// repo_requests.go is the Firestore side of RespondToFollowRequest and the request count (ADR-0025 D7, W3-28a). The accept
// is written once, as small pure pieces (classifyAccept, queueAccept, queueDecline) that take already-read inputs and only
// queue writes on a store.Batch, so the privacy_public job (W3-28b, ADR-0025 AQ1) can run them for a page of requests in
// its own transaction after reading the whole page first (Firestore wants every read before the first write).
package graph

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

// RespondOutcome is how RespondToFollowRequest ended; it is the `respond` request-log field (ADR-0025 D7).
type RespondOutcome string

const (
	// RespondAccept: the edge, the requester's graph write, both counters and the request delete were committed.
	RespondAccept RespondOutcome = "accept"
	// RespondDecline: the request was deleted and `requested` cleaned.
	RespondDecline RespondOutcome = "decline"
	// RespondReplay: the request is gone (answered, withdrawn or never made); nothing was written.
	RespondReplay RespondOutcome = "replay"
	// RespondRequesterInactive: an accept for a requester who is no longer ACTIVE (or whose graph doc is gone): the
	// request was deleted and `requested` cleaned, no edge.
	RespondRequesterInactive RespondOutcome = "requester_inactive"
	// RespondDrift: the requester already follows the target (an I-X drift, never expected): the request was deleted and
	// `requested` cleaned, no second edge.
	RespondDrift RespondOutcome = "drift"
	// RespondRequesterCap: the requester already follows 5,000 accounts; nothing was written (LIMIT_REACHED).
	RespondRequesterCap RespondOutcome = "requester_cap"
)

// acceptKind is classifyAccept's verdict for one request.
type acceptKind int

const (
	acceptEdge     acceptKind = iota // create the edge
	acceptInactive                   // requester not ACTIVE or graph doc gone: drop the request, no edge
	acceptDrift                      // requester already follows the target: drop the request, no edge
	acceptAtCap                      // requester at maxFollowing: write nothing
)

// classifyAccept decides what an accept of requesterUID's request to targetUID does, from the requester's graph doc as
// read in the transaction (exists = the doc is there) and the requester's account status (active, from the Directory,
// cache-first). Pure; no reads. Order: not ACTIVE or no graph doc, then I-X drift, then the 5,000 cap.
func classifyAccept(requester doc, exists, active bool, targetUID string) acceptKind {
	switch {
	case !active || !exists:
		return acceptInactive
	case requester.hasFollowing(targetUID):
		return acceptDrift
	case len(requester.Following) >= maxFollowing:
		return acceptAtCap
	}
	return acceptEdge
}

// queueAccept queues the writes of one accepted request on b: for acceptEdge, Create follows/{requester}_{target}, the
// requester's graph (`following` += target, `requested` -= target) and followingCount +1 on the requester, plus the
// request delete (3 writes + 1 delete). acceptInactive and acceptDrift only delete the request and, when the requester's
// graph doc exists, remove the target from `requested` (I-R); acceptAtCap queues nothing. It does NOT touch the
// target's followersCount: the caller adds +1 (RespondToFollowRequest) or +n once per page (the privacy_public job).
// It reads nothing, so the job can call it for every request of a page after reading the page.
func (r *FirestoreRepo) queueAccept(b store.Batch, kind acceptKind, targetUID, requesterUID string, requesterGraphExists bool, now time.Time) error {
	if kind == acceptAtCap {
		return nil
	}
	reqRef, err := r.requestRef(requesterUID, targetUID)
	if err != nil {
		return err
	}
	if kind == acceptEdge {
		edgeRef, err := r.followRef(requesterUID, targetUID)
		if err != nil {
			return err
		}
		b.Create(edgeRef, followDoc{FollowerID: requesterUID, FolloweeID: targetUID, CreatedAt: now})
		b.Update(r.graphRef(requesterUID), []firestore.Update{
			{Path: "following", Value: firestore.ArrayUnion(targetUID)},
			{Path: "requested", Value: firestore.ArrayRemove(targetUID)},
			{Path: "updatedAt", Value: now},
		})
		r.counters.AddFollowingCount(b, requesterUID, 1)
		b.Delete(reqRef)
		return nil
	}
	return r.queueDrop(b, reqRef, requesterUID, targetUID, requesterGraphExists, now)
}

// queueDecline queues a decline: delete the request and remove the target from the requester's `requested` (1 write +
// 1 delete). When the requester's graph doc is gone (a purge in progress) only the delete is queued: an Update on a
// missing doc would fail the whole transaction, and the doc is never recreated.
func (r *FirestoreRepo) queueDecline(b store.Batch, targetUID, requesterUID string, requesterGraphExists bool, now time.Time) error {
	reqRef, err := r.requestRef(requesterUID, targetUID)
	if err != nil {
		return err
	}
	return r.queueDrop(b, reqRef, requesterUID, targetUID, requesterGraphExists, now)
}

func (r *FirestoreRepo) queueDrop(b store.Batch, reqRef *firestore.DocumentRef, requesterUID, targetUID string, graphExists bool, now time.Time) error {
	if graphExists {
		b.Update(r.graphRef(requesterUID), []firestore.Update{
			{Path: "requested", Value: firestore.ArrayRemove(targetUID)},
			{Path: "updatedAt", Value: now},
		})
	}
	b.Delete(reqRef)
	return nil
}

// RespondArgs are the inputs of Repo.RespondToRequest.
type RespondArgs struct {
	TargetUID    string // the protected account answering (the caller)
	RequesterUID string
	Accept       bool
	// RequesterActive reports whether the requester is still ACTIVE (the service answers it from the identity Directory,
	// cache-first). The repo calls it at most once, only for an accept of a request that still exists, so a replay and a
	// decline never pay for it.
	RequesterActive func(ctx context.Context) (bool, error)
	Now             time.Time
}

// RespondToRequest implements Repo (ADR-0025 D7). One transaction: the request is read fresh (absent = replay, 0 writes),
// then the requester's graph fresh; an accept then classifies (classifyAccept) and queues queueAccept plus
// followersCount +1 on the target, a decline queues queueDecline. Reads 2 (+ the Directory lookup the caller supplies,
// cache-first). Writes: accept 4 + 1 delete, decline 1 + 1 delete, inactive or drift 1 + 1 delete, cap or replay 0.
// A requester at the following cap is LimitReachedError{requester_following} with nothing written.
func (r *FirestoreRepo) RespondToRequest(ctx context.Context, a RespondArgs) (RespondOutcome, error) {
	reqRef, err := r.requestRef(a.RequesterUID, a.TargetUID)
	if err != nil {
		return "", err
	}
	outcome := RespondReplay
	err = r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		outcome = RespondReplay
		_, err := tx.Get(reqRef)
		counter.AddReads(1)
		switch {
		case status.Code(err) == codes.NotFound:
			return nil
		case err != nil:
			return fmt.Errorf("graph: get follow request: %w", err)
		}
		active := true
		if a.Accept {
			if active, err = a.RequesterActive(ctx); err != nil {
				return err
			}
		}
		requester, exists, err := r.getGraphTxExists(ctx, tx, a.RequesterUID)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		if !a.Accept {
			outcome = RespondDecline
			if err := r.queueDecline(b, a.TargetUID, a.RequesterUID, exists, a.Now); err != nil {
				return err
			}
			return b.Err()
		}
		kind := classifyAccept(requester, exists, active, a.TargetUID)
		switch kind {
		case acceptAtCap:
			outcome = RespondRequesterCap
			return &LimitReachedError{Limit: "requester_following"}
		case acceptInactive:
			outcome = RespondRequesterInactive
		case acceptDrift:
			outcome = RespondDrift
		default:
			outcome = RespondAccept
		}
		if err := r.queueAccept(b, kind, a.TargetUID, a.RequesterUID, exists, a.Now); err != nil {
			return err
		}
		if kind == acceptEdge {
			r.counters.AddFollowersCount(b, a.TargetUID, 1)
		}
		return b.Err()
	})
	if err != nil {
		var lim *LimitReachedError
		if errors.As(err, &lim) {
			return RespondRequesterCap, err
		}
		return "", err
	}
	return outcome, nil
}

// pendingRequestsCap bounds CountRequests (rule 5: every query has a Limit, aggregations included): Firestore bills a
// count() as 1 read per 1,000 matches, so the cap keeps the badge at 1 read. The client shows "999+" past it.
const pendingRequestsCap = 1000

// CountRequests implements Repo: count() on followRequests where followeeId == uid, capped at pendingRequestsCap. Reads
// ceil(n/1000), minimum 1, so 1 (ADR-0025 AQ3).
func (r *FirestoreRepo) CountRequests(ctx context.Context, uid string) (int64, error) {
	q := r.client.Collection(followRequestsCollection).Where("followeeId", "==", uid).Limit(pendingRequestsCap)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		return 0, fmt.Errorf("graph: count follow requests: %w", err)
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("graph: decode follow request count: %w", err)
	}
	return out.Count, nil
}
