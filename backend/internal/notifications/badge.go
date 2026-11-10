package notifications

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// unreadVisible is the badge count: the unseen rows whose displayed actor the caller may see, by the same rule as
// List (visible): hidden when the displayed actor is blocked or muted by the caller or blocks the caller, including
// the F-04 overflow lookup. Folded actors only change a row's actor count, never whether it shows, so they are not read.
//
// Reads, per call (GetMe caches the answer 30 s per uid):
//   - the caller's graph snapshot (graph's 60 s cache; one graph/{uid} read on a miss), shared with every other read path;
//   - a caller whose snapshot hides nobody (no blocked, muted or blockedBy entry, no overflow): one count() aggregation,
//     Limit UnreadBadgeCap, billed as one read, the same query identity ran before;
//   - otherwise: one query for the newest UnreadBadgeCap unseen rows projected to actor.userId, billed one read per
//     row returned (at most UnreadBadgeCap; one when none), filtered in memory against the snapshot;
//   - and only when blockedBy overflowed: one graph.BlockLookup call for the distinct displayed actors not already
//     hidden (at most UnreadBadgeCap = graph.MaxBlockLookup, so every one is covered), answered from the graph cache
//     or batched GetAlls of up to 25 docs.
//
// It never reads in a loop and never falls back to the raw count: any failed read is an error (identity turns it into
// a WARN and a badge of 0, so GetMe still answers). A row that does not decode is skipped, not counted (see
// FirestoreRepo.UnreadActors). The filtered path reads
// only the newest UnreadBadgeCap unseen rows, so with more unseen rows than that and some of them hidden the badge can
// read below the cap: it may under-count past the cap, never over-count a hidden row.
func (b *UnreadBadge) unreadVisible(ctx context.Context, uid string, since time.Time) (int64, error) {
	snap, err := b.social.Snapshot(ctx, uid)
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("notifications: unread badge: caller graph: %w", err), uid)
	}
	if !snapHidesAnyone(snap) {
		n, err := b.store.CountUnread(ctx, uid, since, UnreadBadgeCap)
		if err != nil {
			return 0, logger.RedactErr(fmt.Errorf("notifications: unread badge: %w", err), uid)
		}
		return n, nil
	}
	actors, err := b.store.UnreadActors(ctx, uid, since, UnreadBadgeCap)
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("notifications: unread badge: %w", err), uid)
	}
	var ov *overflowBlocks
	if snap.BlockedByOverflow && len(actors) > 0 {
		rows := make([]Notification, len(actors))
		for i, id := range actors {
			rows[i] = Notification{Actor: Actor{UserID: id}}
		}
		if ov, err = lookupOverflowBlockers(ctx, b.blocks, uid, rows, snap); err != nil {
			return 0, err
		}
	}
	hidden := hiddenRule(snap, ov)
	var n int64
	for _, id := range actors {
		if !hidden(id) {
			n++
		}
	}
	return min(n, UnreadBadgeCap), nil
}

// snapHidesAnyone reports whether the snapshot can hide any row: otherwise every unseen row is visible and the badge
// is the plain count.
func snapHidesAnyone(snap graph.Snapshot) bool {
	return snap.BlockedByOverflow || len(snap.Blocked) > 0 || len(snap.Muted) > 0 || len(snap.BlockedBy) > 0
}
