package main

import (
	"context"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// nameKeysUsage documents `opsctl search backfill-name-keys` (F20, F21).
const nameKeysUsage = `  opsctl search backfill-name-keys --project P --collection lists|communities [--after ID] [--max-pages N] [--write]
                          (writes nameLower, the SearchLists / SearchCommunities prefix key, on documents created before
                          it existed or holding a stale one; dry run unless --write. Pages of 200 in document-id order, at most
                          --max-pages (default 25, so <= 5,000 writes per run); a capped run prints the --after to resume
                          with. Idempotent: a second run finds nothing stale. Prints counts and ids only, never a name)
`

const (
	nameKeysDefaultPages = 25
	nameKeysMaxPages     = 500
)

// nameKeyBackfiller is one module's backfill page (*lists.FirestoreRepo, *communities.FirestoreRepo).
type nameKeyBackfiller interface {
	BackfillNameKeys(ctx context.Context, after string, limit int, write bool) (namekey.BackfillPage, error)
}

// nameKeyCollections maps --collection to its backfill; opsctl never touches the collections itself.
func (b *backends) nameKeyCollections() map[string]nameKeyBackfiller {
	return map[string]nameKeyBackfiller{"lists": b.listNameKeys, "communities": b.communityNameKeys}
}

// backfillNameKeys is `opsctl search backfill-name-keys`: pages of namekey.MaxBackfillPage documents, each a read of the page and,
// with write, one field-level Update per stale document (LastUpdateTime precondition: a rename that landed since the read
// keeps its own key and is counted as skipped).
func backfillNameKeys(ctx context.Context, b *backends, collection, after string, maxPages int, write bool, out io.Writer) error {
	src, ok := b.nameKeyCollections()[collection]
	if !ok || src == nil {
		return usageErr("--collection must be lists or communities")
	}
	if after != "" && !ids.ValidPostID(after) {
		return usageErr("--after must be a 19-digit document id (the value a capped run printed)")
	}
	switch {
	case maxPages == 0:
		maxPages = nameKeysDefaultPages
	case maxPages < 0 || maxPages > nameKeysMaxPages:
		return usageErr(fmt.Sprintf("--max-pages must be 1-%d", nameKeysMaxPages))
	}
	var total namekey.BackfillPage
	for page := 0; page < maxPages; page++ {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		p, err := src.BackfillNameKeys(cctx, after, namekey.MaxBackfillPage, write)
		cancel()
		total.Add(p)
		if err != nil {
			fmt.Fprintf(out, "%s: stopped after %d scanned; resume with --after %s\n", collection, total.Scanned, after)
			return err
		}
		if p.Last != "" {
			after = p.Last
		}
		if p.Done {
			break
		}
	}
	mode := "dry-run"
	if write {
		mode = "write"
	}
	fmt.Fprintf(out, "%s (%s): scanned=%d stale=%d written=%d skipped=%d\n", collection, mode, total.Scanned, total.Stale, total.Written, total.Skipped)
	switch {
	case !total.Done:
		fmt.Fprintf(out, "capped at %d pages: resume with --after %s\n", maxPages, after)
	case !write && total.Stale > 0:
		fmt.Fprintln(out, "dry-run: nothing written (re-run with --write)")
	default:
		fmt.Fprintln(out, "done")
	}
	return nil
}
