// repo_scheduled.go is the Firestore repository of users/{uid}/scheduled/{scheduledId} (ADR-0021 "Firestore model").
//
// Index map (firebase/firestore.indexes.json, already on main):
//
//	list         status in [PENDING, FAILED] ORDER BY publishAt, __name__ ASC   COLLECTION  (status ASC, publishAt ASC)
//	window count status == PENDING AND publishAt in [t-4m, t+4m]                COLLECTION  (status ASC, publishAt ASC)
//	pending      status == PENDING                                              automatic single-field index
//	sweep        status == PENDING AND publishAt <= now ORDER BY publishAt      COLLECTION_GROUP (status ASC, publishAt ASC)
//	export       ORDER BY publishAt, __name__ ASC (no filter)                   automatic single-field index
//
// `draft` and `requestHash` are index-exempt; `expireAt` is the TTL field (Terraform ttl_fields scheduled_expire_at),
// so the Go tags below must match those names exactly or documents silently never expire.
//
// Every write is conditional on the document existing in a known state; none uses Set or merge, so a write that
// arrives after the account eraser cannot recreate a purged document (ADR-0021 Sweep "State writes").
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	scheduledParentCollection = "users"
	scheduledSubcollection    = "scheduled"
)

var (
	// ErrScheduledNotFound is returned when the document does not exist (or belongs to another user: the path is built
	// from the caller's uid, so another user's id is simply absent).
	ErrScheduledNotFound = errors.New("posts: scheduled post not found")
	// ErrScheduledExists is returned by CreateScheduled when the document already exists: a replay or a concurrent
	// first call of the same idempotency key. The caller reads the document once and answers as for a replay.
	ErrScheduledExists = errors.New("posts: scheduled post already exists")
	// errScheduledTransition is a programming error: an impossible transition request.
	errScheduledTransition = errors.New("posts: invalid scheduled transition")
)

// ScheduledRepo is posts' storage seam for scheduled posts; FirestoreRepo implements it and the later service
// depends on it. It is separate from Repo so the posts read path and its fakes are untouched.
type ScheduledRepo interface {
	ScheduledLister
	ScheduledPurger
	ScheduledExportSource
	// GetScheduled reads one document outside any transaction. Reads 1; ErrScheduledNotFound when absent.
	GetScheduled(ctx context.Context, uid, id string) (*ScheduledPost, error)
	// CountPending counts uid's PENDING items, stopping at limit (callers pass SCHEDULED_MAX_PENDING+1). Reads 1,
	// charged by hand: the store wrappers do not see aggregation queries.
	CountPending(ctx context.Context, uid string, limit int) (int64, error)
	// CountWindow counts uid's PENDING items whose publishAt is within +/-ScheduledWindowRadius of center, stopping
	// at limit (callers pass SCHEDULED_PER_AUTHOR_PER_RUN+1). Reads 1, charged by hand.
	CountWindow(ctx context.Context, uid string, center time.Time, limit int) (int64, error)
	// CreateScheduled runs the schedule transaction. Reads 1 (quotas) + len(MediaIDs) (1 at the daily cap, which is
	// checked before the media read); writes 2 (the document and quotas.schedules). ErrScheduledExists,
	// ErrMediaNotReady or the quota package's QUOTA_EXCEEDED error otherwise, with nothing written.
	CreateScheduled(ctx context.Context, p ScheduledCreateParams) (*ScheduledPost, error)
	// CancelScheduled moves a PENDING or FAILED item to CANCELLED, clearing its draft. Reads 1, writes 1 (0 and
	// changed=false when the item is already PUBLISHED or CANCELLED: the current state is returned).
	CancelScheduled(ctx context.Context, uid, id string, now time.Time, ttl time.Duration) (post *ScheduledPost, changed bool, err error)
	// TransitionScheduled applies a transition outside the publish transaction, conditional on the document being
	// unchanged since ref.UpdateTime. Reads 0, writes 1; applied=false (and nothing written) when it changed or vanished.
	TransitionScheduled(ctx context.Context, ref ScheduledRef, t ScheduledTransition, now time.Time, ttl time.Duration) (next ScheduledRef, applied bool, err error)
	// BumpScheduledAttempts adds one transient failure under the same precondition. Reads 0, writes 1.
	BumpScheduledAttempts(ctx context.Context, ref ScheduledRef, now time.Time) (next ScheduledRef, applied bool, err error)
	// DueScheduled is the sweep's collection-group query. Reads len(docs), minimum 1.
	DueScheduled(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error)
}

