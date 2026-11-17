// repo_view_rollup.go is the storage side of the view rollup (F1 post views): it folds posts/{id}/viewShards into
// posts/{id}.viewCount for the posts that have a view marker, and the engagement counter shards of hot posts into
// posts/{id}.likeCount, repostCount, shareCount, poll.total and poll.counts.<n> for the posts that have a counter marker (repo_views.go), then deletes
// the markers.
//
//	Q-V1 viewDirty where window < W ORDER BY window LIMIT n               -> automatic single-field index
//	Q-V2 viewDirty where counterWindow < W ORDER BY counterWindow LIMIT n -> automatic single-field index
//	viewRollup/state {lastRunAt}                                          -> one transaction per views run (the min-interval gate)
//
// The two folds have different semantics and separate code paths. Views are ABSOLUTE: the fold writes the shard sum
// (never an Increment), so a redelivered or overlapping run writes the same value again. Engagement counters are a DELTA
// (shardcount.StageDeltaFold): the plain post field stays the source of truth (cold writers Increment it directly), and
// one transaction per shard moves what the shards hold onto it and takes exactly that off the shards, so a redelivered or
// overlapping run reads the shards at 0 and moves nothing. A marker is deleted only if it was not rewritten since it was
// read (LastUpdateTime precondition), and only after its own fold for its post is done.
package posts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sort"
	"strconv"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// viewRollupCollection holds the one state doc of the rollup's min-interval gate.
	viewRollupCollection = "viewRollup"
	viewRollupStateID    = "state"
	// ViewRollupPage is the most markers one page reads; a page folds at most this many posts (x10 shard reads, within
	// shardcount.MaxReadDocs).
	ViewRollupPage = 50
)

// ViewMarker is one rollup marker as read: the post it names and the update time the delete is conditioned on. Counter
// is true for an engagement counter marker (counterMarkers), false for a view marker.
type ViewMarker struct {
	ref        *firestore.DocumentRef
	PostID     string
	Window     int64
	Counter    bool
	UpdateTime time.Time
}

// ViewRollupRepo is the storage seam of ViewRollup. *FirestoreRepo implements it; tests use a fake.
type ViewRollupRepo interface {
	// AcquireViewRollup reads viewRollup/state in a transaction and, when lastRunAt is at least minInterval before now
	// (or absent), sets it to now and answers true; otherwise it writes nothing and answers false. One read, at most one
	// write: two overlapping runs (a Scheduler retry and the next tick) never both proceed.
	AcquireViewRollup(ctx context.Context, now time.Time, minInterval time.Duration) (bool, error)
	// DirtyViewMarkers is Q-V1: up to limit markers of windows before window (foldBefore), oldest first.
	DirtyViewMarkers(ctx context.Context, window int64, limit int) ([]ViewMarker, error)
	// FoldViews reads the shards of postIDs (at most ViewRollupPage; one GetAll) and sets each post's viewCount to the
	// sum in one batch. A post that is gone gets its shards deleted instead. It reports how many posts it folded and how
	// many were gone.
	FoldViews(ctx context.Context, postIDs []string) (folded, gone int, err error)
	// DirtyCounterMarkers is Q-V2: up to limit engagement counter markers of windows before window, oldest first.
	DirtyCounterMarkers(ctx context.Context, window int64, limit int) ([]ViewMarker, error)
	// FoldCounters folds the engagement counter shards of postIDs (at most ViewRollupPage) into their posts, one
	// transaction per non-zero shard (the delta fold); a post that is gone gets its shards deleted instead. done lists
	// the posts whose fold finished (folded or gone): only their markers may be deleted. A post with a shard that lost
	// to contention, or that the context deadline did not reach, is left out of done without an error (its markers
	// stay for the next run).
	FoldCounters(ctx context.Context, postIDs []string) (done []string, folded, gone int, err error)
	// DeleteViewMarkers deletes markers, each only if unchanged since it was read; a rewritten one stays for the next run.
	DeleteViewMarkers(ctx context.Context, markers []ViewMarker) error
}

