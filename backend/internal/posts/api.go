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

// ReplyPolicy is who may reply in a conversation (ADR-0021 D2), stored on the first post of the conversation and
// copied (never with a user id) onto every reply. The empty value is EVERYONE: legacy docs and EVERYONE both have it.
// The doc stores the upper-case name.
type ReplyPolicy string

const (
	ReplyPolicyEveryone      ReplyPolicy = ""
	ReplyPolicyFollowing     ReplyPolicy = "FOLLOWING"
	ReplyPolicyMentionedOnly ReplyPolicy = "MENTIONED_ONLY"
)

// Restricted reports whether the policy limits who may reply (anything but EVERYONE).
func (r ReplyPolicy) Restricted() bool {
	return r == ReplyPolicyFollowing || r == ReplyPolicyMentionedOnly
}

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

// Moderation is a post's moderation state (ADR-0016 D3). The Firestore doc stores the upper-case name, absent
// when the post is visible. A hidden post is dropped by every read path and consumer.
type Moderation string

const (
	// ModerationNone is the zero value: the post is visible.
	ModerationNone Moderation = ""
	// ModerationTakenDown: a moderator removed this post (opsctl takedown-post). Reversible with restore-post.
	ModerationTakenDown Moderation = "TAKEN_DOWN"
	// ModerationSuspendedAuthor: hidden because its author is suspended (opsctl suspend-user, ADR-0010 D10).
	// unsuspend-user restores exactly these.
	ModerationSuspendedAuthor Moderation = "SUSPENDED_AUTHOR"
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
	ID            string
	AuthorID      string
	Author        AuthorSnapshot
	Kind          Kind
	IsReply       bool
	Text          string
	ReplyToID     string
	ReplyToHandle string
	// ReplyToAuthorID is the parent post's author (the reply's notification recipient, ADR-0017). It is TRANSIENT:
	// set only on the *Post that CreatePost hands to PostEvents.Created (from the parent already read by the reply
	// validation, 0 extra reads) and never persisted: a Post read back from Firestore leaves it empty.
	ReplyToAuthorID string
	ConversationID  string
	QuoteOfID       string
	RepostOfID      string
	// Embedded is the snapshot of the quoted or reposted post (kind QUOTE / REPOST), nil otherwise. It is
	// immutable like the Post that holds it.
	Embedded *Embedded
	// EmbeddedAuthorID is the top-level copy of Embedded.Author.UserID that the Eraser and the moderation cleanup
	// query (the `embedded` map is exempt from indexing); empty for plain posts and for a tombstone.
	EmbeddedAuthorID string
	Hashtags         []string
	Mentions         []Mention
	Media            []MediaRef
	LikeCount        int64
	RepostCount      int64
	ReplyCount       int64
	QuoteCount       int64
	Visibility       Visibility
	SnapshotVersion  int64
	// Moderation is the moderation state (ADR-0016). Readers return hidden posts WITH this field set: every
	// consumer must drop them (Visible), exactly like it drops blocked authors.
	Moderation Moderation
	// CreatedAt is the Snowflake's millisecond timestamp (ADR-0010 D18), so (CreatedAt, ID) order equals id order.
	CreatedAt time.Time
	// PaidPartnership and MadeWithAI are the author's own content-disclosure labels (ADR-0021 D3): user assertions,
	// never detected or verified. Absent on legacy docs = false. A REPOST carries none of its own (its original's
	// labels travel in Embedded).
	PaidPartnership bool
	MadeWithAI      bool
	// ReplyPolicy is the conversation's effective reply policy (ADR-0021 D2): the author's choice on a root post or
	// a quote, the value copied from the parent on a reply. Absent = EVERYONE. A REPOST has none of its own (the
	// original's travels in Embedded). No user id is ever stored with it.
	ReplyPolicy ReplyPolicy
	// HasMedia mirrors the stored posts.hasMedia (ADR-0024 D4): true when the post carries its own images; always false
	// for a REPOST (its original's images live in Embedded). toDoc writes it from HasMediaFor on every create path, so it
	// is derived from Media at write time and never set by a caller; a legacy doc written before W3 reads false until
	// `opsctl backfill-has-media` ran. Only the ByAuthorMedia query (the Media tab index) filters on the stored field.
	HasMedia bool
}

// Hidden reports whether a moderator action hides the post from every viewer (ADR-0016 D3).
func (p *Post) Hidden() bool { return p.Moderation != ModerationNone }

