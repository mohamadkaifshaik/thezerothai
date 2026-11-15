package location

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// areaSubcollection is users/{uid}/locationArea/{current}; consentsSubcollection is users/{uid}/locationConsents/{id}.
	// Distinctive names (not a bare `location`) so the collection-group scans of the lifecycle guard and sweep cannot
	// collide. Only FirestoreRepo touches them. Each has a row in apiserver/lifecycle_collections_guard_test.go, the
	// `location` eraser step and the `location` export section.
	areaSubcollection     = "locationArea"
	consentsSubcollection = "locationConsents"
	usersCollection       = "users"
	areaDocID             = "current"

	// The idempotency doc id is hashed with these rpc names.
	rpcSetArea   = "SetArea"
	rpcClearArea = "ClearArea"

	// txTimeout bounds one transaction (all attempts); maxTxRuns bounds the outer re-runs. One user writes their own
	// area doc, so contention is a double tap.
	txTimeout = 5 * time.Second
	maxTxRuns = 3
	txBackoff = 20 * time.Millisecond
)

// ist is the fixed IST (+05:30) offset the daily consent cap rolls over at.
var ist = time.FixedZone("IST", 5*3600+30*60)

// istMidnight is the start of t's IST day.
func istMidnight(t time.Time) time.Time {
	y, m, d := t.In(ist).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, ist).UTC()
}

// areaDoc is users/{uid}/locationArea/current.
type areaDoc struct {
	AreaID             string    `firestore:"areaId"`
	Purposes           []string  `firestore:"purposes"`
	ConsentCopyVersion int       `firestore:"consentCopyVersion"`
	AdultConfirmedAt   time.Time `firestore:"adultConfirmedAt"`
	ConsentedAt        time.Time `firestore:"consentedAt"`
	UpdatedAt          time.Time `firestore:"updatedAt"`
}

func (d areaDoc) stored() *StoredArea {
	s := StoredArea(d)
	return &s
}

// consentDoc is users/{uid}/locationConsents/{snowflake}.
type consentDoc struct {
	Purpose        string    `firestore:"purpose"`
	Action         string    `firestore:"action"`
	CopyVersion    int       `firestore:"copyVersion"`
	AdultConfirmed bool      `firestore:"adultConfirmed"`
	At             time.Time `firestore:"at"`
}

func (d consentDoc) record(id string) *ConsentRecord {
	return &ConsentRecord{ID: id, Purpose: d.Purpose, Action: d.Action, CopyVersion: d.CopyVersion, AdultConfirmed: d.AdultConfirmed, At: d.At}
}

// FirestoreRepo is the Firestore implementation of Repo, and the source of the eraser and the exporter.
type FirestoreRepo struct {
	client *firestore.Client
	idem   *idempotency.Store
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repository on the process's one Firestore client. A repo built without idem (the
// lifecycle tests) can still erase and export.
func NewFirestoreRepo(client *firestore.Client, idem *idempotency.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, idem: idem}
}

func (r *FirestoreRepo) userDoc(uid string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid)
}

func (r *FirestoreRepo) areaRef(uid string) *firestore.DocumentRef {
	return r.userDoc(uid).Collection(areaSubcollection).Doc(areaDocID)
}

func (r *FirestoreRepo) consents(uid string) *firestore.CollectionRef {
	return r.userDoc(uid).Collection(consentsSubcollection)
}

// latestQuery is the newest consent record: `at` DESC with Limit(1), served by the automatic single-field index. The
// design note's __name__ DESC alone is refused ("Firestore does not support descending key scans", seen on the
// emulator); `at` orders one user's records the same way (each is appended at its transaction's time), and equal times
// fall back to the implicit __name__ DESC tie-break, i.e. the later snowflake.
func (r *FirestoreRepo) latestQuery(uid string) firestore.Query {
	return r.consents(uid).OrderBy("at", firestore.Desc).Limit(1)
}

func decodeArea(snap *firestore.DocumentSnapshot, err error) (*StoredArea, error) {
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("location: get area: %w", err)
	}
	var d areaDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("location: decode area: %w", err)
	}
	return d.stored(), nil
}

