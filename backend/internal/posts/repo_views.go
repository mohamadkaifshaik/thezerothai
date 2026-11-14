// repo_views.go holds the storage of F1 post view counts that posts owns (FEATURE_POST_VIEWS):
//
//	posts/{id}/viewShards/{0..9}  {count}          the sharded counter (pkg/platform/shardcount), one random shard per view
//	viewDirty/{window}_{postId}   {postId, window} the rollup marker: "this post had views in this 5-minute window"
//	posts/{id}.viewCount                           the rolled-up total every read path shows (rollup: repo_view_rollup.go)
//
// Engagement records an impression through ViewWriter (the EngagementWriter pattern: posts stages, engagement commits),
// so no other module names these paths. A view is one shard write. The marker is written at most once per post, window and
// instance: an in-process memo remembers the markers this instance committed in the current window. Losing the memo (a
// cold start, a second instance) costs one extra idempotent Set of the same marker, never a lost count, so this is not
// in-process buffering of counts. Many viewers of one hot post therefore write its marker about once per instance per
// 5 minutes, far under the one-write-per-second limit of a document, and the rollup finds every post with new views by
// one query on viewDirty (window < the current one) instead of scanning posts.
//
// Q-V1 viewDirty where window < W ORDER BY window LIMIT n -> automatic single-field index (no firestore.indexes.json change)
package posts

import (
	"strconv"
	"sync"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ViewsFlagName is the wire name of FEATURE_POST_VIEWS: globally off, no view count is shown anywhere and the rollup
// does nothing; on for a caller, RecordImpressions accepts their views (engagement).
const ViewsFlagName = "post_views"

const (
	// ViewShardsSubcollection is posts/{id}/viewShards (lifecycle tables).
	ViewShardsSubcollection = "viewShards"
	// ViewShardCount is N: about 10 views per second per post before a shard nears Firestore's per-document limit.
	ViewShardCount = 10
	// viewDirtyCollection holds the rollup markers.
	viewDirtyCollection = "viewDirty"
	// ViewWindow is the marker window: a post with views gets at most one marker write per window and instance, and the
	// rollup folds a window once it has closed.
	ViewWindow = 5 * time.Minute
	// viewMemoMax bounds the memo (distinct posts marked by this instance in one window); past it the memo stops
	// remembering and the extra writes are idempotent Sets.
	viewMemoMax = 50_000
)

// viewShards is the view counter family; the shard field is "count".
var (
	viewShards     = shardcount.MustNew(ViewShardsSubcollection, ViewShardCount)
	viewShardField = firestore.FieldPath{"count"}
)

// ViewWriter is the impression seam engagement stages through. *FirestoreRepo implements it.
type ViewWriter interface {
	// StageViews appends one view per post id: one shard increment of posts/{id}/viewShards, plus the rollup marker
	// viewDirty/{window}_{id} unless this instance already committed it in now's window. The shard write has no
	// precondition on the post (a view of a post deleted in between leaves shards the rollup deletes). committed must
	// be called once the batch committed (it records the markers in the memo); never call it after a failed commit.
	StageViews(b store.Batch, postIDs []string, now time.Time) (committed func())
}

var _ ViewWriter = (*FirestoreRepo)(nil)

// viewWindow is the window number of t: Unix seconds / 300.
func viewWindow(t time.Time) int64 { return t.Unix() / int64(ViewWindow/time.Second) }

// viewMarkerID is the marker doc id {window}_{postId}.
func viewMarkerID(window int64, postID string) string {
	return strconv.FormatInt(window, 10) + "_" + postID
}

// viewMarkerDoc is viewDirty/{window}_{postId}. It holds a post id and a window, no user data.
type viewMarkerDoc struct {
	PostID string `firestore:"postId"`
	Window int64  `firestore:"window"`
}

// viewMemo is the set of markers this instance committed in one window.
type viewMemo struct {
	mu     sync.Mutex
	window int64
	marked map[string]struct{}
}

// needs reports whether postID's marker for window is not known to be written.
func (m *viewMemo) needs(window int64, postID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.window != window {
		return true
	}
	_, ok := m.marked[postID]
	return !ok
}

// note records committed markers for window; a new window drops the old set.
func (m *viewMemo) note(window int64, postIDs []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.window != window || m.marked == nil {
		m.window, m.marked = window, make(map[string]struct{}, len(postIDs))
	}
	for _, id := range postIDs {
		if len(m.marked) >= viewMemoMax {
			return
		}
		m.marked[id] = struct{}{}
	}
}

func (r *FirestoreRepo) viewMarkerRef(window int64, postID string) *firestore.DocumentRef {
	return r.client.Collection(viewDirtyCollection).Doc(viewMarkerID(window, postID))
}

// StageViews implements ViewWriter.
func (r *FirestoreRepo) StageViews(b store.Batch, postIDs []string, now time.Time) func() {
	window := viewWindow(now)
	var marked []string
	for _, id := range postIDs {
		viewShards.StageIncrement(b, r.ref(id), shardcount.Delta{Field: viewShardField, N: 1})
		if r.viewMemo.needs(window, id) {
			b.Set(r.viewMarkerRef(window, id), viewMarkerDoc{PostID: id, Window: window})
			marked = append(marked, id)
		}
	}
	return func() { r.viewMemo.note(window, marked) }
}
