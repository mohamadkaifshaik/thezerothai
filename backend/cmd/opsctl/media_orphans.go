package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

const (
	// mediaOrphanBackfillPage is one page of the backfill scan (media documents by id).
	mediaOrphanBackfillPage = 100
	// mediaOrphanBackfillMaxWrites caps one backfill run, like backfill-has-media; a capped run prints its checkpoint.
	mediaOrphanBackfillMaxWrites = 5000
	// mediaOrphanSweepMaxPages caps one `media-orphan-sweep` run (pages of media.OrphanSweepPage; a dry run reads one).
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

// mediaSweeperFactory builds the orphan sweep for one media-orphan-sweep run under the operator's explicit
// --profile-retire and --dry-run (openFirestore's is media.NewOrphanSweeper in delete mode over the real holders).
type mediaSweeperFactory func(retire config.ProfileMediaRetire, dryRun bool) (mediaOrphanSweeper, error)

// mediaOrphanSweepHeader is the line media-orphan-sweep prints before anything runs (and before the prod prompt): the
// effective switches, the project and this workstation's clock, which the sweep uses as "now".
func mediaOrphanSweepHeader(project string, retire config.ProfileMediaRetire, dryRun bool, now time.Time) string {
	return fmt.Sprintf("media-orphan-sweep: project=%s sweep=%s profile-retire=%s dry-run=%t clock=%s (MEDIA_ORPHAN_SWEEP and PROFILE_MEDIA_RETIRE are not read from this shell)\n",
		project, config.MediaOrphanSweepDelete, retire, dryRun, now.UTC().Format(time.RFC3339))
}

// mediaOrphanSweep is `opsctl media-orphan-sweep`: it runs the daily step's sweep in process in delete mode, page after
// page, to drain a backlog (after the backfill, say). Profile images are deleted only when the explicit --profile-retire
// allows their purpose (the operator chooses it; nothing is read from the shell). It stops when a page is not full, after
// mediaOrphanSweepMaxPages pages, or when a page changed nothing (only conflicts, failures or skips: running again would
// read the same documents). --dry-run computes the verdicts of exactly one page (nothing is written, so a second page would
// be the same one) and prints what a real run would do. The sweep's clock sanity check never marks an image whose
// createdAt is less than media.OrphanAfter before this workstation's clock.
func mediaOrphanSweep(ctx context.Context, b *backends, retire config.ProfileMediaRetire, dryRun bool, out io.Writer, now func() time.Time) error {
	if b.newMediaSweeper == nil {
		return errors.New("media-orphan-sweep: no sweeper configured")
	}
	sweeper, err := b.newMediaSweeper(retire, dryRun)
	if err != nil {
		return fmt.Errorf("media-orphan-sweep: %w", err)
	}
	maxPages := mediaOrphanSweepMaxPages
	if dryRun {
		maxPages = 1
	}
	var total media.OrphanSweepResult
	for page := 1; page <= maxPages; page++ {
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		res, err := sweeper.Sweep(pctx, now(), media.OrphanSweepPage)
		cancel()
		total.Add(res)
		fmt.Fprintf(out, "page %d: due=%d marked=%d deleted=%d held=%d kept=%d attached=%d restored=%d waiting=%d young=%d conflicts=%d failed=%d skipped=%d undecodable=%d\n",
			page, res.Due, res.Marked, res.Deleted, res.Held, res.Kept, res.Attached, res.Restored, res.Waiting, res.Young, res.Conflicts, res.Failed, res.Skipped, res.Undecodable)
		if err != nil {
			return err
		}
		if !res.More || res.Progressed() == 0 {
			break
		}
	}
	if dryRun {
		fmt.Fprintf(out, "dry-run: one page, nothing written: would mark=%d would delete=%d (more=%t)\n", total.Marked, total.Deleted, total.More)
		return nil
	}
	fmt.Fprintf(out, "media-orphan-sweep: due=%d marked=%d deleted=%d (marked images are deleted by a run at least %s later)\n",
		total.Due, total.Marked, total.Deleted, media.OrphanGrace)
	return nil
}