var _ ScheduledRepo = (*FirestoreRepo)(nil)

// scheduledDoc is the stored shape. Optional fields use omitempty or nil pointers so a PENDING document carries no
// expireAt, failure or postId, and a PUBLISHED, CANCELLED or FAILED one carries no draft.
type scheduledDoc struct {
	SchemaVersion int                `firestore:"schemaVersion"`
	Draft         *scheduledDraftDoc `firestore:"draft,omitempty"`
	PublishAt     time.Time          `firestore:"publishAt"`
	Status        string             `firestore:"status"`
	Failure       string             `firestore:"failure,omitempty"`
	Attempts      int                `firestore:"attempts"`
	PostID        string             `firestore:"postId,omitempty"`
	RequestHash   string             `firestore:"requestHash"`
	CreatedAt     time.Time          `firestore:"createdAt"`
	UpdatedAt     time.Time          `firestore:"updatedAt"`
	ExpireAt      *time.Time         `firestore:"expireAt,omitempty"`
}

type scheduledDraftDoc struct {
	Text            string     `firestore:"text"`
	Media           []mediaDoc `firestore:"media,omitempty"`
	ReplyPolicy     string     `firestore:"replyPolicy,omitempty"`
	PaidPartnership bool       `firestore:"paidPartnership,omitempty"`
	MadeWithAI      bool       `firestore:"madeWithAi,omitempty"`
}

func mediaRefsToDocs(refs []MediaRef) []mediaDoc {
	if len(refs) == 0 {
		return nil
	}
	out := make([]mediaDoc, len(refs))
	for i, m := range refs {
		out[i] = mediaDoc{MediaID: m.ID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText}
	}
	return out
}

func mediaDocsToRefs(docs []mediaDoc) []MediaRef {
	if len(docs) == 0 {
		return nil
	}
	out := make([]MediaRef, len(docs))
	for i, m := range docs {
		out[i] = MediaRef{ID: m.MediaID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText}
	}
	return out
}

func toScheduledDoc(p *ScheduledPost) scheduledDoc {
	d := scheduledDoc{
		SchemaVersion: p.SchemaVersion, PublishAt: p.PublishAt, Status: string(p.Status), Failure: string(p.Failure),
		Attempts: p.Attempts, PostID: p.PostID, RequestHash: p.RequestHash,
		CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt, ExpireAt: p.ExpireAt,
	}
	if dr := p.Draft; dr != nil {
		d.Draft = &scheduledDraftDoc{
			Text: dr.Text, Media: mediaRefsToDocs(dr.Media), ReplyPolicy: string(dr.ReplyPolicy),
			PaidPartnership: dr.PaidPartnership, MadeWithAI: dr.MadeWithAI,
		}
	}
	return d
}

func (d scheduledDoc) toScheduledPost(uid, id string, updateTime time.Time) *ScheduledPost {
	p := &ScheduledPost{
		ID: id, UID: uid, SchemaVersion: d.SchemaVersion, PublishAt: d.PublishAt.UTC(),
		Status: ScheduledStatus(d.Status), Failure: ScheduledFailure(d.Failure), Attempts: d.Attempts,
		PostID: d.PostID, RequestHash: d.RequestHash, CreatedAt: d.CreatedAt.UTC(), UpdatedAt: d.UpdatedAt.UTC(),
		UpdateTime: updateTime,
	}
	if d.ExpireAt != nil {
		t := d.ExpireAt.UTC()
		p.ExpireAt = &t
	}
	if dr := d.Draft; dr != nil {
		p.Draft = &ScheduledDraft{
			Text: dr.Text, Media: mediaDocsToRefs(dr.Media), ReplyPolicy: ReplyPolicy(dr.ReplyPolicy),
			PaidPartnership: dr.PaidPartnership, MadeWithAI: dr.MadeWithAI,
		}
	}
	return p
}

