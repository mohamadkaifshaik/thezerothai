package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
)

const (
	// mediaOrphanBackfillPage is one page of the backfill scan (media documents by id).
	mediaOrphanBackfillPage = 100
	// mediaOrphanBackfillMaxWrites caps one backfill run, like backfill-has-media; a capped run prints its checkpoint.
	mediaOrphanBackfillMaxWrites = 5000
	// mediaOrphanSweepMaxPages caps one `media-orphan-sweep` run (pages of media.OrphanSweepPage).
	mediaOrphanSweepMaxPages = 20
)

// mediaOrphanBackfiller is *media.FirestoreRepo's BackfillOrphanChecks.
type mediaOrphanBackfiller interface {
	BackfillOrphanChecks(ctx context.Context, after string, limit int, checkAt time.Time, dryRun bool) (media.OrphanBackfillPage, error)
}

// mediaOrphanSweeper is *media.OrphanSweeper's Sweep.
type mediaOrphanSweeper interface {
	Sweep(ctx context.Context, now time.Time, limit int) (media.OrphanSweepResult, error)
}

// backfillMediaOrphans is `opsctl backfill-media-orphans`: it gives every published, unattached, unretired media document
// that predates the orphan sweep an orphanCheckAt of now + media.OrphanAfter, so the daily sweep starts looking at it a
// week later (the holders are checked then, and nothing is deleted before a second run at least media.OrphanGrace after
// the mark). Pages of 100 by document id; at most 5,000 writes per run, after which it prints the checkpoint to pass as
// --after. A rerun writes nothing for documents that have the field. --dry-run scans and counts, writing nothing.
func backfillMediaOrphans(ctx context.Context, b *backends, after string, dryRun bool, out io.Writer, now func() time.Time) error {
	if b.mediaBackfill == nil {
		return errors.New("backfill-media-orphans: no media repo configured")
	}
	checkAt := now().UTC().Add(media.OrphanAfter)
	var scanned, eligible, set, conflicts int
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("interrupted at checkpoint %s: %w", checkpointOrDash(after), err)
		}
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		p, err := b.mediaBackfill.BackfillOrphanChecks(pctx, after, mediaOrphanBackfillPage, checkAt, dryRun)
		cancel()
		scanned, eligible, set, conflicts = scanned+p.Scanned, eligible+p.Eligible, set+p.Set, conflicts+p.Conflicts
		if err != nil {
			return fmt.Errorf("page after %s: %w (rerun with --after %s)", checkpointOrDash(after), err, checkpointOrDash(after))
		}
		if p.Last != "" {
			after = p.Last
		}
		fmt.Fprintf(out, "page: scanned=%d eligible=%d set=%d conflicts=%d checkpoint=%s\n", scanned, eligible, set, conflicts, checkpointOrDash(after))
		if p.Scanned < mediaOrphanBackfillPage {
			break
		}
		if set >= mediaOrphanBackfillMaxWrites {
			fmt.Fprintf(out, "backfill-media-orphans: write cap of %d reached: rerun with --after %s\n", mediaOrphanBackfillMaxWrites, after)
			return nil
		}
	}
	switch {
	case dryRun:
		fmt.Fprintf(out, "dry-run: scanned=%d would_set=%d (nothing written)\n", scanned, eligible)
	default:
		fmt.Fprintf(out, "backfill-media-orphans: complete: scanned=%d set=%d conflicts=%d (orphanCheckAt=%s; rerun to retry conflicts)\n",
			scanned, set, conflicts, checkAt.Format(time.RFC3339))
	}
	return nil
}

// mediaOrphanSweep is `opsctl media-orphan-sweep`: it runs the daily step's sweep in process, page after page, to drain a
// backlog (after the backfill, say). It stops when a page is not full, after mediaOrphanSweepMaxPages pages, or when a page
// changed nothing (only conflicts, failures or skips: running again would read the same documents). Profile images are
// deleted only when PROFILE_MEDIA_RETIRE in this shell allows their purpose (unset = off = kept), so set it to the
// project's value. No dry run: nothing is deleted before a second pass at least media.OrphanGrace after the mark.
func mediaOrphanSweep(ctx context.Context, b *backends, out io.Writer, now func() time.Time) error {
	if b.retireErr != nil {
		return fmt.Errorf("PROFILE_MEDIA_RETIRE: %w", b.retireErr)
	}
	if b.mediaSweeper == nil {
		return errors.New("media-orphan-sweep: no sweeper configured")
	}
	var total media.OrphanSweepResult
	for page := 1; page <= mediaOrphanSweepMaxPages; page++ {
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		res, err := b.mediaSweeper.Sweep(pctx, now(), media.OrphanSweepPage)
		cancel()
		total.Due += res.Due
		total.Marked += res.Marked
		total.Deleted += res.Deleted
		fmt.Fprintf(out, "page %d: due=%d marked=%d deleted=%d held=%d kept=%d attached=%d restored=%d waiting=%d conflicts=%d failed=%d skipped=%d\n",
			page, res.Due, res.Marked, res.Deleted, res.Held, res.Kept, res.Attached, res.Restored, res.Waiting, res.Conflicts, res.Failed, res.Skipped)
		if err != nil {
			return err
		}
		progressed := res.Marked + res.Deleted + res.Held + res.Kept + res.Attached + res.Restored + res.Waiting
		if !res.More || progressed == 0 {
			break
		}
	}
	fmt.Fprintf(out, "media-orphan-sweep: due=%d marked=%d deleted=%d (marked images are deleted by a run at least %s later)\n",
		total.Due, total.Marked, total.Deleted, media.OrphanGrace)
	return nil
}

// draftHolds is media.DraftHolds over the posts repo (PENDING scheduled drafts) and articles (unpublished draft covers),
// the same composition as apiserver's draftMediaHolds.
type draftHolds struct {
	scheduled interface {
		PendingScheduledMediaHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
	}
	articles interface {
		DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
	}
}

func (h draftHolds) HeldByDrafts(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	held, err := h.scheduled.PendingScheduledMediaHolds(ctx, uid, ids)
	if err != nil {
		return nil, err
	}
	covers, err := h.articles.DraftCoverHolds(ctx, uid, ids)
	if err != nil {
		return nil, err
	}
	for id := range covers {
		held[id] = true
	}
	return held, nil
}