var _ ViewRollupRepo = (*FirestoreRepo)(nil)

type viewRollupState struct {
	LastRunAt time.Time `firestore:"lastRunAt"`
}

// AcquireViewRollup implements ViewRollupRepo.
func (r *FirestoreRepo) AcquireViewRollup(ctx context.Context, now time.Time, minInterval time.Duration) (bool, error) {
	ref := r.client.Collection(viewRollupCollection).Doc(viewRollupStateID)
	acquired := false
	_, err := store.RunTransaction(ctx, r.client, func(_ context.Context, tx *firestore.Transaction) error {
		acquired = false
		snap, err := tx.Get(ref)
		var st viewRollupState
		switch {
		case status.Code(err) == codes.NotFound:
		case err != nil:
			return fmt.Errorf("posts: view rollup state: %w", err)
		default:
			if err := snap.DataTo(&st); err != nil {
				return fmt.Errorf("posts: view rollup state decode: %w", err)
			}
		}
		if !viewRollupDue(st.LastRunAt, now, minInterval) {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Set(ref, viewRollupState{LastRunAt: now.UTC()})
		acquired = true
		return b.Err()
	})
	if err != nil {
		return false, fmt.Errorf("posts: acquire view rollup: %w", err)
	}
	return acquired, nil
}

// viewRollupDue is the gate: no run yet, at least minInterval since the last one, or a last run in the future (a clock
// step back must not stall the rollup).
func viewRollupDue(last, now time.Time, minInterval time.Duration) bool {
	return last.IsZero() || !now.Before(last.Add(minInterval)) || last.After(now.Add(minInterval))
}

// DirtyViewMarkers implements ViewRollupRepo.
func (r *FirestoreRepo) DirtyViewMarkers(ctx context.Context, window int64, limit int) ([]ViewMarker, error) {
	return r.dirtyMarkers(ctx, viewMarkers, window, limit)
}

// DirtyCounterMarkers implements ViewRollupRepo.
func (r *FirestoreRepo) DirtyCounterMarkers(ctx context.Context, window int64, limit int) ([]ViewMarker, error) {
	return r.dirtyMarkers(ctx, counterMarkers, window, limit)
}

// dirtyMarkers is Q-V1 or Q-V2: the k markers of windows before window (the caller passes foldBefore), oldest first.
func (r *FirestoreRepo) dirtyMarkers(ctx context.Context, k markerKind, window int64, limit int) ([]ViewMarker, error) {
	docs, err := r.client.Collection(viewDirtyCollection).Where(k.windowField, "<", window).OrderBy(k.windowField, firestore.Asc).
		Limit(min(max(limit, 1), ViewRollupPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("posts: rollup markers query: %w", err)
	}
	out := make([]ViewMarker, 0, len(docs))
	for _, d := range docs {
		pid, _ := d.DataAt("postId")
		w, _ := d.DataAt(k.windowField)
		id, okID := pid.(string)
		win, okW := w.(int64)
		if !okID || !okW {
			return nil, fmt.Errorf("posts: decode rollup marker %s: want postId and %s", d.Ref.ID, k.windowField)
		}
		out = append(out, ViewMarker{ref: d.Ref, PostID: id, Window: win, Counter: k.counter, UpdateTime: d.UpdateTime})
	}
	return out, nil
}

// viewFold is the fold of the view counter: shard count -> posts/{id}.viewCount.
var viewFold = shardcount.Fold{From: viewShardField, To: firestore.FieldPath{"viewCount"}}

// FoldViews implements ViewRollupRepo.
func (r *FirestoreRepo) FoldViews(ctx context.Context, postIDs []string) (int, int, error) {
	if len(postIDs) == 0 {
		return 0, 0, nil
	}
	refs := make([]*firestore.DocumentRef, len(postIDs))
	for i, id := range postIDs {
		refs[i] = r.ref(id)
	}
	// The creator stats (F2) need each post's author and old viewCount: one more GetAll of the posts, read BEFORE the
	// shards, so a view landing in between is in the new total and the delta stays exact.
	var before []viewBefore
	if r.statsOn() { // no read while the stats are off
		var err error
		if before, err = r.readViewsBefore(ctx, refs); err != nil {
			return 0, 0, err
		}
	}
	totals, err := viewShards.Read(ctx, r.client, refs, viewShardField)
	if err != nil {
		return 0, 0, fmt.Errorf("posts: fold views: %w", err)
	}
	b := store.NewFirestoreBatch(r.client)
	for i, ref := range refs {
		shardcount.StageFold(b, ref, totals[i], viewFold)
	}
	r.stageImpressions(b, before, totals, postIDs, -1)
	err = b.Commit(ctx)
	switch {
	case err == nil:
		return len(refs), 0, nil
	case !store.IsPreconditionFailed(err):
		return 0, 0, fmt.Errorf("posts: fold views: %w", err)
	}
	// A post in the page is gone: fold one by one, and delete the shards of the gone ones.
	folded, gone := 0, 0
	for i, ref := range refs {
		sb := store.NewFirestoreBatch(r.client)
		shardcount.StageFold(sb, ref, totals[i], viewFold)
		r.stageImpressions(sb, before, totals, postIDs, i)
		switch err := sb.Commit(ctx); {
		case err == nil:
			folded++
		case store.IsPreconditionFailed(err):
			db := store.NewFirestoreBatch(r.client)
			viewShards.StageDelete(db, ref)
			if err := db.Commit(ctx); err != nil {
				return folded, gone, fmt.Errorf("posts: delete view shards of a gone post: %w", err)
			}
			gone++
		default:
			return folded, gone, fmt.Errorf("posts: fold views: %w", err)
		}
	}
	return folded, gone, nil
}

// viewBefore is one post as read before its view fold: its author and its rolled-up viewCount.
type viewBefore struct {
	author string
	views  int64
}

// readViewsBefore reads the posts of a view fold (one GetAll, len(refs) reads) for their author and viewCount; a gone
// post has no author (its fold fails anyway and stages nothing), and so has a post that does not decode (a warning with
// its id hashed; its views still fold, only its stat is skipped).
func (r *FirestoreRepo) readViewsBefore(ctx context.Context, refs []*firestore.DocumentRef) ([]viewBefore, error) {
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("posts: fold views: read posts: %w", err)
	}
	if len(snaps) != len(refs) {
		return nil, fmt.Errorf("posts: fold views: got %d posts for %d refs", len(snaps), len(refs))
	}
	out := make([]viewBefore, len(refs))
	for i, s := range snaps {
		if s == nil || !s.Exists() {
			continue
		}
		var d struct {
			AuthorID  string `firestore:"authorId"`
			ViewCount int64  `firestore:"viewCount"`
		}
		if err := s.DataTo(&d); err != nil {
			slog.WarnContext(ctx, "posts_fold_views_stats_decode_failed", "post_hash", logger.HashPost(s.Ref.ID), "error", err.Error())
			continue
		}
		out[i] = viewBefore{author: d.AuthorID, views: d.ViewCount}
	}
	return out, nil
}

// impressionDeltas are the creator impressions of one view fold, summed per author and dailyStats shard (the post id's,
// identity.StatsShard) in first-seen order: each post's new shard total minus the viewCount it had, never below 0 (a
// total only grows; a lowered count must not subtract). only >= 0 keeps that one post (the per-post fallback); -1 keeps
// all. Each group carries the first post id of the group as its shard key. Pure.
//
// The delta reads viewCount outside the fold's write: it is exact because views runs never overlap (the
// AcquireViewRollup gate admits one per MinInterval, and nothing else writes viewCount), so no other fold can move it
// between this read and the commit. A redelivered fold reads the folded value and adds 0.
func impressionDeltas(before []viewBefore, totals []shardcount.Totals, postIDs []string, only int) []impressionGroup {
	var out []impressionGroup
	at := map[string]int{}
	for i, b := range before {
		if (only >= 0 && i != only) || b.author == "" || i >= len(totals) || i >= len(postIDs) {
			continue
		}
		d := totals[i].Get(viewShardField) - b.views
		if d <= 0 {
			continue
		}
		k := b.author + "\x00" + strconv.Itoa(identity.StatsShard(postIDs[i]))
		j, ok := at[k]
		if !ok {
			j = len(out)
			at[k] = j
			out = append(out, impressionGroup{author: b.author, shardKey: postIDs[i]})
		}
		out[j].n += d
	}
	return out
}

// impressionGroup is one impressions stage: an author's views on one dailyStats shard.
type impressionGroup struct {
	author, shardKey string
	n                int64
}

// stageImpressions stages one impressions Increment per author and shard of the fold (so a batch never writes one doc
// twice), on today's day. It rides the batch of the viewCount Updates, whose Exists keeps a gone post's author out.
func (r *FirestoreRepo) stageImpressions(b store.Batch, before []viewBefore, totals []shardcount.Totals, postIDs []string, only int) {
	for _, g := range impressionDeltas(before, totals, postIDs, only) {
		r.stageStats(b, g.author, g.shardKey, identity.DailyDelta{Impressions: g.n})
	}
}

// DeleteViewMarkers implements ViewRollupRepo.
func (r *FirestoreRepo) DeleteViewMarkers(ctx context.Context, markers []ViewMarker) error {
	if len(markers) == 0 {
		return nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, m := range markers {
		b.Delete(r.markerRefOf(m), firestore.LastUpdateTime(m.UpdateTime))
	}
	err := b.Commit(ctx)
	if err == nil {
		return nil
	}
	if !store.IsPreconditionFailed(err) {
		return fmt.Errorf("posts: delete view markers: %w", err)
	}
	for _, m := range markers {
		sb := store.NewFirestoreBatch(r.client)
		sb.Delete(r.markerRefOf(m), firestore.LastUpdateTime(m.UpdateTime))
		if err := sb.Commit(ctx); err != nil && !store.IsPreconditionFailed(err) {
			return fmt.Errorf("posts: delete view marker: %w", err)
		}
	}
	return nil
}

func (r *FirestoreRepo) markerRefOf(m ViewMarker) *firestore.DocumentRef {
	if m.ref != nil {
		return m.ref
	}
	if m.Counter {
		return r.markerRef(counterMarkers, m.Window, m.PostID)
	}
	return r.viewMarkerRef(m.Window, m.PostID)
}

// Engagement counter fields of a hot post: the shard field and the post field share a name (repo_engagement.go writes
// them on the viewShards docs, next to the views field "count").
var (
	likeCountField   = firestore.FieldPath{"likeCount"}
	repostCountField = firestore.FieldPath{"repostCount"}
	shareCountField  = firestore.FieldPath{"shareCount"}
	replyCountField  = firestore.FieldPath{fieldReplyCount}
	quoteCountField  = firestore.FieldPath{fieldQuoteCount}
	// pollTotalField is poll.total; pollCountField(n) is poll.counts.<n>. FieldPath values, never dotted strings: the
	// counts keys are numeric strings.
	pollTotalField = firestore.FieldPath{"poll", "total"}
	// counterFolds are the fixed delta folds of the counter rollup: shard field -> the same post field. The per-choice
	// poll counts are added per shard from the keys the shard actually holds (counterFoldsOf).
	counterFolds = []shardcount.Fold{
		{From: likeCountField, To: likeCountField},
		{From: repostCountField, To: repostCountField},
		{From: shareCountField, To: shareCountField},
		{From: replyCountField, To: replyCountField},
		{From: quoteCountField, To: quoteCountField},
		{From: pollTotalField, To: pollTotalField},
	}
)

// pollCountField is poll.counts.<choice>.
func pollCountField(choice int) firestore.FieldPath {
	return firestore.FieldPath{"poll", "counts", strconv.Itoa(choice)}
}

// counterFoldsOf are the delta folds of one shard's data: counterFolds plus one fold per key of the shard's poll.counts
// map, whatever the key (a hard-coded list of choices could miss one and strand its delta), in key order so the staged
// writes are deterministic. Poll choices are bounded (MaxPollChoices), so the set stays small.
func counterFoldsOf(data map[string]any) []shardcount.Fold {
	poll, _ := data["poll"].(map[string]any)
	counts, _ := poll["counts"].(map[string]any)
	if len(counts) == 0 {
		return counterFolds
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]shardcount.Fold, 0, len(counterFolds)+len(keys))
	out = append(out, counterFolds...)
	for _, k := range keys {
		fp := firestore.FieldPath{"poll", "counts", k}
		out = append(out, shardcount.Fold{From: fp, To: fp})
	}
	return out
}

// FoldCounters implements ViewRollupRepo (likeCount, repostCount, shareCount, replyCount, quoteCount, poll.total and every poll.counts.<n>). Per post: one plain GetAll of the post and its shards (1 + ViewShardCount
// reads), then one small transaction per shard that holds an engagement value (1 read, 2 writes: the shard and the
// post), so a page never nears the 500-write limit of one commit and contention costs only that shard.
//
// Why per shard: the database runs with OPTIMISTIC concurrency (infra/terraform/modules/firestore), where a transaction
// takes no locks and fails at commit when any document it read was written in between. The shards of a hot post take
// every hot write (and its views), so one transaction that read all of them would lose on most attempts and might
// never fold the busiest posts. A transaction that reads ONE shard conflicts only with writes to that shard, and it
// does not read the post at all (the post Update's implicit Exists answers "gone"), so in-flight hot writers, which
// only read the post, are retried only when a fold actually writes it.
func (r *FirestoreRepo) FoldCounters(ctx context.Context, postIDs []string) ([]string, int, int, error) {
	done := make([]string, 0, len(postIDs))
	folded, gone := 0, 0
	for _, id := range postIDs {
		if ctx.Err() != nil {
			break // the step budget is spent: the rest keep their markers
		}
		wasGone, complete, err := r.foldCountersOf(ctx, id)
		switch {
		case err != nil && ctx.Err() != nil:
			return done, folded, gone, nil
		case err != nil:
			return done, folded, gone, fmt.Errorf("posts: fold counters: %w", err)
		case !complete:
			continue // a shard lost to contention or the deadline: the marker stays for the next tick
		}
		done = append(done, id)
		if wasGone {
			gone++
		} else {
			folded++
		}
	}
	return done, folded, gone, nil
}

// foldCountersOf is the delta fold of one post: the shards that hold an engagement value are folded one transaction
// each (foldCounterShard), and a post that is gone gets its shards deleted instead (as FoldViews does). complete is
// false when a shard was left (contention or the deadline). The views field on the same shard docs is never touched.
func (r *FirestoreRepo) foldCountersOf(ctx context.Context, postID string) (gone, complete bool, err error) {
	post := r.ref(postID)
	refs := append([]*firestore.DocumentRef{post}, viewShards.Refs(post)...)
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return false, false, fmt.Errorf("posts: read counter shards: %w", err)
	}
	if len(snaps) != len(refs) {
		return false, false, fmt.Errorf("posts: read counter shards: got %d documents for %d refs", len(snaps), len(refs))
	}
	if !snaps[0].Exists() {
		return true, true, r.deleteShardsOfGone(ctx, post)
	}
	author := ""
	if v, err := snaps[0].DataAt("authorId"); err == nil {
		author, _ = v.(string)
	}
	complete = true
	for _, s := range shardcount.ShardsOf(snaps[1:]) {
		if !holdsCounters(s.Data) {
			continue
		}
		if ctx.Err() != nil {
			return false, false, nil
		}
		goneNow, contended, err := afterShardFold(r.foldCounterShard(ctx, post, s.Ref, author), func() (bool, error) {
			return r.postExists(ctx, post)
		})
		switch {
		case err != nil:
			return false, false, err
		case goneNow:
			return true, true, r.deleteShardsOfGone(ctx, post)
		case contended:
			complete = false
		}
	}
	return false, complete, nil
}

