// repo_firestore.go is the Firestore implementation of moderation's storage (ADR-0016 D2).
//
// reports/{reportId}: the id is derived from (reporter, target type, target id), so the same reporter cannot file
// two reports of one target, and a repeat is detected by one document read inside the transaction.
//
// Queries (every one has a Limit):
//
//	list     status == S ORDER BY createdAt ASC, __name__ ASC LIMIT n   -> (status ASC, createdAt ASC) index
//	eraser   reporterId == uid LIMIT 500                                -> single-field index
//	export   reporterId == uid ORDER BY __name__ LIMIT 500 (paged)      -> single-field index
package moderation

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	reportsCollection = "reports"
	// txTimeout bounds the ReportContent transaction.
	txTimeout = 5 * time.Second
	// opsPage is the page size of the eraser and export queries and the batch bound (Firestore's 500 writes).
	opsPage = 500
)

var (
	_ Ops      = (*FirestoreRepo)(nil)
	_ Eraser   = (*FirestoreRepo)(nil)
	_ Exporter = (*FirestoreRepo)(nil)
)

// ReportID derives the report doc id: the first 32 hex characters of SHA-256(reporter|type|target).
func ReportID(reporterID string, t TargetType, targetID string) string {
	sum := sha256.Sum256([]byte(reporterID + "|" + string(t) + "|" + targetID))
	return hex.EncodeToString(sum[:])[:32]
}

// CreateParams is everything the report transaction needs.
type CreateParams struct {
	Report     Report // ID, ReporterID, target, reason, note, evidence, CreatedAt set; Status OPEN
	QuotaLimit int64
}

// CreateResult says whether the report already existed.
type CreateResult struct {
	Existing bool
	Attempts int
}

// FirestoreRepo implements Ops, Eraser, Exporter and the report transaction.
type FirestoreRepo struct {
	client *firestore.Client
	quotas *quota.Store
}

// NewFirestoreRepo builds the repo on the process-wide Firestore client.
func NewFirestoreRepo(client *firestore.Client, quotas *quota.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, quotas: quotas}
}

// Repo is the storage seam service.go depends on; unit tests use an in-memory fake.
type Repo interface {
	// Create writes the report and charges the quota in one transaction, unless the report doc exists (a repeat:
	// Existing=true, 0 writes, no charge). Reads 2 (report, quotas; 1 on a repeat), writes 2.
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
}

var _ Repo = (*FirestoreRepo)(nil)

type evidenceDoc struct {
	Text          string    `firestore:"text"`
	AuthorHandle  string    `firestore:"authorHandle"`
	MediaIDs      []string  `firestore:"mediaIds"`
	PostCreatedAt time.Time `firestore:"postCreatedAt"`
}

type reportDoc struct {
	ReporterID     string       `firestore:"reporterId"`
	TargetType     string       `firestore:"targetType"`
	TargetID       string       `firestore:"targetId"`
	TargetOwnerID  string       `firestore:"targetOwnerId"`
	Reason         string       `firestore:"reason"`
	Note           string       `firestore:"note"`
	Status         string       `firestore:"status"`
	Evidence       *evidenceDoc `firestore:"evidence,omitempty"`
	CreatedAt      time.Time    `firestore:"createdAt"`
	ResolvedAt     *time.Time   `firestore:"resolvedAt,omitempty"`
	Resolution     string       `firestore:"resolution,omitempty"`
	ResolutionNote string       `firestore:"resolutionNote,omitempty"`
	ExpireAt       *time.Time   `firestore:"expireAt,omitempty"`
}

func toDoc(r Report) reportDoc {
	d := reportDoc{
		ReporterID: r.ReporterID, TargetType: string(r.TargetType), TargetID: r.TargetID, TargetOwnerID: r.TargetOwnerID,
		Reason: string(r.Reason), Note: r.Note, Status: string(r.Status), CreatedAt: r.CreatedAt,
	}
	if r.Evidence != nil {
		ids := r.Evidence.MediaIDs
		if ids == nil {
			ids = []string{}
		}
		d.Evidence = &evidenceDoc{Text: r.Evidence.Text, AuthorHandle: r.Evidence.AuthorHandle, MediaIDs: ids, PostCreatedAt: r.Evidence.PostCreatedAt}
	}
	return d
}

