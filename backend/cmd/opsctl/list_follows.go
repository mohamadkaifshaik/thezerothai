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
`

// listFollowRecounter is the lists repository's recount (*lists.FirestoreRepo).
type listFollowRecounter interface {
	RecountFollowers(ctx context.Context, listID string, write bool) (lists.FollowRecount, error)
}

// recountListFollows is `opsctl recount-list-follows`: the stored followerCount, the marker count, and with --write the stored
// value set to the marker count in one transaction (a concurrent follow conflicts and the repair retries).
func recountListFollows(ctx context.Context, b *backends, listID string, write bool, out io.Writer) error {
	if !postIDRe.MatchString(listID) {
		return usageErr("--list must be a 19-digit list id")
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
	fmt.Fprintf(out, "list %s: followerCount=%d markers=%d\n", listID, res.Stored, res.Counted)
	switch {
	case res.Stored == res.Counted:
		fmt.Fprintln(out, "in step: nothing to write")
	case res.Written:
		fmt.Fprintf(out, "set followerCount to %d\n", res.Counted)
	default:
		fmt.Fprintf(out, "dry-run: would set followerCount to %d (re-run with --write)\n", res.Counted)
	}
	return nil
}
