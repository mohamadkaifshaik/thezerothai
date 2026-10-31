package lists

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// listsCollection is the one collection this module owns (ADR-0030 D2). Only lists.FirestoreRepo touches it. It has a T11
	// row (apiserver/lifecycle_collections_guard_test.go), the `lists` eraser step and the `lists` export section (W5-5).
	listsCollection = "lists"

	// The idempotency doc id is hashed with these rpc names (ADR-0030 D7).
	rpcCreateList = "CreateList"
	rpcUpdateList = "UpdateList"
	rpcDeleteList = "DeleteList"

	// txTimeout bounds one list transaction (all attempts); maxTxRuns bounds the outer re-runs after the SDK's own attempts
	// lost the lock race. A list doc has one writer (its owner), so contention is a double tap, not a hot document.
	txTimeout = 5 * time.Second
	maxTxRuns = 3
	txBackoff = 20 * time.Millisecond
)

// listDoc is lists/{listId} (ADR-0030 D2). memberIds is always written as an array (never null) and stays indexed: the
// eraser's `memberIds array-contains uid` query needs the automatic array index, so firestore.indexes.json has no override.
type listDoc struct {
	OwnerID     string    `firestore:"ownerId"`
	Name        string    `firestore:"name"`
	Description string    `firestore:"description"`
	IsPrivate   bool      `firestore:"isPrivate"`
	MemberIDs   []string  `firestore:"memberIds"`
	Hidden      bool      `firestore:"hidden,omitempty"`
	CreatedAt   time.Time `firestore:"createdAt"`
	UpdatedAt   time.Time `firestore:"updatedAt"`
}

func (d listDoc) list(id string) List {
	return List{
		ID: id, OwnerID: d.OwnerID, Name: d.Name, Description: d.Description, IsPrivate: d.IsPrivate,
		MemberIDs: slices.Clone(d.MemberIDs), Hidden: d.Hidden, CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt,
	}
}

func (l List) header() Header {
	return Header{ID: l.ID, Name: l.Name, Description: l.Description, IsPrivate: l.IsPrivate, MemberCount: len(l.MemberIDs)}
}

// FirestoreRepo is the Firestore implementation of Repo, and the page source of the eraser and the exporter.
type FirestoreRepo struct {
	client *firestore.Client
	quotas *quota.Store
	idem   *idempotency.Store
	now    func() time.Time
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repository on the process's one Firestore client. quotas and idem are the shared stores; a
// repo built without them (the lifecycle tests) can still erase and export.
func NewFirestoreRepo(client *firestore.Client, quotas *quota.Store, idem *idempotency.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, quotas: quotas, idem: idem, now: time.Now}
}

func (r *FirestoreRepo) col() *firestore.CollectionRef { return r.client.Collection(listsCollection) }

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef { return r.col().Doc(id) }

func (r *FirestoreRepo) ready() error {
	if r == nil || r.client == nil || r.quotas == nil || r.idem == nil {
		return errors.New("lists: repo is not fully wired")
	}
	return nil
}

// run is one list transaction with bounded re-runs. A same-key request that committed first leaves AlreadyExists on this
// one's idempotency Create; the transaction is run once more, finds the record and replays it.
func (r *FirestoreRepo) run(ctx context.Context, fn store.TxnFunc) (int, error) {
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, fn)
	if status.Code(err) == codes.AlreadyExists {
		again, err2 := store.RunTransactionRetry(ctx, r.client, cfg, fn)
		return attempts + again, err2
	}
	return attempts, err
}

// headerResult is the Result map of an idempotency record: the header as strings.
func headerResult(h Header) map[string]string {
	return map[string]string{
		"id": h.ID, "name": h.Name, "description": h.Description,
		"private": strconv.FormatBool(h.IsPrivate), "members": strconv.Itoa(h.MemberCount),
	}
}

func resultHeader(m map[string]string) Header {
	n, _ := strconv.Atoi(m["members"])
	return Header{ID: m["id"], Name: m["name"], Description: m["description"], IsPrivate: m["private"] == "true", MemberCount: n}
}

