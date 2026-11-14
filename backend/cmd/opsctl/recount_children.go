package main

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// recountChildrenUsage documents `opsctl recount-replies` and `opsctl recount-quotes`.
const recountChildrenUsage = `  opsctl recount-replies --project P --post POST_ID [--write]
  opsctl recount-quotes  --project P --post POST_ID [--write]
                          (repairs posts/{id}.replyCount / quoteCount from count() of the posts with replyToId / quoteOfId
                          == id; dry run unless --write. Every existing reply or quote doc counts whatever its moderation
                          state, as the live counters do (moderation keeps counters so a restore is exact). Use it after an
                          erasure before the counter fix, or a reply/quote release failure; it prints counts only. A count at its
                          100,000 cap is never written)
`

// recountCommand maps the two command names to the counter they repair and the label they print.
var recountCommand = map[string]struct {
	which posts.ChildCount
	label string
}{
	"recount-replies": {posts.ChildReplies, "reply_count"},
	"recount-quotes":  {posts.ChildQuotes, "quote_count"},
}

// recountChildren is `opsctl recount-replies|recount-quotes`: the stored counter, the count of referencing posts, and with
// --write the stored value set to the count in one transaction. One post read and one bounded aggregation; at most one write.
func recountChildren(ctx context.Context, b *backends, cmd, postID string, write bool, out io.Writer) error {
	rc, ok := recountCommand[cmd]
	if !ok {
		return fmt.Errorf("unknown recount command %q", cmd)
	}
	if !postIDRe.MatchString(postID) {
		return usageErr("--post must be a 19-digit post id")
	}
	if b.childCounts == nil {
		return fmt.Errorf("%s is not wired", cmd)
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	res, err := b.childCounts.RecountChildren(cctx, postID, rc.which, write)
	if errors.Is(err, posts.ErrNotFound) {
		return fmt.Errorf("post %s not found", postID)
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "post %s: %s=%d counted=%d\n", postID, rc.label, res.Stored, res.Counted)
	switch {
	case res.Capped:
		fmt.Fprintln(out, "the count reached its cap; the true count may be higher: nothing written")
	case res.Stored == res.Counted:
		fmt.Fprintln(out, "in step: nothing to write")
	case res.Written:
		fmt.Fprintf(out, "set %s to %d\n", rc.label, res.Counted)
	default:
		fmt.Fprintf(out, "dry-run: would set %s to %d (re-run with --write)\n", rc.label, res.Counted)
	}
	return nil
}