// afterShardFold reads the outcome of one shard's fold transaction. A failed precondition is ambiguous (Firestore answers
// NotFound or FailedPrecondition, and not only for a missing post), and the answer to "gone" is a blind delete of every
// shard of the post, views and pending deltas included: so the post is re-read (exists) and only a confirmed missing
// post is gone; a post that is still there, or a re-read that fails, is an error and the markers stay. Contention is
// reported as such (the shard is left for the next tick).
func afterShardFold(err error, exists func() (bool, error)) (gone, contended bool, out error) {
	switch {
	case err == nil:
		return false, false, nil
	case store.IsContention(err):
		return false, true, nil
	case !store.IsPreconditionFailed(err):
		return false, false, err
	}
	ok, rerr := exists()
	switch {
	case rerr != nil:
		return false, false, errors.Join(err, fmt.Errorf("posts: re-read post after a failed fold: %w", rerr))
	case ok:
		return false, false, fmt.Errorf("posts: fold failed a precondition on a post that exists: %w", err)
	}
	return true, false, nil
}

// postExists is one read of the post: false only on NotFound.
func (r *FirestoreRepo) postExists(ctx context.Context, post *firestore.DocumentRef) (bool, error) {
	_, err := post.Get(ctx)
	switch {
	case status.Code(err) == codes.NotFound:
		return false, nil
	case err != nil:
		return false, fmt.Errorf("posts: read post: %w", err)
	}
	return true, nil
}

