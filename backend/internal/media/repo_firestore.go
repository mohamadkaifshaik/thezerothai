// repo_firestore.go is the Firestore side of media (ADR-0003 `media/{mediaId}`, `admin/vision-{yyyymm}`).
//
// CreateUploads is one transaction:
//
//	reads : idempotency/{hash} (1), then, on a first attempt, quotas/{uid} (1)
//	writes: Create idempotency doc, Set quotas/{uid}, Create media/{id} per image   (2 + n)
//
// A replay reads only the idempotency doc and writes nothing. Every query has a Limit (CLAUDE.md rule 5).
package media

import (
	"context"
	"errors"
	"fmt"
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
	mediaCollection = "media"
	// adminCollection holds the SafeSearch counter, admin/vision-{yyyymm} (ADR-0003).
	adminCollection = "admin"
	createTxTimeout = 5 * time.Second
	createRPC       = "CreateUpload"
	// idemMediaIDs is the idempotency Record.Result key holding the reserved ids, comma-joined.
	idemMediaIDs = "mediaIds"
	// opsPage is the page of the purge and export queries and the batch bound (Firestore's 500 writes).
	opsPage = 100
)

// Doc is media/{mediaId}: the stored shape and the domain type in one (media owns its collection; nothing else
// reads it directly). UpdateTime is Firestore's, for the status-change precondition.
type Doc struct {
	ID string `firestore:"-"`
	// UpdateTime is set on reads only.
	UpdateTime time.Time `firestore:"-"`

	OwnerID         string     `firestore:"ownerId"`
	Purpose         string     `firestore:"purpose"`
	Status          string     `firestore:"status"`
	ContentType     string     `firestore:"contentType"`
	Bytes           int64      `firestore:"bytes"`
	ThumbBytes      int64      `firestore:"thumbBytes"`
	Width           int        `firestore:"w"`
	Height          int        `firestore:"h"`
	FullMD5         string     `firestore:"fullMd5"`
	ThumbMD5        string     `firestore:"thumbMd5"`
	Blurhash        string     `firestore:"blurhash,omitempty"`
	UploadPath      string     `firestore:"uploadPath"`
	ThumbUploadPath string     `firestore:"thumbUploadPath"`
	PublicPath      string     `firestore:"publicPath,omitempty"`
	ThumbPath       string     `firestore:"thumbPath,omitempty"`
	RejectionReason string     `firestore:"rejectionReason,omitempty"`
	PostID          string     `firestore:"postId,omitempty"`
	CreatedAt       time.Time  `firestore:"createdAt"`
	ExpireAt        *time.Time `firestore:"expireAt,omitempty"`
}

// Published reports whether the document is publicly served (READY or READY_UNSCREENED).
func (d *Doc) Published() bool {
	return d.Status == string(StatusReady) || d.Status == string(StatusReadyUnscreened)
}

// CreateUploadsParams is everything the CreateUpload transaction needs.
type CreateUploadsParams struct {
	UID         string
	IdemKey     string
	RequestHash string
	QuotaLimit  int64
	// Docs are the media documents to create (IDs set); Created is stamped by the caller.
	Docs []Doc
}

// CreateUploadsResult is the outcome of CreateUploads. For a replay, ReplayIDs are the ids the first call reserved.
type CreateUploadsResult struct {
	ReplayIDs []string
	Attempts  int
}

// Resolution is the final state of a PENDING document.
type Resolution struct {
	Status          Status
	PublicPath      string
	ThumbPath       string
	Blurhash        string
	RejectionReason string
	// ExpireAt, when non-zero, keeps a TTL on the document (REJECTED docs); zero removes the field (published).
	ExpireAt time.Time
}

