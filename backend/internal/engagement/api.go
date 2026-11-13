// Package engagement is the module: likes and reposts (quotes are CreatePost in posts). It owns
// likes/{postId}_{uid}, reposts/{postId}_{uid} and userLikes/{uid}. It never touches posts/* directly: counters,
// the REPOST post doc and the clean-up of dependants go through posts' EngagementWriter / Cleanup / Engagement
// seams, and users.postsCount through identity.Counters.
//
// Operations are state-setting and keyed by (post, caller), so a replay or ten concurrent calls converge on one
// effect: the idempotency_key is validated for format and needs no stored record.
//
// Bookmarks also live here: users/{uid}/bookmarks/{postId} and userLikes.bookmarks, behind the Bookmarks and
// BookmarkRepo seams. Unlike likes they store an idempotency doc (rule 4), and they emit no event.
package engagement

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// FlagName is the wire name RPCs check (FEATURE_ENGAGEMENT <-> "engagement"). It is the same string
// posts.EngagementFlagName gates the quote path and viewer flags with.
const FlagName = posts.EngagementFlagName

// BookmarksFlagName is the wire name of FEATURE_BOOKMARKS. AddBookmark needs it on for the caller;
// ListBookmarks and RemoveBookmark only need it not globally off. It is independent of FlagName (engagement).
const BookmarksFlagName = posts.BookmarksFlagName

// Limits.
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

// Result is what every RPC returns: the post's engagement as this instance now knows it.
type Result struct {
	// PostID is the post the action applied to: the original when the request named a REPOST.
	PostID                 string
	LikeCount, RepostCount int64
	// ShareCount is the post's shareCount from the same read (plus RecordPostShare's own change).
	ShareCount       int64
	LikedByViewer    bool
	RepostedByViewer bool
	// RepostPostID is the REPOST post doc a RepostPost created or found (empty for the other RPCs).
	RepostPostID string
}

