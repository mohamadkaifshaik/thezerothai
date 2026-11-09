package beacons

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// GetParticipant implements Repo: one point read, outside any transaction.
func (r *FirestoreRepo) GetParticipant(ctx context.Context, beaconID, uid string) (Participant, error) {
	if err := r.readable(); err != nil {
		return Participant{}, err
	}
	snap, err := r.participantRef(beaconID, uid).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Participant{}, ErrNotFound
		}
		return Participant{}, logger.RedactErr(fmt.Errorf("beacons: get participant: %w", err), beaconID, uid)
	}
	var d participantDoc
	if err := snap.DataTo(&d); err != nil {
		return Participant{}, logger.RedactErr(fmt.Errorf("beacons: decode participant: %w", err), beaconID, uid)
	}
	return d.participant(beaconID), nil
}

// GetParticipants implements Repo: one GetAll of beacons/{id}/beaconParticipants/{uid} over beaconIDs (at most a page),
// outside any transaction; a missing row is absent from the map.
func (r *FirestoreRepo) GetParticipants(ctx context.Context, uid string, beaconIDs []string) (map[string]Participant, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	out := make(map[string]Participant, len(beaconIDs))
	if len(beaconIDs) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, 0, len(beaconIDs))
	for _, id := range beaconIDs {
		refs = append(refs, r.participantRef(id, uid))
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: get participants: %w", err), append([]string{uid}, beaconIDs...)...)
	}
	for i, s := range snaps {
		if !s.Exists() {
			continue
		}
		id := beaconIDs[i]
		var d participantDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode participant: %w", err), uid, id)
		}
		if d.UID == "" {
			d.UID = uid
		}
		out[id] = d.participant(id)
	}
	return out, nil
}

// ListMemberships implements Repo: users/{uid}/beaconMemberships, role in q.Roles when set, endAt >= now soonest first
// (upcoming) or endAt < now most recent first (past), then document id, resuming after (q.AfterEndAt, q.AfterID).
// Composite index (role, endAt) in both directions.
func (r *FirestoreRepo) ListMemberships(ctx context.Context, q MembershipQuery) ([]Membership, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	col := r.client.Collection(usersCollection).Doc(q.UID).Collection(membershipsSubcollection)
	fq := col.Query
	if len(q.Roles) > 0 {
		fq = fq.Where("role", "in", q.Roles)
	}
	dir := firestore.Asc
	if q.Past {
		dir = firestore.Desc
		fq = fq.Where("endAt", "<", q.Now.UTC())
	} else {
		fq = fq.Where("endAt", ">=", q.Now.UTC())
	}
	fq = fq.OrderBy("endAt", dir).OrderBy(firestore.DocumentID, dir)
	if q.AfterID != "" {
		fq = fq.StartAfter(q.AfterEndAt.UTC(), col.Doc(q.AfterID))
	}
	docs, err := fq.Limit(min(max(q.Limit, 1), maxListDocs)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: list memberships: %w", err), q.UID, q.AfterID)
	}
	out := make([]Membership, 0, len(docs))
	for _, s := range docs {
		var m membershipDoc
		if err := s.DataTo(&m); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode membership: %w", err), q.UID, s.Ref.ID)
		}
		out = append(out, m.membership(s.Ref.ID))
	}
	return out, nil
}

// GetBeacons implements Repo: one GetAll over the ids; a missing document is absent from the map.
func (r *FirestoreRepo) GetBeacons(ctx context.Context, ids []string) (map[string]Beacon, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	out := make(map[string]Beacon, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, 0, len(ids))
	for _, id := range ids {
		refs = append(refs, r.ref(id))
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: get beacons: %w", err), ids...)
	}
	for _, s := range snaps {
		if !s.Exists() {
			continue
		}
		var d beaconDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode beacon: %w", err), s.Ref.ID)
		}
		out[s.Ref.ID] = d.beacon(s.Ref.ID)
	}
	return out, nil
}

// ListParticipants implements Repo: the rows of one beacon in q.State, oldest first by respondedAt (ACCEPTED) or
// requestedAt (REQUESTED), then document id, resuming after (q.AfterAt, q.AfterUID). Composite index (state, <at>).
func (r *FirestoreRepo) ListParticipants(ctx context.Context, q ParticipantQuery) ([]Participant, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	at := "requestedAt"
	if q.State == PStateAccepted {
		at = "respondedAt"
	}
	col := r.ref(q.BeaconID).Collection(participantsSubcollection)
	fq := col.Where("state", "==", q.State).OrderBy(at, firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if q.AfterUID != "" {
		fq = fq.StartAfter(q.AfterAt.UTC(), col.Doc(q.AfterUID))
	}
	docs, err := fq.Limit(min(max(q.Limit, 1), maxListDocs)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: list participants: %w", err), q.BeaconID, q.AfterUID)
	}
	out := make([]Participant, 0, len(docs))
	for _, s := range docs {
		var d participantDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: decode participant: %w", err), q.BeaconID, s.Ref.ID)
		}
		if d.UID == "" {
			d.UID = s.Ref.ID
		}
		out = append(out, d.participant(q.BeaconID))
	}
	return out, nil
}
