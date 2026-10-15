package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"
	"golang.org/x/sync/singleflight"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-log fields (counts, booleans and enums only; fs_reads/fs_writes/fs_deletes come from mw.Logging).
const (
	fieldOp      = "engagement_op"
	fieldOutcome = "outcome"
	fieldCache   = "userlikes_cache_hit"
)

// Outcomes.
const (
	outcomeDone     = "done"
	outcomeReplay   = "replay"
	outcomeNoop     = "noop"
	outcomeNotFound = "not_found"
)

const postNotFoundText = "post not found"

// notFound is byte-identical to posts' postNotFound: NOT_FOUND, no reason, "post not found" for every cause.
func notFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, postNotFoundText)
}

// Deps is everything New needs.
type Deps struct {
	Repo Repo
	// Posts is posts' seam (visibility check, instance-cache updates); Reader serves the post for returned counts
	// (cache first). apiserver passes the one posts service for both.
	Posts  posts.Engagement
	Reader posts.Reader
	// Directory supplies the caller's profile (REPOST author snapshot, new-account window), cache first.
	Directory identity.Directory
	Events    Events

	LikesPerDay           int64
	NewAccountLikesPerDay int64
	PostsPerDay           int64
	NewAccountPostsPerDay int64
	NewAccountWindow      time.Duration

	// CacheTTL and CacheEntries size the userLikes cache (config.CacheTTL; 0 entries = default).
	CacheTTL     time.Duration
	CacheEntries int
	// AllowAnonymous is config.AuthEmulator only (ADR-0010 D5 A10).
	AllowAnonymous bool
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
}

type service struct {
	d          Deps
	cache      *userCache
	now        func() time.Time
	likeFlight singleflight.Group
}

// New builds the service. Events defaults to the no-op.
func New(d Deps) (*Module, error) {
	if d.Repo == nil || d.Posts == nil || d.Reader == nil || d.Directory == nil {
		return nil, errors.New("engagement: Repo, Posts, Reader and Directory are required")
	}
	if d.Events == nil {
		d.Events = NopEvents{}
	}
	now := d.Now
	if now == nil {
		now = time.Now
	}
	s := &service{d: d, now: now, cache: newUserCache(d.CacheTTL, d.CacheEntries)}
	return &Module{s: s}, nil
}

// Module is the concrete engagement module value: it implements Service and posts.ViewerFlags.
type Module struct{ s *service }

var (
	_ Service           = (*Module)(nil)
	_ posts.ViewerFlags = (*Module)(nil)
)

// Like implements Service.
func (m *Module) Like(ctx context.Context, uid, key, postID string) (Result, error) {
	return m.s.like(ctx, uid, key, postID)
}

// Unlike implements Service.
func (m *Module) Unlike(ctx context.Context, uid, key, postID string) (Result, error) {
	return m.s.unlike(ctx, uid, key, postID)
}

// Repost implements Service.
func (m *Module) Repost(ctx context.Context, uid, key, postID string) (Result, error) {
	return m.s.repost(ctx, uid, key, postID)
}

// UndoRepost implements Service.
func (m *Module) UndoRepost(ctx context.Context, uid, key, postID string) (Result, error) {
	return m.s.undoRepost(ctx, uid, key, postID)
}

// Viewer implements posts.ViewerFlags: one userLikes read per request, cached (ADR-0018 D5). A failed read
// degrades to the zero ViewerSet (logged), never to a failed GetPost or timeline.
func (m *Module) Viewer(ctx context.Context, uid string) posts.ViewerSet {
	st, err := m.s.state(ctx, uid)
	if err != nil {
		slog.WarnContext(ctx, "engagement_viewer_flags_degraded", "error", logger.RedactErr(err, uid).Error())
		return posts.ViewerSet{}
	}
	return st.set
}

var _ posts.RepostLinks = (*Module)(nil)

// StageRelease implements posts.RepostLinks: the blind delete of the reposts doc, in DeletePost's batch.
func (m *Module) StageRelease(b store.Batch, originalID, uid string) {
	if r, ok := m.s.d.Repo.(releaser); ok {
		r.StageRelease(b, originalID, uid)
	}
}

