// backfill.go is the one-off `opsctl backfill-has-media` repo helper (ADR-0024 D4, W3-8): it gives every pre-W3 post
// document the `hasMedia` field that the create paths have written since W3-7, so the profile Media tab query
// (authorId == A AND hasMedia == true) sees old posts too.
//
// Query:  posts ORDER BY __name__ ASC [StartAfter(checkpoint)] LIMIT page (page <= opsPage = 500). A collection-wide
// scan in id order uses the automatic __name__ index (no firestore.indexes.json change). The Limit(500) is an ops path
// (ADR-0003 purge rule); CLAUDE.md rule 5's maximum of 50 governs RPC pagination only.
//
// Cost: 1 read per post scanned (the `Select` projection narrows the payload, not the billing) and 1 write per post whose
// document lacks the key, never more than BackfillMaxWrites in one run. A rerun finds no missing key and writes 0.
package posts

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fieldHasMedia is the stored name of posts.hasMedia (postDoc.HasMedia).
const fieldHasMedia = "hasMedia"

// BackfillMaxWrites is the most writes one backfill run issues (ADR-0024 D4): a quarter of a day's free Firestore writes
// (20,000), so the backfill never starves the live API of its quota. A bigger collection is finished by rerunning the
// next day (with `--after`, from the checkpoint the capped run printed).
const BackfillMaxWrites = 5_000

// HasMediaBackfiller is the seam opsctl drives. The zero BackfillCheckpoint starts from the first post; call again with
// the returned checkpoint until the state is not BackfillMore.
type HasMediaBackfiller interface {
	BackfillHasMedia(ctx context.Context, cp BackfillCheckpoint, opts BackfillOptions) (BackfillCheckpoint, BackfillState, error)
}

var _ HasMediaBackfiller = (*FirestoreRepo)(nil)

// BackfillOptions tunes one BackfillHasMedia call. The zero value is the production setting.
type BackfillOptions struct {
	// PageSize is the posts read per call; 0 or more than opsPage (500) means opsPage. Tests use small pages.
	PageSize int
	// MaxWrites caps the writes of the whole run (the checkpoint's Updated counts them); 0 or more than
	// BackfillMaxWrites means BackfillMaxWrites. It is ignored in a dry run, which writes nothing.
	MaxWrites int
	// DryRun scans and counts but writes nothing. It costs the same reads as a real run.
	DryRun bool
}

// BackfillCheckpoint is the progress of one run, carried between calls.
type BackfillCheckpoint struct {
	// After is the id of the last post decided on (written, or found to have the field already): the next page starts
	// after it, and it is what `opsctl backfill-has-media --after` accepts to resume a capped run. "" = the start.
	After string
	// Scanned counts the posts decided on so far. On a capped run the last page may have been read beyond this point
	// (the posts after the cap were read but are not decided), so reads can exceed Scanned by less than one page.
	Scanned int
	// Missing counts the posts found without the field: written in a real run, "would be written" in a dry run.
	Missing int
	// Updated counts the posts written (always 0 in a dry run).
	Updated int
}

// BackfillState says what a BackfillHasMedia call found.
type BackfillState int

const (
	// BackfillMore: there may be more posts; call again with the returned checkpoint.
	BackfillMore BackfillState = iota
	// BackfillDone: the end of the collection was reached.
	BackfillDone
	// BackfillCapped: the run's write cap was reached before the end. Rerun later with the checkpoint's After.
	BackfillCapped
)

func (s BackfillState) String() string {
	switch s {
	case BackfillDone:
		return "done"
	case BackfillCapped:
		return "capped"
	default:
		return "more"
	}
}

// backfillDoc is what the backfill needs from one posts document: its kind, how many images it stores itself, and
// whether `hasMedia` already exists as a bool. Presence is read from the raw map, never by decoding into postDoc:
// postDoc.HasMedia has no omitempty, so an absent key would decode as false and be indistinguishable from the explicit
// false every post written since W3-7 carries.
type backfillDoc struct {
	id       string
	kind     Kind
	media    int
	hasField bool
}

// backfillDocOf extracts a backfillDoc from a projected posts document. A hasMedia that is not a bool (null) counts as
// missing, so the backfill repairs it.
func backfillDocOf(id string, data map[string]any) backfillDoc {
	kind, _ := data["kind"].(string)
	media, _ := data["media"].([]any)
	_, isBool := data[fieldHasMedia].(bool)
	return backfillDoc{id: id, kind: Kind(kind), media: len(media), hasField: isBool}
}

// backfillWrite is one pending field update.
type backfillWrite struct {
	id    string
	value bool
}

