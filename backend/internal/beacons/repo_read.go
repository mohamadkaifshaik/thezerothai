package beacons

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// maxListDocs bounds one ListByAudience read: a page of at most limits.MaxPageSize plus the extra row that decides the next
// token.
const maxListDocs = 51

// readable reports whether the repository can serve reads: they need the client only, not the quota and idempotency
// stores.
func (r *FirestoreRepo) readable() error {
	if r == nil || r.client == nil {
		return errors.New("beacons: repo has no firestore client")
	}
	return nil
}

// Get implements Repo: one point read of beacons/{id}, outside any transaction.
func (r *FirestoreRepo) Get(ctx context.Context, id string) (Beacon, error) {
	if err := r.readable(); err != nil {
		return Beacon{}, err
	}
	snap, err := r.ref(id).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Beacon{}, ErrNotFound
		}
		return Beacon{}, logger.RedactErr(fmt.Errorf("beacons: get beacon: %w", err), id)
	}
	var d beaconDoc
	if err := snap.DataTo(&d); err != nil {
		return Beacon{}, logger.RedactErr(fmt.Errorf("beacons: decode beacon: %w", err), id)
	}
	return d.beacon(snap.Ref.ID), nil
}

// ListByAudience implements Repo: communityId == q.CommunityID ("" = public), activity == q.Activity when set, status in
// [open, full], startAt >= q.From, ordered by startAt then document id, resuming after (q.AfterStartAt, q.AfterID), with a
// Limit. Composite indexes (communityId, status, startAt) and, with an activity, (communityId, activity, status, startAt)
// (TestFirestoreIndexesCoverTheBeaconQueries). Hidden beacons are returned; the service drops them.
func (r *FirestoreRepo) ListByAudience(ctx context.Context, q ListQuery) ([]Beacon, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	fq := r.col().Where("communityId", "==", q.CommunityID)
	if q.Activity != "" {
		fq = fq.Where("activity", "==", string(q.Activity))
	}
	fq = fq.Where("status", "in", liveStatuses).
		Where("startAt", ">=", q.From.UTC()).OrderBy("startAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if q.AfterID != "" {
		fq = fq.StartAfter(q.AfterStartAt.UTC(), r.ref(q.AfterID))
	}
	docs, err := fq.Limit(min(max(q.Limit, 1), maxListDocs)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: list by audience: %w", err), q.CommunityID, q.AfterID)
	}
	out := make([]Beacon, 0, len(docs))
	for _, s := range docs {
		var d beaconDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode beacon: %w", err), q.CommunityID, s.Ref.ID)
		}
		out = append(out, d.beacon(s.Ref.ID))
	}
	return out, nil
}