// Released implements posts.RepostLinks: the best-effort counter release after DeletePost of a REPOST, plus the
// instance userLikes cache.
func (m *Module) Released(ctx context.Context, originalID, uid string) error {
	m.s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return recent, withoutID(reposts, originalID)
	})
	r, ok := m.s.d.Repo.(releaser)
	if !ok {
		return nil
	}
	return r.release(ctx, originalID, uid)
}

// releaser is the part of FirestoreRepo RepostLinks needs (Repo fakes in unit tests need not implement it).
type releaser interface {
	StageRelease(b store.Batch, originalID, uid string)
	release(ctx context.Context, originalID, uid string) error
}

// Cache hooks for the Eraser/job wiring and tests.

// ForgetUser drops uid's cached userLikes (the Eraser deleted the document).
func (m *Module) ForgetUser(uid string) { m.s.cache.delete(uid) }

// state returns uid's userLikes state: the instance cache, or one read (1) that fills it.
func (s *service) state(ctx context.Context, uid string) (*likesState, error) {
	if st, ok := s.cache.get(uid); ok {
		logger.AddRequestCount(ctx, fieldCache, 1)
		return st, nil
	}
	ul, err := s.d.Repo.LoadUserLikes(ctx, uid)
	if err != nil {
		return nil, fmt.Errorf("engagement: load userLikes: %w", err)
	}
	return s.cache.set(uid, ul), nil
}

func validate(key, postID string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !ids.ValidPostID(postID) {
		return apierr.Validation("post_id", "post_id must be a 19-digit post id")
	}
	return nil
}

// resolveViewable returns the post an action applies to: the target when visible to uid, and for a REPOST id the
// original, also visible (D4, D13). Every refusal is the one NOT_FOUND. Reads: post 1 + author 1 + caller graph 1
// cold, 0 warm; +2 for a REPOST id.
func (s *service) resolveViewable(ctx context.Context, uid, postID string) (*posts.Post, error) {
	p, err := s.d.Posts.Viewable(ctx, uid, postID)
	if errors.Is(err, posts.ErrNotFound) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, notFound()
	}
	if err != nil {
		return nil, err
	}
	if p.Kind != posts.KindRepost {
		return p, nil
	}
	if p.RepostOfID == "" {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, notFound()
	}
	orig, err := s.d.Posts.Viewable(ctx, uid, p.RepostOfID)
	if errors.Is(err, posts.ErrNotFound) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, notFound()
	}
	if err != nil {
		return nil, err
	}
	return orig, nil
}

// resolveForCounts is resolveViewable without the visibility rules, for Unlike and UndoRepost (a user can always
// retract): the post for the returned counts, cache first. ok is false when the post is gone.
func (s *service) resolveForCounts(ctx context.Context, postID string) (*posts.Post, bool, error) {
	p, err := s.d.Reader.Get(ctx, postID)
	if errors.Is(err, posts.ErrNotFound) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if p.Kind == posts.KindRepost && p.RepostOfID != "" {
		o, err := s.d.Reader.Get(ctx, p.RepostOfID)
		if errors.Is(err, posts.ErrNotFound) {
			return nil, false, nil
		}
		if err != nil {
			return nil, false, err
		}
		return o, true, nil
	}
	return p, true, nil
}

func (s *service) profile(ctx context.Context, uid string) (identity.Profile, error) {
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return identity.Profile{}, logger.RedactErr(fmt.Errorf("engagement: load profile: %w", err), uid)
	}
	p, ok := profiles[uid]
	if !ok {
		return identity.Profile{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
	}
	return p, nil
}

func (s *service) isNew(p identity.Profile) bool {
	return !p.CreatedAt.IsZero() && s.now().Sub(p.CreatedAt) < s.d.NewAccountWindow
}

