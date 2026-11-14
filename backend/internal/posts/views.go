// views.go is the read side of F1 post view counts: who sees Post.view_count (the hybrid rule, owner decision
// 2026-11-14). The field is proto3 optional and its presence is the visibility signal.
//
//   - The author always sees their own count. ToView sets it (the rolled-up posts/{id}.viewCount), and GetPost replaces it
//     with the exact live shard sum (one GetAll of 10 shard docs, only for the author with FEATURE_POST_VIEWS on).
//   - Anyone else sees the rolled-up count only once it reaches the threshold (POST_VIEWS_PUBLIC_THRESHOLD) and only when
//     the author is not protected. That is decided by ApplyPublicViews, which every surface calls next to
//     ApplyWireVisibility, where the author's protected state is known. A surface that never decides it never shows
//     another author's count: the rule fails closed.
//   - Never on a REPOST row, an embed or a withheld row; nowhere while FEATURE_POST_VIEWS is globally off, and nowhere
//     before SetViewCountRule ran (the zero rule is off).
package posts

import (
	"context"
	"fmt"
	"math"
	"sync/atomic"

	"cloud.google.com/go/firestore"
	"google.golang.org/protobuf/proto"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// ViewCountRule is the process-wide view count rule: Threshold is POST_VIEWS_PUBLIC_THRESHOLD (>= 1) and Off reports
// FEATURE_POST_VIEWS globally off (nil = never off).
type ViewCountRule struct {
	Threshold int64
	Off       func() bool
}

// viewRule is set once at startup (apiserver). It is process-wide rather than a dependency of every converter caller
// because ToView and ApplyPublicViews are free functions called from posts, timeline, search and engagement; unset, the
// rule is off and no count is ever shown.
var viewRule atomic.Pointer[ViewCountRule]

// SetViewCountRule installs the rule (startup, and tests). A Threshold below 1 is read as "no public count".
func SetViewCountRule(r ViewCountRule) {
	if r.Threshold < 1 {
		r.Threshold = math.MaxInt64
	}
	viewRule.Store(&r)
}

// activeViewRule is the installed rule when it is on.
func activeViewRule() (ViewCountRule, bool) {
	r := viewRule.Load()
	if r == nil || (r.Off != nil && r.Off()) {
		return ViewCountRule{}, false
	}
	return *r, true
}

// authorViewCount is ToView's part: the author's own count, rolled up.
func authorViewCount(p *Post, viewer string) *int64 {
	if p.Kind == KindRepost || viewer == "" || viewer != p.AuthorID {
		return nil
	}
	if _, on := activeViewRule(); !on {
		return nil
	}
	return proto.Int64(max(p.ViewCount, 0))
}

// ApplyPublicViews sets Post.view_count for a viewer who is not the author: the rolled-up count of p (the post v was
// built from) when it is at least the threshold and the author is not protected. It never lowers what ToView set (the
// author's own count) and does nothing on a withheld row or a REPOST row.
func ApplyPublicViews(v *postsv1.PostView, p *Post, protectedAuthor bool) {
	if v == nil || v.GetPost() == nil || v.Withheld || p == nil || v.Post.ViewCount != nil {
		return
	}
	r, on := activeViewRule()
	if !on || protectedAuthor || p.Kind == KindRepost || p.ViewCount < r.Threshold {
		return
	}
	v.Post.ViewCount = proto.Int64(p.ViewCount)
}

// ViewCounter is the live read of a post's views (*FirestoreRepo).
type ViewCounter interface {
	// LiveViewCount sums posts/{id}/viewShards: one GetAll of ViewShardCount docs.
	LiveViewCount(ctx context.Context, postID string) (int64, error)
}

var _ ViewCounter = (*FirestoreRepo)(nil)

// LiveViewCount implements ViewCounter.
func (r *FirestoreRepo) LiveViewCount(ctx context.Context, postID string) (int64, error) {
	t, err := viewShards.Read(ctx, r.client, []*firestore.DocumentRef{r.ref(postID)}, viewShardField)
	if err != nil {
		return 0, fmt.Errorf("posts: live view count: %w", err)
	}
	return max(t[0].Get(viewShardField), 0), nil
}

// LiveViewHinter is implemented by the concrete service: the author's exact count for GetPost.
type LiveViewHinter interface {
	// LiveViewCount answers the live shard sum of p for its author; ok is false when there is none to give (the rule is
	// off, p is a REPOST, the repo cannot count, or the read failed; the caller keeps the rolled-up count).
	LiveViewCount(ctx context.Context, p *Post) (n int64, ok bool)
}

// LiveViewCount implements LiveViewHinter.
func (s *service) LiveViewCount(ctx context.Context, p *Post) (int64, bool) {
	if _, on := activeViewRule(); !on || p.Kind == KindRepost {
		return 0, false
	}
	vc, ok := s.repo.(ViewCounter)
	if !ok {
		return 0, false
	}
	n, err := vc.LiveViewCount(ctx, p.ID)
	if err != nil {
		return 0, false
	}
	return n, true
}

// applyAuthorLiveViews is GetPost's step: for the author with FEATURE_POST_VIEWS on, the exact live count (never below
// the rolled-up one, which a lagging read cannot undo).
func (s *Server) applyAuthorLiveViews(ctx context.Context, v *postsv1.PostView, uid string, p *Post) {
	if v.GetPost().ViewCount == nil || uid != p.AuthorID || s.flags == nil || !s.flags.Enabled(uid, ViewsFlagName) {
		return
	}
	h, ok := s.svc.(LiveViewHinter)
	if !ok {
		return
	}
	if n, ok := h.LiveViewCount(ctx, p); ok {
		v.Post.ViewCount = proto.Int64(max(n, v.Post.GetViewCount()))
	}
}
