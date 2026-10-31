// purge.go is the right-to-delete and right-to-access path of lists/{listId} (ADR-0030 D8, ticket W5-5). Deleting users/{uid}
// does not delete a list, so the `lists` account-deletion step (Eraser, registered BeforeIdentity after `messaging`) removes
// the user's own lists and then removes the uid from every other list that names it, and the `lists` export section writes
// the user's own lists. Neither is flag-gated: documents outlive the flag.
package lists

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// purgePage is the most lists one eraser invocation touches (a Firestore batch holds 500 writes).
	purgePage = 500
	// exportPage is the page of the export (a user owns at most LISTS_MAX_PER_USER = 20 lists, so one page in practice).
	exportPage = 100

	phaseOwn    = ""
	phaseMember = "member"
)

// MemberPage is the outcome of one RemoveMemberPage call.
type MemberPage struct {
	// Scanned is how many lists named the uid on this page (the query's size, at most purgePage).
	Scanned int
	// Updated is how many of them were rewritten.
	Updated int
	// Conflict says the batch lost a race (a list changed or went away between the query and the commit); nothing was
	// written and the next call re-queries.
	Conflict bool
}

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// PurgeOwnedPage deletes up to purgePage of uid's own lists in one atomic batch and reports how many. Reads: one per
	// list (minimum 1); deletes: one per list. Deleted lists leave the next page, so repeating the call is self-resuming.
	PurgeOwnedPage(ctx context.Context, uid string) (deleted int, err error)
	// RemoveMemberPage removes uid from up to purgePage lists that name it (memberIds array-contains uid): a field-level
	// Update (ArrayRemove and updatedAt) with a LastUpdateTime precondition, never a Set. Reads: one per list (minimum 1);
	// writes: one per list. A list changed or deleted since the query makes the batch a Conflict with nothing written.
	RemoveMemberPage(ctx context.Context, uid string) (MemberPage, error)
}

var _ PagePurger = (*FirestoreRepo)(nil)