func decodeScheduled(snap *firestore.DocumentSnapshot, uid string) (*ScheduledPost, error) {
	var d scheduledDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("posts: decode scheduled post: %w", err)
	}
	return d.toScheduledPost(uid, snap.Ref.ID, snap.UpdateTime), nil
}

// decodeScheduledAll decodes a query result for uid, in order.
func decodeScheduledAll(docs []*firestore.DocumentSnapshot, uid string) ([]*ScheduledPost, error) {
	out := make([]*ScheduledPost, 0, len(docs))
	for _, s := range docs {
		p, err := decodeScheduled(s, uid)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// ScheduledTransition is a state change out of PENDING (or FAILED, for a dismiss). Every transition stamps
// status, updatedAt and expireAt; PUBLISHED, CANCELLED and FAILED also clear the draft (review L-2; a failed item is never rescheduled).
type ScheduledTransition struct {
	To ScheduledStatus
	// Failure is required when To is FAILED.
	Failure ScheduledFailure
	// PostID is required when To is PUBLISHED.
	PostID string
}

func (t ScheduledTransition) validate(ttl time.Duration) error {
	switch {
	case ttl <= 0:
		return fmt.Errorf("%w: ttl must be positive", errScheduledTransition)
	case t.To == ScheduledPublished && t.PostID == "":
		return fmt.Errorf("%w: PUBLISHED needs a post id", errScheduledTransition)
	case t.To == ScheduledFailed && !t.Failure.Valid():
		return fmt.Errorf("%w: FAILED needs a valid reason", errScheduledTransition)
	case t.To != ScheduledPublished && t.To != ScheduledCancelled && t.To != ScheduledFailed:
		return fmt.Errorf("%w: cannot move to %q", errScheduledTransition, t.To)
	}
	return nil
}

// updates are the field updates of the transition, never a whole-document write.
func (t ScheduledTransition) updates(now time.Time, ttl time.Duration) ([]firestore.Update, error) {
	if err := t.validate(ttl); err != nil {
		return nil, err
	}
	ups := []firestore.Update{
		{Path: "status", Value: string(t.To)},
		{Path: "updatedAt", Value: now.UTC()},
		{Path: "expireAt", Value: now.UTC().Add(ttl)},
	}
	switch t.To {
	case ScheduledPublished:
		ups = append(ups, firestore.Update{Path: "postId", Value: t.PostID}, firestore.Update{Path: "draft", Value: firestore.Delete})
	case ScheduledCancelled:
		ups = append(ups, firestore.Update{Path: "draft", Value: firestore.Delete})
	case ScheduledFailed:
		ups = append(ups, firestore.Update{Path: "failure", Value: string(t.Failure)}, firestore.Update{Path: "draft", Value: firestore.Delete})
	}
	return ups, nil
}

// apply mirrors updates on the in-memory copy, so a repo method can return the state it just wrote without re-reading.
func (t ScheduledTransition) apply(p *ScheduledPost, now time.Time, ttl time.Duration) {
	exp := now.UTC().Add(ttl)
	p.Status, p.UpdatedAt, p.ExpireAt = t.To, now.UTC(), &exp
	switch t.To {
	case ScheduledPublished:
		p.PostID, p.Draft = t.PostID, nil
	case ScheduledCancelled:
		p.Draft = nil
	case ScheduledFailed:
		p.Failure, p.Draft = t.Failure, nil
	}
}

func (r *FirestoreRepo) scheduledCol(uid string) (*firestore.CollectionRef, error) {
	if !ids.ValidUID(uid) {
		return nil, ErrInvalidScheduledID
	}
	return r.client.Collection(scheduledParentCollection).Doc(uid).Collection(scheduledSubcollection), nil
}

func (r *FirestoreRepo) scheduledRef(uid, id string) (*firestore.DocumentRef, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return nil, err
	}
	if !ValidScheduledID(id) {
		return nil, ErrInvalidScheduledID
	}
	return col.Doc(id), nil
}

// ScheduledCreateParams is everything the schedule transaction needs. The service validates and normalises first;
// the repository stores what it is given (PublishAt is truncated to the minute here as a backstop).
type ScheduledCreateParams struct {
	UID, ID     string
	Draft       ScheduledDraft
	PublishAt   time.Time
	RequestHash string
	Now         time.Time
	QuotaLimit  int64
	// MediaIDs are validated inside the transaction (owned, READY or READY_UNSCREENED, unattached) but not attached
	// or reserved; the claim's refs, with MediaAlts applied, become Draft.Media.
	MediaIDs  []string
	MediaAlts []string
}

// CreateScheduled implements ScheduledRepo.
func (r *FirestoreRepo) CreateScheduled(ctx context.Context, p ScheduledCreateParams) (*ScheduledPost, error) {
	if r.w.Quotas == nil {
		return nil, errors.New("posts: repo has no scheduled-post writers configured")
	}
	ref, err := r.scheduledRef(p.UID, p.ID)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()

	var out *ScheduledPost
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		qrec, err := r.w.Quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("posts: quota lookup: %w", err)
		}
		// The daily cap is checked before the media read: a call at the cap costs 1 read however many images it names
		// (the SchedulePost proto budget), and nothing has been written yet. CheckAndReserve below repeats the same
		// rule when it stages the quota write.
		if qrec.Schedules >= p.QuotaLimit {
			return quota.ExceededError(quota.Schedules, p.Now)
		}
		draft := p.Draft
		if len(p.MediaIDs) > 0 {
			if r.w.Media == nil {
				return ErrMediaNotReady
			}
			// Reads before the first write (a Firestore transaction rule); no Attach: media are validated, not reserved.
			claim, err := r.w.Media.LoadForPost(ctx, tx, p.UID, p.MediaIDs)
			if err != nil {
				return err
			}
			draft.Media = mediaWithAlts(claim.Refs(), p.MediaAlts)
		}
		post := &ScheduledPost{
			ID: p.ID, UID: p.UID, SchemaVersion: ScheduledSchemaVersion, Draft: &draft,
			PublishAt: p.PublishAt.UTC().Truncate(time.Minute), Status: ScheduledPending, RequestHash: p.RequestHash,
			CreatedAt: p.Now.UTC(), UpdatedAt: p.Now.UTC(),
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.UID), qrec, quota.Schedules, p.QuotaLimit); err != nil {
			return err
		}
		b.Create(ref, toScheduledDoc(post))
		if err := b.Err(); err != nil {
			return err
		}
		out = post
		return nil
	})
	if status.Code(err) == codes.AlreadyExists {
		return nil, ErrScheduledExists
	}
	if err != nil {
		return nil, err
	}
	return out, nil
}

