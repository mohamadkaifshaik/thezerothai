package beacons

// repo_reschedule.go is the F28 part of Repo.Update: a change of start_at, duration_minutes or cost. start_at drives the
// beacon's endAt and its TTL expireAt, and both are denormalized: every participant row carries the beacon's expireAt
// (its own TTL policy, R11) and every membership row carries startAt and endAt (and a live request its pendingUntil, the
// beacon's endAt), so a new start or duration rewrites them all in the same transaction as the beacon. The rows are read
// inside the transaction (at most maxEditRows + 1 participant rows, then one GetAll of the matching membership refs) and
// updated field-level, never Set: a membership row an erasure removed stays removed.

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// reschedulePlan is what one Update adds for F28: the beacon's own field updates, the row writes to stage after them,
// whether start, duration or cost changed, and the participants ACCEPTED at this commit.
type reschedulePlan struct {
	beacon   []firestore.Update
	rows     []rowUpdate
	changed  bool
	accepted []string
}

type rowUpdate struct {
	ref     *firestore.DocumentRef
	updates []firestore.Update
}

func (p reschedulePlan) stage(b store.Batch) {
	for _, w := range p.rows {
		b.Update(w.ref, w.updates)
	}
}

// planReschedule compares the request's start, duration and cost with d (stored precision: microseconds) and, when any
// differs, refuses with ErrStarted once p.Now reached the stored start, else updates d in place and plans the writes.
// Every read happens here, before the caller stages any write.
func (r *FirestoreRepo) planReschedule(ctx context.Context, tx *firestore.Transaction, p UpdateParams, d *beaconDoc) (reschedulePlan, error) {
	var plan reschedulePlan
	start, duration := d.StartAt, d.DurationMin
	if p.StartAt != nil && !p.StartAt.Equal(d.StartAt) {
		start = p.StartAt.UTC()
	}
	if p.DurationMin != nil {
		duration = *p.DurationMin
	}
	timing := !start.Equal(d.StartAt) || duration != d.DurationMin
	costChanged := p.Cost != nil && string(*p.Cost) != d.Cost
	if !timing && !costChanged {
		return plan, nil
	}
	if !p.Now.Before(d.StartAt) {
		return plan, ErrStarted
	}
	rows, err := r.participantsIn(ctx, tx, p.BeaconID, p.MaxEditRows)
	if err != nil {
		return plan, err
	}
	plan.changed = true
	for _, row := range rows {
		if row.State == PStateAccepted {
			plan.accepted = append(plan.accepted, row.UID)
		}
	}
	if costChanged {
		plan.beacon = append(plan.beacon, firestore.Update{Path: "cost", Value: string(*p.Cost)})
		d.Cost = string(*p.Cost)
	}
	if !timing {
		return plan, nil
	}
	end := start.Add(time.Duration(duration) * time.Minute)
	expire := start.Add(ExpireAfterStart)
	moveTTL := !expire.Equal(d.ExpireAt)
	plan.beacon = append(plan.beacon,
		firestore.Update{Path: "startAt", Value: start},
		firestore.Update{Path: "endAt", Value: end},
		firestore.Update{Path: "durationMin", Value: duration},
	)
	if moveTTL {
		plan.beacon = append(plan.beacon, firestore.Update{Path: "expireAt", Value: expire})
	}
	d.StartAt, d.EndAt, d.DurationMin, d.ExpireAt = start, end, duration, expire

	// The organiser's membership row and one per participant row (any state: a declined or withdrawn row is history the
	// owner still lists under PAST, so its window moves with the beacon).
	refs := make([]*firestore.DocumentRef, 0, len(rows)+1)
	refs = append(refs, r.membershipRef(d.OrganiserID, p.BeaconID))
	for _, row := range rows {
		if moveTTL {
			plan.rows = append(plan.rows, rowUpdate{ref: r.participantRef(p.BeaconID, row.UID), updates: []firestore.Update{{Path: "expireAt", Value: expire}}})
		}
		refs = append(refs, r.membershipRef(row.UID, p.BeaconID))
	}
	snaps, err := tx.GetAll(refs)
	if err != nil {
		return plan, fmt.Errorf("beacons: read memberships to reschedule: %w", err)
	}
	for _, s := range snaps {
		if !s.Exists() {
			continue // erased with its owner's account; never recreated
		}
		var m membershipDoc
		if err := s.DataTo(&m); err != nil {
			return plan, fmt.Errorf("beacons: decode membership to reschedule: %w", err)
		}
		ups := []firestore.Update{{Path: "startAt", Value: start}, {Path: "endAt", Value: end}}
		if !m.PendingUntil.IsZero() {
			ups = append(ups, firestore.Update{Path: "pendingUntil", Value: end}) // a live request keeps counting until the new end
		}
		plan.rows = append(plan.rows, rowUpdate{ref: s.Ref, updates: ups})
	}
	return plan, nil
}

// participantsIn reads every participant row of beaconID inside tx, at most maxRows (ErrEditRows past it).
func (r *FirestoreRepo) participantsIn(ctx context.Context, tx *firestore.Transaction, beaconID string, maxRows int) ([]participantDoc, error) {
	if maxRows <= 0 {
		maxRows = MaxEditRows
	}
	docs, err := tx.Documents(r.ref(beaconID).Collection(participantsSubcollection).Limit(maxRows + 1)).GetAll()
	if err != nil {
		return nil, fmt.Errorf("beacons: read participants to reschedule: %w", err)
	}
	if len(docs) > maxRows {
		return nil, ErrEditRows
	}
	out := make([]participantDoc, 0, len(docs))
	for _, s := range docs {
		var pd participantDoc
		if err := s.DataTo(&pd); err != nil {
			return nil, fmt.Errorf("beacons: decode participant to reschedule: %w", err)
		}
		if pd.UID == "" {
			pd.UID = s.Ref.ID
		}
		out = append(out, pd)
	}
	return out, nil
}
