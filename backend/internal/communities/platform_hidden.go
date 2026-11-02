// platform_hidden.go is the platform recovery of hidden posts and replies (ADR-0031 Amendment 1 D14a, plan W5-52b): the listing behind
// `opsctl community hidden` and the page restore behind `opsctl community restore-hidden`. Like platform.go it runs in the operator's
// process, so it touches no instance cache: a restored root returns to feeds within the shared entry's 5-minute bound, a restored reply
// to thread pages at once. Every write is a field-level Update (never a Set). It works in any community status and any flag state.
package communities

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// HiddenPosts is the posts-side seam of the platform recovery, the identical methods of posts.CommunityModerator (communities never imports
// posts, N9): the listing query and the in-transaction page restore. SetCommunityListing cannot be called once per post inside one
// transaction (it reads then writes, and a transaction refuses a read after a write), so the page is read once and written after.
type HiddenPosts interface {
	ListHidden(ctx context.Context, cid, after string, limit int, each func(id string, reply bool, hiddenAt time.Time, moderated bool) bool) (rows int, last string, err error)
	RestoreHiddenPage(ctx context.Context, tx *firestore.Transaction, cid, after string, limit int, want func(id string, reply bool, hiddenAt time.Time, moderated bool) bool) (res HiddenPage, err error)
}

// HiddenPage mirrors posts.HiddenPageResult (an alias of the same unnamed struct).
type HiddenPage = struct {
	Rows          int
	Last          string
	Restored      int
	RestoredRoots []string
}

// WithHiddenPosts wires the posts-side listing and restore (opsctl). Without it the platform recovery fails closed.
func (r *FirestoreRepo) WithHiddenPosts(h HiddenPosts) *FirestoreRepo {
	r.hidden = h
	return r
}

// HiddenRow is one hidden post or reply as the operator sees it: ids and times only, never text or a uid.
type HiddenRow struct {
	PostID string
	Reply  bool
	// HiddenAt is the server time of the hide; the zero time means "unknown" (hidden before communityHiddenAt existed, no backfill).
	HiddenAt time.Time
	// Moderated is true when `moderation` is set on the post (a platform takedown or suspended author): restore-hidden leaves it hidden.
	Moderated bool
}

// RestoreHiddenParams is one page of RestoreHidden.
type RestoreHiddenParams struct {
	CID string
	// After is the id of the last row of the previous page ("" for the first); Limit is the page size (<= 50).
	After string
	Limit int
	// Since restricts the restore to posts hidden at or after it (zero = every hidden post). A row without a hide time is skipped.
	Since time.Time
	// WriteEntry asks for the run's single RESTORE modlog entry (actor PlatformMarker) in this page's transaction when the page restores at
	// least one post. The caller sets it until a page reported EntryWritten.
	WriteEntry bool
	// DryRun makes the same reads (the community, then the page outside a transaction) and writes nothing: Restored counts what would be restored.
	DryRun bool
	// Now stamps the entry; ModlogMax and RemovalsMax <= 0 read as the defaults.
	Now                    time.Time
	ModlogMax, RemovalsMax int
}

// RestoreHiddenResult is what one page read and did.
type RestoreHiddenResult struct {
	Listed          int    // rows read
	Restored        int    // posts restored (written)
	SkippedPlatform int    // `moderation` set: stays hidden (D5a, L-2)
	SkippedNoTime   int    // no communityHiddenAt, with Since set
	Last            string // the last row's id, the next page's After
	EntryWritten    bool   // this page wrote the run's modlog entry
}

// ListHidden is one page of the community's hidden posts and replies after `after` (read-only). Reads: 1 (the community, so a wrong id is
// ErrNotFound; the SUSPENDED rule is not applied) + max(1, rows). next is the last row's id when the page is full, else "".
func (r *FirestoreRepo) ListHidden(ctx context.Context, cid, after string, limit int) (rows []HiddenRow, next string, err error) {
	if err := r.needClient(); err != nil {
		return nil, "", err
	}
	if r.hidden == nil {
		return nil, "", errors.New("communities: repo has no hidden-posts reader")
	}
	if _, err := r.Get(ctx, cid); err != nil {
		return nil, "", err
	}
	n, last, err := r.hidden.ListHidden(ctx, cid, after, limit, func(id string, reply bool, at time.Time, moderated bool) bool {
		rows = append(rows, HiddenRow{PostID: id, Reply: reply, HiddenAt: at, Moderated: moderated})
		return false
	})
	if err != nil {
		return nil, "", err
	}
	if n >= limit {
		next = last
	}
	return rows, next, nil
}