// PurgeOwnedPage implements PagePurger.
func (r *FirestoreRepo) PurgeOwnedPage(ctx context.Context, uid string) (int, error) {
	docs, err := r.col().Where("ownerId", "==", uid).Select().Limit(purgePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("lists: purge owned %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	ids := make([]string, len(docs))
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for i, d := range docs {
		ids[i] = d.Ref.ID
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		// The commit error names the deleted documents' paths: redact the uid and the list ids.
		return 0, logger.RedactErr(fmt.Errorf("lists: purge owned %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
	}
	return len(docs), nil
}

// RemoveMemberPage implements PagePurger.
func (r *FirestoreRepo) RemoveMemberPage(ctx context.Context, uid string) (MemberPage, error) {
	docs, err := r.col().Where("memberIds", "array-contains", uid).Select().Limit(purgePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge member %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return MemberPage{}, nil
	}
	ids := make([]string, len(docs))
	now := r.now().UTC()
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for i, d := range docs {
		ids[i] = d.Ref.ID
		b.Update(d.Ref, []firestore.Update{
			{Path: "memberIds", Value: firestore.ArrayRemove(uid)},
			{Path: "updatedAt", Value: now},
		}, firestore.LastUpdateTime(d.UpdateTime))
	}
	if err := b.Commit(ctx); err != nil {
		if store.IsPreconditionFailed(err) {
			return MemberPage{Scanned: len(docs), Conflict: true}, nil
		}
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge member %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
	}
	return MemberPage{Scanned: len(docs), Updated: len(docs)}, nil
}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning. Deleted and rewritten lists drop
// out of the next page, so the purge is self-resuming and the counts are only for logging. It is the step's own type: the step
// name is persisted in deletionJob.step.
type Checkpoint struct {
	// Phase is "" while the user's own lists are being deleted and "member" while the uid is being removed from other lists.
	Phase   string `json:"phase,omitempty"`
	Deleted int    `json:"deleted,omitempty"`
	Updated int    `json:"updated,omitempty"`
}

// Eraser is the `lists` account-deletion step (ADR-0030 D8). Phase 1 deletes the user's own lists (which also removes any
// membership in them), phase 2 removes the uid from other users' lists. One page of at most 500 per call; never flag-gated.
type Eraser struct {
	repo PagePurger
}

// NewEraser builds the step on a PagePurger (FirestoreRepo in production).
func NewEraser(repo PagePurger) *Eraser { return &Eraser{repo: repo} }

// PurgeUser runs one page and reports whether the step is finished. An account with no lists takes two calls (an empty page
// per phase, 1 read each, 0 writes); a repeat after completion is the same two empty pages, so a rerun writes 0. Reads: one
// per list (minimum 1 per call); deletes: one per own list; writes: one per list the user was a member of.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Phase == phaseOwn {
		n, err := e.repo.PurgeOwnedPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Phase: phaseOwn, Deleted: cp.Deleted + n, Updated: cp.Updated}
		if n < purgePage {
			next.Phase = phaseMember
		}
		slog.InfoContext(ctx, "lists_purge", "uid_hash", logger.HashUID(uid), "phase", "own", "docs", n, "deleted_total", next.Deleted)
		return next, false, nil
	}
	pg, err := e.repo.RemoveMemberPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := Checkpoint{Phase: phaseMember, Deleted: cp.Deleted, Updated: cp.Updated + pg.Updated}
	slog.InfoContext(ctx, "lists_purge", "uid_hash", logger.HashUID(uid), "phase", "member", "docs", pg.Updated, "conflict", pg.Conflict, "updated_total", next.Updated)
	if pg.Conflict {
		return next, false, nil // nothing was written: the next call re-queries
	}
	return next, pg.Scanned < purgePage, nil
}

// ExportedList is one row of the `lists` export section: the user's own list with its member ids (ADR-0030 D8). Lists the user
// is a member of belong to their owners and are not exported.
type ExportedList struct {
	ListID      string    `json:"listId"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	IsPrivate   bool      `json:"isPrivate"`
	MemberIDs   []string  `json:"memberIds"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

// ExportSource pages through a user's own lists (FirestoreRepo in production).
type ExportSource interface {
	// ExportPage returns uid's lists after the list id `after` ("" = from the start), in id order, at most limit. Reads:
	// len(result), minimum 1.
	ExportPage(ctx context.Context, uid, after string, limit int) ([]ExportedList, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// ExportPage implements ExportSource: ownerId == uid ordered by the document id, on the automatic single-field index, with a
// Limit.
func (r *FirestoreRepo) ExportPage(ctx context.Context, uid, after string, limit int) ([]ExportedList, error) {
	q := r.col().Where("ownerId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(min(max(limit, 1), exportPage)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("lists: export %s: query: %w", logger.HashUID(uid), err), uid, after)
	}
	out := make([]ExportedList, 0, len(docs))
	for _, s := range docs {
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: export decode: %w", err), uid, s.Ref.ID)
		}
		members := d.MemberIDs
		if members == nil {
			members = []string{}
		}
		out = append(out, ExportedList{
			ListID: s.Ref.ID, Name: d.Name, Description: d.Description, IsPrivate: d.IsPrivate, MemberIDs: members,
			CreatedAt: d.CreatedAt.UTC(), UpdatedAt: d.UpdatedAt.UTC(),
		})
	}
	return out, nil
}

// Exporter writes the `lists` export section.
type Exporter struct {
	src ExportSource
	// member, handles and social are set by WithMembership (W5-46); a nil member writes no lists_member_of part.
	member  MemberOfSource
	handles HandleSource
	social  SocialSource
}

// NewExporter builds the section on an ExportSource (FirestoreRepo in production).
func NewExporter(src ExportSource) *Exporter { return &Exporter{src: src} }

// ExportUser streams {"lists":[...]} to w, in list-id order, in pages of 100 (memory stays bounded). Reads: one per list,
// minimum 1.
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"lists":[`); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first, after := true, ""
	for {
		page, err := x.src.ExportPage(ctx, uid, after, exportPage)
		if err != nil {
			return err
		}
		for _, l := range page {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("lists: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(l); err != nil {
				return fmt.Errorf("lists: write export: %w", err)
			}
		}
		if len(page) < exportPage {
			break
		}
		after = page[len(page)-1].ListID
	}
	if _, err := io.WriteString(w, "]"); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	if x.member != nil {
		if err := x.writeMemberOf(ctx, uid, w); err != nil {
			return err
		}
	}
	if _, err := io.WriteString(w, "}\n"); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	return nil
}
