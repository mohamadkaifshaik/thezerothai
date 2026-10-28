// repo_privacy_public.go is the Firestore side of the privacy_public job (ADR-0025 D8, W3-28b): one page of a protected
// account's pending follow requests, accepted in a single transaction through the W3-28a pieces (classifyAccept,
// queueAccept). No second accept path exists: this file only reads the page and feeds those pieces.
package graph

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// PendingCursor is where the next page of a privacy_public run continues: the last request of the previous page in
// (createdAt DESC, __name__ DESC) order. It lives in the run's memory only; a redelivery starts from the top, where the
// accepted requests have already dropped out.
type PendingCursor struct {
	CreatedAt time.Time
	ID        string
}

// PendingPageArgs are the inputs of AcceptPendingPage.
type PendingPageArgs struct {
	TargetUID string         // the account that went public
	After     *PendingCursor // nil = the first page
	Limit     int            // page size, 1 to 100 (a page of 100 is at most 401 writes and deletes; the limit is 500)
	// Active answers which of uids are ACTIVE (the identity Directory, cache-first). It is called at most once per
	// transaction attempt, with the page's requesters, after every read of the page and before the first write.
	Active func(ctx context.Context, uids []string) (map[string]bool, error)
	Now    time.Time
}

// PendingPageResult is what one AcceptPendingPage committed.
type PendingPageResult struct {
	// Stop is empty when the page was processed, else why nothing was accepted: "protected" (the account is protected
	// again), "target_gone" (no users doc) or "target_inactive" (not ACTIVE). Nothing was written.
	Stop string
	// Scanned is the number of requests the query returned; a page shorter than Limit is the last one.
	Scanned         int
	Accepted        []string // requesters that now follow the target (edge created)
	SkippedInactive int      // requester not ACTIVE or graph doc gone: request dropped, no edge
	SkippedCap      int      // requester at the 5,000 following cap: request left in place
	Drift           int      // requester already followed the target (an I-X drift): request dropped, no second edge
	Last            *PendingCursor
}

// AcceptPendingPage accepts one page of uid's pending requests in one transaction (ADR-0025 D8). In order, all reads
// first: the target's users doc fresh (re-protected, gone or not ACTIVE = Stop, nothing written, so a protect that
// commits mid-run conflicts with the page and wins), the page query INSIDE the transaction (so a concurrent withdraw,
// decline or Block conflicts and the retry sees the request gone), the requesters' status (Active), then each
// requester's graph doc. Then per request classifyAccept + queueAccept, and once per page followersCount += accepted.
//
// Reads: 1 (users) + len(page) (the query) + len(page) (requester graphs) + the cache-first Directory lookup; an empty
// page 2. Writes: 3 per accepted request (edge, requester graph, requester followingCount) + 1 delete, + 1 for the
// target's followersCount once per page: at most 401 operations at Limit 100. Skipped-inactive and drift: 1 write + 1
// delete; at the cap: 0.
func (r *FirestoreRepo) AcceptPendingPage(ctx context.Context, a PendingPageArgs) (PendingPageResult, error) {
	profiles, err := r.txProfilesReader()
	if err != nil {
		return PendingPageResult{}, err
	}
	if a.Limit < 1 || a.Limit > 100 {
		return PendingPageResult{}, fmt.Errorf("graph: privacy_public page limit %d out of range", a.Limit)
	}
	var res PendingPageResult
	err = r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = PendingPageResult{} // a retried attempt starts clean
		counter := budget.FromContext(ctx)

		target, err := profiles.ProfileInTx(ctx, tx, a.TargetUID)
		switch {
		case errors.Is(err, identity.ErrNotFound):
			res.Stop = "target_gone"
			return nil
		case err != nil:
			return err
		case target.Status != identity.AccountStatusActive:
			res.Stop = "target_inactive"
			return nil
		case target.IsPrivate:
			res.Stop = "protected"
			return nil
		}

		q := r.client.Collection(followRequestsCollection).Where("followeeId", "==", a.TargetUID).
			OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(a.Limit)
		if a.After != nil {
			q = q.StartAfter(a.After.CreatedAt, a.After.ID)
		}
		snaps, err := tx.Documents(q).GetAll()
		counter.AddReads(int64(max(len(snaps), 1))) // Firestore bills an empty query as one read
		if err != nil {
			return fmt.Errorf("graph: list pending follow requests: %w", err)
		}
		res.Scanned = len(snaps)
		if len(snaps) == 0 {
			return nil
		}
		uids := make([]string, 0, len(snaps))
		for _, s := range snaps {
			var d requestDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("graph: decode follow request: %w", err)
			}
			res.Last = &PendingCursor{CreatedAt: d.CreatedAt, ID: s.Ref.ID}
			// The doc id is the key: only a request whose id is exactly {follower}_{target} is acted on.
			if want, err := edgeID(d.FollowerID, a.TargetUID); err != nil || want != s.Ref.ID || d.FolloweeID != a.TargetUID {
				continue
			}
			uids = append(uids, d.FollowerID)
		}
		active, err := a.Active(ctx, uids)
		if err != nil {
			return err
		}
		graphs := make([]doc, len(uids))
		exists := make([]bool, len(uids))
		for i, requester := range uids {
			if graphs[i], exists[i], err = r.getGraphTxExists(ctx, tx, requester); err != nil {
				return err
			}
		}

		b := store.NewFirestoreTxBatch(tx, counter)
		for i, requester := range uids {
			kind := classifyAccept(graphs[i], exists[i], active[requester], a.TargetUID)
			if err := r.queueAccept(b, kind, a.TargetUID, requester, exists[i], a.Now); err != nil {
				return err
			}
			switch kind {
			case acceptEdge:
				res.Accepted = append(res.Accepted, requester)
			case acceptInactive:
				res.SkippedInactive++
			case acceptDrift:
				res.Drift++
			case acceptAtCap:
				res.SkippedCap++
			}
		}
		if n := len(res.Accepted); n > 0 {
			r.counters.AddFollowersCount(b, a.TargetUID, int64(n))
		}
		return b.Err()
	})
	if err != nil {
		return PendingPageResult{}, err
	}
	return res, nil
}
