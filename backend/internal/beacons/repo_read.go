package beacons

import (
	"context"
	"errors"
	"fmt"
	"time"

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

// NearbyQuery is one Nearby read (Location P2): public beacons (communityId == "") with nearAreaIds array-contains
// AreaID (AREA scope) or cityId == CityID (CITY scope; set exactly one), status in [open, full], startAt >= From,
// ordered by startAt then id, resuming after (AfterStartAt, AfterID) when AfterID is set, at most Limit docs.
type NearbyQuery struct {
	AreaID       string
	CityID       string
	From         time.Time
	AfterStartAt time.Time
	AfterID      string
	Limit        int
}

// nearbyBase is NearbyQuery's filter without order or cursor (the list and the count share it). Composite indexes
// (communityId, nearAreaIds CONTAINS, status, startAt) and (communityId, cityId, status, startAt): an owner deploy
// (location design 4.1); without them a real project answers FAILED_PRECONDITION, mapped to ErrNearbyIndex.
func (r *FirestoreRepo) nearbyBase(q NearbyQuery) firestore.Query {
	fq := r.col().Where("communityId", "==", "")
	if q.CityID != "" {
		fq = fq.Where("cityId", "==", q.CityID)
	} else {
		fq = fq.Where("nearAreaIds", "array-contains", q.AreaID)
	}
	return fq.Where("status", "in", liveStatuses).Where("startAt", ">=", q.From.UTC())
}

// nearbyErr maps a refused Nearby query: FAILED_PRECONDITION (the index is missing or still building) is ErrNearbyIndex,
// checked on the raw error before any wrapping; anything else is wrapped with the area ids redacted.
func nearbyErr(op string, err error, q NearbyQuery) error {
	if status.Code(err) == codes.FailedPrecondition {
		return fmt.Errorf("beacons: %s: %w", op, ErrNearbyIndex)
	}
	return logger.RedactErr(fmt.Errorf("beacons: %s: %w", op, err), q.AreaID, q.CityID, q.AfterID)
}

// ListNearby implements Repo. Hidden beacons are returned; the service drops them.
func (r *FirestoreRepo) ListNearby(ctx context.Context, q NearbyQuery) ([]Beacon, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	fq := r.nearbyBase(q).OrderBy("startAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if q.AfterID != "" {
		fq = fq.StartAfter(q.AfterStartAt.UTC(), r.ref(q.AfterID))
	}
	docs, err := fq.Limit(min(max(q.Limit, 1), maxListDocs)).Documents(ctx).GetAll()
	if err != nil {
		return nil, nearbyErr("list nearby", err, q)
	}
	out := make([]Beacon, 0, len(docs))
	for _, s := range docs {
		var d beaconDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode beacon: %w", err), s.Ref.ID)
		}
		out = append(out, d.beacon(s.Ref.ID))
	}
	return out, nil
}

// CountNearby implements Repo: one count aggregation over nearbyBase, capped at q.Limit.
func (r *FirestoreRepo) CountNearby(ctx context.Context, q NearbyQuery) (int64, error) {
	if err := r.readable(); err != nil {
		return 0, err
	}
	fq := r.nearbyBase(q).Limit(max(q.Limit, 1))
	res, err := fq.NewAggregationQuery().WithCount("n").Get(ctx)
	if err != nil {
		return 0, nearbyErr("count nearby", err, q)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("beacons: count nearby decode: %w", err)
	}
	return out.N, nil
}
