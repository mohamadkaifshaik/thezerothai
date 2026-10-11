// Package posts owns posts/{postId} (ADR-0003 data model, ADR-0010 slice decisions). It exposes Service
// (consumed by server.go, the Connect handler), Reader (consumed by the timeline module and other modules; they
// never query `posts` directly, ADR-0004 handoff), PostEvents (a no-op post-commit hook until notifications,
// P6) and the Eraser/Exporter seams the account-lifecycle job and opsctl use (implemented in T10).
//
// posts depends on identity's api.go interfaces (Directory, Counters) and graph.Reader only; neither imports
// posts, and timeline imports only this file's interfaces.
package posts

import (
	"context"
	"errors"
	"io"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Kind mirrors postsv1.PostKind as a plain Go type (no proto import at the domain-model layer; server.go
// converts at the boundary). The Firestore doc stores the upper-case name ("POST", "REPLY", ...).
type Kind string

const (
	KindPost   Kind = "POST"
	KindReply  Kind = "REPLY"
	KindQuote  Kind = "QUOTE"
	KindRepost Kind = "REPOST"
)

// Visibility mirrors postsv1.Visibility. P1 writes only VisibilityPublic (private accounts are deferred,
// ADR-0008 D1).
type Visibility string

const (
	VisibilityPublic    Visibility = "PUBLIC"
	VisibilityFollowers Visibility = "FOLLOWERS"
)

// AuthorSnapshot is the author's denormalised profile copy stored in the post (ADR-0003: refreshed lazily by a
// job when a profile changes, P2), so rendering a post never joins to users/*.
type AuthorSnapshot struct {
	UserID      string
	Handle      string
	DisplayName string
	AvatarURL   string
	Verified    bool
}

// Mention is a resolved @mention: the lower-case handle as resolved at write time (ADR-0010 D7).
type Mention struct {
	UserID string
	Handle string
}

// Post is the domain representation of posts/{postId}. A *Post held by the caches is immutable and shared by
// the posts cache and the author-recent cache: never mutate one you received from a Reader.
//
// Embedded posts are not modelled yet: root posts write kind POST, isReply false, conversationId = postId,
// visibility PUBLIC, all counters 0 (ADR-0010 D2), and the replies and engagement slices add their fields. Media
// (P4) is the published image refs the post carries, in request order.
type Post struct {
	ID              string
	AuthorID        string
	Author          AuthorSnapshot
	Kind            Kind
	IsReply         bool
	Text            string
	ReplyToID       string
	ReplyToHandle   string
	ConversationID  string
	QuoteOfID       string
	RepostOfID      string
	Hashtags        []string
	Mentions        []Mention
	Media           []MediaRef
	LikeCount       int64
	RepostCount     int64
	ReplyCount      int64
	QuoteCount      int64
	Visibility      Visibility
	SnapshotVersion int64
	// CreatedAt is the Snowflake's millisecond timestamp (ADR-0010 D18), so (CreatedAt, ID) order equals id order.
	CreatedAt time.Time
}

// MediaRef is one image of a post (common.v1.MediaRef): the URLs are the published public-bucket objects, copied
// into the post at create time so rendering a post never reads media/*. ThumbURL is always set; list views show
// it and never fall back to URL (review #110 M2).
type MediaRef struct {
	ID       string
	URL      string
	ThumbURL string
	Width    int
	Height   int
	Blurhash string
	AltText  string
}

// Position is a (createdAt, postId) point in the createdAt-descending order every post query uses.
type Position struct {
	CreatedAt time.Time
	ID        string
}

// Window bounds a createdAt-descending post query. Before, when set, resumes strictly below that position (the
// oldest item already returned); After, when set, stops strictly above that position (a timeline gap's old
// `since`), so a bounded page never reads an item at or below it.
type Window struct {
	Before *Position
	After  *Position
}

// Reader is posts' read-only seam for other modules (timeline, later search and notifications). Every method
// is cache-first, every query has a Limit, and every Firestore read is charged to the request's
// budget.Counter (an empty query costs 1 read).
//
// Posts returned are shared and immutable.
//
// A Reader applies NO visibility or relationship filtering: it returns every matching post, including those by
// blocked, muting, suspended or deleting authors. Callers must filter per ADR-0010 D6 (block, mute and author
// status via graph.Reader and identity.Directory) before returning anything to a client.
type Reader interface {
	// Get returns one post, or ErrNotFound. Cache hit: 0 reads; miss: 1 read.
	Get(ctx context.Context, id string) (*Post, error)
	// GetMany returns the posts that exist for ids (at most MaxGetMany, duplicates ignored); missing ids are
	// absent from the map. Cached ids cost 0; the rest are fetched in one GetAll, 1 read each.
	GetMany(ctx context.Context, ids []string) (map[string]*Post, error)
	// ByAuthors returns root posts (isReply == false) by any of authorIDs (at most MaxByAuthors), newest first,
	// inside window, at most limit (clamped to 1..50). The caller passes only the authors the author-recent
	// cache does not cover. Reads: len(result), minimum 1.
	ByAuthors(ctx context.Context, authorIDs []string, window Window, limit int) ([]*Post, error)
	// ByAuthor returns one author's posts, newest first, inside window, at most limit (clamped to 1..50).
	// includeReplies=false restricts to root posts (the Posts tab); true is the Replies-tab query with no
	// isReply filter. Reads: len(result), minimum 1.
	ByAuthor(ctx context.Context, authorID string, includeReplies bool, window Window, limit int) ([]*Post, error)

	// AuthorRecent returns authorID's author-recent entry if it is still fresh (loaded within the cache TTL).
	// It also serves as the profile Posts-tab first-page cache (ADR-0010 D15). 0 reads.
	AuthorRecent(authorID string) (Recent, bool)
	// StoreAuthorRecent records an author's newest root posts (newest first; at most MaxRecent are kept).
	// truncated=true means the author may have older posts than the entry holds. loadedAt is when the data
	// was read (the query start), which timelines use to bound the since watermark (ADR-0010 D13).
	StoreAuthorRecent(authorID string, newest []*Post, truncated bool, loadedAt time.Time)
}

// Recent is an author-recent cache entry: the author's newest root posts, newest first.
type Recent struct {
	Posts []*Post
	// Truncated is true when the author may have root posts older than the entry holds.
	Truncated bool
	// LoadedAt is when the entry's data was read from Firestore (or last known complete).
	LoadedAt time.Time
}

// Service is the Connect handler's dependency: the Reader plus CreatePost (T8), DeletePost and GetPost (T9).
type Service interface {
	Reader
	// Create writes one root post for uid (ADR-0010 D2, T8). It returns the stored post, or, for a replayed
	// idempotency key, the post the first call created. Worst-case Firestore cost: see the CreatePost proto
	// comment (14 reads cold / 2 warm, 4 writes; replay 14 cold / 1 warm, 0 writes).
	Create(ctx context.Context, uid string, in CreateInput) (*Post, error)
	// Delete removes uid's own post (ADR-0010 D4, T9). Success for every other case (another user's post, an
	// unknown or already-deleted id) with 0 writes: no existence oracle. Firestore: reads 1 (the post; 0 when
	// cached) plus the interceptor's profile read; writes 1 (users.postsCount -1) + 1 delete (Exists precondition).
	Delete(ctx context.Context, uid, idempotencyKey, postID string) error
	// GetForViewer returns one post as seen by callerUID (ADR-0010 D6 GetPost column), or the one NOT_FOUND
	// "post not found" answer for a missing, deleted, hidden, blocked-author or non-ACTIVE-author post.
	// Firestore: reads post 1 + author users 1 + caller graph 1 cold (+1 author graph if the caller's blockedBy
	// overflowed), 0 warm; writes 0.
	GetForViewer(ctx context.Context, callerUID, postID string) (*Post, error)
}

// CreateInput is the CreatePost request at the domain layer (server.go converts from the proto). Slice-2+
// fields are carried only so the service can reject them uniformly (FEATURE_DISABLED, ADR-0010 D2).
type CreateInput struct {
	IdempotencyKey string
	Text           string
	MediaIDs       []string
	MediaAltTexts  []string
	ReplyToPostID  string
	QuoteOfPostID  string
	// MediaEnabled is FEATURE_MEDIA for the caller (set by server.go from the flag registry). When false, media
	// ids and alt texts are rejected FEATURE_DISABLED("media"), exactly as before P4.
	MediaEnabled bool
}

// ErrMediaNotReady is returned by Repo.Create when a media id is missing, not the caller's, not a READY POST
// image, or already attached to another post (one answer: no oracle). The service maps it to
// FAILED_PRECONDITION + MEDIA_NOT_READY.
var ErrMediaNotReady = errors.New("posts: media not ready")

// MediaClaim is a validated set of the caller's READY images, loaded inside the CreatePost transaction.
type MediaClaim interface {
	// Refs are the published refs in request order (AltText unset: the post owns the alt texts).
	Refs() []MediaRef
	// Attach marks every image as belonging to postID in the same batch that creates the post.
	Attach(b store.Batch, postID string)
}

// MediaAttacher is the consumer-side seam to the media module (ADR-0002); apiserver adapts media.Library.
type MediaAttacher interface {
	// LoadForPost reads ids inside tx (len(ids) reads, before the transaction's first write) and returns the
	// claim, or ErrMediaNotReady.
	LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (MediaClaim, error)
}

// PostDeleteJobs publishes the post_delete background job (P4; P5 reuses it for likes/reposts clean-up). It is
// called once, after DeletePost's commit, for a post that has dependants (today: images). An error is logged and
// never fails the delete: the post is already gone and the objects are also removed by the account purge.
type PostDeleteJobs interface {
	PostDeleted(ctx context.Context, uid, postID string, mediaIDs []string) error
}

// ErrIdempotencyKeyReused is returned by Repo.Create when the idempotency key was already used for a different
// request body (the service maps it to INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED).
var ErrIdempotencyKeyReused = errors.New("posts: idempotency key reused with a different request")

// Limits (ADR-0010 D15, ADR-0004).
const (
	// MaxGetMany is the most ids one GetMany takes (Firestore GetAll batch, rule 6).
	MaxGetMany = 50
	// MaxByAuthors is the most authors one ByAuthors query takes (Firestore `in` limit).
	MaxByAuthors = 30
	// MaxLimit is the largest query Limit (CLAUDE.md rule 5).
	MaxLimit = 50
	// MaxRecent is how many newest root posts one author-recent entry holds.
	MaxRecent = 20
	// MaxMedia is the most images one post carries (ADR-0005).
	MaxMedia = 4
)

// ErrNotFound is returned by Reader.Get for a missing or deleted post. Callers map it at their own boundary;
// GetPost uses one message for every not-found cause (ADR-0010 D6).
var ErrNotFound = errors.New("posts: post not found")

// ErrInvalidID is returned by Get and GetMany for an empty id or one containing "/": never a post id, and
// refused before any cache lookup or read. RPC handlers validate ids (^[0-9]{19}$) first; this is the backstop.
var ErrInvalidID = errors.New("posts: invalid post id")

// PostEvents is a post-commit hook, a no-op until notifications (P6, ADR-0010): "CreatePost calls
// PostEvents.Created after a commit; replays don't". Never called inside the transaction or its budget.
type PostEvents interface {
	Created(ctx context.Context, p *Post)
	Deleted(ctx context.Context, postID, authorID string)
}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning; because every
// page is the newest remaining posts and deleted docs drop out of the next page, the purge is self-resuming
// and the checkpoint only carries progress for logging.
type Checkpoint struct {
	// Deleted counts posts removed so far across calls.
	Deleted int
}

// Eraser is the delete-cascade building block (ADR-0010 D19 Q-E), used by opsctl purge-posts now and later the
// account-lifecycle job. PurgeUser is resumable: call again with the returned checkpoint until done is true.
// Implemented in T10.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint Checkpoint) (next Checkpoint, done bool, err error)
}

// Exporter writes one user's posts as the manual data export (ADR-0003 "Deletes & privacy"). Implemented in T10.
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}
