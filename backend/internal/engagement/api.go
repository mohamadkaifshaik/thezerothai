// Package engagement is the P5 module (ADR-0018): likes and reposts (quotes are CreatePost in posts). It owns
// likes/{postId}_{uid}, reposts/{postId}_{uid} and userLikes/{uid}. It never touches posts/* directly: counters,
// the REPOST post doc and the clean-up of dependants go through posts' EngagementWriter / Cleanup / Engagement
// seams (ADR-0002), and users.postsCount through identity.Counters.
//
// Operations are state-setting and keyed by (post, caller), so a replay or ten concurrent calls converge on one
// effect (ADR-0018 D3): the idempotency_key is validated for format and needs no stored record.
package engagement

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// FlagName is the wire name RPCs check (FEATURE_ENGAGEMENT <-> "engagement", ADR-0018 D8). It is the same string
// posts.EngagementFlagName gates the quote path and viewer flags with.
const FlagName = posts.EngagementFlagName

// Limits (ADR-0018 D7, D8).
const (
	// MaxRecentLikes and MaxRecentReposts bound userLikes.recent / recentReposts (newest last).
	MaxRecentLikes   = 1000
	MaxRecentReposts = 500
	// trimSlack is how far a cached list may exceed its cap before a best-effort ArrayRemove of the oldest
	// trimChunk entries (one write per ~100 likes, D8).
	trimSlack = 100
	// trimChunk is how many of the oldest entries one trim removes.
	trimChunk = 100
)

// Result is what every RPC returns: the post's engagement as this instance now knows it (ADR-0018 D4).
type Result struct {
	// PostID is the post the action applied to: the original when the request named a REPOST.
	PostID                 string
	LikeCount, RepostCount int64
	LikedByViewer          bool
	RepostedByViewer       bool
	// RepostPostID is the REPOST post doc a RepostPost created or found (empty for the other RPCs).
	RepostPostID string
}

// Service is the Connect handler's dependency.
type Service interface {
	// Like likes a post for uid. Reads: 1 in the transaction (quotas) + the visibility check (post, author users,
	// caller graph; +2 for a REPOST id). Writes 4 (like doc, likeCount, userLikes, quota); replay 0 writes.
	Like(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// Unlike removes uid's like. Reads <= 1 (+1 for a REPOST id): the post for the returned counts, cache first.
	// Writes 2 + 1 delete (likeCount, userLikes; the like doc); a no-op writes 0.
	Unlike(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// Repost reposts a post for uid. Reads as Like; writes 6 (reposts doc, REPOST post, repostCount, postsCount,
	// userLikes, quota); replay +1 read, 0 writes.
	Repost(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// UndoRepost removes uid's repost of the ORIGINAL postID. Reads 1 (reposts doc) + the original (cache first);
	// writes 3 + 2 deletes; a no-op writes 0.
	UndoRepost(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
}

// UserLikes is the userLikes/{uid} document: the ids the user liked and reposted most recently, newest last.
type UserLikes struct {
	Recent        []string
	RecentReposts []string
}

// Repo is the storage seam service.go depends on; repo_firestore.go implements it, tests use a fake.
type Repo interface {
	// LoadUserLikes reads userLikes/{uid} (1 read). A missing doc is an empty UserLikes, not an error.
	LoadUserLikes(ctx context.Context, uid string) (UserLikes, error)
	// Like runs the like transaction. replayed is true when the like already existed (0 writes).
	Like(ctx context.Context, p LikeParams) (replayed bool, err error)
	// Unlike removes the like. removed is false for a no-op. A post that is gone is handled inside (the counter
	// is dropped and the delete is retried alone).
	Unlike(ctx context.Context, uid, postID string) (removed bool, err error)
	// Repost runs the repost transaction.
	Repost(ctx context.Context, p RepostParams) (RepostResult, error)
	// UndoRepost deletes the repost of originalID, if any.
	UndoRepost(ctx context.Context, uid, originalID string) (UndoResult, error)
	// TrimLikes removes ids from userLikes.recent (best effort, 1 write).
	TrimLikes(ctx context.Context, uid string, recent, reposts []string) error
}

// LikeParams is one like transaction.
type LikeParams struct {
	UID, PostID string
	QuotaLimit  int64
}

// RepostParams is one repost transaction.
type RepostParams struct {
	UID string
	// Original is the post being reposted (never a REPOST: the service resolved it, D4).
	Original *posts.Post
	// Author and SnapshotVersion are the reposter's denormalised profile for the REPOST doc.
	Author          posts.AuthorSnapshot
	SnapshotVersion int64
	QuotaLimit      int64
}

// RepostResult is the outcome of Repo.Repost: exactly one of Post (a new REPOST, committed) and ReplayPostID.
type RepostResult struct {
	Post         *posts.Post
	ReplayPostID string
}

// UndoResult is the outcome of Repo.UndoRepost.
type UndoResult struct {
	// Removed is false when there was no repost (a no-op, 0 writes).
	Removed bool
	// RepostPostID is the REPOST post doc that was deleted.
	RepostPostID string
}

// Events is the post-commit notification seam (ADR-0018 D9). apiserver adapts it to notifications.Emitter. It is
// called after the commit, never inside it, and only for effects that were written (replays do not call it).
type Events interface {
	// Liked reports that actor liked post (post.AuthorID is the recipient).
	Liked(ctx context.Context, actorUID string, post *posts.Post, at time.Time)
	// Reposted reports that actor reposted original (original.AuthorID is the recipient).
	Reposted(ctx context.Context, actorUID string, original *posts.Post, repostPostID string, at time.Time)
}

// NopEvents is the default Events.
type NopEvents struct{}

// Liked implements Events.
func (NopEvents) Liked(context.Context, string, *posts.Post, time.Time) {}

// Reposted implements Events.
func (NopEvents) Reposted(context.Context, string, *posts.Post, string, time.Time) {}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning.
type Checkpoint struct {
	// Step: 0 the user's likes, 1 the user's reposts, 2 userLikes/{uid}.
	Step int
	// Deleted counts documents processed so far.
	Deleted int
}

// Eraser is the delete-cascade building block (ADR-0018 D7); PurgeUser is resumable.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, cp Checkpoint) (next Checkpoint, done bool, err error)
}

// Errors the repo reports to the service.
var (
	// ErrPostGone is returned by Repo.Like and Repo.Repost when the target was deleted between the visibility
	// check and the commit. The service maps it to the one NOT_FOUND "post not found" answer.
	ErrPostGone = errors.New("engagement: post no longer exists")
)
