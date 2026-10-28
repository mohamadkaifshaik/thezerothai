// Package engagement is the P5 module (ADR-0018): likes and reposts (quotes are CreatePost in posts). It owns
// likes/{postId}_{uid}, reposts/{postId}_{uid} and userLikes/{uid}. It never touches posts/* directly: counters,
// the REPOST post doc and the clean-up of dependants go through posts' EngagementWriter / Cleanup / Engagement
// seams (ADR-0002), and users.postsCount through identity.Counters.
//
// Operations are state-setting and keyed by (post, caller), so a replay or ten concurrent calls converge on one
// effect (ADR-0018 D3): the idempotency_key is validated for format and needs no stored record.
//
// Bookmarks (ADR-0023) also live here: users/{uid}/bookmarks/{postId} and userLikes.bookmarks, behind the Bookmarks and
// BookmarkRepo seams. Unlike likes they store an idempotency doc (rule 4), and they emit no event.
package engagement

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// FlagName is the wire name RPCs check (FEATURE_ENGAGEMENT <-> "engagement", ADR-0018 D8). It is the same string
// posts.EngagementFlagName gates the quote path and viewer flags with.
const FlagName = posts.EngagementFlagName

// BookmarksFlagName is the wire name of FEATURE_BOOKMARKS (ADR-0023 D5). AddBookmark needs it on for the caller;
// ListBookmarks and RemoveBookmark only need it not globally off. It is independent of FlagName (engagement).
const BookmarksFlagName = posts.BookmarksFlagName

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

// UserLikes is the userLikes/{uid} document: the ids the user liked and reposted most recently, newest last, and the
// complete bookmark set.
type UserLikes struct {
	Recent        []string
	RecentReposts []string
	// Bookmarks is the complete set of the user's bookmarked post ids (ADR-0023 D3), at most the per-user cap.
	Bookmarks []string
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
	// ErrBookmarkLimit is returned by BookmarkRepo.Add when userLikes.bookmarks already holds MaxPerUser ids. The service
	// maps it to FAILED_PRECONDITION + LIMIT_REACHED limit=bookmarks.
	ErrBookmarkLimit = errors.New("engagement: bookmark limit reached")
	// ErrIdempotencyKeyReused is returned by BookmarkRepo when the key was used before for a different post_id. The
	// service maps it to INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED.
	ErrIdempotencyKeyReused = errors.New("engagement: idempotency key reused with a different request")
)

// BookmarkState is the caller's bookmark state of one post after AddBookmark or RemoveBookmark (ADR-0023).
type BookmarkState struct {
	// PostID is the post the action applied to: the original when AddBookmark named a REPOST.
	PostID string
	// Bookmarked is true after AddBookmark (also for a post that was already bookmarked), false after RemoveBookmark.
	Bookmarked bool
}

// Bookmarks is the bookmark seam of the module (ADR-0023 D1): the Connect handler depends on it, a later split into
// its own service changes no caller. It reads posts only through posts.Engagement.Viewable, emits no event and
// notifies nobody; a bookmark is private to the caller.
type Bookmarks interface {
	// AddBookmark bookmarks postID (a REPOST id: its original) for uid. Reads cold: the visibility check 3 (+2 for a
	// REPOST id, +1 on blockedBy overflow; 0 warm) + idempotency + quotas + userLikes = 6, 7 with the interceptor's own
	// read (3 warm); a replay stops after the idempotency read (5 cold / 1 warm). Writes 4 (bookmark,
	// idempotency doc, quotas, userLikes); an existing bookmark writes 1 (the idempotency doc, so a late retry replays); a replay, the cap and the quota write 0.
	AddBookmark(ctx context.Context, uid, idempotencyKey, postID string) (BookmarkState, error)
	// RemoveBookmark removes uid's bookmark of postID. No visibility check and no quota. Reads 1 (idempotency);
	// writes 2 (idempotency doc, userLikes) + 1 delete; a missing bookmark writes 1 (the idempotency doc); a replay writes 0.
	RemoveBookmark(ctx context.Context, uid, idempotencyKey, postID string) (BookmarkState, error)
	// ListBookmarks returns one page of uid's bookmarks, newest first, as live posts (ADR-0023 D2, D6). pageSize 0 is
	// 20, clamped to 50; pageToken is empty for the first page. A foreign, expired or tampered token is VALIDATION
	// page_token with 0 reads. Reads cold: the bookmark query 1 + len(page) (an empty list: 1), GetMany <= len(page)
	// (0 for cached posts), the caller's graph snapshot 1 and userLikes 1, each only when a row is left to render
	// (cached 60 s); 41 at page 20 and 101 at page 50, 43 / 103 with the interceptor's own read. Writes 0; a page that
	// prunes missing posts writes 1 (userLikes) and deletes 1 per pruned row.
	ListBookmarks(ctx context.Context, uid string, pageSize int32, pageToken string) (BookmarkPage, error)
}

// BookmarkRow is one bookmark the caller sees now: the live post and the time it was bookmarked.
type BookmarkRow struct {
	Post         *posts.Post
	BookmarkedAt time.Time
	// Hint is the embed state and protected-author mark the handler applies (ADR-0025 D4).
	Hint RowHint
}

