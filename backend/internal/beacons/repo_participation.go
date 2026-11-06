package beacons

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// The idempotency doc id is hashed with these rpc names.
const (
	rpcRequestToJoin        = "RequestToJoin"
	rpcWithdrawJoinRequest  = "WithdrawJoinRequest"
	rpcRespondToJoinRequest = "RespondToJoinRequest"
	rpcLeaveBeacon          = "LeaveBeacon"
	rpcRemoveParticipant    = "RemoveParticipant"
)

// participantDoc is beacons/{beaconId}/beaconParticipants/{uid}. uid is repeated as a field so the lifecycle sweep and
// collection-group reads see it; expireAt is the beacon's (its own TTL policy, R11).
type participantDoc struct {
	UID         string    `firestore:"uid"`
	State       string    `firestore:"state"`
	Note        string    `firestore:"note"`
	RequestedAt time.Time `firestore:"requestedAt"`
	RespondedAt time.Time `firestore:"respondedAt"`
	ExpireAt    time.Time `firestore:"expireAt"`
}

func (d participantDoc) participant(beaconID string) Participant {
	return Participant{BeaconID: beaconID, UID: d.UID, State: d.State, Note: d.Note, RequestedAt: d.RequestedAt, RespondedAt: d.RespondedAt, ExpireAt: d.ExpireAt}
}

// participantRef is beacons/{beaconId}/beaconParticipants/{uid}.
func (r *FirestoreRepo) participantRef(beaconID, uid string) *firestore.DocumentRef {
	return r.ref(beaconID).Collection(participantsSubcollection).Doc(uid)
}

// getBeacon reads beacons/{id} inside tx with no owner check: ErrNotFound when missing.
func (r *FirestoreRepo) getBeacon(ctx context.Context, tx *firestore.Transaction, id string) (beaconDoc, error) {
	snap, err := tx.Get(r.ref(id))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return beaconDoc{}, ErrNotFound
		}
		return beaconDoc{}, fmt.Errorf("beacons: get beacon: %w", err)
	}
	var d beaconDoc
	if err := snap.DataTo(&d); err != nil {
		return beaconDoc{}, fmt.Errorf("beacons: decode beacon: %w", err)
	}
	return d, nil
}

// getParticipantTx reads the row inside tx; exists is false when there is none.
func (r *FirestoreRepo) getParticipantTx(ctx context.Context, tx *firestore.Transaction, beaconID, uid string) (participantDoc, bool, error) {
	snap, err := tx.Get(r.participantRef(beaconID, uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return participantDoc{}, false, nil
		}
		return participantDoc{}, false, fmt.Errorf("beacons: get participant: %w", err)
	}
	var d participantDoc
	if err := snap.DataTo(&d); err != nil {
		return participantDoc{}, false, fmt.Errorf("beacons: decode participant: %w", err)
	}
	return d, true, nil
}

// countPending counts uid's live requests (membership rows with pending == true), inside tx, stopping at limit
// (single-field index, R10).
func (r *FirestoreRepo) countPending(ctx context.Context, tx *firestore.Transaction, uid string, limit int) (int64, error) {
	q := r.client.Collection(usersCollection).Doc(uid).Collection(membershipsSubcollection).Where("pending", "==", true).Limit(limit)
	res, err := q.NewAggregationQuery().WithCount("n").Transaction(tx).Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("beacons: count pending: %w", err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("beacons: count decode: %w", err)
	}
	return out.N, nil
}

// replayParticipation answers a replay of a participation write from the beacon and the target's row as they are now.
func (r *FirestoreRepo) replayParticipation(ctx context.Context, tx *firestore.Transaction, rec idempotency.Record) (ParticipantResult, error) {
	id, target := rec.Result["id"], rec.Result["uid"]
	if id == "" || target == "" {
		return ParticipantResult{}, ErrNotFound
	}
	d, err := r.getBeacon(ctx, tx, id)
	if err != nil {
		return ParticipantResult{}, err
	}
	pd, _, err := r.getParticipantTx(ctx, tx, id, target)
	if err != nil {
		return ParticipantResult{}, err
	}
	return ParticipantResult{Outcome: Replayed, Beacon: d.beacon(id), Participant: pd.participant(id)}, nil
}

// checkLive refuses a mutation on a CANCELLED or ENDED beacon.
func checkLive(d beaconDoc, id string, now time.Time) error {
	switch d.beacon(id).EffectiveStatus(now) {
	case StatusCancelled:
		return ErrCancelled
	case StatusEnded:
		return ErrEnded
	}
	return nil
}

func idemResult(beaconID, target string) map[string]string {
	return map[string]string{"id": beaconID, "uid": target}
}