// Repo is media's storage seam.
type Repo interface {
	// CreateUploads runs the CreateUpload transaction. ErrKeyReused / the quota package's RESOURCE_EXHAUSTED
	// apierr are returned as documented there.
	CreateUploads(ctx context.Context, p CreateUploadsParams) (CreateUploadsResult, error)
	// GetMany reads media/{id} for every id in one GetAll; missing ids are absent. Reads: len(ids).
	GetMany(ctx context.Context, ids []string) (map[string]*Doc, error)
	// Resolve moves a PENDING document to its final state, conditional on its UpdateTime (ErrConflict when
	// another call changed it first). Writes: 1.
	Resolve(ctx context.Context, id string, updateTime time.Time, r Resolution) error
	// VisionUsed returns the units counted for month ("200601"); 0 when the counter does not exist. Reads: 1.
	VisionUsed(ctx context.Context, month string) (int64, error)
	// AddVisionUnits adds n units to the month's counter. Writes: 1.
	AddVisionUnits(ctx context.Context, month string, n int64) error
	// ListByOwner returns up to limit of uid's media documents (any order), resuming after the document id
	// `after` ("" = from the start). Reads: len(result), minimum 1.
	ListByOwner(ctx context.Context, uid, after string, limit int) ([]*Doc, error)
	// DeleteDocs deletes the documents in one batch (<= 500). Deletes: len(ids).
	DeleteDocs(ctx context.Context, ids []string) error
}

// Errors of the repo.
var (
	// ErrKeyReused is returned by CreateUploads when the idempotency key was used with a different request.
	ErrKeyReused = errors.New("media: idempotency key reused with a different request")
	// ErrConflict means Resolve lost its UpdateTime precondition: another call finalized the document first.
	ErrConflict = errors.New("media: media document changed concurrently")
)

// WriteDeps are the cross-module collaborators of the CreateUpload transaction.
type WriteDeps struct {
	Idempotency *idempotency.Store
	Quotas      *quota.Store
}

// FirestoreRepo implements Repo against the shared Firestore client.
type FirestoreRepo struct {
	client *firestore.Client
	w      WriteDeps
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repo on the process-wide Firestore client.
func NewFirestoreRepo(client *firestore.Client, w WriteDeps) *FirestoreRepo {
	return &FirestoreRepo{client: client, w: w}
}

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef {
	return r.client.Collection(mediaCollection).Doc(id)
}

func (r *FirestoreRepo) visionRef(month string) *firestore.DocumentRef {
	return r.client.Collection(adminCollection).Doc("vision-" + month)
}

// CreateUploads implements Repo.
func (r *FirestoreRepo) CreateUploads(ctx context.Context, p CreateUploadsParams) (CreateUploadsResult, error) {
	if r.w.Idempotency == nil || r.w.Quotas == nil {
		return CreateUploadsResult{}, errors.New("media: repo has no CreateUpload writers configured")
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()
	var (
		res      CreateUploadsResult
		attempts int
	)
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		attempts++
		var err error
		res, err = r.createAttempt(ctx, tx, p)
		return err
	})
	res.Attempts = attempts
	if err != nil {
		return CreateUploadsResult{Attempts: attempts}, err
	}
	return res, nil
}

func (r *FirestoreRepo) createAttempt(ctx context.Context, tx *firestore.Transaction, p CreateUploadsParams) (CreateUploadsResult, error) {
	rec, err := r.w.Idempotency.Get(ctx, tx, p.IdemKey)
	switch {
	case err == nil:
		if rec.RequestHash != p.RequestHash {
			return CreateUploadsResult{}, ErrKeyReused
		}
		ids := splitIDs(rec.Result[idemMediaIDs])
		if len(ids) == 0 {
			return CreateUploadsResult{}, fmt.Errorf("media: idempotency record %s has no media ids", p.IdemKey)
		}
		return CreateUploadsResult{ReplayIDs: ids}, nil
	case !errors.Is(err, idempotency.ErrNotFound):
		return CreateUploadsResult{}, fmt.Errorf("media: idempotency lookup: %w", err)
	}
	qrec, err := r.w.Quotas.Get(ctx, tx, p.UID)
	if err != nil {
		return CreateUploadsResult{}, fmt.Errorf("media: quota lookup: %w", err)
	}
	b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
	if err := quota.CheckAndReserveN(b, r.w.Quotas.Ref(p.UID), qrec, quota.Uploads, p.QuotaLimit, int64(len(p.Docs))); err != nil {
		return CreateUploadsResult{}, err
	}
	ids := make([]string, len(p.Docs))
	for i := range p.Docs {
		d := p.Docs[i]
		ids[i] = d.ID
		b.Create(r.ref(d.ID), d)
	}
	r.w.Idempotency.Put(b, p.IdemKey, idempotency.Record{
		UID: p.UID, RPC: createRPC, RequestHash: p.RequestHash,
		Result:   map[string]string{idemMediaIDs: joinIDs(ids)},
		ExpireAt: time.Now().Add(idempotency.TTL),
	})
	if err := b.Err(); err != nil {
		return CreateUploadsResult{}, err
	}
	return CreateUploadsResult{}, nil
}