// BookmarkPage is one page of ListBookmarks. Rows may be shorter than the page size: rows whose post is missing,
// hidden or by a blocked or muted author are dropped after the read (ADR-0023 D6), so the client keeps following
// NextPageToken until it is empty.
type BookmarkPage struct {
	// Rows are newest bookmarked first.
	Rows []BookmarkRow
	// Viewer is the caller's viewer state for Rows (posts.HydrateViewer): the zero set when no row is left.
	Viewer posts.ViewerSet
	// NextPageToken is "" when this was the last page.
	NextPageToken string
}

// BookmarkOutcome says what a BookmarkRepo call did.
type BookmarkOutcome int

const (
	// BookmarkWritten means the transaction committed its writes.
	BookmarkWritten BookmarkOutcome = iota
	// BookmarkReplayed means the idempotency doc already existed: the stored state is returned, nothing was written.
	BookmarkReplayed
	// BookmarkUnchanged means the state already held (Add of an existing bookmark, Remove of a missing one): 1 write (the idempotency doc).
	BookmarkUnchanged
)

// AddBookmarkParams is one AddBookmark transaction.
type AddBookmarkParams struct {
	UID string
	// PostID is the original's id (the service resolved a REPOST id): the bookmark doc id.
	PostID string
	// IdemKey is idempotency.Key(uid, "AddBookmark", key); RequestHash is the hash of the post_id as sent.
	IdemKey, RequestHash string
	// QuotaLimit is the daily AddBookmark limit for this caller (200, or 50 for a new account); MaxPerUser is the
	// hard cap of bookmarks (1,000).
	QuotaLimit int64
	MaxPerUser int
}

// RemoveBookmarkParams is one RemoveBookmark transaction.
type RemoveBookmarkParams struct {
	UID, PostID string
	// IdemKey is idempotency.Key(uid, "RemoveBookmark", key); RequestHash is the hash of the post_id as sent.
	IdemKey, RequestHash string
}

// BookmarkResult is the outcome of a BookmarkRepo call. State is the stored one on a replay.
type BookmarkResult struct {
	Outcome BookmarkOutcome
	State   BookmarkState
}

// BookmarkRepo is the storage seam of the bookmark service; repo_bookmarks.go implements it, tests use a fake.
type BookmarkRepo interface {
	// Add runs the AddBookmark transaction (ADR-0023 D4). It returns ErrBookmarkLimit at the cap, a
	// quota.ExceededError at the daily quota and ErrIdempotencyKeyReused for a key used with another post_id.
	Add(ctx context.Context, p AddBookmarkParams) (BookmarkResult, error)
	// Remove runs the RemoveBookmark transaction. It returns ErrIdempotencyKeyReused like Add.
	Remove(ctx context.Context, p RemoveBookmarkParams) (BookmarkResult, error)
	// ListPage returns uid's bookmarks strictly after `after` (nil = from the newest), newest first by
	// (createdAt, post id), at most limit (clamped to 1..MaxListPage). Reads: len(result), minimum 1; the same query as
	// the export (ExportBookmarksPage).
	ListPage(ctx context.Context, uid string, after *posts.Position, limit int) ([]ExportedBookmark, error)
	// Prune deletes the bookmark docs of ids (posts that no longer exist) and removes the ids from
	// userLikes.bookmarks, in one batch: 0 reads, 1 write (the field-level userLikes update) and 1 delete per id.
	// Blind: a doc another request already pruned is deleted again without error. At most MaxListPage ids.
	Prune(ctx context.Context, uid string, ids []string) error
}

// MaxListPage is the largest ListBookmarks page (CLAUDE.md rule 5).
const MaxListPage = limits.MaxPageSize

// LikesList is the likes-list seam of the module (ADR-0024 D6, ticket W3-10): the Connect handler depends on it, a later
// split into its own service (or a `likes (uid, createdAt)` index or SQL table at Stage 2/3) changes no caller. It is
// owner-only (there is no user id in the request), reads posts only through posts.Reader.GetMany, writes nothing and
// notifies nobody.
type LikesList interface {
	// ListLikedPosts returns one page of uid's own likes, most recently liked first, as live posts (ADR-0024 D6).
	// pageSize 0 is 20, clamped to 1..50; pageToken is empty for the first page. A foreign, expired or tampered token
	// is VALIDATION page_token with 0 reads. The ids come from userLikes.recent (the last MaxRecentLikes likes) through
	// the 60 s instance cache. Reads cold: userLikes 1, GetMany <= len(page) (0 for cached posts), the caller's graph
	// snapshot 1 (only when a row of someone else is live), the viewer state 0 (same userLikes state): 22 at page 20
	// and 52 at page 50, 23 / 53 with the interceptor's own read; an empty array 1 (2 with the interceptor). Writes 0,
	// and nothing is pruned: a row whose post is gone is only dropped from the page.
	ListLikedPosts(ctx context.Context, uid string, pageSize int32, pageToken string) (LikesPage, error)
}

// LikesPage is one page of ListLikedPosts. Posts may be shorter than the page size: rows whose post is missing, hidden
// or by a blocked or muted author are dropped after the read (ADR-0024 D6), so the client keeps following
// NextPageToken until it is empty.
type LikesPage struct {
	// Posts are the live posts, most recently liked first.
	Posts []*posts.Post
	// Hints are the render hints of Posts, same length and order.
	Hints []RowHint
	// Viewer is the caller's viewer state for Posts (posts.HydrateViewer): the zero set when no row is left.
	Viewer posts.ViewerSet
	// NextPageToken is "" when this was the last page.
	NextPageToken string
}
