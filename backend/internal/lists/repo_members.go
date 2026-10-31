package lists

import (
	"context"
	"fmt"
	"slices"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	rpcAddListMember    = "AddListMember"
	rpcRemoveListMember = "RemoveListMember"
)

// dropBlocking returns members without the entries of blockedBy (the owner's blockedBy: accounts that block the owner, F4) and
// without skip, in the stored order, as a fresh non-nil slice (an empty array is written as an array, never null, because the
// eraser's array-contains query needs it, ADR-0030 D2). The caller\u2019s slice is not changed.
func dropBlocking(members []string, blockedBy map[string]bool, skip string) []string {
	out := make([]string, 0, len(members))
	for _, m := range members {
		if m == skip || blockedBy[m] {
			continue
		}
		out = append(out, m)
	}
	return out
}

// writeMembers appends the field-level Update that replaces memberIds with members (computed from the document read fresh in
// this transaction, so a whole-array write loses nothing) and moves updatedAt. An Update never creates a document: a list
// deleted meanwhile stays deleted. ArrayUnion and ArrayRemove cannot share one field in one write, which the lazy drop needs.
func (r *FirestoreRepo) writeMembers(b store.Batch, id string, d *listDoc, members []string) {
	d.MemberIDs = members
	d.UpdatedAt = r.now().UTC()
	b.Update(r.ref(id), []firestore.Update{{Path: "memberIds", Value: members}, {Path: "updatedAt", Value: d.UpdatedAt}})
}

// AddMember implements Repo: one transaction (ADR-0030 D4, D7). Reads, fresh and in this order: idempotency/{hash} (a replay
// returns here: 1 read), the list (2; a foreign or missing list is ErrNotFound before anything about the target is said),
// then the service's Refusal, then quotas/{uid} (3) only when a member is really added. Already a member: the idempotency
// document only (1 write), no quota. The cap is checked on the list after the lazy drop of members who block the owner (F4), so
// the drop can make room; at the cap nothing is written. Otherwise 3 writes: the list (memberIds, updatedAt), the quota record,
// the idempotency document.
func (r *FirestoreRepo) AddMember(ctx context.Context, p AddMemberParams) (MemberResult, error) {
	if err := r.ready(); err != nil {
		return MemberResult{}, err
	}
	var res MemberResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = MemberResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = MemberResult{Outcome: Replayed, Header: resultHeader(rec.Result)}
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.ListID)
		if err != nil {
			return err
		}
		if p.Refusal != nil {
			return p.Refusal
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if slices.Contains(d.MemberIDs, p.TargetID) {
			l := d.list(p.ListID)
			r.putIdem(b, p.UID, p.IdemKey, rpcAddListMember, p.RequestHash, headerResult(l.header()))
			if err := b.Err(); err != nil {
				return err
			}
			res = MemberResult{Outcome: Unchanged, Header: l.header(), List: &l}
			return nil
		}
		kept := dropBlocking(d.MemberIDs, p.BlockedBy, "")
		if len(kept) >= p.MaxMembers {
			return ErrMemberLimit
		}
		qrec, err := r.quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("lists: quota lookup: %w", err)
		}
		if err := quota.CheckAndReserve(b, r.quotas.Ref(p.UID), qrec, quota.ListAdds, p.QuotaLimit); err != nil {
			return err
		}
		dropped := len(d.MemberIDs) - len(kept)
		r.writeMembers(b, p.ListID, &d, append(kept, p.TargetID))
		l := d.list(p.ListID)
		r.putIdem(b, p.UID, p.IdemKey, rpcAddListMember, p.RequestHash, headerResult(l.header()))
		if err := b.Err(); err != nil {
			return err
		}
		res = MemberResult{Outcome: Written, Header: l.header(), List: &l, Dropped: dropped}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}

// RemoveMember implements Repo: one transaction. Reads, fresh: idempotency (a replay returns: 1 read), the list (2; a foreign
// or missing list is ErrNotFound). Not a member: the idempotency document only (1 write), the list untouched. A member:
// BlockedBy is loaded (cache-first, 1 read cold) and the same write drops members who block the owner (F4): 2 writes (list,
// idempotency). No quota.
func (r *FirestoreRepo) RemoveMember(ctx context.Context, p RemoveMemberParams) (MemberResult, error) {
	if err := r.ready(); err != nil {
		return MemberResult{}, err
	}
	var res MemberResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = MemberResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = MemberResult{Outcome: Replayed, Header: resultHeader(rec.Result)}
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.ListID)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		outcome, dropped := Unchanged, 0
		if slices.Contains(d.MemberIDs, p.TargetID) {
			var blockedBy map[string]bool
			if p.BlockedBy != nil {
				blockedBy = p.BlockedBy(ctx)
			}
			kept := dropBlocking(d.MemberIDs, blockedBy, p.TargetID)
			dropped = len(d.MemberIDs) - 1 - len(kept)
			r.writeMembers(b, p.ListID, &d, kept)
			outcome = Written
		}
		l := d.list(p.ListID)
		r.putIdem(b, p.UID, p.IdemKey, rpcRemoveListMember, p.RequestHash, headerResult(l.header()))
		if err := b.Err(); err != nil {
			return err
		}
		res = MemberResult{Outcome: outcome, Header: l.header(), List: &l, Dropped: dropped}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}