// putIdem appends the TTL'd idempotency document of rpc, holding the answer, to b (same atomic unit as the effect).
func (r *FirestoreRepo) putIdem(b store.Batch, uid, key, rpc, hash string, result map[string]string) {
	r.idem.Put(b, key, idempotency.Record{
		UID: uid, RPC: rpc, RequestHash: hash, Result: result, ExpireAt: r.now().UTC().Add(idempotency.TTL),
	})
}

// lookup reads the idempotency document in tx (1 read). found with a nil error is a replay; found with ErrKeyReused is a
// record that belongs to another request body; not found means the caller proceeds.
func (r *FirestoreRepo) lookup(ctx context.Context, tx *firestore.Transaction, key, hash string) (rec idempotency.Record, found bool, err error) {
	rec, err = r.idem.Get(ctx, tx, key)
	switch {
	case err == nil:
		if rec.RequestHash != hash {
			return rec, true, ErrKeyReused
		}
		return rec, true, nil
	case errors.Is(err, idempotency.ErrNotFound):
		return rec, false, nil
	default:
		return rec, false, fmt.Errorf("lists: idempotency lookup: %w", err)
	}
}

// countOwned counts uid's lists inside tx, stopping at max (the cap check is exact: n >= max means full). An aggregation
// is invisible to the store wrappers, so it is charged by hand: one read per 1,000 entries counted, minimum 1.
func (r *FirestoreRepo) countOwned(ctx context.Context, tx *firestore.Transaction, uid string, limit int) (int64, error) {
	q := r.col().Where("ownerId", "==", uid).Limit(limit)
	res, err := q.NewAggregationQuery().WithCount("n").Transaction(tx).Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("lists: count owned: %w", err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("lists: count decode: %w", err)
	}
	budget.FromContext(ctx).AddReads(out.N/1000 + 1)
	return out.N, nil
}

// Create implements Repo: one transaction (ADR-0030 D7, rule 4). Reads, fresh and in this order: idempotency/{hash} (a
// replay returns here: 1 read), quotas/{uid}, count() of the owner's lists (3 reads; the cap is exact). Writes 3: Create the
// list, Create the idempotency document, the quota record. At the cap or over the quota nothing is written.
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if err := r.ready(); err != nil {
		return CreateResult{}, err
	}
	var res CreateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = CreateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = CreateResult{Outcome: Replayed, Header: resultHeader(rec.Result)}
			}
			return err
		}
		qrec, err := r.quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("lists: quota lookup: %w", err)
		}
		n, err := r.countOwned(ctx, tx, p.UID, p.MaxPerUser)
		if err != nil {
			return err
		}
		if n >= int64(p.MaxPerUser) {
			return ErrListLimit
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if err := quota.CheckAndReserve(b, r.quotas.Ref(p.UID), qrec, quota.ListCreates, p.QuotaLimit); err != nil {
			return err
		}
		now := r.now().UTC()
		doc := listDoc{
			OwnerID: p.UID, Name: p.Name, Description: p.Description, IsPrivate: p.IsPrivate,
			MemberIDs: []string{}, CreatedAt: now, UpdatedAt: now,
		}
		l := doc.list(p.ID)
		b.Create(r.ref(p.ID), doc)
		r.putIdem(b, p.UID, p.IdemKey, rpcCreateList, p.RequestHash, headerResult(l.header()))
		if err := b.Err(); err != nil {
			return err
		}
		res = CreateResult{Outcome: Written, Header: l.header(), List: &l}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}

