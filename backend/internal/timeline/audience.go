package timeline

import (
	"context"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Log fields for protected accounts (ADR-0025 D4). A boolean and a count: never ids.
const (
	fieldAuthorProtected = "author_protected"
	fieldAudienceDropped = "audience_dropped"
)

// Option configures NewServer.
type Option func(*Server)

// WithProtectedAuthors wires the one protected-set loader (ADR-0025 D3, built once in apiserver) into the timeline's
// posts.Audience. Without it nobody is protected, which is the pre-W3-26a behaviour.
func WithProtectedAuthors(p identity.ProtectedAuthors) Option {
	return func(s *Server) { s.aud = posts.NewSnapshotAudience(p) }
}

// audienceFilter applies posts.Audience.Decide to the rows of one response (ADR-0025 D4): a REPOST whose original is
// by a protected author the viewer may not see is dropped, a QUOTE of one is kept with embed_viewer_state PROTECTED
// (posts.ApplyEmbedState strips the copy). Decisions run after the author-recent entry or the page query, per viewer,
// so a cache filled before the viewer was checked never leaks. Reads: +0 (the caller's graph snapshot is already
// held, the set is a detached instance cache).
type audienceFilter struct {
	aud     *posts.Audience
	ctx     context.Context
	viewer  string
	snap    graph.Snapshot
	err     error // the first set error: the response is UNAVAILABLE, never a partial page
	dropped int
	embed   map[string]postsv1.EmbedViewerState
}

func (s *Server) newAudienceFilter(ctx context.Context, viewer string, snap graph.Snapshot) *audienceFilter {
	return &audienceFilter{aud: s.aud, ctx: ctx, viewer: viewer, snap: snap}
}

// keep is a Merge keep function: false for a hidden post or one Decide drops.
func (f *audienceFilter) keep(p *posts.Post) bool {
	if f.err != nil || !p.Visible() {
		return false
	}
	// SurfaceDirect: a caller who blocks or mutes the profile's owner still sees the posts (ADR-0010 D6); the Home
	// authors and the embedded authors were already filtered by allowedAuthor and embedAllowed.
	d, err := f.aud.Decide(f.ctx, f.viewer, f.snap, p, posts.SurfaceDirect)
	if err != nil {
		f.err = err
		return false
	}
	if d.Verdict != posts.Show {
		f.dropped++
		return false
	}
	if d.Embed != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
		if f.embed == nil {
			f.embed = map[string]postsv1.EmbedViewerState{}
		}
		f.embed[p.ID] = d.Embed
	}
	return true
}

// finish logs the drop count and returns the first set error, if any.
func (f *audienceFilter) finish() error {
	logger.SetRequestField(f.ctx, fieldAudienceDropped, f.dropped)
	return f.err
}
