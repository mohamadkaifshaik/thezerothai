package main

import (
	"context"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// recountListFollowsUsage documents `opsctl recount-list-follows` (lists follow design, lane B).
const recountListFollowsUsage = `  opsctl recount-list-follows --project P --list LIST_ID [--write]
                          (repairs lists/{id}.followerCount from count() of its listFollows markers; dry run unless --write.
                          Use it after a list_follow failure or an erasure fallback; it prints counts only. Lists created
                          before followerCount existed have no field, so they do not appear in DiscoverLists until repaired)
  opsctl recount-list-follows --project P --all-missing [--write] [--after LIST_ID]
                          (scans every list, private ones too, and repairs each one with no followerCount field as above;
                          lists that have the field are left alone. Dry run unless --write; <= 5,000 writes per run, then
                          it prints the checkpoint to pass as --after. Prints counts only)
`

const (
	// listFollowsScanPage is one page of the --all-missing scan (document ids, followerCount only).
	listFollowsScanPage = 300
	// listFollowsMaxWrites caps one --all-missing --write run, like the backfills; a capped run prints its checkpoint.
	listFollowsMaxWrites = 5000
)

// listFollowRecounter is the lists repository's recount (*lists.FirestoreRepo).
type listFollowRecounter interface {
	RecountFollowers(ctx context.Context, listID string, write bool) (lists.FollowRecount, error)
	MissingFollowerCount(ctx context.Context, after string, limit int) (lists.MissingFollowerCountPage, error)
}

// recountListFollowsArgs are recount-list-follows' flags: one --list, or --all-missing with an optional --after.
type recountListFollowsArgs struct {
	list       string
	allMissing bool
	after      string
	write      bool
}

// recountListFollows is `opsctl recount-list-follows`: the stored followerCount, the marker count, and with --write the stored
// value set to the marker count in one transaction (a concurrent follow conflicts and the repair retries).
func recountListFollows(ctx context.Context, b *backends, a recountListFollowsArgs, out io.Writer) error {
	if a.allMissing {
		if a.list != "" {
			return usageErr("--list and --all-missing cannot be used together")
		}
		if a.after != "" && !postIDRe.MatchString(a.after) {
			return usageErr("--after must be a 19-digit list id")
		}
		if b.listFollows == nil {
			return fmt.Errorf("recount-list-follows is not wired")
		}
		return recountAllMissingListFollows(ctx, b, a.after, a.write, out)
	}
	if a.after != "" {
		return usageErr("--after needs --all-missing")
	}
	listID, write := a.list, a.write
	if !postIDRe.MatchString(listID) {
		return usageErr("--list must be a 19-digit list id (or pass --all-missing)")
	}
	if b.listFollows == nil {
		return fmt.Errorf("recount-list-follows is not wired")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	res, err := b.listFollows.RecountFollowers(cctx, listID, write)
	if err != nil {
		return err
	}
	stored := fmt.Sprint(res.Stored)
	if res.Missing {
		stored = "missing"
	}
	fmt.Fprintf(out, "list %s: followerCount=%s markers=%d\n", listID, stored, res.Counted)
	switch {
	case res.InStep():
		fmt.Fprintln(out, "in step: nothing to write")
	case res.Written:
		fmt.Fprintf(out, "set followerCount to %d\n", res.Counted)
	default:
		fmt.Fprintf(out, "dry-run: would set followerCount to %d (re-run with --write)\n", res.Counted)
	}
	return nil
}

// recountAllMissingListFollows is `recount-list-follows --all-missing`: page through every list by document id and run
// RecountFollowers on each one with no followerCount field (each repair is its own transaction, so a follow landing between
// the scan and the repair is counted). A dry run counts the missing lists and writes nothing. It prints counts only.
func recountAllMissingListFollows(ctx context.Context, b *backends, after string, write bool, out io.Writer) error {
	var scanned, missing, written int
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("interrupted at checkpoint %s: %w", checkpointOrDash(after), err)
		}
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		p, err := b.listFollows.MissingFollowerCount(pctx, after, listFollowsScanPage)
		cancel()
		if err != nil {
			return fmt.Errorf("page after %s: %w (rerun with --after %s)", checkpointOrDash(after), err, checkpointOrDash(after))
		}
		scanned += p.Scanned
		missing += len(p.Missing)
		if write {
			for _, id := range p.Missing {
				rctx, rcancel := context.WithTimeout(ctx, callTimeout)
				res, err := b.listFollows.RecountFollowers(rctx, id, true)
				rcancel()
				if err != nil {
					// Resume from the page's start: the lists already repaired now have the field, so a rerun skips them.
					return fmt.Errorf("repair failed after %d written: %w (rerun with --all-missing --write --after %s)", written, err, checkpointOrDash(after))
				}
				if res.Written {
					written++
				}
				if written >= listFollowsMaxWrites {
					fmt.Fprintf(out, "page: scanned=%d missing=%d written=%d checkpoint=%s\n", scanned, missing, written, id)
					fmt.Fprintf(out, "recount-list-follows: write cap of %d reached: rerun with --all-missing --write --after %s\n", listFollowsMaxWrites, id)
					return nil
				}
			}
		}
		if p.Last != "" {
			after = p.Last
		}
		fmt.Fprintf(out, "page: scanned=%d missing=%d written=%d checkpoint=%s\n", scanned, missing, written, checkpointOrDash(after))
		if p.Scanned < listFollowsScanPage {
			break
		}
	}
	if write {
		fmt.Fprintf(out, "recount-list-follows --all-missing: complete: scanned=%d missing=%d written=%d\n", scanned, missing, written)
	} else {
		fmt.Fprintf(out, "dry-run: scanned=%d missing=%d would_write=%d (re-run with --write)\n", scanned, missing, missing)
	}
	return nil
}