// planBackfillPage decides which docs of a page to write. A doc lacking the field gets HasMediaFor(kind, media), the one
// definition of hasMedia. room is the number of writes still allowed; a doc that would exceed it ends the page early:
// decided is the number of leading docs decided on (written, or already carrying the field), so the checkpoint is the
// last doc decided and a resume re-reads, never skips, the rest. A dry run (room < 0) has no cap.
func planBackfillPage(docs []backfillDoc, room int) (writes []backfillWrite, decided int, capped bool) {
	for i, d := range docs {
		if d.hasField {
			continue
		}
		if room >= 0 && len(writes) >= room {
			return writes, i, true
		}
		writes = append(writes, backfillWrite{id: d.id, value: HasMediaFor(d.kind, d.media)})
	}
	return writes, len(docs), false
}

// normaliseBackfill applies the BackfillOptions defaults and bounds.
func normaliseBackfill(o BackfillOptions) (page, maxWrites int) {
	page, maxWrites = o.PageSize, o.MaxWrites
	if page <= 0 || page > opsPage {
		page = opsPage
	}
	if maxWrites <= 0 || maxWrites > BackfillMaxWrites {
		maxWrites = BackfillMaxWrites
	}
	return page, maxWrites
}

// BackfillHasMedia implements HasMediaBackfiller. One call reads one page (<= opsPage posts, 1 read each, 1 for an empty
// page) and commits one field-level `Update` batch for the posts that lack `hasMedia` (1 write each, <= 500, never
// `Set`). It never overwrites an existing value, explicit false included.
//
// There is deliberately no LastUpdateTime precondition (unlike HideAuthor): the inputs, kind and media, are immutable
// after create, and a like on any one of 500 posts would otherwise fail the whole page. A post deleted between the read
// and the commit fails the batch with NotFound (Update requires the document to exist); nothing is written, and the caller retries the
// call, whose fresh page no longer holds it.
//
// A short page is the end of the collection (BackfillDone, no extra empty query). BackfillCapped is returned once the
// run's writes reach MaxWrites with posts left, with the checkpoint on the last post decided.
func (r *FirestoreRepo) BackfillHasMedia(ctx context.Context, cp BackfillCheckpoint, opts BackfillOptions) (BackfillCheckpoint, BackfillState, error) {
	if strings.Contains(cp.After, "/") {
		return cp, BackfillMore, ErrInvalidID
	}
	page, maxWrites := normaliseBackfill(opts)
	room := maxWrites - cp.Updated
	if opts.DryRun {
		room = -1
	} else if room <= 0 {
		return cp, BackfillCapped, nil // the cap was reached by an earlier call: read nothing more
	}
	q := r.client.Collection(postsCollection).Select("kind", "media", fieldHasMedia).OrderBy(firestore.DocumentID, firestore.Asc)
	if cp.After != "" {
		q = q.StartAfter(r.ref(cp.After))
	}
	snaps, err := q.Limit(page).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(int64(max(len(snaps), 1)))
	if err != nil {
		return cp, BackfillMore, fmt.Errorf("posts: backfill hasMedia: query: %w", err)
	}
	docs := make([]backfillDoc, len(snaps))
	for i, s := range snaps {
		docs[i] = backfillDocOf(s.Ref.ID, s.Data())
	}
	writes, decided, capped := planBackfillPage(docs, room)
	if len(writes) > 0 && !opts.DryRun {
		b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
		for _, w := range writes {
			b.Update(r.ref(w.id), []firestore.Update{{Path: fieldHasMedia, Value: w.value}})
		}
		if err := b.Commit(ctx); err != nil {
			return cp, BackfillMore, fmt.Errorf("posts: backfill hasMedia: %w", err)
		}
	}
	next := cp
	next.Scanned += decided
	next.Missing += len(writes)
	if !opts.DryRun {
		next.Updated += len(writes)
	}
	if decided > 0 {
		next.After = docs[decided-1].id
	}
	state := BackfillMore
	switch {
	case capped:
		state = BackfillCapped
	case len(snaps) < page:
		state = BackfillDone
	case !opts.DryRun && next.Updated >= maxWrites:
		state = BackfillCapped
	}
	// Post ids only, never author ids or text (logging rule).
	slog.InfoContext(ctx, "backfill_has_media", "page_scanned", decided, "page_missing", len(writes), "page_updated", next.Updated-cp.Updated,
		"scanned", next.Scanned, "missing", next.Missing, "updated", next.Updated, "checkpoint", next.After,
		"state", state.String(), "dry_run", opts.DryRun)
	return next, state, nil
}