// foldCounterShard moves one shard's engagement values onto the post in one transaction: read the shard, then
// shardcount.StageDeltaFold over that shard alone (Increment(-v) on the shard, Increment(+v) on the post, the post's
// Update carrying Exists). A shard read at 0 (a redelivery, or a fold that ran in between) stages nothing.
//
// The creator stats (F2): the folded like, repost, reply and quote deltas of THIS shard, as read in this transaction,
// go to the post author's engagements for the fold day in the same transaction (one write per shard fold that moves
// any of them; shares and poll votes do not count). They are exactly what the cold path would have staged, so a hot
// post is never counted twice: its writers staged nothing. The author's own hot replies and quotes are marked on the
// shard (selfReplyCount, selfQuoteCount): drained here with the rest, never moved onto the post, and subtracted from the
// stat. The author's own hot likes and reposts are not marked (the engagement seam does not say who the author is), so
// they are counted: a known gap, as small as a creator liking their own post while it is hot. The stat's shard key is
// the post id (a fold has no actor).
func (r *FirestoreRepo) foldCounterShard(ctx context.Context, post, shard *firestore.DocumentRef, author string) error {
	_, err := store.RunTransaction(ctx, r.client, func(_ context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(shard)
		if status.Code(err) == codes.NotFound {
			return nil // deleted in between (the post went with it): nothing to move
		}
		if err != nil {
			return fmt.Errorf("posts: read counter shard: %w", err)
		}
		data := snap.Data()
		b := store.NewFirestoreTxBatch(tx)
		// The folds come from the shard as read in THIS transaction, so a poll.counts key written since the page read is folded too.
		folds := slices.Concat(counterFoldsOf(data), selfFolds)
		shardcount.StageDeltaFold(dropOnParent{Batch: b, parent: post.Path}, post, []shardcount.Shard{{Ref: shard, Data: data}}, folds...)
		if n := engagementOfShard(data); n != 0 {
			r.stageStats(b, author, post.ID, identity.DailyDelta{Engagements: n})
		}
		return b.Err()
	})
	return err
}