// Service is the Connect handler's dependency.
type Service interface {
	// Like likes a post for uid. The transaction writes the like doc, likeCount and userLikes; a replay
	// writes nothing. The visibility check (post, author, caller graph) runs first.
	Like(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// Unlike removes uid's like. The post for the returned counts comes cache first. It updates likeCount and
	// userLikes and deletes the like doc; a no-op writes nothing.
	Unlike(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// Repost reposts a post for uid. It reads as Like and writes the reposts doc, the REPOST post, repostCount,
	// postsCount and userLikes; a replay writes nothing.
	Repost(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
	// UndoRepost removes uid's repost of the ORIGINAL postID. It reads the reposts doc and the original (cache
	// first); a no-op writes nothing.
	UndoRepost(ctx context.Context, uid, idempotencyKey, postID string) (Result, error)
}

// UserLikes is the userLikes/{uid} document: the ids the user liked and reposted most recently, newest last, and the
// complete bookmark set.
type UserLikes struct {
	Recent        []string
	RecentReposts []string
	// Bookmarks is the complete set of the user's bookmarked post ids, at most the per-user cap.
	Bookmarks []string
	// PollVotes are the entries "<postId>:<index>:<closesAtUnix>" (two-part in older entries) of the polls the user voted in, newest last. Written only by VotePoll.
	PollVotes []string
}

// Repo is the storage seam service.go depends on; repo_firestore.go implements it, tests use a fake.
type Repo interface {
	// LoadUserLikes reads userLikes/{uid}. A missing doc is an empty UserLikes, not an error.
	LoadUserLikes(ctx context.Context, uid string) (UserLikes, error)
	// Like runs the like transaction. replayed is true when the like already existed (nothing is written).
	Like(ctx context.Context, p LikeParams) (replayed bool, err error)
	// Unlike removes the like. removed is false for a no-op. A post that is gone is handled inside (the counter
	// is dropped and the delete is retried alone).
	Unlike(ctx context.Context, uid, postID string) (removed bool, err error)
	// Repost runs the repost transaction.
	Repost(ctx context.Context, p RepostParams) (RepostResult, error)
	// UndoRepost deletes the repost of originalID, if any.
	UndoRepost(ctx context.Context, uid, originalID string) (UndoResult, error)
	// TrimLikes removes ids from userLikes.recent (best effort).
	TrimLikes(ctx context.Context, uid string, recent, reposts []string) error
}

// LikeParams is one like transaction.
type LikeParams struct {
	UID, PostID string
}

// RepostParams is one repost transaction.
type RepostParams struct {
	UID string
	// Original is the post being reposted (never a REPOST: the service resolved it, D4).
	Original *posts.Post
	// Author and SnapshotVersion are the reposter's denormalised profile for the REPOST doc.
	Author          posts.AuthorSnapshot
	SnapshotVersion int64
}

// RepostResult is the outcome of Repo.Repost: exactly one of Post (a new REPOST, committed) and ReplayPostID.
type RepostResult struct {
	Post         *posts.Post
	ReplayPostID string
}

// UndoResult is the outcome of Repo.UndoRepost.
type UndoResult struct {
	// Removed is false when there was no repost (a no-op, nothing is written).
	Removed bool
	// RepostPostID is the REPOST post doc that was deleted.
	RepostPostID string
}

// Events is the post-commit notification seam. apiserver adapts it to notifications.Emitter. It is
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

// Eraser is the delete-cascade building block; PurgeUser is resumable.
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

// BookmarkState is the caller's bookmark state of one post after AddBookmark or RemoveBookmark.
type BookmarkState struct {
	// PostID is the post the action applied to: the original when AddBookmark named a REPOST.
	PostID string
	// Bookmarked is true after AddBookmark (also for a post that was already bookmarked), false after RemoveBookmark.
	Bookmarked bool
}

// Bookmarks is the bookmark seam of the module: the Connect handler depends on it, a later split into
// its own service changes no caller. It reads posts only through posts.Engagement.Viewable, emits no event and
// notifies nobody; a bookmark is private to the caller.
type Bookmarks interface {
	// AddBookmark bookmarks postID (a REPOST id: its original) for uid. It runs the visibility check, then reads
	// idempotency and userLikes; a replay stops after the idempotency read. It writes the bookmark, the
	// idempotency doc and userLikes; an existing bookmark writes only the idempotency doc (so a late retry
	// replays); a replay and the cap write nothing.
	AddBookmark(ctx context.Context, uid, idempotencyKey, postID string) (BookmarkState, error)
	// RemoveBookmark removes uid's bookmark of postID. No visibility check. It reads the
	// idempotency doc, writes it and userLikes, and deletes the bookmark; a missing bookmark writes only the
	// idempotency doc; a replay writes nothing.
	RemoveBookmark(ctx context.Context, uid, idempotencyKey, postID string) (BookmarkState, error)
	// ListBookmarks returns one page of uid's bookmarks, newest first, as live posts. pageSize 0 is
	// 20, clamped to 50; pageToken is empty for the first page. A foreign, expired or tampered token is VALIDATION
	// page_token, rejected before any lookup. It reads the bookmark rows, then GetMany for posts that are not
	// cached, plus the caller's graph snapshot and userLikes, each only when a row is left to render (cached 60 s), and
	// the authors' account status (one cache-first Directory batch; a failure fails the page). It writes nothing, except that a page that prunes missing posts updates userLikes and deletes one row per
	// pruned post.
	ListBookmarks(ctx context.Context, uid string, pageSize int32, pageToken string) (BookmarkPage, error)
}

// BookmarkRow is one bookmark the caller sees now: the live post (a QUOTE of an author who is not ACTIVE is its
// tombstoned copy, posts.TombstonedQuote) and the time it was bookmarked.
type BookmarkRow struct {
	Post         *posts.Post
	BookmarkedAt time.Time
	// Hint is the embed state and protected-author mark the handler applies.
	Hint RowHint
}

// BookmarkPage is one page of ListBookmarks. Rows may be shorter than the page size: rows whose post is missing,
// hidden, by a blocked or muted author, or by an author who is not ACTIVE (F-03) are dropped after the read, so the client keeps following
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
	// BookmarkUnchanged means the state already held (Add of an existing bookmark, Remove of a missing one): only the idempotency doc is written.
	BookmarkUnchanged
)

// AddBookmarkParams is one AddBookmark transaction.
type AddBookmarkParams struct {
	UID string
	// PostID is the original's id (the service resolved a REPOST id): the bookmark doc id.
	PostID string
	// IdemKey is idempotency.Key(uid, "AddBookmark", key); RequestHash is the hash of the post_id as sent.
	IdemKey, RequestHash string
	// MaxPerUser is the hard cap of bookmarks (1,000).
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
	// Add runs the AddBookmark transaction. It returns ErrBookmarkLimit at the cap and
	// ErrIdempotencyKeyReused for a key used with another post_id.
	Add(ctx context.Context, p AddBookmarkParams) (BookmarkResult, error)
	// Remove runs the RemoveBookmark transaction. It returns ErrIdempotencyKeyReused like Add.
	Remove(ctx context.Context, p RemoveBookmarkParams) (BookmarkResult, error)
	// ListPage returns uid's bookmarks strictly after `after` (nil = from the newest), newest first by
	// (createdAt, post id), at most limit (clamped to 1..MaxListPage). It is the same query as the export
	// (ExportBookmarksPage).
	ListPage(ctx context.Context, uid string, after *posts.Position, limit int) ([]ExportedBookmark, error)
	// Prune deletes the bookmark docs of ids (posts that no longer exist) and removes the ids from
	// userLikes.bookmarks, in one batch: a field-level userLikes update and a delete per id.
	// Blind: a doc another request already pruned is deleted again without error. At most MaxListPage ids.
	Prune(ctx context.Context, uid string, ids []string) error
}

// MaxListPage is the largest ListBookmarks page (the query-limit rule).
const MaxListPage = limits.MaxPageSize

// LikesList is the likes-list seam of the module: the Connect handler depends on it, a later
// split into its own service (or a `likes (uid, createdAt)` index or SQL table at Stage 2/3) changes no caller. It is
// owner-only (there is no user id in the request), reads posts only through posts.Reader.GetMany, writes nothing and
// notifies nobody.
type LikesList interface {
	// ListLikedPosts returns one page of uid's own likes, most recently liked first, as live posts.
	// pageSize 0 is 20, clamped to 1..50; pageToken is empty for the first page. A foreign, expired or tampered token
	// is VALIDATION page_token, rejected before any lookup. The ids come from userLikes.recent (the last MaxRecentLikes likes) through
	// the 60 s instance cache. It reads userLikes, GetMany for posts that are not cached, and the caller's graph
	// snapshot (only when a row of someone else is live) and the authors' account status (one cache-first Directory
	// batch; a failure fails the page); the viewer state reuses the same userLikes state. It
	// writes nothing, and nothing is pruned: a row whose post is gone is only dropped from the page.
	ListLikedPosts(ctx context.Context, uid string, pageSize int32, pageToken string) (LikesPage, error)
}

// LikesPage is one page of ListLikedPosts. Posts may be shorter than the page size: rows whose post is missing, hidden,
// by a blocked or muted author, or by an author who is not ACTIVE (F-03) are dropped after the read, so the client keeps following
// NextPageToken until it is empty.
type LikesPage struct {
	// Posts are the live posts, most recently liked first (a QUOTE of an author who is not ACTIVE is its tombstoned copy).
	Posts []*posts.Post
	// Hints are the render hints of Posts, same length and order.
	Hints []RowHint
	// Viewer is the caller's viewer state for Posts (posts.HydrateViewer): the zero set when no row is left.
	Viewer posts.ViewerSet
	// NextPageToken is "" when this was the last page.
	NextPageToken string
}

// Polls is the poll-voting seam of the module: the Connect handler depends on it (NewServer detects it on the
// Service, as LikesList), a later split into its own service changes no caller. It reads posts only through
// posts.Engagement.Viewable and posts.EngagementWriter.StagePollVote.
type Polls interface {
	// VotePoll records uid's one vote in the poll of postID (a REPOST id: its original), or changes it until the poll closes.
	// expectedChoice is VotePollRequest.expected_choice: 0 = "I hold no vote", 1..4 = the choice the caller believes it holds, as index + 1;
	// a different choice is a change only when it names the stored vote (the A2.2 table), else ALREADY_VOTED. The voter blocking the author is
	// TARGET_BLOCKED (A1), after the closed and range checks. A change reads the vote doc first and writes in one batch
	// (vote doc, post counters, userLikes twice); a replay, ALREADY_VOTED, LIMIT_REACHED and every refusal write
	// nothing. A first vote runs the visibility check (post, author users, caller graph) and reads userLikes for
	// the response's viewer flags; a replay or ALREADY_VOTED reads the vote doc too. A first vote writes in one batch
	// (vote doc, the post's poll.counts.<i> and poll.total in one Update, userLikes.pollVotes); the vote doc is
	// removed later by its TTL.
	VotePoll(ctx context.Context, uid, idempotencyKey, postID string, choiceIndex, expectedChoice int32) (PollVote, error)
}

// PollVote is what the handler renders for VotePoll: the poll's post (the original when the request named a REPOST) with the
// committed counts, the viewer set for it (flags from the userLikes cache; the choice from this call's vote) and the render hint.
type PollVote struct {
	Post   *posts.Post
	Viewer posts.ViewerSet
	Hint   RowHint
}

// VoteOutcome says what PollRepo.Vote did.
type VoteOutcome int

const (
	// VoteWritten means the batch committed: vote doc, counters and userLikes entry.
	VoteWritten VoteOutcome = iota
	// VoteExists means the vote doc already existed (AlreadyExists): nothing was written.
	VoteExists
	// VotePostGone means the post was deleted before the commit (the counter Update found no document): nothing was written.
	VotePostGone
)

// ChangeOutcome says what PollRepo.ChangeVote did.
type ChangeOutcome int

const (
	// ChangeWritten means the batch committed: vote doc, counters and both userLikes writes.
	ChangeWritten ChangeOutcome = iota
	// ChangeStale means a precondition failed (the vote doc moved since it was read, or the post is gone): nothing was written. The service
	// re-reads the vote doc to tell the two apart.
	ChangeStale
)

// VoteState is the vote doc as GetVote reads it: the stored 0-based choice, how many times it was changed, and the document's UpdateTime (the
// version a change is made against).
type VoteState struct {
	Choice, Changes int
	UpdateTime      time.Time
}

// ChangeParams is one vote change batch: From is the stored choice read at Version (VoteState.UpdateTime), To the new one (both 0-based).
type ChangeParams struct {
	UID, PostID string
	From, To    int
	Version     time.Time
	// ClosesAt and ExpireAt are the poll's closing time and the vote's TTL time (closesAt + POLL_VOTE_TTL_AFTER_CLOSE): the userLikes entry is
	// "<postId>:<choice>:<closesAtUnix>" (poll_retention.go), and its expiry day goes into pollVotesDueDays.
	ClosesAt, ExpireAt time.Time
}

// VoteParams is one vote batch.
type VoteParams struct {
	UID, PostID string
	// Choice is the 0-based index. ExpireAt is the vote doc's TTL time (closesAt + POLL_VOTE_TTL_AFTER_CLOSE).
	Choice   int
	ExpireAt time.Time
	// ClosesAt is the poll's closing time: it goes into the userLikes entry (poll_retention.go).
	ClosesAt time.Time
}

// PollRepo is the storage seam of VotePoll; repo_polls.go implements it, tests use a fake.
type PollRepo interface {
	// Vote commits the vote batch (no read). AlreadyExists is VoteExists; a missing post is VotePostGone; exhausted contention is an
	// error wrapping store.ErrContended.
	Vote(ctx context.Context, p VoteParams) (VoteOutcome, error)
	// GetVote reads pollVotes/{postId}_{uid} found is false for a missing document.
	GetVote(ctx context.Context, uid, postID string) (state VoteState, found bool, err error)
	// ChangeVote commits one vote change as a blind batch (no reads): the vote doc is updated under a
	// LastUpdateTime precondition equal to p.Version, the post counters move by StagePollChange, and userLikes.pollVotes loses the entry of From
	// and gains the entry of To (two writes to one document in one commit). A failed precondition is ChangeStale; exhausted contention is an
	// error wrapping store.ErrContended.
	ChangeVote(ctx context.Context, p ChangeParams) (ChangeOutcome, error)
	// TrimPollVotes removes entries from userLikes.pollVotes (field-level, best effort, no read).
	TrimPollVotes(ctx context.Context, uid string, drop []string) error
}

// ShareFlagName is the wire name of FEATURE_SHARE_COUNT: RecordPostShare needs it on for the caller, and a direct-message
// share (Shares.Record) is recorded while it is not globally off.
const ShareFlagName = "share_count"

// ShareResult is RecordPostShare's answer: the post's engagement as the caller now sees it, and whether this call created
// the caller's postShares marker.
type ShareResult struct {
	Result
	Counted bool
}

// PostShares is the RecordPostShare seam of the module: the Connect handler depends on it (NewServer detects it on the
// Service, like Polls). It reads posts only through posts.Engagement and writes posts/{id}.shareCount only through
// posts.EngagementWriter.StageShareCount.
type PostShares interface {
	// RecordShare records that uid shared postID (a REPOST id: its original) outside the app, once per (uid, post), merged
	// with direct-message shares. channel is a request-log value only (never stored). The rules and the order of the
	// checks are the RPC's (engagement.proto): shape, then the GetPost visibility check, then a protected author's post or
	// the caller's own post answer success with nothing written, then one marker read and, on a first share, one batch
	// (marker Create + shareCount Increment).
	RecordShare(ctx context.Context, uid, idempotencyKey, postID, channel string) (ShareResult, error)
}

// Shares is the seam messaging's post share records through (adapted in apiserver; messaging does not import
// engagement). Record is best effort for the caller: it is called after a direct message that shares postID committed.
type Shares interface {
	// Record counts uid's share of postID (the ORIGINAL post id, already visible to uid and never a protected author's
	// post unless uid is its author) once per (uid, post). It writes nothing when FEATURE_SHARE_COUNT is globally off,
	// when uid is the post's author, or when the marker exists: one cache-first post read and one marker read, plus on a
	// first share one batch (marker Create + shareCount Increment). counted is true only when this call created the marker.
	Record(ctx context.Context, uid, postID string) (counted bool, err error)
}

// ShareOutcome says what ShareRepo.Create did.
type ShareOutcome int

const (
	// ShareCreated means the batch committed: the marker and shareCount +1.
	ShareCreated ShareOutcome = iota
	// ShareExists means the marker already existed (a concurrent first share won): nothing was written.
	ShareExists
	// SharePostGone means the post was deleted before the commit (the counter Update found no document): nothing was written.
	SharePostGone
)

// ShareRepo is the storage seam of the shares paths; repo_shares.go implements it, tests use a fake.
type ShareRepo interface {
	// HasShare reads postShares/{postId}_{uid}: one read.
	HasShare(ctx context.Context, uid, postID string) (bool, error)
	// CreateShare commits one batch: Create postShares/{postId}_{uid} {postId, uid, createdAt} and Increment
	// posts/{postId}.shareCount (Exists precondition), retried on contention; exhausted contention is an error wrapping
	// store.ErrContended.
	CreateShare(ctx context.Context, uid, postID string) (ShareOutcome, error)
}