// GetScheduled implements ScheduledRepo.
func (r *FirestoreRepo) GetScheduled(ctx context.Context, uid, id string) (*ScheduledPost, error) {
	ref, err := r.scheduledRef(uid, id)
	if err != nil {
		return nil, err
	}
	snap, err := ref.Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return nil, ErrScheduledNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("posts: get scheduled: %w", err)
	}
	return decodeScheduled(snap, uid)
}

// ListScheduled implements ScheduledLister (the list index: status in [PENDING, FAILED] ORDER BY publishAt, __name__).
func (r *FirestoreRepo) ListScheduled(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return nil, err
	}
	q := col.Where("status", "in", []string{string(ScheduledPending), string(ScheduledFailed)}).
		OrderBy("publishAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, col.Doc(after.ID))
	}
	docs, err := q.Limit(min(max(limit, 1), MaxLimit)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, fmt.Errorf("posts: list scheduled: %w", err)
	}
	return decodeScheduledAll(docs, uid)
}

// countQuery runs a count aggregation and charges it by hand: Firestore bills one read per 1,000 index entries
// counted, minimum 1, and the store wrappers do not see aggregation queries.
func countQuery(ctx context.Context, q firestore.Query) (int64, error) {
	res, err := q.NewAggregationQuery().WithCount("n").Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("posts: count: %w", err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("posts: count decode: %w", err)
	}
	budget.FromContext(ctx).AddReads(out.N/1000 + 1)
	return out.N, nil
}

// CountPending implements ScheduledRepo.
func (r *FirestoreRepo) CountPending(ctx context.Context, uid string, limit int) (int64, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return 0, err
	}
	return countQuery(ctx, col.Where("status", "==", string(ScheduledPending)).Limit(max(limit, 1)))
}