// Visible is !Hidden. Every consumer of Reader results (timelines, thread views, notifications, counts) must
// drop posts for which it is false.
func (p *Post) Visible() bool { return p.Moderation == ModerationNone }

// EmbeddedAuthor is the one derivation of the author of the post a QUOTE or REPOST copies, used by every
// block/mute check on a copy (GetPost, GetThread context, feed filter). Precedence: a tombstone (Embedded
// marked Unavailable) has no author -> ""; else the snapshot's Author.UserID; else the top-level
// EmbeddedAuthorID; "" for plain posts.
func (p *Post) EmbeddedAuthor() string {
	if p.Embedded != nil {
		if p.Embedded.Unavailable {
			return ""
		}
		if p.Embedded.Author.UserID != "" {
			return p.Embedded.Author.UserID
		}
	}
	return p.EmbeddedAuthorID
}

// Embedded is the frozen one-level snapshot a QUOTE or REPOST carries of the post it copies (ADR-0018 D2, D12). The
// author snapshot is not refreshed by the profile-snapshot job. A tombstone has only PostID and Unavailable set.
type Embedded struct {
	PostID      string
	Author      AuthorSnapshot
	Text        string
	Media       []MediaRef
	CreatedAt   time.Time
	Unavailable bool
	// PaidPartnership and MadeWithAI are the embedded post's disclosure labels, frozen with the snapshot
	// (ADR-0021 D3, review I-6: the embed shows its own labels).
	PaidPartnership bool
	MadeWithAI      bool
	// ReplyPolicy is the embedded post's effective reply policy, frozen with the snapshot: the viewer hint of a
	// REPOST row reads it (ADR-0021 D2, review I-6).
	ReplyPolicy ReplyPolicy
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
// blocked, muting, suspended or deleting authors, and posts a moderator hid (Post.Hidden, ADR-0016). Callers
// must filter per ADR-0010 D6 (block, mute and author status via graph.Reader and identity.Directory) and drop
// every post with !Visible() before returning anything to a client.
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

	// ByAuthorMedia returns authorID's posts that carry their own images (hasMedia == true: root posts, replies and
	// quotes with images, never a REPOST), newest first, inside window (Before resumes strictly older; After is the
	// since bound), at most limit (clamped to 1..50). Query: authorId == X && hasMedia == true ORDER BY createdAt DESC,
	// __name__ DESC, served by the W3-2 composite index posts(authorId, hasMedia, createdAt desc) (ADR-0024 D14). Reads:
	// len(result), minimum 1 (charged with AddQueryReads); no cache read and no cache write other than filling the posts
	// cache. Same contract as ByAuthor: NO visibility, block or mute filtering (the timeline applies the drop rules,
	// ADR-0010 D6) and posts a moderator hid come back with Hidden() true. Must not be called in a project where that
	// index is not READY and `opsctl backfill-has-media` has not run (the emulator does not enforce indexes; Firestore
	// answers FAILED_PRECONDITION without it): the timeline gates the call on the profile_tabs flag.
	ByAuthorMedia(ctx context.Context, authorID string, window Window, limit int) ([]*Post, error)
	// ByAuthorKind returns authorID's posts of one kind (the Reposts tab passes KindRepost), newest first, inside
	// window, at most limit (clamped to 1..50). Query: authorId == X && kind == K ORDER BY createdAt DESC, __name__
	// DESC, served by the W3-2 composite index posts(authorId, kind, createdAt desc). An empty or unknown kind is
	// refused before any read. Reads, filtering and the index precondition are ByAuthorMedia's: the timeline drops a
	// REPOST whose embedded author the viewer blocks or mutes (or who blocks the viewer) and every !Visible() row.
	ByAuthorKind(ctx context.Context, authorID string, kind Kind, window Window, limit int) ([]*Post, error)

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

// Removals is the seam timeline uses (ADR-0016 D10, amendment 2026-10-18 (b)).
type Removals interface {
	// RemovedSince returns the ids of posts a moderator removed after cutoff and has not restored, restricted to
	// the authors in scope (the feed being refreshed), newest first, at most RemovalMaxIDs. An empty scope returns
	// nothing with 0 reads. truncated=true means the answer would be incomplete for THIS feed (the cutoff is older
	// than the log keeps, the window the instance cache lacks could not be queried for this scope, or more than
	// RemovalMaxIDs match): the caller must make the client reset instead of trusting ids.
	// Reads: shared cache refresh 0 on a warm hit, otherwise 1-50 (1 when the log is empty or unchanged), 100 at
	// most when the incremental page was full, charged to a detached counter (log field removal_log_reads), not
	// the caller's budget. Window query (cutoff older than the cache's coverage and a feed of at most 180 authors):
	// at most RemovalWindowWorstReads (107), charged to ctx.
	RemovedSince(ctx context.Context, cutoff time.Time, scope RemovalScope) (ids []string, truncated bool, err error)
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
	// GetThread returns a post with its parent, conversation root and a page of the conversation (P3, plan
	// replies-and-threads.md). Same visibility rules as GetForViewer for the focal post; an unavailable
	// parent/root is flagged, not an error. Reads: see ThreadBudget in service_thread.go; writes 0.
	GetThread(ctx context.Context, callerUID string, in ThreadInput) (*Thread, error)
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
	// QuotesEnabled is the FEATURE_QUOTES AND FEATURE_ENGAGEMENT decision for the caller, made by server.go (never from the request).
	// A non-empty QuoteOfPostID with it false is FEATURE_DISABLED (metadata feature=quotes).
	QuotesEnabled bool
	// RepliesEnabled is the FEATURE_REPLIES decision for the caller, made by server.go (never from the request).
	// A non-empty ReplyToPostID with it false is FEATURE_DISABLED (metadata feature=replies).
	RepliesEnabled bool
	// PaidPartnership and MadeWithAI are the user-asserted disclosure labels (ADR-0021 D3). Either true with
	// DisclosureEnabled false is FEATURE_DISABLED (metadata feature=content_disclosure); nothing else is rejected.
	PaidPartnership bool
	MadeWithAI      bool
	// DisclosureEnabled is the FEATURE_CONTENT_DISCLOSURE decision for the caller, made by server.go (never from
	// the request).
	DisclosureEnabled bool
	// ReplyPolicy is the raw postsv1.ReplyPolicy number of the request (ADR-0021 D2); the service validates it, so
	// EVERYONE, FOLLOWING_OF_FOLLOWING, VERIFIED and unknown numbers all reach the checks. ReplyAudienceEnabled is
	// the FEATURE_REPLY_AUDIENCE decision for the caller, made by server.go (never from the request): a non-zero
	// ReplyPolicy with it false is FEATURE_DISABLED (metadata feature=reply_audience). Only SETTING is gated;
	// enforcement of a stored policy never consults it.
	ReplyPolicy          int32
	ReplyAudienceEnabled bool
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

// PostDeleteJobs publishes the post_delete background job (P4 media, P5 likes/reposts/quotes; ADR-0018 D6). It is
// called once, after DeletePost's commit, for every deleted post (mediaIDs may be empty). An error is logged and
// never fails the delete: the post is already gone and the dependants are also removed by the account purge.
type PostDeleteJobs interface {
	PostDeleted(ctx context.Context, uid, postID string, mediaIDs []string) error
}

// EngagementFlagName is the wire name of FEATURE_ENGAGEMENT (ADR-0018 D8). It gates the quote path of CreatePost
// and viewer-flag hydration here; engagement.FlagName is the same string and gates its own RPCs. FEATURE_POSTS is
// still required.
const EngagementFlagName = "engagement"

// BookmarksFlagName is the wire name of FEATURE_BOOKMARKS (ADR-0023 D5); engagement.BookmarksFlagName is the same
// string and gates its own RPCs. Here it only widens viewer-state hydration (HydrateViewer).
const BookmarksFlagName = "bookmarks"

// ViewerSet is what a viewer has liked, reposted and bookmarked, from one userLikes read (ADR-0018 D5, ADR-0023 D3).
// The zero value means "nothing", which is also what every flag is while FEATURE_ENGAGEMENT is off. A ViewerSet is
// read-only.
type ViewerSet struct {
	liked, reposted, bookmarked map[string]struct{}
}

// NewViewerSet builds a ViewerSet from post-id lists (no bookmarks).
func NewViewerSet(liked, reposted []string) ViewerSet {
	return NewViewerSetWithBookmarks(liked, reposted, nil)
}

// NewViewerSetWithBookmarks is NewViewerSet plus the ids the viewer bookmarked (userLikes.bookmarks, ADR-0023 D3).
func NewViewerSetWithBookmarks(liked, reposted, bookmarked []string) ViewerSet {
	v := ViewerSet{
		liked: make(map[string]struct{}, len(liked)), reposted: make(map[string]struct{}, len(reposted)),
		bookmarked: make(map[string]struct{}, len(bookmarked)),
	}
	for _, id := range liked {
		v.liked[id] = struct{}{}
	}
	for _, id := range reposted {
		v.reposted[id] = struct{}{}
	}
	for _, id := range bookmarked {
		v.bookmarked[id] = struct{}{}
	}
	return v
}

// BookmarksOnly returns v without its liked and reposted sets: what a viewer with FEATURE_BOOKMARKS on but
// FEATURE_ENGAGEMENT off may see, so the wider hydration never leaks like or repost flags (ADR-0023 D5).
func (v ViewerSet) BookmarksOnly() ViewerSet { return ViewerSet{bookmarked: v.bookmarked} }

// Bookmarked reports whether the viewer bookmarked the item; for a REPOST item it describes the original
// (embedded.post_id), as Flags does. ToView puts it on the wire as PostView.bookmarked_by_viewer.
func (v ViewerSet) Bookmarked(p *Post) bool {
	_, ok := v.bookmarked[viewerID(p)]
	return ok
}

// viewerID is the id viewer flags are keyed by: the post itself, or the original for a REPOST item.
func viewerID(p *Post) string {
	if p.Kind == KindRepost && p.Embedded != nil && p.Embedded.PostID != "" {
		return p.Embedded.PostID
	}
	return p.ID
}

// Flags returns the viewer's flags for an item. For a REPOST item they describe the original (embedded.post_id),
// as the PostView proto documents.
func (v ViewerSet) Flags(p *Post) (liked, reposted bool) {
	id := viewerID(p)
	_, liked = v.liked[id]
	_, reposted = v.reposted[id]
	return liked, reposted
}

// ViewerFlags is implemented by engagement and consumed by the GetPost/GetThread handlers and the timelines. One
// call is one cached userLikes read per request; a failed read degrades to the zero ViewerSet (never an error).
// Callers go through HydrateViewer, which invokes it only when FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS is on for the
// viewer, so the off path performs no read.
type ViewerFlags interface {
	Viewer(ctx context.Context, uid string) ViewerSet
}

// HydrateViewer is the one place that decides whether and how a request hydrates viewer state: nothing (0 reads) when
// neither FEATURE_ENGAGEMENT nor FEATURE_BOOKMARKS is on for uid, the full set with engagement on, and the bookmarks
// alone (liked and reposted stripped) with only FEATURE_BOOKMARKS on. Cost: one cached userLikes read, 0 extra
// (ADR-0023 D3, D5). Staleness bound: the userLikes instance cache TTL (60 s).
func HydrateViewer(ctx context.Context, fc FlagChecker, vf ViewerFlags, uid string) ViewerSet {
	if vf == nil || fc == nil {
		return ViewerSet{}
	}
	engagement := fc.Enabled(uid, EngagementFlagName)
	if !engagement && !fc.Enabled(uid, BookmarksFlagName) {
		return ViewerSet{}
	}
	vs := vf.Viewer(ctx, uid)
	if !engagement {
		return vs.BookmarksOnly()
	}
	return vs
}

// ReleaseStager is the part of RepostLinks the clean-up paths (opsctl takedown, the account purge) need: the
// blind delete of a reposts doc inside their own batch.
type ReleaseStager interface {
	// StageRelease appends the blind delete of reposts/{originalID}_{uid} to b.
	StageRelease(b store.Batch, originalID, uid string)
}

// RepostLinks is implemented by engagement (it owns reposts/{postId}_{uid}) and consumed by DeletePost: deleting a
// REPOST post is an undo, so the reposts doc goes in the same batch and the counters are released afterwards.
type RepostLinks interface {
	// ReleaseStager's StageRelease is blind: the DeletePost batch's only guard is the post's own Exists
	// precondition, so a missing reposts doc never blocks the post's removal.
	ReleaseStager
	// Released runs after the commit, best effort: repostCount -1 on the original (a gone original is fine) and
	// ArrayRemove on the user's userLikes.recentReposts.
	Released(ctx context.Context, originalID, uid string) error
}

// Engagement is posts' read/cache seam for the engagement module (ADR-0018 D4, D5). It is implemented by the
// concrete service returned by New (apiserver type-asserts it, like identity.Directory), so Service and every
// fake of it stay unchanged.
type Engagement interface {
	// Viewable returns the post if the caller may see it by the GetPost rules (missing, deleted, hidden, blocked
	// or non-ACTIVE author are the single ErrNotFound). It reads like GetPost (post 1, author 1, caller graph 1
	// cold) and sets no request-log fields.
	Viewable(ctx context.Context, callerUID, postID string) (*Post, error)
	// CountsChanged applies deltas to the instance copy of a post (copy on write), after a commit.
	CountsChanged(postID string, likeDelta, repostDelta int64)
	// RepostCreated caches a REPOST this instance just committed: posts cache, author-recent, and the author's
	// postsCount via identity.Directory.Forget.
	RepostCreated(p *Post)
	// RepostRemoved drops a REPOST this instance removed from the caches and Forgets the author's profile.
	RepostRemoved(authorID, repostID string)
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
	// Phase is 0 while the user's own posts are being deleted and 1 while the copies of the user's content that
	// live in other users' REPOST and QUOTE docs are removed (ADR-0018 D14). A checkpoint written before P5
	// decodes as phase 0. Phase 2 deletes the user's postRemovals entries (amendment 2026-10-18 (b)).
	Phase int `json:"Phase,omitempty"`
	// Copies counts REPOST docs removed and QUOTE embeds tombstoned in phase 1.
	Copies int `json:"Copies,omitempty"`
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

// ModerationCheckpoint resumes Moderator.HideAuthor across calls. The zero value starts from the newest post.
type ModerationCheckpoint struct {
	// Changed counts posts updated so far across calls.
	Changed int
	// After is the oldest position already processed (HideAuthor pages newest to oldest). Nil at the start.
	After *Position
	// Since, when non-zero, restricts HideAuthor to posts with createdAt >= Since (the same Q-E index, a range
	// on its first order field). opsctl suspend-user uses it for the settle pass that catches posts created on
	// instances whose cached account status was still ACTIVE when the first pass read their page.
	Since time.Time
}

// ModerationResult is what Moderator.Takedown and Restore found.
type ModerationResult struct {
	AuthorID string
	// Before and After are the moderation state before and after the call.
	Before, After Moderation
	// RepostReleased is set when a takedown hit a REPOST: the doc was deleted and its reposts record, the original's
	// repostCount and the reposter's postsCount were released (issue #153), so there is nothing left to restore.
	RepostReleased bool
}

// Moderator is the moderator-action seam used by opsctl (ADR-0016 D4). It never runs in the API process, so
// it does not touch the instance caches: serving instances converge within CACHE_TTL (60 s).
type Moderator interface {
	// Takedown sets TAKEN_DOWN on one post (ErrNotFound when it does not exist). A post already hidden by a
	// suspension becomes TAKEN_DOWN (the stronger state, which unsuspend does not undo). Reads 1, writes 2 (the post and its
	// postRemovals entry, ADR-0016 D10; 0 when already TAKEN_DOWN).
	// A REPOST is not hidden but removed: its doc is deleted and the reposts record and counters released (see
	// ModerationResult.RepostReleased); Restore then reports ErrNotFound and the user can repost again.
	Takedown(ctx context.Context, postID string, now time.Time) (ModerationResult, error)
	// Restore clears TAKEN_DOWN (ErrNotFound when missing). A SUSPENDED_AUTHOR post is left unchanged: only
	// unsuspend-user restores those. Reads 1, writes 2 (post + RESTORED entry; 0 when not TAKEN_DOWN).
	Restore(ctx context.Context, postID string, now time.Time) (ModerationResult, error)
	// HideAuthor sets SUSPENDED_AUTHOR on every post of uid whose moderation is empty, one page of up to 250 per
	// call, newest first. Resumable and idempotent: re-running from the zero checkpoint is safe. Reads one per
	// post paged (minimum 1), writes two per post changed (the update and its postRemovals entry, one atomic batch).
	HideAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (next ModerationCheckpoint, done bool, err error)
	// RestoreAuthor clears SUSPENDED_AUTHOR on uid's posts (TAKEN_DOWN posts are untouched), one page of up to 250
	// per call (now is the operator's clock, used only for the log entries' expireAt), writing two documents per post (the update and a RESTORED postRemovals entry). Cleared documents
	// leave the query, so it is self-resuming.
	RestoreAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (next ModerationCheckpoint, done bool, err error)
}