// getOwned reads lists/{id} inside tx (1 read) and decodes it, or ErrNotFound when it is missing or not uid's. The two are
// indistinguishable to every caller (ADR-0030 D3).
func (r *FirestoreRepo) getOwned(ctx context.Context, tx *firestore.Transaction, uid, id string) (listDoc, error) {
	snap, err := tx.Get(r.ref(id))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return listDoc{}, ErrNotFound
		}
		return listDoc{}, fmt.Errorf("lists: get list: %w", err)
	}
	var d listDoc
	if err := snap.DataTo(&d); err != nil {
		return listDoc{}, fmt.Errorf("lists: decode list: %w", err)
	}
	if d.OwnerID != uid {
		return listDoc{}, ErrNotFound
	}
	return d, nil
}

// Update implements Repo: one transaction. Reads, fresh: idempotency (a replay returns: 1 read), the list (2 reads). The
// list changes through a field-level Update (it fails on a missing document, never a Set, so a write can not recreate a
// deleted list): 2 writes (list, idempotency), or 1 when no set field differs from what is stored. A missing, foreign or
// deleted list is ErrNotFound and writes nothing (an error is not recorded).
func (r *FirestoreRepo) Update(ctx context.Context, p UpdateParams) (UpdateResult, error) {
	if err := r.ready(); err != nil {
		return UpdateResult{}, err
	}
	var res UpdateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = UpdateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = UpdateResult{Outcome: Replayed, Header: resultHeader(rec.Result)}
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.ListID)
		if err != nil {
			return err
		}
		var updates []firestore.Update
		nameChanged := false
		if p.Name != nil && *p.Name != d.Name {
			updates = append(updates, firestore.Update{Path: "name", Value: *p.Name})
			d.Name, nameChanged = *p.Name, true
		}
		if p.Description != nil && *p.Description != d.Description {
			updates = append(updates, firestore.Update{Path: "description", Value: *p.Description})
			d.Description = *p.Description
		}
		if p.IsPrivate != nil && *p.IsPrivate != d.IsPrivate {
			updates = append(updates, firestore.Update{Path: "isPrivate", Value: *p.IsPrivate})
			d.IsPrivate = *p.IsPrivate
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		outcome := Unchanged
		if len(updates) > 0 {
			d.UpdatedAt = r.now().UTC()
			updates = append(updates, firestore.Update{Path: "updatedAt", Value: d.UpdatedAt})
			b.Update(r.ref(p.ListID), updates) // an Update never creates a document: a deleted list stays deleted
			outcome = Written
		}
		l := d.list(p.ListID)
		r.putIdem(b, p.UID, p.IdemKey, rpcUpdateList, p.RequestHash, headerResult(l.header()))
		if err := b.Err(); err != nil {
			return err
		}
		res = UpdateResult{Outcome: outcome, Header: l.header(), List: &l, NameChanged: nameChanged}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}

// Delete implements Repo: one transaction. Reads, fresh: idempotency (a replay returns: 1 read), the list (2 reads). The
// owner's list is deleted with an Exists precondition (1 delete) and the idempotency document is written (1 write). A
// list that is missing or not the caller's is success with no effect: still the idempotency document (1 write), so a late
// retry replays (ADR-0030 D7, the DeletePost precedent).
func (r *FirestoreRepo) Delete(ctx context.Context, p DeleteParams) (DeleteResult, error) {
	if err := r.ready(); err != nil {
		return DeleteResult{}, err
	}
	var res DeleteResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = DeleteResult{}
		_, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				res = DeleteResult{Outcome: Replayed}
			}
			return err
		}
		_, gerr := r.getOwned(ctx, tx, p.UID, p.ListID)
		if gerr != nil && !errors.Is(gerr, ErrNotFound) {
			return gerr
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		deleted := gerr == nil
		if deleted {
			b.Delete(r.ref(p.ListID), firestore.Exists)
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcDeleteList, p.RequestHash, map[string]string{"deleted": strconv.FormatBool(deleted)})
		if err := b.Err(); err != nil {
			return err
		}
		res = DeleteResult{Outcome: Unchanged, Deleted: deleted}
		if deleted {
			res.Outcome = Written
		}
		return nil
	})
	store.NoteTxnAttempts(ctx, "lists_txn_contention", attempts)
	return res, err
}