// Request implements Repo (RequestToJoin). Reads, fresh and in order: idempotency, the beacon, the caller's row, the
// caller's pending count. Refusals write nothing: ErrOrganiser, ErrCancelled, ErrEnded, ErrFull, ErrAlreadyRequested,
// ErrPendingLimit. An ACCEPTED caller is Unchanged (idempotency doc only). Otherwise the row is (re)written REQUESTED
// with the note and the beacon's expireAt, the membership row becomes requester/requested/pending.
func (r *FirestoreRepo) Request(ctx context.Context, p RequestParams) (ParticipantResult, error) {
	if err := r.ready(); err != nil {
		return ParticipantResult{}, err
	}
	var res ParticipantResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = ParticipantResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res, err = r.replayParticipation(ctx, tx, rec)
			}
			return err
		}
		d, err := r.getBeacon(ctx, tx, p.BeaconID)
		if err != nil {
			return err
		}
		if d.OrganiserID == p.UID {
			return ErrOrganiser
		}
		if err := checkLive(d, p.BeaconID, p.Now); err != nil {
			return err
		}
		if d.Status == string(StatusFull) {
			return ErrFull
		}
		pd, exists, err := r.getParticipantTx(ctx, tx, p.BeaconID, p.UID)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		if exists && pd.State == PStateRequested {
			return ErrAlreadyRequested
		}
		if exists && pd.State == PStateAccepted {
			r.putIdemResult(b, p.UID, p.IdemKey, rpcRequestToJoin, p.RequestHash, idemResult(p.BeaconID, p.UID))
			if err := b.Err(); err != nil {
				return err
			}
			res = ParticipantResult{Outcome: Unchanged, Beacon: d.beacon(p.BeaconID), Participant: pd.participant(p.BeaconID)}
			return nil
		}
		n, err := r.countPending(ctx, tx, p.UID, p.MaxPending)
		if err != nil {
			return err
		}
		if n >= int64(p.MaxPending) {
			return ErrPendingLimit
		}
		pd = participantDoc{UID: p.UID, State: PStateRequested, Note: p.Note, RequestedAt: p.Now.UTC(), ExpireAt: d.ExpireAt}
		b.Set(r.participantRef(p.BeaconID, p.UID), pd)
		b.Set(r.membershipRef(p.UID, p.BeaconID), membershipDoc{
			BeaconID: p.BeaconID, Role: RoleRequester, State: PStateRequested, Pending: true, CommunityID: d.CommunityID, StartAt: d.StartAt, EndAt: d.EndAt,
		})
		r.putIdemResult(b, p.UID, p.IdemKey, rpcRequestToJoin, p.RequestHash, idemResult(p.BeaconID, p.UID))
		if err := b.Err(); err != nil {
			return err
		}
		res = ParticipantResult{Outcome: Written, Beacon: d.beacon(p.BeaconID), Participant: pd.participant(p.BeaconID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}

// Withdraw implements Repo (WithdrawJoinRequest): the caller's REQUESTED row becomes WITHDRAWN and its membership row
// stops being pending; any other state is ErrNotRequested.
func (r *FirestoreRepo) Withdraw(ctx context.Context, p StateParams) (ParticipantResult, error) {
	return r.transition(ctx, p, rpcWithdrawJoinRequest, false, PStateRequested, PStateWithdrawn, ErrNotRequested)
}

// Leave implements Repo (LeaveBeacon): the caller's ACCEPTED row becomes LEFT, the beacon's acceptedCount drops and a
// FULL beacon reopens; any other state is ErrNotParticipant.
func (r *FirestoreRepo) Leave(ctx context.Context, p StateParams) (ParticipantResult, error) {
	return r.transition(ctx, p, rpcLeaveBeacon, false, PStateAccepted, PStateLeft, ErrNotParticipant)
}

// Remove implements Repo (RemoveParticipant): the organiser moves the target's ACCEPTED row to REMOVED with the same
// count rules as Leave; any other caller is ErrNotOrganiser.
func (r *FirestoreRepo) Remove(ctx context.Context, p StateParams) (ParticipantResult, error) {
	return r.transition(ctx, p, rpcRemoveParticipant, true, PStateAccepted, PStateRemoved, ErrNotParticipant)
}

// transition is the shared body of Withdraw, Leave and Remove: idempotency, the beacon (owner-checked when owned),
// the live check, the target's row in `from` (else notIn), then the row to `to`, the membership row no longer pending,
// and, when leaving an ACCEPTED seat, the beacon's count and status.
func (r *FirestoreRepo) transition(ctx context.Context, p StateParams, rpc string, owned bool, from, to string, notIn error) (ParticipantResult, error) {
	if err := r.ready(); err != nil {
		return ParticipantResult{}, err
	}
	var res ParticipantResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = ParticipantResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res, err = r.replayParticipation(ctx, tx, rec)
			}
			return err
		}
		var d beaconDoc
		if owned {
			d, err = r.getOwned(ctx, tx, p.UID, p.BeaconID)
		} else {
			d, err = r.getBeacon(ctx, tx, p.BeaconID)
		}
		if err != nil {
			return err
		}
		if err := checkLive(d, p.BeaconID, p.Now); err != nil {
			return err
		}
		pd, exists, err := r.getParticipantTx(ctx, tx, p.BeaconID, p.TargetUID)
		if err != nil {
			return err
		}
		if !exists || pd.State != from {
			return notIn
		}
		b := store.NewFirestoreTxBatch(tx)
		now := p.Now.UTC()
		pd.State = to
		b.Update(r.participantRef(p.BeaconID, p.TargetUID), []firestore.Update{{Path: "state", Value: to}})
		b.Set(r.membershipRef(p.TargetUID, p.BeaconID), map[string]any{"state": to, "pending": false}, firestore.MergeAll)
		if from == PStateAccepted {
			d.AcceptedCount = max(d.AcceptedCount-1, 0)
			d.Status, d.UpdatedAt = string(liveStatus(d.AcceptedCount, d.OpenSpots)), now
			b.Update(r.ref(p.BeaconID), []firestore.Update{
				{Path: "acceptedCount", Value: d.AcceptedCount},
				{Path: "status", Value: d.Status},
				{Path: "updatedAt", Value: now},
			})
		}
		r.putIdemResult(b, p.UID, p.IdemKey, rpc, p.RequestHash, idemResult(p.BeaconID, p.TargetUID))
		if err := b.Err(); err != nil {
			return err
		}
		res = ParticipantResult{Outcome: Written, Beacon: d.beacon(p.BeaconID), Participant: pd.participant(p.BeaconID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}

// Respond implements Repo (RespondToJoinRequest). Reads: idempotency, the beacon (owner-checked), the target's row
// (REQUESTED else ErrNotRequested). ACCEPT at capacity is ErrFull and writes nothing; two racing accepts both read and
// write the beacon, so only one commits. Otherwise the row becomes ACCEPTED (respondedAt) with the beacon's count and
// status, or DECLINED; the membership row follows.
func (r *FirestoreRepo) Respond(ctx context.Context, p RespondParams) (ParticipantResult, error) {
	if err := r.ready(); err != nil {
		return ParticipantResult{}, err
	}
	var res ParticipantResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = ParticipantResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res, err = r.replayParticipation(ctx, tx, rec)
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.BeaconID)
		if err != nil {
			return err
		}
		if err := checkLive(d, p.BeaconID, p.Now); err != nil {
			return err
		}
		pd, exists, err := r.getParticipantTx(ctx, tx, p.BeaconID, p.TargetUID)
		if err != nil {
			return err
		}
		if !exists || pd.State != PStateRequested {
			return ErrNotRequested
		}
		b := store.NewFirestoreTxBatch(tx)
		now := p.Now.UTC()
		pd.RespondedAt = now
		if p.Accept {
			if d.AcceptedCount >= d.OpenSpots {
				return ErrFull
			}
			pd.State = PStateAccepted
			d.AcceptedCount++
			d.Status, d.UpdatedAt = string(liveStatus(d.AcceptedCount, d.OpenSpots)), now
			b.Update(r.ref(p.BeaconID), []firestore.Update{
				{Path: "acceptedCount", Value: d.AcceptedCount},
				{Path: "status", Value: d.Status},
				{Path: "updatedAt", Value: now},
			})
			b.Set(r.membershipRef(p.TargetUID, p.BeaconID), map[string]any{"role": RoleParticipant, "state": PStateAccepted, "pending": false}, firestore.MergeAll)
		} else {
			pd.State = PStateDeclined
			b.Set(r.membershipRef(p.TargetUID, p.BeaconID), map[string]any{"state": PStateDeclined, "pending": false}, firestore.MergeAll)
		}
		b.Update(r.participantRef(p.BeaconID, p.TargetUID), []firestore.Update{
			{Path: "state", Value: pd.State},
			{Path: "respondedAt", Value: now},
		})
		r.putIdemResult(b, p.UID, p.IdemKey, rpcRespondToJoinRequest, p.RequestHash, idemResult(p.BeaconID, p.TargetUID))
		if err := b.Err(); err != nil {
			return err
		}
		res = ParticipantResult{Outcome: Written, Beacon: d.beacon(p.BeaconID), Participant: pd.participant(p.BeaconID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}
