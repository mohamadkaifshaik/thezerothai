package posts

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Audience is THE visibility predicate for posts (ADR-0025 D3, D4). Every read path that shows a post to a viewer
// (GetPost, Engagement.Viewable, GetThread, lists, feeds, W4 search) calls Decide or CanSee; nothing decides from
// the stored posts.visibility (always PUBLIC, D2) or from users.isPrivate. The expression itself is written once, on
// identity.ProtectedSet.CanSee (AQ2).
//
// Undo is never gated: UnlikePost, UndoRepost and RemoveBookmark resolve through engagement's resolveForCounts and
// must stay outside Audience (plan Part B rule 4).
//
// Reads: +0 on every path. The set comes from identity.ProtectedAuthors.Current, a detached instance-cached loader
// (protected_set_reads), and is consulted only for an author who is neither the viewer nor followed.
type Audience struct {
	authors   identity.ProtectedAuthors // nil: no loader wired, nobody is protected (the pre-W3-26a state)
	blockedBy func(ctx context.Context, snap graph.Snapshot, viewer, other string) (bool, error)
}

// Surface is where a post is shown; it decides what a refusal means.
type Surface int

const (
	// SurfaceDirect is a post asked for by id (GetPost, Viewable, GetThread's focal post): a refusal is NotFound, and a
	// post by an author the viewer blocked or muted is still shown (ADR-0010 D6).
	SurfaceDirect Surface = iota
	// SurfaceList is a row in a feed or list: a refusal is Drop, and rows by authors the viewer blocked or muted drop too.
	SurfaceList
)

// Verdict is the outcome class of Decide.
type Verdict int

const (
	// Show: render the row, with Decision.Embed as its embed_viewer_state.
	Show Verdict = iota
	// Drop: leave the row out of a list or feed.
	Drop
	// NotFound: answer the one "post not found" error.
	NotFound
)

// Decision is Decide's answer. Embed is UNSPECIFIED unless the post copies another post whose author the viewer
// blocks, mutes or may not see (PROTECTED: the view converter then strips the copy, ApplyEmbedState).
type Decision struct {
	Verdict Verdict
	Embed   postsv1.EmbedViewerState
}

func newAudience(a identity.ProtectedAuthors, blockedBy func(context.Context, graph.Snapshot, string, string) (bool, error)) *Audience {
	return &Audience{authors: a, blockedBy: blockedBy}
}

// Enabled reports whether a protected-set loader is wired.
func (a *Audience) Enabled() bool { return a != nil && a.authors != nil }

// CanSee is the pure D3 predicate: viewer == author || !set.Has(author) || snap.Following[author]. No I/O.
func (a *Audience) CanSee(viewer, author string, snap graph.Snapshot, set identity.ProtectedSet) bool {
	if set == nil {
		return true
	}
	return set.CanSee(viewer, author, snap.Following[author])
}

// set returns the protected set, or nil when no loader is wired. An error means the set is unknown: callers answer
// UNAVAILABLE and never read it as "everyone public" (D3 fail closed).
func (a *Audience) set(ctx context.Context) (identity.ProtectedSet, error) {
	if !a.Enabled() {
		return nil, nil
	}
	return a.authors.Current(ctx)
}

// visibleAuthor reports whether the viewer may see posts by author, asking the loader only when it matters.
func (a *Audience) visibleAuthor(ctx context.Context, viewer, author string, snap graph.Snapshot) (bool, error) {
	if !a.Enabled() || author == viewer || snap.Following[author] {
		return true, nil
	}
	set, err := a.set(ctx)
	if err != nil {
		return false, setUnavailable(ctx, err)
	}
	return a.CanSee(viewer, author, snap, set), nil
}

