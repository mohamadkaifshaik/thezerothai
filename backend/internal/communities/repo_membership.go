package communities

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	rpcJoinCommunity  = "JoinCommunity"
	rpcLeaveCommunity = "LeaveCommunity"
)

// memberCountDelta is the one writer of communities/{cid}.memberCount: a blind FieldValue.Increment that is
// never read back in the same transaction, so a join burst does not abort other joins on a read lock. The signal for sustained
// contention is `community_txn_attempts` and ABORTED on the request line (noteAttempts); the fallback is the Stage ladder's shards.
func memberCountDelta(n int64) firestore.Update {
	return firestore.Update{Path: "memberCount", Value: firestore.Increment(n)}
}

// notFoundIfNoDoc maps the commit error of a blind field-level Update on a community document that was deleted inside the 60 s cache
// window (Firestore answers NotFound at commit) to the one ErrNotFound.
func notFoundIfNoDoc(err error) error {
	if err != nil && status.Code(err) == codes.NotFound {
		return ErrNotFound
	}
	return err
}

// memberInTx reads the member doc inside tx. A missing doc is MemberNone.
func (r *FirestoreRepo) memberInTx(ctx context.Context, tx *firestore.Transaction, cid, uid string) (MemberState, error) {
	snap, err := tx.Get(r.memberRef(cid, uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return MemberNone, nil
		}
		return MemberNone, fmt.Errorf("communities: get member: %w", err)
	}
	var d memberDoc
	if err := snap.DataTo(&d); err != nil {
		return MemberNone, fmt.Errorf("communities: decode member: %w", err)
	}
	switch MemberState(d.State) {
	case MemberJoined, MemberBanned:
		return MemberState(d.State), nil
	}
	return MemberNone, nil
}

// Join implements Repo. One transaction. Reads, fresh and in this order: idempotency (a replay returns here),
// the caller's member doc (BANNED is ErrBanned, JOINED writes the idempotency document only and spends no quota), the caller's
// memberships (the joined cap is exact, ErrJoinedLimit), quotas/{uid} (QUOTA_EXCEEDED). The community document is never read: its status
// comes from the service's 60 s cache, and memberCount is a blind Increment. Writes: Create the member doc (JOINED), memberships
// (joined += id, created when missing), the memberCount Increment, quotas.communityJoins, and Create the idempotency document. A community
// deleted inside the cache window fails the memberCount Update at commit with NotFound, which is ErrNotFound with nothing written.
func (r *FirestoreRepo) Join(ctx context.Context, p JoinParams) (JoinResult, error) {
	if err := r.ready(); err != nil {
		return JoinResult{}, err
	}
	var res JoinResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = JoinResult{}
		if _, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash); found || err != nil {
			if err == nil {
				res = JoinResult{Outcome: Replayed}
			}
			return err
		}
		st, err := r.memberInTx(ctx, tx, p.ID, p.UID)
		if err != nil {
			return err
		}
		if st == MemberBanned {
			return ErrBanned
		}
		b := store.NewFirestoreTxBatch(tx)
		if st == MemberJoined {
			r.putIdem(b, p.UID, p.IdemKey, rpcJoinCommunity, p.RequestHash, p.ID)
			if err := b.Err(); err != nil {
				return err
			}
			res = JoinResult{Outcome: Unchanged, State: MemberJoined}
			return nil
		}
		ms, exists, err := r.membershipsInTx(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		if len(ms.Joined) >= p.MaxJoined {
			return ErrJoinedLimit
		}
		qrec, err := r.quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("communities: quota lookup: %w", err)
		}
		if err := quota.CheckAndReserve(b, r.quotas.Ref(p.UID), qrec, quota.CommunityJoins, p.QuotaLimit); err != nil {
			return err
		}
		now := r.now().UTC()
		b.Create(r.memberRef(p.ID, p.UID), memberDoc{UID: p.UID, State: string(MemberJoined), JoinedAt: &now})
		if exists {
			b.Update(r.membershipsRef(p.UID), []firestore.Update{
				{Path: "joined", Value: firestore.ArrayUnion(p.ID)},
				{Path: "updatedAt", Value: now},
			})
		} else {
			b.Create(r.membershipsRef(p.UID), membershipsDoc{
				Joined: []string{p.ID}, Owned: []string{}, Banned: []string{}, Modlogged: []string{}, UpdatedAt: now,
			})
		}
		b.Update(r.ref(p.ID), []firestore.Update{memberCountDelta(1)})
		r.putIdem(b, p.UID, p.IdemKey, rpcJoinCommunity, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = JoinResult{Outcome: Written, State: MemberJoined}
		return nil
	})
	noteAttempts(ctx, attempts)
	return res, notFoundIfNoDoc(err)
}