func decodeLatest(docs []*firestore.DocumentSnapshot, err error) (*ConsentRecord, error) {
	if err != nil {
		return nil, fmt.Errorf("location: latest consent: %w", err)
	}
	if len(docs) == 0 {
		return nil, nil
	}
	var d consentDoc
	if err := docs[0].DataTo(&d); err != nil {
		return nil, fmt.Errorf("location: decode consent: %w", err)
	}
	return d.record(docs[0].Ref.ID), nil
}

// Area implements Repo.
func (r *FirestoreRepo) Area(ctx context.Context, uid string) (*StoredArea, error) {
	a, err := decodeArea(r.areaRef(uid).Get(ctx))
	return a, logger.RedactErr(err, uid)
}

// LatestConsent implements Repo.
func (r *FirestoreRepo) LatestConsent(ctx context.Context, uid string) (*ConsentRecord, error) {
	c, err := decodeLatest(r.latestQuery(uid).Documents(ctx).GetAll())
	return c, logger.RedactErr(err, uid)
}

// stateTx reads the settings state inside tx: the area doc, and the latest consent only when there is no area.
func (r *FirestoreRepo) stateTx(tx *firestore.Transaction, uid string) (State, error) {
	a, err := decodeArea(tx.Get(r.areaRef(uid)))
	if err != nil || a != nil {
		return State{Area: a}, err
	}
	latest, err := decodeLatest(tx.Documents(r.latestQuery(uid)).GetAll())
	return State{Latest: latest}, err
}

// countSince counts uid's consent records with at >= since inside tx, stopping at limit (the single-field `at` index; one
// aggregation read). Inside the transaction, so two racing grants conflict and the cap is exact.
func (r *FirestoreRepo) countSince(ctx context.Context, tx *firestore.Transaction, uid string, since time.Time, limit int) (int64, error) {
	q := r.consents(uid).Where("at", ">=", since).Limit(limit)
	res, err := q.NewAggregationQuery().WithCount("n").Transaction(tx).Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("location: count consents: %w", err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("location: count decode: %w", err)
	}
	return out.N, nil
}

// txBody is the part of a write that differs per RPC: it gets the current area doc (nil when none), may read more (all
// reads before the first write), stages its writes on b and answers the state after them.
type txBody func(ctx context.Context, tx *firestore.Transaction, cur *StoredArea, b store.Batch) (State, Outcome, error)

// write is one idempotent transaction with bounded re-runs. Reads, fresh and in this order: idempotency/{hash} (a replay
// answers the current state and writes nothing; another body is ErrKeyReused), the area doc, then whatever body reads.
// Writes: body's, then the idempotency doc (24 h TTL) in the same commit. A same-key request that committed first leaves
// AlreadyExists on this one's idempotency Create; the transaction is run once more, finds the record and replays it.
func (r *FirestoreRepo) write(ctx context.Context, uid, key, rpc, hash string, now time.Time, body txBody) (WriteResult, error) {
	if r == nil || r.client == nil || r.idem == nil {
		return WriteResult{}, errors.New("location: repo is not fully wired")
	}
	var res WriteResult
	fn := func(ctx context.Context, tx *firestore.Transaction) error {
		res = WriteResult{}
		rec, err := r.idem.Get(ctx, tx, key)
		switch {
		case err == nil:
			if rec.RequestHash != hash {
				return ErrKeyReused
			}
			st, err := r.stateTx(tx, uid)
			res = WriteResult{Outcome: Replayed, State: st}
			return err
		case !errors.Is(err, idempotency.ErrNotFound):
			return fmt.Errorf("location: idempotency lookup: %w", err)
		}
		cur, err := decodeArea(tx.Get(r.areaRef(uid)))
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		st, out, err := body(ctx, tx, cur, b)
		if err != nil {
			return err
		}
		r.idem.Put(b, key, idempotency.Record{
			UID: uid, RPC: rpc, RequestHash: hash, Result: map[string]string{"op": rpc}, ExpireAt: now.UTC().Add(idempotency.TTL),
		})
		if err := b.Err(); err != nil {
			return err
		}
		res = WriteResult{Outcome: out, State: st}
		return nil
	}
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, fn)
	if status.Code(err) == codes.AlreadyExists {
		again, err2 := store.RunTransactionRetry(ctx, r.client, cfg, fn)
		attempts, err = attempts+again, err2
	}
	store.NoteTxnAttempts(ctx, "location_txn_contention", attempts)
	return res, err
}