// Decide is the whole-post decision (ADR-0025 D3): moderation, ADR-0010 D6 block and mute by surface, CanSee on the
// post's author and CanSee on the author of the post it copies. A REPOST of an unseen author's post is NotFound or
// Drop; a QUOTE of one is shown with Embed = PROTECTED. A set error is UNAVAILABLE. Status of the author (suspended,
// deleting) is the caller's directory check, not this function's.
func (a *Audience) Decide(ctx context.Context, viewer string, snap graph.Snapshot, p *Post, surface Surface) (Decision, error) {
	refuse := Decision{Verdict: NotFound}
	if surface == SurfaceList {
		refuse.Verdict = Drop
	}
	if !p.Visible() {
		return refuse, nil
	}
	if p.AuthorID != viewer {
		blocked, err := a.blockedBy(ctx, snap, viewer, p.AuthorID)
		if err != nil {
			return Decision{}, err
		}
		if blocked || (surface == SurfaceList && (snap.Blocked[p.AuthorID] || snap.Muted[p.AuthorID])) {
			return refuse, nil
		}
	}
	ok, err := a.visibleAuthor(ctx, viewer, p.AuthorID, snap)
	if err != nil {
		return Decision{}, err
	}
	if !ok {
		logger.SetRequestField(ctx, "audience", "protected")
		return refuse, nil
	}

	ea := p.EmbeddedAuthor()
	if ea == "" || ea == viewer || ea == p.AuthorID {
		return Decision{Verdict: Show}, nil
	}
	// The block checks keep the ADR-0018 D13 exemption for the viewer's own copy; the protected check does not.
	if p.AuthorID != viewer {
		blocked, err := a.blockedBy(ctx, snap, viewer, ea)
		if err != nil {
			return Decision{}, err
		}
		if blocked {
			return refuse, nil
		}
	}
	ok, err = a.visibleAuthor(ctx, viewer, ea, snap)
	if err != nil {
		return Decision{}, err
	}
	if !ok {
		if p.Kind == KindRepost {
			logger.SetRequestField(ctx, "audience", "protected")
			return refuse, nil
		}
		return Decision{Verdict: Show, Embed: postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED}, nil
	}
	if p.AuthorID == viewer {
		return Decision{Verdict: Show}, nil
	}
	return Decision{Verdict: Show, Embed: embedStateFor(snap, ea)}, nil
}

// EmbedState is the embed_viewer_state of p for viewer (the hinter behind GetPost and GetThread): PROTECTED when the
// viewer may not see the copied post's author (checked first: it strips content), else BLOCKED or MUTED from the
// viewer's own lists. A set error fails closed to PROTECTED, so an unknown set never shows a copy.
func (a *Audience) EmbedState(ctx context.Context, viewer string, snap graph.Snapshot, p *Post) postsv1.EmbedViewerState {
	ea := p.EmbeddedAuthor()
	if ea == "" || ea == viewer {
		return postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED
	}
	if ea != p.AuthorID {
		if ok, err := a.visibleAuthor(ctx, viewer, ea, snap); err != nil || !ok {
			return postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED
		}
	}
	if p.AuthorID == viewer {
		return postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED
	}
	return embedStateFor(snap, ea)
}

// ProtectedAuthor reports whether author is in the set, for the computed wire visibility. Best effort: with no
// loader or an unknown set it reports false, because the value is informational for a viewer Decide already admitted.
// following is the viewer's follow state toward author from the snapshot the path already holds. For the viewer's own
// and a followed author (the rows Decide never asks the set about) it answers from the loader's cached copy when one is
// fresh (identity.ProtectedAuthorsCached: no refresh, no log), so a Home page makes no Current call; with no fresh copy
// it asks Current like any other row, so the wire value never changes. A set outage logs one ERROR per request
// (the loader's fallback), WARN after that (W3-36 L-4).
func (a *Audience) ProtectedAuthor(ctx context.Context, viewer, author string, following bool) bool {
	if !a.Enabled() {
		return false
	}
	if author == viewer || following {
		if c, ok := a.authors.(identity.ProtectedAuthorsCached); ok {
			if set, fresh := c.Cached(); fresh {
				return set.Has(author)
			}
		}
	}
	set, err := a.set(ctx)
	return err == nil && set != nil && set.Has(author)
}

