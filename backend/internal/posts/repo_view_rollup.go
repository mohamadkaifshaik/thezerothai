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
	"sort"
	"strconv"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

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
	totals, err := viewShards.Read(ctx, r.client, refs, viewShardField)
	if err != nil {
		return 0, 0, fmt.Errorf("posts: fold views: %w", err)
	}
	b := store.NewFirestoreBatch(r.client)
	for i, ref := range refs {
		shardcount.StageFold(b, ref, totals[i], viewFold)
	}
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
	// pollTotalField is poll.total; pollCountField(n) is poll.counts.<n>. FieldPath values, never dotted strings: the
	// counts keys are numeric strings.
	pollTotalField = firestore.FieldPath{"poll", "total"}
	// counterFolds are the fixed delta folds of the counter rollup: shard field -> the same post field. The per-choice
	// poll counts are added per shard from the keys the shard actually holds (counterFoldsOf).
	counterFolds = []shardcount.Fold{
		{From: likeCountField, To: likeCountField},
		{From: repostCountField, To: repostCountField},
		{From: shareCountField, To: shareCountField},
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

// FoldCounters implements ViewRollupRepo (likeCount, repostCount, shareCount, poll.total and every poll.counts.<n>). Per post: one plain GetAll of the post and its shards (1 + ViewShardCount
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
	complete = true
	for _, s := range shardcount.ShardsOf(snaps[1:]) {
		if !holdsCounters(s.Data) {
			continue
		}
		if ctx.Err() != nil {
			return false, false, nil
		}
		goneNow, contended, err := afterShardFold(r.foldCounterShard(ctx, post, s.Ref), func() (bool, error) {
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
func (r *FirestoreRepo) foldCounterShard(ctx context.Context, post, shard *firestore.DocumentRef) error {
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
		shardcount.StageDeltaFold(b, post, []shardcount.Shard{{Ref: shard, Data: data}}, counterFoldsOf(data)...)
		return b.Err()
	})
	return err
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