// CountWindow implements ScheduledRepo.
func (r *FirestoreRepo) CountWindow(ctx context.Context, uid string, center time.Time, limit int) (int64, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return 0, err
	}
	q := col.Where("status", "==", string(ScheduledPending)).
		Where("publishAt", ">=", center.UTC().Add(-ScheduledWindowRadius)).
		Where("publishAt", "<=", center.UTC().Add(ScheduledWindowRadius)).
		Limit(max(limit, 1))
	return countQuery(ctx, q)
}

// CancelScheduled implements ScheduledRepo.
func (r *FirestoreRepo) CancelScheduled(ctx context.Context, uid, id string, now time.Time, ttl time.Duration) (*ScheduledPost, bool, error) {
	ref, err := r.scheduledRef(uid, id)
	if err != nil {
		return nil, false, err
	}
	t := ScheduledTransition{To: ScheduledCancelled}
	ups, err := t.updates(now, ttl)
	if err != nil {
		return nil, false, err
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()

	var (
		out     *ScheduledPost
		changed bool
	)
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		changed = false
		snap, err := tx.Get(ref)
		budget.FromContext(ctx).AddReads(1)
		if status.Code(err) == codes.NotFound {
			return ErrScheduledNotFound
		}
		if err != nil {
			return fmt.Errorf("posts: get scheduled: %w", err)
		}
		cur, err := decodeScheduled(snap, uid)
		if err != nil {
			return err
		}
		out = cur
		if cur.Status != ScheduledPending && cur.Status != ScheduledFailed {
			return nil // PUBLISHED (too late) or already CANCELLED: the current state, 0 writes
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(ref, ups)
		if err := b.Err(); err != nil {
			return err
		}
		t.apply(cur, now, ttl)
		changed = true
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	return out, changed, nil
}

// GetScheduledInTx reads one document inside the caller's transaction (the publish transaction re-reads the item and
// requires PENDING before it writes). Reads 1; ErrScheduledNotFound when absent.
func (r *FirestoreRepo) GetScheduledInTx(ctx context.Context, tx *firestore.Transaction, uid, id string) (*ScheduledPost, error) {
	ref, err := r.scheduledRef(uid, id)
	if err != nil {
		return nil, err
	}
	snap, err := tx.Get(ref)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return nil, ErrScheduledNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("posts: get scheduled: %w", err)
	}
	return decodeScheduled(snap, uid)
}

// StageScheduledTransition appends the transition to b (a transaction batch that already read the document as
// PENDING). The update carries the implicit exists precondition of a transactional Update. Writes 1.
func (r *FirestoreRepo) StageScheduledTransition(b store.Batch, uid, id string, t ScheduledTransition, now time.Time, ttl time.Duration) error {
	ref, err := r.scheduledRef(uid, id)
	if err != nil {
		return err
	}
	ups, err := t.updates(now, ttl)
	if err != nil {
		return err
	}
	b.Update(ref, ups)
	return nil
}

// updateIfUnchanged applies ups with a LastUpdateTime precondition (0 reads, 1 write). A document that changed
// since the query read it, or that is gone (the eraser, a TTL delete), is not an error: applied=false, nothing written.
func (r *FirestoreRepo) updateIfUnchanged(ctx context.Context, ref ScheduledRef, ups []firestore.Update) (ScheduledRef, bool, error) {
	if ref.UpdateTime.IsZero() {
		return ref, false, fmt.Errorf("%w: reference has no update time", errScheduledTransition)
	}
	dr, err := r.scheduledRef(ref.UID, ref.ID)
	if err != nil {
		return ref, false, err
	}
	wr, err := dr.Update(ctx, ups, firestore.LastUpdateTime(ref.UpdateTime))
	switch status.Code(err) {
	case codes.OK:
		budget.FromContext(ctx).AddWrites(1)
		return ScheduledRef{UID: ref.UID, ID: ref.ID, UpdateTime: wr.UpdateTime}, true, nil
	case codes.FailedPrecondition, codes.NotFound:
		return ref, false, nil
	}
	return ref, false, fmt.Errorf("posts: update scheduled: %w", err)
}

// TransitionScheduled implements ScheduledRepo.
func (r *FirestoreRepo) TransitionScheduled(ctx context.Context, ref ScheduledRef, t ScheduledTransition, now time.Time, ttl time.Duration) (ScheduledRef, bool, error) {
	ups, err := t.updates(now, ttl)
	if err != nil {
		return ref, false, err
	}
	return r.updateIfUnchanged(ctx, ref, ups)
}

// BumpScheduledAttempts implements ScheduledRepo.
func (r *FirestoreRepo) BumpScheduledAttempts(ctx context.Context, ref ScheduledRef, now time.Time) (ScheduledRef, bool, error) {
	return r.updateIfUnchanged(ctx, ref, []firestore.Update{
		{Path: "attempts", Value: firestore.Increment(1)},
		{Path: "updatedAt", Value: now.UTC()},
	})
}

// ScheduledDueCursor resumes the due query after the last raw result of a page.
type ScheduledDueCursor struct {
	publishAt time.Time
	ref       *firestore.DocumentRef
}

// ScheduledDuePage is one page of the sweep query.
type ScheduledDuePage struct {
	// Items are the accepted documents, in query order (publishAt, then full path). Each carries UpdateTime, the
	// precondition of the sweep writes outside the publish transaction.
	Items []*ScheduledPost
	// SkippedBadPath counts results whose ref is not exactly users/{uid}/scheduled/{32 hex} (review L-7); Undecodable
	// counts well-shaped documents that do not decode. Both are re-read every run (1 read each), so the sweep alerts.
	SkippedBadPath, Undecodable int
	// Next resumes after this page; nil when the page was short (nothing more is due).
	Next *ScheduledDueCursor
}

// scheduledPathShape returns the owner and id of a ref shaped exactly users/{uid}/scheduled/{id}: the parent
// collection is `scheduled`, its parent is a document of the top-level `users` collection, the uid is a valid uid and
// the id is 32 lower-case hex characters. The uid is taken from the path, never from a field.
func scheduledPathShape(ref *firestore.DocumentRef) (uid, id string, ok bool) {
	if ref == nil || ref.Parent == nil || ref.Parent.ID != scheduledSubcollection {
		return "", "", false
	}
	owner := ref.Parent.Parent
	if owner == nil || owner.Parent == nil || owner.Parent.ID != scheduledParentCollection || owner.Parent.Parent != nil {
		return "", "", false
	}
	if !ids.ValidUID(owner.ID) || !ValidScheduledID(ref.ID) {
		return "", "", false
	}
	return owner.ID, ref.ID, true
}

// DueScheduled implements ScheduledRepo: status == PENDING AND publishAt <= now ORDER BY publishAt, LIMIT limit on the
// scheduled collection group (the COLLECTION_GROUP index). Ties on publishAt break on the full path.
func (r *FirestoreRepo) DueScheduled(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error) {
	limit = min(max(limit, 1), MaxLimit)
	q := r.client.CollectionGroup(scheduledSubcollection).
		Where("status", "==", string(ScheduledPending)).
		Where("publishAt", "<=", now.UTC()).
		OrderBy("publishAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.publishAt, after.ref)
	}
	it := q.Limit(limit).Documents(ctx)
	defer it.Stop()

	var (
		page ScheduledDuePage
		last *firestore.DocumentSnapshot
		n    int
	)
	for {
		snap, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			budget.FromContext(ctx).AddQueryReads(n)
			return ScheduledDuePage{}, fmt.Errorf("posts: due scheduled: %w", err)
		}
		n++
		last = snap
		uid, _, ok := scheduledPathShape(snap.Ref)
		if !ok {
			page.SkippedBadPath++
			continue
		}
		p, err := decodeScheduled(snap, uid)
		if err != nil {
			page.Undecodable++
			continue
		}
		page.Items = append(page.Items, p)
	}
	budget.FromContext(ctx).AddQueryReads(n)
	if n >= limit && last != nil {
		v, err := last.DataAt("publishAt")
		at, isTime := v.(time.Time)
		if err != nil || !isTime {
			return ScheduledDuePage{}, errors.New("posts: due scheduled: last result has no publishAt")
		}
		page.Next = &ScheduledDueCursor{publishAt: at, ref: last.Ref}
	}
	return page, nil
}