// engagementFields are the counters that count as creator engagements (F2): shares and poll votes do not.
var engagementFields = []firestore.FieldPath{likeCountField, repostCountField, replyCountField, quoteCountField}

// Self fields: a hot reply or quote by the parent's own author adds 1 here too (stageChildCounter). They are drained by
// the fold like any shard field (selfFolds) but never written onto the post (dropOnParent), and engagementOfShard
// subtracts them.
var (
	selfReplyCountField = firestore.FieldPath{"selfReplyCount"}
	selfQuoteCountField = firestore.FieldPath{"selfQuoteCount"}
	selfFolds           = []shardcount.Fold{
		{From: selfReplyCountField, To: selfReplyCountField},
		{From: selfQuoteCountField, To: selfQuoteCountField},
	}
)

// selfFieldOf is the self field of replyCount or quoteCount.
func selfFieldOf(field firestore.FieldPath) firestore.FieldPath {
	if shardcount.Key(field) == shardcount.Key(quoteCountField) {
		return selfQuoteCountField
	}
	return selfReplyCountField
}

// dropOnParent is a store.Batch that drops the self fields from Updates of the parent post (an Update left empty is not
// staged): StageDeltaFold drains them off the shard, and they must not appear on the post.
type dropOnParent struct {
	store.Batch
	parent string
}