// RefuseShare is the D5 write rule for RepostPost and CreatePost(quote_of_post_id): p is the post the caller may
// already see (Viewable passed). A protected author's post can be shared only by that author; an approved caller
// gets FAILED_PRECONDITION PROTECTED_ACCOUNT with 0 writes. A set error is UNAVAILABLE.
func (a *Audience) RefuseShare(ctx context.Context, caller string, p *Post) error {
	if !a.Enabled() || p.AuthorID == caller {
		return nil
	}
	set, err := a.set(ctx)
	if err != nil {
		return setUnavailable(ctx, err)
	}
	if set != nil && set.Has(p.AuthorID) {
		logger.SetRequestField(ctx, "audience", "protected")
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT,
			"this account's posts are protected")
	}
	return nil
}

func setUnavailable(ctx context.Context, err error) error {
	logger.SetRequestField(ctx, "audience", "set_unavailable")
	return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
		WithCause(fmt.Errorf("posts: protected set: %w", err))
}

// ApplyEmbedState is the one place the embed state meets the wire view. It sets embed_viewer_state and, for
// PROTECTED, empties the copy: text, media (urls, thumbs, alt text, sizes), the labels and the
// timestamp (EmbeddedPost carries no hashtags or mentions), keeping only post_id and the author snapshot. Every surface that calls it inherits the strip.
func ApplyEmbedState(v *postsv1.PostView, st postsv1.EmbedViewerState) {
	v.EmbedViewerState = st
	if st != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || v.GetPost().GetEmbedded() == nil {
		return
	}
	e := v.Post.Embedded
	v.Post.Embedded = &postsv1.EmbeddedPost{PostId: e.PostId, Unavailable: e.Unavailable, Author: e.Author}
}

// ApplyWireVisibility sets the computed Post.visibility: FOLLOWERS while the author is protected (D2). Stored docs
// stay PUBLIC.
func ApplyWireVisibility(v *postsv1.PostView, protectedAuthor bool) {
	if protectedAuthor && v.GetPost() != nil {
		v.Post.Visibility = postsv1.Visibility_VISIBILITY_FOLLOWERS
	}
}

// Audience returns the service's Audience, for the owner-only lists of other modules that decide rows through the
// same predicate (engagement ListBookmarks and ListLikedPosts, W3-29b).
func (s *service) Audience() *Audience { return s.aud }

// AudienceOf returns the Audience of a posts Service built by New, or nil for any other implementation (a test fake).
func AudienceOf(svc Service) *Audience {
	if h, ok := svc.(interface{ Audience() *Audience }); ok {
		return h.Audience()
	}
	return nil
}

// NewSnapshotAudience builds an Audience for a read path that already holds the viewer's graph snapshot and must not
// spend a read on a block check (the timelines, W3-30). The block test is the snapshot's blockedBy set alone: a caller
// whose blockedBy set overflowed is handled by the caller's own fail-closed rule (timeline.embedAllowed), not here. A
// nil loader means nobody is protected. The protected rule itself is still CanSee, written once on identity.ProtectedSet.
func NewSnapshotAudience(a identity.ProtectedAuthors) *Audience {
	return newAudience(a, func(_ context.Context, snap graph.Snapshot, _, other string) (bool, error) {
		return snap.BlockedBy[other], nil
	})
}

// VisibleAuthor reports whether viewer may see posts by author (CanSee), asking the loader only when the author is
// neither the viewer nor followed. Reads: +0 (the loader is detached and instance-cached). A set error is UNAVAILABLE:
// never read it as "visible".
func (a *Audience) VisibleAuthor(ctx context.Context, viewer, author string, snap graph.Snapshot) (bool, error) {
	return a.visibleAuthor(ctx, viewer, author, snap)
}
