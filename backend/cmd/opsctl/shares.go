package main

import (
	"context"
	"fmt"
	"io"
)

// recountSharesUsage documents `opsctl recount-shares` (shares design 2026-11-13 §4.8).
const recountSharesUsage = `  opsctl recount-shares --project P --post POST_ID [--write]
                          (repairs posts/{id}.shareCount from count() of its postShares markers; dry run unless --write.
                          Use it after a share_record_failed WARN or an erasure fallback; it prints counts only)
`

// shareMarkerCounter is engagement's count() of a post's postShares markers (*engagement.FirestoreRepo).
type shareMarkerCounter interface {
	CountShares(ctx context.Context, postID string) (int64, error)
}

// recountShares is `opsctl recount-shares`: the stored shareCount, the marker count, and with write the stored value set
// to the marker count (one write, with the post's Exists precondition). A share committed between the count and the
// write is off by one; re-running converges. Two reads (the post and one aggregation); at most one write.
func recountShares(ctx context.Context, b *backends, postID string, write bool, out io.Writer) error {
	if !postIDRe.MatchString(postID) {
		return usageErr("--post must be a 19-digit post id")
	}
	if b.shareMarkers == nil || b.shareCounts == nil {
		return fmt.Errorf("recount-shares is not wired")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	stored, found, err := b.shareCounts.StoredShareCount(cctx, postID)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("post %s not found", postID)
	}
	markers, err := b.shareMarkers.CountShares(cctx, postID)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "post %s: share_count=%d markers=%d\n", postID, stored, markers)
	switch {
	case stored == markers:
		fmt.Fprintln(out, "in step: nothing to write")
		return nil
	case !write:
		fmt.Fprintf(out, "dry-run: would set share_count to %d (re-run with --write)\n", markers)
		return nil
	}
	if err := b.shareCounts.SetShareCount(cctx, postID, markers); err != nil {
		return err
	}
	fmt.Fprintf(out, "set share_count to %d\n", markers)
	return nil
}
