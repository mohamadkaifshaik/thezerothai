package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const trendsUsage = `  opsctl trends hide      TAG --project P   (the tag leaves Trending on every server within 10 min, every screen within 15; quote a leading #)
  opsctl trends unhide    TAG --project P
  opsctl trends list      --project P       (the hide list: folded keys, at most 100)
`

// parseTrendsArgs validates `opsctl trends <hide|unhide|list> [TAG]` before anything is opened or confirmed. The tag is
// folded by search.TrendKey (NFKC, lower-case, U+200C, U+200D and '_' removed); one that folds to nothing, or is longer
// than a hashtag can be, is a usage error.
func parseTrendsArgs(sub, tag string) error {
	switch sub {
	case "hide", "unhide":
		if tag == "" {
			return usageErr("trends " + sub + " needs the tag as its first argument (quote it if it starts with #)")
		}
		if _, err := search.HideKey(tag); err != nil {
			return usageErr("trends " + sub + ": " + err.Error())
		}
	case "list":
	default:
		return usageErr("trends needs a sub-command: hide, unhide or list")
	}
	return nil
}

// trendsCommand is `opsctl trends hide|unhide|list` (ADR-0028 note 2026-10-31 part 1, review M-1): the operator's fast
// removal of an abusive trend, with no deploy. It writes only trends/hidden, through search.TrendsStore. The usual prod
// confirmation (the typed project id) already ran in run().
//
// Cost: hide and unhide are one transaction: 1 read and, when the list changes, 1 write (a repeat, an unknown key and a
// missing document write 0; a full list of 100 keys refuses with 0 writes). list is 1 read. The cost line is printed
// last. Hide and unhide print a fixed-shape audit line (project, UTC time, folded key, whether it wrote, the list size):
// it is the moderation trail, because the document records no actor.
func trendsCommand(ctx context.Context, b *backends, project, sub, tag string, out io.Writer, now func() time.Time) error {
	if b.trends == nil {
		return errors.New("trends: no trends store configured")
	}
	ctx, counter := budget.WithCounter(ctx)
	defer func() { fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes()) }()
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	switch sub {
	case "list":
		keys, err := b.trends.Hidden(cctx)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "%d hidden key(s)\n", len(keys))
		for _, k := range keys {
			fmt.Fprintln(out, k)
		}
		return nil
	case "hide", "unhide":
		var (
			res search.HideResult
			err error
		)
		if sub == "hide" {
			res, err = b.trends.Hide(cctx, tag)
		} else {
			res, err = b.trends.Unhide(cctx, tag)
		}
		if errors.Is(err, search.ErrHiddenFull) {
			return fmt.Errorf("%w (run `opsctl trends list` and unhide one)", err)
		}
		if err != nil {
			return err
		}
		switch {
		case res.Changed && sub == "hide":
			fmt.Fprintf(out, "hidden: %q (%d on the list)\nGetTrends drops it within 10 min on every server and every screen within 15 min; the next sweep drops it too\n", res.Key, res.Count)
		case res.Changed:
			fmt.Fprintf(out, "unhidden: %q (%d on the list)\nit can appear again at the next list load (10 min) if it still qualifies\n", res.Key, res.Count)
		case sub == "hide":
			fmt.Fprintf(out, "already hidden: %q; nothing written\n", res.Key)
		default:
			fmt.Fprintf(out, "not on the hide list: %q; nothing written\n", res.Key)
		}
		fmt.Fprintf(out, "audit: trends %s project=%s at=%s key=%s wrote=%t count=%d\n",
			sub, project, now().UTC().Format(time.RFC3339), res.Key, res.Changed, res.Count)
		return nil
	}
	return usageErr("trends needs a sub-command: hide, unhide or list")
}