func (d reportDoc) toReport(id string) Report {
	r := Report{
		ID: id, ReporterID: d.ReporterID, TargetType: TargetType(d.TargetType), TargetID: d.TargetID,
		TargetOwnerID: d.TargetOwnerID, Reason: Reason(d.Reason), Note: d.Note, Status: Status(d.Status),
		CreatedAt: d.CreatedAt.UTC(), Resolution: Resolution(d.Resolution), ResolutionNote: d.ResolutionNote,
	}
	if d.Evidence != nil {
		r.Evidence = &Evidence{Text: d.Evidence.Text, AuthorHandle: d.Evidence.AuthorHandle,
			MediaIDs: d.Evidence.MediaIDs, PostCreatedAt: d.Evidence.PostCreatedAt.UTC()}
	}
	if d.ResolvedAt != nil {
		r.ResolvedAt = d.ResolvedAt.UTC()
	}
	if d.ExpireAt != nil {
		r.ExpireAt = d.ExpireAt.UTC()
	}
	return r
}

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef {
	return r.client.Collection(reportsCollection).Doc(id)
}

// Create implements Repo.
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if r.quotas == nil {
		return CreateResult{}, errors.New("moderation: repo has no quota store")
	}
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	var res CreateResult
	attempts, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		res = CreateResult{}
		counter := budget.FromContext(ctx)
		_, err := tx.Get(r.ref(p.Report.ID))
		counter.AddReads(1)
		switch {
		case err == nil:
			res.Existing = true
			return nil
		case status.Code(err) != codes.NotFound:
			return fmt.Errorf("moderation: get report: %w", err)
		}
		qrec, err := r.quotas.Get(ctx, tx, p.Report.ReporterID)
		if err != nil {
			return fmt.Errorf("moderation: quota lookup: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		if err := quota.CheckAndReserve(b, r.quotas.Ref(p.Report.ReporterID), qrec, quota.Reports, p.QuotaLimit); err != nil {
			return err
		}
		b.Create(r.ref(p.Report.ID), toDoc(p.Report))
		return b.Err()
	})
	res.Attempts = attempts
	if err != nil {
		return CreateResult{Attempts: attempts}, err
	}
	return res, nil
}

// List implements Ops.
func (r *FirestoreRepo) List(ctx context.Context, st Status, limit int) ([]Report, error) {
	if limit <= 0 {
		limit = DefaultListLimit
	}
	if limit > MaxListLimit {
		limit = MaxListLimit
	}
	docs, err := r.client.Collection(reportsCollection).Where("status", "==", string(st)).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc).
		Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("moderation: list reports: %w", err)
	}
	out := make([]Report, 0, len(docs))
	for _, s := range docs {
		var d reportDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("moderation: decode report %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toReport(s.Ref.ID))
	}
	return out, nil
}

// Get implements Ops.
func (r *FirestoreRepo) Get(ctx context.Context, id string) (Report, error) {
	if id == "" {
		return Report{}, ErrNotFound
	}
	s, err := r.ref(id).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Report{}, ErrNotFound
		}
		return Report{}, fmt.Errorf("moderation: get report %s: %w", id, err)
	}
	var d reportDoc
	if err := s.DataTo(&d); err != nil {
		return Report{}, fmt.Errorf("moderation: decode report %s: %w", id, err)
	}
	return d.toReport(id), nil
}

