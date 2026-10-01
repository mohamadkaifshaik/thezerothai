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
// Media and embedded posts are not modelled yet: P1 writes root posts only (ADR-0010 D2: kind POST, isReply
// false, conversationId = postId, visibility PUBLIC, all counters 0), and the replies, media and engagement
// slices add their fields.
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
	LikeCount       int64
	RepostCount     int64
	ReplyCount      int64
	QuoteCount      int64
	Visibility      Visibility
	SnapshotVersion int64
	// CreatedAt is the Snowflake's millisecond timestamp (ADR-0010 D18), so (CreatedAt, ID) order equals id order.
	CreatedAt time.Time
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

// Service is the Connect handler's dependency. T8/T9 extend it with CreatePost, DeletePost and GetPost; it is
// a Reader today.
type Service interface {
	Reader
}

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
)

// ErrNotFound is returned by Reader.Get for a missing or deleted post. Callers map it at their own boundary;
// GetPost uses one message for every not-found cause (ADR-0010 D6).
var ErrNotFound = errors.New("posts: post not found")

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