func noteRejected(ctx context.Context, err error) {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		switch {
		case ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
			logger.SetRequestField(ctx, fieldOutcome, "rejected:quota_exceeded")
		case ae.Code == connect.CodeNotFound:
			logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		default:
			logger.SetRequestField(ctx, fieldOutcome, "rejected:"+ae.Code.String())
		}
		return
	}
	logger.SetRequestField(ctx, fieldOutcome, "error")
}

// like implements Service.Like (ADR-0018 D3).
func (s *service) like(ctx context.Context, uid, key, postID string) (_ Result, err error) {
	logger.SetRequestField(ctx, fieldOp, "like")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return Result{}, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "liking posts"); err != nil {
		return Result{}, err
	}
	target, err := s.resolveViewable(ctx, uid, postID)
	if err != nil {
		return Result{}, err
	}
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return Result{}, err
	}
	limit := s.d.LikesPerDay
	if s.isNew(prof) {
		limit = s.d.NewAccountLikesPerDay
	}
	// Concurrent likes of one post by one user (a retry storm, a double tap) collapse into one transaction per
	// instance: they would only contend on the same like, post and quota docs. The followers did not write, so
	// they are replays (no counter bump, no notification).
	led := false
	v, err, _ := s.likeFlight.Do(uid+"/"+target.ID, func() (any, error) {
		led = true
		return s.d.Repo.Like(ctx, LikeParams{UID: uid, PostID: target.ID, QuotaLimit: limit})
	})
	replayed, _ := v.(bool)
	if err == nil && !led {
		replayed = true
	}
	switch {
	case errors.Is(err, ErrPostGone):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return Result{}, notFound()
	case err != nil:
		var ae *apierr.Error
		if errors.As(err, &ae) {
			// At the daily limit a replay of a like the cache knows about is still a success (idempotent).
			if ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED {
				if st, ok := s.cache.get(uid); ok {
					if liked, _ := st.set.Flags(target); liked {
						logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
						out := s.result(ctx, uid, target, 0, 0)
						out.LikedByViewer = true
						return out, nil
					}
				}
			}
			return Result{}, err
		}
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: like: %w", err), uid)
	}
	likeDelta := int64(1)
	if replayed {
		likeDelta = 0
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
		s.d.Posts.CountsChanged(target.ID, 1, 0)
	}
	s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return withID(recent, target.ID), reposts
	})
	s.trim(ctx, uid)
	if !replayed {
		s.d.Events.Liked(ctx, uid, target, s.now())
	}
	out := s.result(ctx, uid, target, likeDelta, 0)
	out.LikedByViewer = true
	return out, nil
}

// result builds the response from the post as read plus this call's own delta, and the cached viewer flags.
func (s *service) result(ctx context.Context, uid string, p *posts.Post, likeDelta, repostDelta int64) Result {
	r := Result{PostID: p.ID, LikeCount: max(p.LikeCount+likeDelta, 0), RepostCount: max(p.RepostCount+repostDelta, 0)}
	if st, ok := s.cache.get(uid); ok {
		r.LikedByViewer, r.RepostedByViewer = st.set.Flags(p)
	}
	return r
}

// trim is the best-effort trim of D8: a cached list over its cap + slack gets its oldest chunk ArrayRemoved (1
// write, no read). A failure is logged and ignored; the list stays long until the next like retries.
func (s *service) trim(ctx context.Context, uid string) {
	st, ok := s.cache.get(uid)
	if !ok {
		return
	}
	var dropLikes, dropReposts []string
	if len(st.recent) > MaxRecentLikes+trimSlack {
		dropLikes = append(dropLikes, st.recent[:trimChunk]...)
	}
	if len(st.reposts) > MaxRecentReposts+trimSlack {
		dropReposts = append(dropReposts, st.reposts[:trimChunk]...)
	}
	if len(dropLikes) == 0 && len(dropReposts) == 0 {
		return
	}
	if err := s.d.Repo.TrimLikes(ctx, uid, dropLikes, dropReposts); err != nil {
		slog.WarnContext(ctx, "engagement_trim_failed", "error", logger.RedactErr(err, uid).Error())
		return
	}
	s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return withoutIDs(recent, dropLikes), withoutIDs(reposts, dropReposts)
	})
}