// GetMany implements Repo.
func (r *FirestoreRepo) GetMany(ctx context.Context, ids []string) (map[string]*Doc, error) {
	out := make(map[string]*Doc, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = r.ref(id)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	budget.FromContext(ctx).AddReads(int64(len(ids)))
	if err != nil {
		return nil, fmt.Errorf("media: get %d media docs: %w", len(ids), err)
	}
	for _, s := range snaps {
		if !s.Exists() {
			continue
		}
		d, err := decode(s)
		if err != nil {
			return nil, err
		}
		out[s.Ref.ID] = d
	}
	return out, nil
}

func decode(s *firestore.DocumentSnapshot) (*Doc, error) {
	var d Doc
	if err := s.DataTo(&d); err != nil {
		return nil, fmt.Errorf("media: decode media %s: %w", s.Ref.ID, err)
	}
	d.ID, d.UpdateTime = s.Ref.ID, s.UpdateTime
	return &d, nil
}

// Resolve implements Repo.
func (r *FirestoreRepo) Resolve(ctx context.Context, id string, updateTime time.Time, res Resolution) error {
	updates := []firestore.Update{
		{Path: "status", Value: string(res.Status)},
		{Path: "publicPath", Value: orDelete(res.PublicPath)},
		{Path: "thumbPath", Value: orDelete(res.ThumbPath)},
		{Path: "blurhash", Value: orDelete(res.Blurhash)},
		{Path: "rejectionReason", Value: orDelete(res.RejectionReason)},
	}
	if res.ExpireAt.IsZero() {
		updates = append(updates, firestore.Update{Path: "expireAt", Value: firestore.Delete})
	} else {
		updates = append(updates, firestore.Update{Path: "expireAt", Value: res.ExpireAt})
	}
	_, err := r.ref(id).Update(ctx, updates, firestore.LastUpdateTime(updateTime))
	budget.FromContext(ctx).AddWrites(1)
	switch status.Code(err) {
	case codes.OK:
		return nil
	case codes.FailedPrecondition, codes.NotFound:
		return ErrConflict
	}
	return fmt.Errorf("media: resolve media: %w", err)
}

func orDelete(s string) any {
	if s == "" {
		return firestore.Delete
	}
	return s
}

// VisionUsed implements Repo.
func (r *FirestoreRepo) VisionUsed(ctx context.Context, month string) (int64, error) {
	snap, err := r.visionRef(month).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("media: read vision counter: %w", err)
	}
	var v struct {
		Units int64 `firestore:"units"`
	}
	if err := snap.DataTo(&v); err != nil {
		return 0, fmt.Errorf("media: decode vision counter: %w", err)
	}
	return v.Units, nil
}

// AddVisionUnits implements Repo.
func (r *FirestoreRepo) AddVisionUnits(ctx context.Context, month string, n int64) error {
	_, err := r.visionRef(month).Set(ctx, map[string]any{
		"units":     firestore.Increment(n),
		"updatedAt": firestore.ServerTimestamp,
	}, firestore.MergeAll)
	budget.FromContext(ctx).AddWrites(1)
	if err != nil {
		return fmt.Errorf("media: add vision units: %w", err)
	}
	return nil
}

// ListByOwner implements Repo.
func (r *FirestoreRepo) ListByOwner(ctx context.Context, uid, after string, limit int) ([]*Doc, error) {
	q := r.client.Collection(mediaCollection).Where("ownerId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(snaps))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("media: list by owner: %w", err)
	}
	out := make([]*Doc, 0, len(snaps))
	for _, s := range snaps {
		d, err := decode(s)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, nil
}

// DeleteDocs implements Repo.
func (r *FirestoreRepo) DeleteDocs(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, id := range ids {
		b.Delete(r.ref(id))
	}
	return b.Commit(ctx)
}
