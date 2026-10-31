// purge_polls.go is the right-to-delete and right-to-access path of pollVotes/{postId}_{uid} (ADR-0029 D8, ADR-0011, ticket
// W6-8). The `poll_votes` account-deletion step (PollVoteEraser, registered BeforeIdentity after the existing steps, so it runs
// after `engagement`, which already deleted userLikes and with it userLikes.pollVotes) deletes every vote document the user cast,
// and the `poll_votes` export section lists post id, choice, time and (once changed) changedAt per row.
//
// Counts are left as they are (F6): a deleted account's vote stays in the poll's anonymous totals, and no document keeps naming
// the uid afterwards. A vote document of ANOTHER user on a poll post that was deleted holds no uid of the post's author and
// expires by TTL (closesAt + POLL_VOTE_TTL_AFTER_CLOSE). Neither path is flag-gated: documents outlive the flag.
//
// Both queries are `uid ==` on the automatic single-field index, paged by document id (the id starts with the time-ordered post id):
// no ordering on createdAt, so no composite index is needed.
package engagement

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

// pollVotePage is the page of the erase step and of the export (ops path, a Firestore batch holds 500 writes).
const pollVotePage = 500

// PollVotePurger deletes one page of a user's vote documents.
type PollVotePurger interface {
	// PurgePollVotesPage deletes up to pollVotePage (500) of uid's pollVotes documents in one atomic batch and reports how many.
	// Reads: one per document (minimum 1); deletes: one per document. Deleted documents leave the next page, so repeating the
	// call is self-resuming.
	PurgePollVotesPage(ctx context.Context, uid string) (deleted int, err error)
}

// PollVoteExportSource pages through a user's vote documents for the export.
type PollVoteExportSource interface {
	// ExportPollVotesPage returns uid's votes with a document id after afterID ("" = from the start), by document id, at most
	// limit (clamped to 1..pollVotePage). Reads: len(result), minimum 1.
	ExportPollVotesPage(ctx context.Context, uid, afterID string, limit int) ([]ExportedPollVote, error)
}

var (
	_ PollVotePurger       = (*FirestoreRepo)(nil)
	_ PollVoteExportSource = (*FirestoreRepo)(nil)
)

// ExportedPollVote is one row of the `poll_votes` export section: the user's own vote, never anyone else's.
type ExportedPollVote struct {
	PostID    string    `json:"postId"`
	Choice    int       `json:"choice"`
	CreatedAt time.Time `json:"createdAt"`
	// ChangedAt is the time of the last vote change, present only once the vote was changed (ADR-0029 Amendment 1 A2.6). No earlier choice is kept.
	ChangedAt *time.Time `json:"changedAt,omitempty"`
	// id is the document id, the page cursor (not exported).
	id string
}

// PurgePollVotesPage implements PollVotePurger.
func (r *FirestoreRepo) PurgePollVotesPage(ctx context.Context, uid string) (int, error) {
	docs, err := r.client.Collection(pollVotesCollection).Where("uid", "==", uid).Select().Limit(pollVotePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("engagement: purge poll votes %s: query: %w", logger.HashUID(uid), err), uid)
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
		// The commit error names the deleted documents' paths (post id and uid): redact both.
		return 0, logger.RedactErr(fmt.Errorf("engagement: purge poll votes %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
	}
	return len(docs), nil
}

// ExportPollVotesPage implements PollVoteExportSource.
func (r *FirestoreRepo) ExportPollVotesPage(ctx context.Context, uid, afterID string, limit int) ([]ExportedPollVote, error) {
	col := r.client.Collection(pollVotesCollection)
	q := col.Where("uid", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if afterID != "" {
		q = q.StartAfter(col.Doc(afterID))
	}
	docs, err := q.Limit(min(max(limit, 1), pollVotePage)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("engagement: export poll votes %s: query: %w", logger.HashUID(uid), err), uid, afterID)
	}
	out := make([]ExportedPollVote, 0, len(docs))
	for _, s := range docs {
		var d pollVoteDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("engagement: export decode poll vote: %w", err), uid, s.Ref.ID)
		}
		row := ExportedPollVote{PostID: d.PostID, Choice: d.Choice, CreatedAt: d.CreatedAt.UTC(), id: s.Ref.ID}
		if !d.ChangedAt.IsZero() {
			at := d.ChangedAt.UTC()
			row.ChangedAt = &at
		}
		out = append(out, row)
	}
	return out, nil
}

// PollVoteCheckpoint resumes PollVoteEraser.PurgeUser across calls. Deleted documents drop out of the next page, so the purge is
// self-resuming and the checkpoint only carries the running count for logging. It is the step's own type: the step name is
// persisted in deletionJob.step and is never folded into another step's checkpoint.
type PollVoteCheckpoint struct {
	Deleted int
}

// PollVoteEraser is the `poll_votes` account-deletion step (ADR-0029 D8): one page of at most 500 vote documents per call. An
// account with 120 votes takes 1 invocation, 120 reads + 120 deletes (a short page ends the step, so no extra empty read).
type PollVoteEraser struct {
	repo PollVotePurger
}

// NewPollVoteEraser builds the step on a PollVotePurger (FirestoreRepo in production).
func NewPollVoteEraser(repo PollVotePurger) *PollVoteEraser { return &PollVoteEraser{repo: repo} }

// PurgeUser deletes one page. done is true when the page was short, which includes the empty page of an account that never voted
// or whose documents a previous run already deleted (idempotent re-run: 1 read, 0 writes). Reads: one per document (minimum 1);
// deletes: one per document; writes: 0.
func (e *PollVoteEraser) PurgeUser(ctx context.Context, uid string, cp PollVoteCheckpoint) (PollVoteCheckpoint, bool, error) {
	n, err := e.repo.PurgePollVotesPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := PollVoteCheckpoint{Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "engagement_purge_poll_votes", "uid_hash", logger.HashUID(uid), "docs", n, "deleted_total", next.Deleted)
	}
	return next, n < pollVotePage, nil
}

// PollVoteExporter writes the `poll_votes` export section.
type PollVoteExporter struct {
	src PollVoteExportSource
}

// NewPollVoteExporter builds the section on a PollVoteExportSource (FirestoreRepo in production).
func NewPollVoteExporter(src PollVoteExportSource) *PollVoteExporter {
	return &PollVoteExporter{src: src}
}

// ExportUser streams {"poll_votes":[{"postId","choice","createdAt"[,"changedAt"]}]} to w, by post id, in pages of 500 (memory stays bounded).
// Reads: one per vote, minimum 1. Votes expire (closesAt + 30 d), so the section holds recent votes only.
func (x *PollVoteExporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"poll_votes":[`); err != nil {
		return fmt.Errorf("engagement: write poll votes export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	after := ""
	for {
		page, err := x.src.ExportPollVotesPage(ctx, uid, after, pollVotePage)
		if err != nil {
			return err
		}
		for _, v := range page {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("engagement: write poll votes export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(v); err != nil {
				return fmt.Errorf("engagement: write poll votes export: %w", err)
			}
		}
		if len(page) < pollVotePage {
			break
		}
		after = page[len(page)-1].id
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("engagement: write poll votes export: %w", err)
	}
	return nil
}
