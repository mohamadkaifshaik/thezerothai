package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// backfillHasMedia is `opsctl backfill-has-media` (ADR-0024 D4, W3-8): it gives every post document that lacks `hasMedia`
// the field, through posts.HasMediaBackfiller (the one definition, posts.HasMediaFor). Pages of <= 500 posts by __name__;
// at most posts.BackfillMaxWrites (5,000) writes per run, after which it stops, prints the checkpoint and says to rerun
// with --after on another day. A rerun (or a run after it finished) finds nothing missing and writes 0. --dry-run scans
// and counts for the same reads and writes nothing. The shared driveLoop retries a failed page (a post deleted between
// the read and the commit) and prints one progress line per page; the backfiller logs one `backfill_has_media` line each.
//
// Cost: 1 read per post scanned, 1 write per post lacking the field (<= 5,000 per run).
func backfillHasMedia(ctx context.Context, b *backends, after string, dryRun bool, out io.Writer) error {
	if b.backfiller == nil {
		return errors.New("backfill-has-media: no backfiller configured")
	}
	ctx, _ = budget.WithCounter(ctx)
	opts := posts.BackfillOptions{DryRun: dryRun}
	var last posts.BackfillCheckpoint
	var state posts.BackfillState
	err := driveLoop(ctx, out, posts.BackfillCheckpoint{After: after},
		func(ctx context.Context, cp posts.BackfillCheckpoint) (posts.BackfillCheckpoint, bool, error) {
			next, st, err := b.backfiller.BackfillHasMedia(ctx, cp, opts)
			if err != nil {
				return cp, false, err
			}
			last, state = next, st
			return next, st != posts.BackfillMore, nil
		}, describeBackfill, "backfill-has-media")
	if err != nil {
		return err
	}
	switch {
	case dryRun:
		fmt.Fprintf(out, "dry-run: scanned=%d missing=%d would_update=%d runs_needed=%d (nothing written)\n",
			last.Scanned, last.Missing, last.Missing, runsNeeded(last.Missing))
	case state == posts.BackfillCapped:
		fmt.Fprintf(out, "backfill-has-media: write cap of %d reached: scanned=%d updated=%d checkpoint=%s\n"+
			"more posts may lack hasMedia: rerun on another day with --after %s (a rerun without --after is also correct, it only re-reads)\n",
			posts.BackfillMaxWrites, last.Scanned, last.Updated, checkpointOrDash(last.After), last.After)
	default:
		fmt.Fprintf(out, "backfill-has-media: complete: scanned=%d updated=%d checkpoint=%s\n",
			last.Scanned, last.Updated, checkpointOrDash(last.After))
	}
	return nil
}

// describeBackfill renders a checkpoint for driveLoop's per-page progress line.
func describeBackfill(cp posts.BackfillCheckpoint) string {
	return fmt.Sprintf("scanned=%d missing=%d updated=%d checkpoint=%s", cp.Scanned, cp.Missing, cp.Updated, checkpointOrDash(cp.After))
}

func checkpointOrDash(after string) string {
	if after == "" {
		return "-"
	}
	return after
}

// runsNeeded is how many capped runs finish missing writes: ceil(missing / BackfillMaxWrites), 0 when nothing is missing.
func runsNeeded(missing int) int {
	return (missing + posts.BackfillMaxWrites - 1) / posts.BackfillMaxWrites
}

// validBackfillAfter checks --after: a document id, so it cannot contain a path separator.
func validBackfillAfter(after string) bool { return !strings.Contains(after, "/") }