// Resolve implements Ops: one transaction, 1 read, 1 write (0 when already resolved).
func (r *FirestoreRepo) Resolve(ctx context.Context, id string, res Resolution, note string, now time.Time) (Report, error) {
	if !res.Valid() {
		return Report{}, fmt.Errorf("moderation: invalid resolution %q", res)
	}
	if id == "" {
		return Report{}, ErrNotFound
	}
	var out Report
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		s, err := tx.Get(r.ref(id))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("moderation: get report %s: %w", id, err)
		}
		var d reportDoc
		if err := s.DataTo(&d); err != nil {
			return fmt.Errorf("moderation: decode report %s: %w", id, err)
		}
		if Status(d.Status) == StatusResolved {
			out = d.toReport(id)
			return nil
		}
		exp := now.Add(Retention).UTC()
		at := now.UTC()
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.ref(id), []firestore.Update{
			{Path: "status", Value: string(StatusResolved)},
			{Path: "resolvedAt", Value: at},
			{Path: "resolution", Value: string(res)},
			{Path: "resolutionNote", Value: note},
			{Path: "expireAt", Value: exp},
		})
		if err := b.Err(); err != nil {
			return err
		}
		d.Status, d.ResolvedAt, d.Resolution, d.ResolutionNote, d.ExpireAt = string(StatusResolved), &at, string(res), note, &exp
		out = d.toReport(id)
		return nil
	})
	if err != nil {
		return Report{}, err
	}
	return out, nil
}

// PurgeReporter implements Eraser. One call anonymises one page (<= 500) in one batch; updated documents leave
// the query, so a crash or a concurrent run converges. Reads: one per report returned (1 for an empty page).
func (r *FirestoreRepo) PurgeReporter(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	docs, err := r.client.Collection(reportsCollection).Where("reporterId", "==", uid).
		Select().Limit(opsPage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return cp, false, fmt.Errorf("moderation: purge %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, s := range docs {
		b.Update(s.Ref, []firestore.Update{{Path: "reporterId", Value: ""}})
	}
	if err := b.Commit(ctx); err != nil {
		return cp, false, fmt.Errorf("moderation: purge %s: %w", logger.HashUID(uid), err)
	}
	next := Checkpoint{Cleared: cp.Cleared + len(docs)}
	slog.InfoContext(ctx, "moderation_purge_batch", "uid_hash", logger.HashUID(uid), "reports", len(docs), "cleared_total", next.Cleared)
	return next, len(docs) < opsPage, nil
}

// exportedReport is one filed report in the data export (never evidence or anyone else's data).
type exportedReport struct {
	ID         string    `json:"id"`
	TargetType string    `json:"targetType"`
	TargetID   string    `json:"targetId"`
	Reason     string    `json:"reason"`
	Note       string    `json:"note"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"createdAt"`
}

// ExportUser implements Exporter: {"userId": ..., "reports": [...]} in pages of opsPage. Reads: one per report,
// minimum 1.
func (r *FirestoreRepo) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := fmt.Fprintf(w, `{"userId":%q,"reports":[`, uid); err != nil {
		return fmt.Errorf("moderation: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	var last *firestore.DocumentSnapshot
	for {
		q := r.client.Collection(reportsCollection).Where("reporterId", "==", uid).
			OrderBy(firestore.DocumentID, firestore.Asc).Limit(opsPage)
		if last != nil {
			q = q.StartAfter(last)
		}
		docs, err := q.Documents(ctx).GetAll()
		reads := int64(len(docs))
		if reads == 0 {
			reads = 1
		}
		budget.FromContext(ctx).AddReads(reads)
		if err != nil {
			return fmt.Errorf("moderation: export %s: query: %w", logger.HashUID(uid), err)
		}
		for _, s := range docs {
			var d reportDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("moderation: export decode %s: %w", s.Ref.ID, err)
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("moderation: write export: %w", err)
				}
			}
			first = false
			er := exportedReport{ID: s.Ref.ID, TargetType: d.TargetType, TargetID: d.TargetID, Reason: d.Reason,
				Note: d.Note, Status: d.Status, CreatedAt: d.CreatedAt.UTC()}
			if err := enc.Encode(er); err != nil {
				return fmt.Errorf("moderation: write export: %w", err)
			}
		}
		if len(docs) < opsPage {
			break
		}
		last = docs[len(docs)-1]
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("moderation: write export: %w", err)
	}
	return nil
}