// Leave implements Repo. One transaction. Reads, fresh and in this order: idempotency (a replay returns here), the
// caller's member doc (none or BANNED: the idempotency document only, the ban stays), the caller's memberships (the owner is
// exact there: C in owned, I-M, ErrOwnerLeave, nothing written). A caller who may be a moderator (the service's hint from its cached community,
// or the community in the caller's modlogged, which a promotion adds, I-L) also reads the community fresh: a confirmed
// moderator leaves moderatorIds and gets a MODERATOR_LEFT entry (seq+1, trimmed to ModlogMax) in the same single community Update as
// the memberCount -1, and the community joins modlogged in the same memberships Update. Otherwise the community write is the blind
// memberCount -1. Writes: memberships (joined -= id), the community and idempotency, and a delete of the member doc.
//
// Residual window: a moderator promoted on another instance whose promotion is neither in the service's 60 s
// cache nor in this caller's modlogged would stay in moderatorIds after leaving. The promotion must add the target to modlogged in
// its own transaction (I-L says it does), which closes the window through the repository's fresh check.
func (r *FirestoreRepo) Leave(ctx context.Context, p LeaveParams) (LeaveResult, error) {
	if err := r.ready(); err != nil {
		return LeaveResult{}, err
	}
	var res LeaveResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = LeaveResult{}
		if _, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash); found || err != nil {
			if err == nil {
				res = LeaveResult{Outcome: Replayed}
			}
			return err
		}
		st, err := r.memberInTx(ctx, tx, p.ID, p.UID)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		if st != MemberJoined {
			r.putIdem(b, p.UID, p.IdemKey, rpcLeaveCommunity, p.RequestHash, p.ID)
			if err := b.Err(); err != nil {
				return err
			}
			res = LeaveResult{Outcome: Unchanged, State: st}
			return nil
		}
		ms, exists, err := r.membershipsInTx(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		if slices.Contains(ms.Owned, p.ID) {
			return ErrOwnerLeave
		}
		now := r.now().UTC()
		memUpdates := []firestore.Update{{Path: "joined", Value: firestore.ArrayRemove(p.ID)}, {Path: "updatedAt", Value: now}}
		comUpdates := []firestore.Update{memberCountDelta(-1)}
		var written *Community
		if p.ModeratorHint || slices.Contains(ms.Modlogged, p.ID) {
			c, err := r.getInTx(ctx, tx, p.ID)
			if err != nil {
				return err
			}
			if c.OwnerID == p.UID {
				return ErrOwnerLeave
			}
			next := c
			next.MemberCount--
			if i := slices.Index(c.ModeratorIDs, p.UID); i >= 0 {
				next.ModeratorIDs = slices.Delete(slices.Clone(c.ModeratorIDs), i, i+1)
				entry := LogEntry{Seq: c.ModlogSeq + 1, At: now, Actor: p.UID, Action: ActionModeratorLeft}
				next.Modlog = append(slices.Clone(c.Modlog), entry)
				if p.ModlogMax > 0 && len(next.Modlog) > p.ModlogMax {
					next.Modlog = slices.Clone(next.Modlog[len(next.Modlog)-p.ModlogMax:])
				}
				next.ModlogSeq, next.UpdatedAt = entry.Seq, now
				comUpdates = append(comUpdates,
					firestore.Update{Path: "moderatorIds", Value: firestore.ArrayRemove(p.UID)},
					firestore.Update{Path: "modlog", Value: logDocs(next.Modlog)},
					firestore.Update{Path: "modlogSeq", Value: next.ModlogSeq},
					firestore.Update{Path: "updatedAt", Value: now})
				memUpdates = append(memUpdates, firestore.Update{Path: "modlogged", Value: firestore.ArrayUnion(p.ID)})
			}
			written = &next
		}
		b.Delete(r.memberRef(p.ID, p.UID), firestore.Exists)
		if exists {
			b.Update(r.membershipsRef(p.UID), memUpdates)
		}
		b.Update(r.ref(p.ID), comUpdates)
		r.putIdem(b, p.UID, p.IdemKey, rpcLeaveCommunity, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = LeaveResult{Outcome: Written, State: MemberNone, Community: written}
		return nil
	})
	noteAttempts(ctx, attempts)
	return res, notFoundIfNoDoc(err)
}

// Memberships implements Repo: one point read outside any transaction.
func (r *FirestoreRepo) Memberships(ctx context.Context, uid string) (Memberships, error) {
	if r == nil || r.client == nil {
		return Memberships{}, errors.New("communities: repo has no firestore client")
	}
	snap, err := r.membershipsRef(uid).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Memberships{}, nil
		}
		return Memberships{}, logger.RedactErr(fmt.Errorf("communities: get memberships: %w", err), uid)
	}
	var d membershipsDoc
	if err := snap.DataTo(&d); err != nil {
		return Memberships{}, logger.RedactErr(fmt.Errorf("communities: decode memberships: %w", err), uid)
	}
	return d.memberships(), nil
}

// GetMany implements Repo: one GetAll over the ids.
func (r *FirestoreRepo) GetMany(ctx context.Context, ids []string) (map[string]Community, error) {
	if r == nil || r.client == nil {
		return nil, errors.New("communities: repo has no firestore client")
	}
	out := make(map[string]Community, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = r.ref(id)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("communities: get communities: %w", err), ids...)
	}
	for _, s := range snaps {
		if s == nil || !s.Exists() {
			continue
		}
		var d communityDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("communities: decode community: %w", err), ids...)
		}
		out[s.Ref.ID] = d.community(s.Ref.ID)
	}
	return out, nil
}
