// repo_view_rollup.go is the storage side of the view rollup (F1 post views): it folds posts/{id}/viewShards into
// posts/{id}.viewCount for the posts that have a rollup marker (repo_views.go), then deletes the markers.
//
//	Q-V1 viewDirty where window < W ORDER BY window LIMIT n -> automatic single-field index
//	viewRollup/state {lastRunAt}                           -> one transaction per run (the min-interval gate)
//
// Every step is idempotent: the fold writes the ABSOLUTE shard sum (never an Increment), a marker is deleted only if it
// was not rewritten since it was read (LastUpdateTime precondition), and a redelivered or overlapping run folds the same
// sums again.
package posts

import (
	"context"
	"fmt"
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

// ViewMarker is one rollup marker as read: the post it names and the update time the delete is conditioned on.
type ViewMarker struct {
	ref        *firestore.DocumentRef
	PostID     string
	Window     int64
	UpdateTime time.Time
}

// ViewRollupRepo is the storage seam of ViewRollup. *FirestoreRepo implements it; tests use a fake.
type ViewRollupRepo interface {
	// AcquireViewRollup reads viewRollup/state in a transaction and, when lastRunAt is at least minInterval before now
	// (or absent), sets it to now and answers true; otherwise it writes nothing and answers false. One read, at most one
	// write: two overlapping runs (a Scheduler retry and the next tick) never both proceed.
	AcquireViewRollup(ctx context.Context, now time.Time, minInterval time.Duration) (bool, error)
	// DirtyViewMarkers is Q-V1: up to limit markers of windows before window (closed windows only), oldest first.
	DirtyViewMarkers(ctx context.Context, window int64, limit int) ([]ViewMarker, error)
	// FoldViews reads the shards of postIDs (at most ViewRollupPage; one GetAll) and sets each post's viewCount to the
	// sum in one batch. A post that is gone gets its shards deleted instead. It reports how many posts it folded and how
	// many were gone.
	FoldViews(ctx context.Context, postIDs []string) (folded, gone int, err error)
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
	docs, err := r.client.Collection(viewDirtyCollection).Where("window", "<", window).OrderBy("window", firestore.Asc).
		Limit(min(max(limit, 1), ViewRollupPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("posts: view markers query: %w", err)
	}
	out := make([]ViewMarker, 0, len(docs))
	for _, d := range docs {
		var m viewMarkerDoc
		if err := d.DataTo(&m); err != nil {
			return nil, fmt.Errorf("posts: decode view marker %s: %w", d.Ref.ID, err)
		}
		out = append(out, ViewMarker{ref: d.Ref, PostID: m.PostID, Window: m.Window, UpdateTime: d.UpdateTime})
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
		b.Delete(r.markerRef(m), firestore.LastUpdateTime(m.UpdateTime))
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
		sb.Delete(r.markerRef(m), firestore.LastUpdateTime(m.UpdateTime))
		if err := sb.Commit(ctx); err != nil && !store.IsPreconditionFailed(err) {
			return fmt.Errorf("posts: delete view marker: %w", err)
		}
	}
	return nil
}

func (r *FirestoreRepo) markerRef(m ViewMarker) *firestore.DocumentRef {
	if m.ref != nil {
		return m.ref
	}
	return r.viewMarkerRef(m.Window, m.PostID)
}