// RestoreHidden restores one page of hidden posts in ONE transaction with the community document: the community fresh (any status), the
// page fresh through the posts seam, a field-level Update per restored post, and one community Update that deletes the restored roots'
// recentRemovals entries (a reply has none, R1; a skipped platform removal keeps its entry) and, when WriteEntry is set and the page restored
// something, appends the run's single RESTORE entry with actor PlatformMarker (no postId, no target, no modlogged: it is not a uid).
// Reads 1 + max(1, rows) (<= 51); writes <= rows + 1. ErrNotFound for a missing community.
func (r *FirestoreRepo) RestoreHidden(ctx context.Context, p RestoreHiddenParams) (RestoreHiddenResult, error) {
	if err := r.needClient(); err != nil {
		return RestoreHiddenResult{}, err
	}
	if r.hidden == nil {
		return RestoreHiddenResult{}, errors.New("communities: repo has no hidden-posts restorer")
	}
	if p.DryRun {
		return r.dryRunHidden(ctx, p)
	}
	var res RestoreHiddenResult
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = RestoreHiddenResult{}
		c, err := r.getInTx(ctx, tx, p.CID) // not openForModeration: a SUSPENDED community is recovered too
		if err != nil {
			return err
		}
		var platform, noTime int
		pg, err := r.hidden.RestoreHiddenPage(ctx, tx, p.CID, p.After, p.Limit, func(_ string, _ bool, at time.Time, moderated bool) bool {
			restore, v := hiddenVerdict(p.Since, at, moderated)
			platform += v.platform
			noTime += v.noTime
			return restore
		})
		if err != nil {
			return err
		}
		res = RestoreHiddenResult{Listed: pg.Rows, Restored: pg.Restored, SkippedPlatform: platform, SkippedNoTime: noTime, Last: pg.Last}
		if pg.Restored == 0 {
			return nil
		}
		now := p.Now.UTC()
		next := c
		var ups []firestore.Update
		if len(pg.RestoredRoots) > 0 {
			for _, id := range pg.RestoredRoots {
				next.RecentRemovals, next.RemovalsTruncatedAt = removalsAfter(next, id, true, now, p.RemovalsMax)
			}
			if len(next.RecentRemovals) != len(c.RecentRemovals) {
				ups = append(ups, firestore.Update{Path: "recentRemovals", Value: removalDocs(next.RecentRemovals)})
			}
		}
		if p.WriteEntry {
			log, seq := appendLog(c, LogEntry{At: now, Actor: PlatformMarker, Action: ActionRestore}, p.ModlogMax)
			ups = append(ups, logUpdates(&next, now, log, seq)...)
			res.EntryWritten = true
		}
		if len(ups) == 0 {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(r.ref(p.CID), ups)
		return b.Err()
	})
	if err != nil {
		return RestoreHiddenResult{}, fmt.Errorf("communities: restore hidden: %w", err)
	}
	return res, nil
}

// HiddenRecovery is the operator surface behind `opsctl community hidden|restore-hidden` (D14a). *FirestoreRepo implements it.
type HiddenRecovery interface {
	ListHidden(ctx context.Context, cid, after string, limit int) (rows []HiddenRow, next string, err error)
	RestoreHidden(ctx context.Context, p RestoreHiddenParams) (RestoreHiddenResult, error)
}

var _ HiddenRecovery = (*FirestoreRepo)(nil)

// hiddenCounts are the skip counters one verdict adds.
type hiddenCounts struct{ platform, noTime int }

// hiddenVerdict is the one rule of restore-hidden for a row read at `at` (zero = unknown), shared by the real run and --dry-run: a post with
// `moderation` stays hidden (D5a), with Since set a row without a hide time is skipped (skipped_no_time) and one hidden before Since stays.
func hiddenVerdict(since, at time.Time, moderated bool) (restore bool, c hiddenCounts) {
	switch {
	case moderated:
		c.platform = 1
	case !since.IsZero() && at.IsZero():
		c.noTime = 1
	case !since.IsZero() && at.Before(since):
	default:
		restore = true
	}
	return restore, c
}

// dryRunHidden is RestoreHidden with DryRun: the community read, then the page outside any transaction, and no write.
func (r *FirestoreRepo) dryRunHidden(ctx context.Context, p RestoreHiddenParams) (RestoreHiddenResult, error) {
	if _, err := r.Get(ctx, p.CID); err != nil {
		return RestoreHiddenResult{}, err
	}
	var res RestoreHiddenResult
	n, last, err := r.hidden.ListHidden(ctx, p.CID, p.After, p.Limit, func(_ string, _ bool, at time.Time, moderated bool) bool {
		restore, v := hiddenVerdict(p.Since, at, moderated)
		res.SkippedPlatform += v.platform
		res.SkippedNoTime += v.noTime
		if restore {
			res.Restored++
		}
		return false
	})
	if err != nil {
		return RestoreHiddenResult{}, err
	}
	res.Listed, res.Last = n, last
	return res, nil
}