// SetArea implements Repo. Current consent means the area doc exists with consentCopyVersion >= p.MinCopyVersion.
//   - Without it, p.Grant must be set (else ErrConsentRequired); the caller's consent records since IST midnight are
//     counted (at most p.ConsentsPerDay, else ErrConsentLimit), the area doc is Set whole and a GRANTED record appended.
//   - With it, a new area id updates areaId and updatedAt only (no consent record: no location history); the stored id
//     again writes only the idempotency doc.
func (r *FirestoreRepo) SetArea(ctx context.Context, p SetParams) (WriteResult, error) {
	now := p.Now.UTC()
	return r.write(ctx, p.UID, p.IdemKey, rpcSetArea, p.RequestHash, now, func(ctx context.Context, tx *firestore.Transaction, cur *StoredArea, b store.Batch) (State, Outcome, error) {
		if cur == nil || cur.ConsentCopyVersion < p.MinCopyVersion {
			if p.Grant == nil {
				return State{}, Unchanged, ErrConsentRequired
			}
			n, err := r.countSince(ctx, tx, p.UID, istMidnight(now), p.ConsentsPerDay)
			if err != nil {
				return State{}, Unchanged, err
			}
			if n >= int64(p.ConsentsPerDay) {
				return State{}, Unchanged, ErrConsentLimit
			}
			doc := areaDoc{
				AreaID: p.AreaID, Purposes: []string{PurposePlansNearby}, ConsentCopyVersion: p.Grant.CopyVersion,
				AdultConfirmedAt: now, ConsentedAt: now, UpdatedAt: now,
			}
			b.Set(r.areaRef(p.UID), doc)
			b.Create(r.consents(p.UID).Doc(p.ConsentID), consentDoc{
				Purpose: PurposePlansNearby, Action: ActionGranted, CopyVersion: p.Grant.CopyVersion, AdultConfirmed: p.Grant.AdultConfirmed, At: now,
			})
			return State{Area: doc.stored()}, Written, nil
		}
		if cur.AreaID == p.AreaID {
			return State{Area: cur}, Unchanged, nil
		}
		b.Update(r.areaRef(p.UID), []firestore.Update{{Path: "areaId", Value: p.AreaID}, {Path: "updatedAt", Value: now}})
		next := *cur
		next.AreaID, next.UpdatedAt = p.AreaID, now
		return State{Area: &next}, Written, nil
	})
}

// ClearArea implements Repo: with an area set, the doc is deleted and a WITHDRAWN record appended (copy version of the
// grant); with none, only the idempotency doc is written (one more read: the latest record, for the answer).
func (r *FirestoreRepo) ClearArea(ctx context.Context, p ClearParams) (WriteResult, error) {
	now := p.Now.UTC()
	return r.write(ctx, p.UID, p.IdemKey, rpcClearArea, p.RequestHash, now, func(_ context.Context, tx *firestore.Transaction, cur *StoredArea, b store.Batch) (State, Outcome, error) {
		if cur == nil {
			latest, err := decodeLatest(tx.Documents(r.latestQuery(p.UID)).GetAll())
			return State{Latest: latest}, Unchanged, err
		}
		purpose := PurposePlansNearby
		if len(cur.Purposes) > 0 {
			purpose = cur.Purposes[0]
		}
		rec := consentDoc{Purpose: purpose, Action: ActionWithdrawn, CopyVersion: cur.ConsentCopyVersion, At: now}
		b.Delete(r.areaRef(p.UID))
		b.Create(r.consents(p.UID).Doc(p.ConsentID), rec)
		return State{Latest: rec.record(p.ConsentID)}, Written, nil
	})
}