// unlike implements Service.Unlike.
func (s *service) unlike(ctx context.Context, uid, key, postID string) (_ Result, err error) {
	logger.SetRequestField(ctx, fieldOp, "unlike")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return Result{}, err
	}
	target, found, err := s.resolveForCounts(ctx, postID)
	if err != nil {
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: unlike: load post: %w", err), uid)
	}
	id := postID
	if found {
		id = target.ID
	}
	removed, err := s.d.Repo.Unlike(ctx, uid, id)
	if err != nil {
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: unlike: %w", err), uid)
	}
	delta := int64(0)
	if removed {
		delta = -1
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
		if found {
			s.d.Posts.CountsChanged(id, -1, 0)
		}
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
	s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return withoutID(recent, id), reposts
	})
	if !found {
		return Result{PostID: id}, nil
	}
	return s.result(ctx, uid, target, delta, 0), nil
}

// repost implements Service.Repost (ADR-0018 D3, D5).
func (s *service) repost(ctx context.Context, uid, key, postID string) (_ Result, err error) {
	logger.SetRequestField(ctx, fieldOp, "repost")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return Result{}, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "reposting"); err != nil {
		return Result{}, err
	}
	target, err := s.resolveViewable(ctx, uid, postID)
	if err != nil {
		return Result{}, err
	}
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return Result{}, err
	}
	limit := s.d.PostsPerDay
	if s.isNew(prof) {
		limit = s.d.NewAccountPostsPerDay
	}
	res, err := s.d.Repo.Repost(ctx, RepostParams{
		UID: uid, Original: target, QuotaLimit: limit, SnapshotVersion: prof.SnapshotVersion,
		Author: posts.AuthorSnapshot{
			UserID: uid, Handle: prof.Handle, DisplayName: prof.DisplayName, AvatarURL: prof.AvatarThumbURL, Verified: prof.Verified,
		},
	})
	switch {
	case errors.Is(err, ErrPostGone):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return Result{}, notFound()
	case err != nil:
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return Result{}, err
		}
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: repost: %w", err), uid)
	}
	repostID := res.ReplayPostID
	repostDelta := int64(0)
	if res.Post != nil {
		repostID = res.Post.ID
		repostDelta = 1
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
		s.d.Posts.RepostCreated(res.Post)
		s.d.Posts.CountsChanged(target.ID, 0, 1)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	}
	s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return recent, withID(reposts, target.ID)
	})
	s.trim(ctx, uid)
	if res.Post != nil {
		s.d.Events.Reposted(ctx, uid, target, repostID, s.now())
	}
	out := s.result(ctx, uid, target, 0, repostDelta)
	out.RepostPostID = repostID
	out.RepostedByViewer = true
	return out, nil
}

// undoRepost implements Service.UndoRepost.
func (s *service) undoRepost(ctx context.Context, uid, key, postID string) (_ Result, err error) {
	logger.SetRequestField(ctx, fieldOp, "undo_repost")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return Result{}, err
	}
	res, err := s.d.Repo.UndoRepost(ctx, uid, postID)
	if err != nil {
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: undo repost: %w", err), uid)
	}
	if res.Removed {
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
		s.d.Posts.RepostRemoved(uid, res.RepostPostID)
		s.d.Posts.CountsChanged(postID, 0, -1)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
	s.cache.update(uid, func(recent, reposts []string) ([]string, []string) {
		return recent, withoutID(reposts, postID)
	})
	orig, err := s.d.Reader.Get(ctx, postID)
	if errors.Is(err, posts.ErrNotFound) {
		return Result{PostID: postID}, nil
	}
	if err != nil {
		return Result{}, logger.RedactErr(fmt.Errorf("engagement: undo repost: load post: %w", err), uid)
	}
	out := s.result(ctx, uid, orig, 0, 0)
	out.RepostedByViewer = false
	return out, nil
}