func (d dropOnParent) Update(ref *firestore.DocumentRef, ups []firestore.Update, pre ...firestore.Precondition) store.Batch {
	if ref.Path != d.parent {
		return d.Batch.Update(ref, ups, pre...)
	}
	kept := make([]firestore.Update, 0, len(ups))
	for _, u := range ups {
		if k := shardcount.Key(u.FieldPath); k != shardcount.Key(selfReplyCountField) && k != shardcount.Key(selfQuoteCountField) {
			kept = append(kept, u)
		}
	}
	if len(kept) == 0 {
		return d
	}
	return d.Batch.Update(ref, kept, pre...)
}

// engagementOfShard is the sum of one shard's engagement deltas (may be negative after undos), minus the author's own
// hot replies and quotes (the self fields). Pure.
func engagementOfShard(data map[string]any) int64 {
	t := shardcount.Sum([]map[string]any{data}, slices.Concat(engagementFields, []firestore.FieldPath{selfReplyCountField, selfQuoteCountField})...)
	var n int64
	for _, fp := range engagementFields {
		n += t.Get(fp)
	}
	return n - t.Get(selfReplyCountField) - t.Get(selfQuoteCountField)
}

// holdsCounters reports whether a shard holds a non-zero engagement value, poll counts included (a shard that holds only
// poll deltas must be folded, or its marker would be deleted with the deltas still on it).
func holdsCounters(data map[string]any) bool {
	folds := counterFoldsOf(data)
	from := make([]firestore.FieldPath, len(folds))
	for i, f := range folds {
		from[i] = f.From
	}
	t := shardcount.Sum([]map[string]any{data}, from...)
	for _, fp := range from {
		if t.Get(fp) != 0 {
			return true
		}
	}
	return false
}

// deleteShardsOfGone deletes the shards of a post that is gone (blind, one batch of ViewShardCount deletes).
func (r *FirestoreRepo) deleteShardsOfGone(ctx context.Context, post *firestore.DocumentRef) error {
	b := store.NewFirestoreBatch(r.client)
	viewShards.StageDelete(b, post)
	if err := b.Commit(ctx); err != nil {
		return fmt.Errorf("posts: delete counter shards of a gone post: %w", err)
	}
	return nil
}
