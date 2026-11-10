// Package posts owns posts/{postId}. It exposes Service
// (consumed by server.go, the Connect handler), Reader (consumed by the timeline module and other modules; they
// never query `posts` directly), PostEvents (a no-op post-commit hook until notifications)
// and the Eraser/Exporter seams the account-lifecycle job and opsctl use (implemented later).
//
// posts depends on identity's api.go interfaces (Directory, Counters) and graph.Reader only; neither imports
// posts, and timeline imports only this file's interfaces.
package posts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ReplyPolicy is who may reply in a conversation, stored on the first post of the conversation and
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

// Visibility mirrors postsv1.Visibility. Posts are written as VisibilityPublic only (private accounts are deferred).
type Visibility string

const (
	VisibilityPublic    Visibility = "PUBLIC"
	VisibilityFollowers Visibility = "FOLLOWERS"
)

// Moderation is a post's moderation state. The Firestore doc stores the upper-case name, absent
// when the post is visible. A hidden post is dropped by every read path and consumer.
type Moderation string

const (
	// ModerationNone is the zero value: the post is visible.
	ModerationNone Moderation = ""
	// ModerationTakenDown: a moderator removed this post (opsctl takedown-post). Reversible with restore-post.
	ModerationTakenDown Moderation = "TAKEN_DOWN"
	// ModerationSuspendedAuthor: hidden because its author is suspended (opsctl suspend-user).
	// unsuspend-user restores exactly these.
	ModerationSuspendedAuthor Moderation = "SUSPENDED_AUTHOR"
)

// AuthorSnapshot is the author's denormalised profile copy stored in the post (refreshed lazily by a job when a profile changes),
// so rendering a post never joins to users/*.
type AuthorSnapshot struct {
	UserID      string
	Handle      string
	DisplayName string
	AvatarURL   string
	Verified    bool
}

// Mention is a resolved @mention: the lower-case handle as resolved at write time.
type Mention struct {
	UserID string
	Handle string
}

// Post is the domain representation of posts/{postId}. A *Post held by the caches is immutable and shared by
// the posts cache and the author-recent cache: never mutate one you received from a Reader.
//
// Embedded posts are not modelled yet: root posts write kind POST, isReply false, conversationId = postId,
// visibility PUBLIC, all counters 0, and the replies and engagement slices add their fields. Media
// is the published image refs the post carries, in request order.
type Post struct {
	Article       *ArticlePreview
	ID            string
	AuthorID      string
	Author        AuthorSnapshot
	Kind          Kind
	IsReply       bool
	Text          string
	ReplyToID     string
	ReplyToHandle string
	// ReplyToAuthorID is the parent post's author (the reply's notification recipient). It is TRANSIENT:
	// set only on the *Post that CreatePost hands to PostEvents.Created (from the parent already read by the reply
	// validation) and never persisted: a Post read back from Firestore leaves it empty.
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
	// Moderation is the moderation state. Readers return hidden posts WITH this field set: every
	// consumer must drop them (Visible), exactly like it drops blocked authors.
	Moderation Moderation
	// CreatedAt is the Snowflake's millisecond timestamp, so (CreatedAt, ID) order equals id order.
	CreatedAt time.Time
	// PaidPartnership and MadeWithAI are the author's own content-disclosure labels: user assertions,
	// never detected or verified. Absent on legacy docs = false. A REPOST carries none of its own (its original's
	// labels travel in Embedded).
	PaidPartnership bool
	MadeWithAI      bool
	// ReplyPolicy is the conversation's effective reply policy: the author's choice on a root post or
	// a quote, the value copied from the parent on a reply. Absent = EVERYONE. A REPOST has none of its own (the
	// original's travels in Embedded). No user id is ever stored with it.
	ReplyPolicy ReplyPolicy
	// HasMedia mirrors the stored posts.hasMedia: true when the post carries its own images; always false
	// for a REPOST (its original's images live in Embedded). toDoc writes it from HasMediaFor on every create path, so it
	// is derived from Media at write time and never set by a caller; a legacy doc written before W3 reads false until
	// `opsctl backfill-has-media` ran. Only the ByAuthorMedia query (the Media tab index) filters on the stored field.
	HasMedia bool
	// Poll is the root post's poll, nil for every other post. Read-only once cached: a writer builds a new one.
	Poll *Poll
	// CommunityID is the community feed key: set only on a root POST or QUOTE created into a community, never on a reply
	// or a REPOST. Absent = not a community post (no backfill). Community is the label snapshot taken at post time; ConversationCommunityID
	// is the conversation's community, set on the community root and inherited by every reply (the members-only reply key).
	CommunityID             string
	Community               *CommunityLabel
	ConversationCommunityID string
	// CommunityHidden is the label switch only: a moderator hide sets it, a restore clears it. It never feeds Hidden() or
	// the audience; ToView drops the community label while it is true. Absent = false.
	CommunityHidden bool
	// BeaconID is the plan this root post shares (CreatePostRequest.beacon_id), "" for none, and Beacon its snapshot frozen at
	// create time (never put on the wire: the live card comes from BeaconPlans.Previews, see beaconToProto).
	BeaconID string
	Beacon   *BeaconSnapshot
}

// CommunityLabel is the community {id, name} snapshot a community post stores: a rename does not rewrite old posts.
type CommunityLabel struct {
	ID   string
	Name string
}

// Hidden reports whether a moderator action hides the post from every viewer.
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

// Embedded is the frozen one-level snapshot a QUOTE or REPOST carries of the post it copies. The
// author snapshot is not refreshed by the profile-snapshot job. A tombstone has only PostID and Unavailable set.
type Embedded struct {
	Article     *ArticlePreview
	PostID      string
	Author      AuthorSnapshot
	Text        string
	Media       []MediaRef
	CreatedAt   time.Time
	Unavailable bool
	// PaidPartnership and MadeWithAI are the embedded post's disclosure labels, frozen with the snapshot
	// (review I-6: the embed shows its own labels).
	PaidPartnership bool
	MadeWithAI      bool
	// ReplyPolicy is the embedded post's effective reply policy, frozen with the snapshot: the viewer hint of a
	// REPOST row reads it (review I-6).
	ReplyPolicy ReplyPolicy
	// Poll is the frozen poll definition of the copied post: labels and closing time, no counts. Nil when the
	// copied post has no poll.
	Poll *EmbeddedPoll
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
	// ContentType is the full object's type (common.MediaRef.content_type), copied from the media claim.
	// Empty on refs stored before W6 (a still JPEG or WebP).
	ContentType string
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
// is cache-first and every query has a Limit.
//
// Posts returned are shared and immutable.
//
// A Reader applies NO visibility or relationship filtering: it returns every matching post, including those by
// blocked, muting, suspended or deleting authors, and posts a moderator hid (Post.Hidden). Callers
// must filter (block, mute and author status via graph.Reader and identity.Directory) and drop
// every post with !Visible() before returning anything to a client.
type Reader interface {
	// Get returns one post, or ErrNotFound. A cached post is served from memory.
	Get(ctx context.Context, id string) (*Post, error)
	// GetMany returns the posts that exist for ids (at most MaxGetMany, duplicates ignored); missing ids are
	// absent from the map. Cached ids are served from memory; the rest are fetched in one GetAll.
	GetMany(ctx context.Context, ids []string) (map[string]*Post, error)
	// ByAuthors returns root posts (isReply == false) by any of authorIDs (at most MaxByAuthors), newest first,
	// inside window, at most limit (clamped to 1..50). The caller passes only the authors the author-recent
	// cache does not cover.
	ByAuthors(ctx context.Context, authorIDs []string, window Window, limit int) ([]*Post, error)
	// ByAuthor returns one author's posts, newest first, inside window, at most limit (clamped to 1..50).
	// includeReplies=false restricts to root posts (the Posts tab); true is the Replies-tab query with no
	// isReply filter.
	ByAuthor(ctx context.Context, authorID string, includeReplies bool, window Window, limit int) ([]*Post, error)

	// ByAuthorMedia returns authorID's posts that carry their own images (hasMedia == true: root posts, replies and
	// quotes with images, never a REPOST), newest first, inside window (Before resumes strictly older; After is the
	// since bound), at most limit (clamped to 1..50). Query: authorId == X && hasMedia == true ORDER BY createdAt DESC,
	// __name__ DESC, served by the composite index posts(authorId, hasMedia, createdAt desc). It does no cache read and no cache write other
	// than filling the posts cache. Same contract as ByAuthor: NO visibility, block or mute filtering (the timeline
	// applies the drop rules) and posts a moderator hid come back with Hidden() true. Must not be called in a project where that
	// index is not READY and `opsctl backfill-has-media` has not run (the emulator does not enforce indexes; Firestore
	// answers FAILED_PRECONDITION without it): the timeline gates the call on the profile_tabs flag.
	ByAuthorMedia(ctx context.Context, authorID string, window Window, limit int) ([]*Post, error)
	// ByAuthorKind returns authorID's posts of one kind (the Reposts tab passes KindRepost), newest first, inside
	// window, at most limit (clamped to 1..50). Query: authorId == X && kind == K ORDER BY createdAt DESC, __name__
	// DESC, served by the composite index posts(authorId, kind, createdAt desc). An empty or unknown kind is
	// refused before any read. Filtering and the index precondition are ByAuthorMedia's: the timeline drops a
	// REPOST whose embedded author the viewer blocks or mutes (or who blocks the viewer) and every !Visible() row.
	ByAuthorKind(ctx context.Context, authorID string, kind Kind, window Window, limit int) ([]*Post, error)

	// ByHashtag returns posts whose stored hashtags contain tag (a bare lower-case NFC body: no "#", no spaces; the
	// caller normalises), newest first, inside window, at most limit (clamped to 1..50). Query: hashtags
	// array-contains tag ORDER BY createdAt DESC, __name__ DESC on the existing composite index posts(hashtags CONTAINS,
	// createdAt DESC); no new index. A REPOST stores hashtags [] so it never matches. Results fill the posts cache like
	// ByAuthor. Unfiltered: NO visibility, block, mute or audience filtering; posts a
	// moderator hid come back with Hidden() true and protected authors' posts come back too, so the caller (search)
	// must drop !Visible and decide each post through posts.Audience with SurfaceList.
	ByHashtag(ctx context.Context, tag string, window Window, limit int) ([]*Post, error)
	// ByCommunity returns the posts listed in community cid (communityId == cid: root posts and quotes, never a reply or a REPOST; a
	// moderator hide removes the key), newest first, inside window, at most limit (clamped to 1..50). It is its own query, `communityId == cid
	// ORDER BY __name__ DESC` with id-bound windows (automatic single-field index, proven on dzeroth-dev), never the createdAt
	// order of the other methods. Before resumes strictly older (StartAfter), After stops strictly newer (EndBefore); an After whose id is
	// the all-zero sentinel (the timeline settle watermark) is the inclusive EndAt of the smallest Snowflake of its
	// millisecond. Results fill the posts cache. Unfiltered like every Reader method: the caller drops
	// !Visible() rows and applies blocks, mutes and audience.
	ByCommunity(ctx context.Context, cid string, window Window, limit int) ([]*Post, error)
	// CreatedAfter returns posts created strictly after the watermark, OLDEST first (createdAt ASC, __name__ ASC), at
	// most limit (default 20, clamped to MaxCreatedAfterLimit 500), for the trends sweep. With an empty
	// after.ID the bound is createdAt only; otherwise it resumes strictly after the (createdAt, id) pair. Query on the
	// automatic single-field indexes (no composite). The result is PROJECTED: only ID, AuthorID, Hashtags, Moderation,
	// CreatedAt and Kind are set; every other field (text, media, counts, visibility, author snapshot) is zero. Such a
	// post is partial, so it is NEVER stored in the posts cache or the author-recent cache and callers must not pass it
	// to either. Unfiltered like the rest of the Reader: the sweep drops !Visible(), REPOST kinds
	// and protected authors itself.
	CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error)

	// AuthorRecent returns authorID's author-recent entry if it is still fresh (loaded within the cache TTL).
	// It also serves as the profile Posts-tab first-page cache; it never reads Firestore.
	AuthorRecent(authorID string) (Recent, bool)
	// StoreAuthorRecent records an author's newest root posts (newest first; at most MaxRecent are kept).
	// truncated=true means the author may have older posts than the entry holds. loadedAt is when the data
	// was read (the query start), which timelines use to bound the since watermark.
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

// Removals is the seam timeline uses (amendment 2026-10-18 (b)).
type Removals interface {
	// RemovedSince returns the ids of posts a moderator removed after cutoff and has not restored, restricted to
	// the authors in scope (the feed being refreshed), newest first, at most RemovalMaxIDs. An empty scope returns
	// nothing without a query. truncated=true means the answer would be incomplete for THIS feed (the cutoff is older
	// than the log keeps, the window the instance cache lacks could not be queried for this scope, or more than
	// RemovalMaxIDs match): the caller must make the client reset instead of trusting ids.
	RemovedSince(ctx context.Context, cutoff time.Time, scope RemovalScope) (ids []string, truncated bool, err error)
}

// Service is the Connect handler's dependency: the Reader plus CreatePost, DeletePost and GetPost.
type Service interface {
	Reader
	// Create writes one root post for uid. It returns the stored post, or, for a replayed
	// idempotency key, the post the first call created.
	Create(ctx context.Context, uid string, in CreateInput) (*Post, error)
	// Delete removes uid's own post. Success for every other case (another user's post, an
	// unknown or already-deleted id), with nothing written: no existence oracle. A real delete
	// decrements users.postsCount and deletes the post under an Exists precondition.
	Delete(ctx context.Context, uid, idempotencyKey, postID string) error
	// GetForViewer returns one post as seen by callerUID, or the one NOT_FOUND
	// "post not found" answer for a missing, deleted, hidden, blocked-author or non-ACTIVE-author post.
	// Nothing is written.
	GetForViewer(ctx context.Context, callerUID, postID string) (*Post, error)
	// GetThread returns a post with its parent, conversation root and a page of the conversation (plan
	// replies-and-threads.md). Same visibility rules as GetForViewer for the focal post; an unavailable
	// parent/root is flagged, not an error.
	GetThread(ctx context.Context, callerUID string, in ThreadInput) (*Thread, error)
}

// CreateInput is the CreatePost request at the domain layer (server.go converts from the proto). Slice-2+
// fields are carried only so the service can reject them uniformly (FEATURE_DISABLED).
type CreateInput struct {
	// Trusted module input; the public CreatePost handler never sets it.
	ArticlePublication ArticlePublication
	// Article is trusted internal publication metadata; ordinary PostService requests cannot set it.
	Article        *ArticlePreview
	IdempotencyKey string
	Text           string
	MediaIDs       []string
	MediaAltTexts  []string
	ReplyToPostID  string
	QuoteOfPostID  string
	// MediaEnabled is FEATURE_MEDIA for the caller (set by server.go from the flag registry). When false, media
	// ids and alt texts are rejected FEATURE_DISABLED("media"), exactly as before then.
	MediaEnabled bool
	// GifEnabled is FEATURE_GIF for the caller, made by server.go (never from the request). A GIF media doc with it false is
	// FEATURE_DISABLED (metadata feature=gif); the content type is only known from the claim, so the refusal happens in the
	// transaction after the media read and writes nothing.
	GifEnabled bool
	// QuotesEnabled is the FEATURE_QUOTES AND FEATURE_ENGAGEMENT decision for the caller, made by server.go (never from the request).
	// A non-empty QuoteOfPostID with it false is FEATURE_DISABLED (metadata feature=quotes).
	QuotesEnabled bool
	// RepliesEnabled is the FEATURE_REPLIES decision for the caller, made by server.go (never from the request).
	// A non-empty ReplyToPostID with it false is FEATURE_DISABLED (metadata feature=replies).
	RepliesEnabled bool
	// PaidPartnership and MadeWithAI are the user-asserted disclosure labels. Either true with
	// DisclosureEnabled false is FEATURE_DISABLED (metadata feature=content_disclosure); nothing else is rejected.
	PaidPartnership bool
	MadeWithAI      bool
	// DisclosureEnabled is the FEATURE_CONTENT_DISCLOSURE decision for the caller, made by server.go (never from
	// the request).
	DisclosureEnabled bool
	// ReplyPolicy is the raw postsv1.ReplyPolicy number of the request; the service validates it, so
	// EVERYONE, FOLLOWING_OF_FOLLOWING, VERIFIED and unknown numbers all reach the checks. ReplyAudienceEnabled is
	// the FEATURE_REPLY_AUDIENCE decision for the caller, made by server.go (never from the request): a non-zero
	// ReplyPolicy with it false is FEATURE_DISABLED (metadata feature=reply_audience). Only SETTING is gated;
	// enforcement of a stored policy never consults it.
	ReplyPolicy          int32
	ReplyAudienceEnabled bool
	// Poll is the request's poll (CreatePostRequest.poll), nil for none; PollsEnabled is the FEATURE_POLLS decision for
	// the caller, made by server.go (never from the request). A poll with PollsEnabled false is FEATURE_DISABLED (metadata
	// feature=polls), checked after content_disclosure. The service validates it (poll.go) against PollLimits.
	Poll         *PollInput
	PollsEnabled bool
	// CommunityID is the request's community_id, "" for none; CommunitiesEnabled is the FEATURE_COMMUNITIES decision for the
	// caller, made by server.go (never from the request). A set CommunityID is FEATURE_DISABLED (metadata feature=communities),
	// checked after polls: with the flag off for the caller, and with it on while no CommunityGate is wired, so the post is never created
	// as an ordinary one. With the flag on and a gate wired, Create validates the shape (VALIDATION community_id / reply_policy) and runs
	// the gate (community_gate.go).
	CommunityID        string
	CommunitiesEnabled bool
	// CommunitiesGloballyOff is FEATURE_COMMUNITIES off for everyone (the kill switch; server.go, never from the request): a reply into a
	// community conversation then skips CommunityGate.CanReply.
	CommunitiesGloballyOff bool
	// BeaconID is the request's beacon_id, "" for none; BeaconEmbedEnabled is the FEATURE_POST_BEACON_EMBED decision for the
	// caller, made by server.go (never from the request). A set BeaconID with it false, or with no BeaconPlans wired, is
	// FEATURE_DISABLED (metadata feature=post_beacon_embed), checked after polls and before any read.
	BeaconID           string
	BeaconEmbedEnabled bool
}

// ArticlePublication loads the frozen draft inside the root post transaction;
// its claim finalizes the article in the same atomic unit of work.
type ArticlePublication interface {
	LoadForPublish(context.Context, *firestore.Transaction) (ArticlePublicationClaim, error)
}

// ArticleReader returns indexed original article roots in chronological windows.
// It is separate from Reader so older consumer adapters remain compatible.
type ArticleReader interface {
	ByAuthorArticles(context.Context, string, Window, int) ([]*Post, error)
}
type ArticlePublicationClaim interface{ Publish(store.Batch, string) }

// ErrMediaNotReady is returned by Repo.Create when a media id is missing, not the caller's, not a READY POST
// image, or already attached to another post (one answer: no oracle). The service maps it to
// FAILED_PRECONDITION + MEDIA_NOT_READY.
var ErrMediaNotReady = errors.New("posts: media not ready")

// ErrGifDisabled is returned by Repo.Create when the claim holds a GIF and FEATURE_GIF is off for the caller
// (CreateParams.GifEnabled false; the second gate). The service maps it to FEATURE_DISABLED feature=gif.
var ErrGifDisabled = errors.New("posts: gif is disabled")

// ErrGifNotAlone is returned when a GIF is attached next to another image (VALIDATION media_ids).
var ErrGifNotAlone = errors.New("posts: a gif must be the only image")

// ErrGifNotSchedulable is returned by Repo.CreateScheduled for a draft that carries a GIF (VALIDATION media_ids).
var ErrGifNotSchedulable = errors.New("posts: a gif cannot be scheduled")

// MediaClaim is a validated set of the caller's READY images, loaded inside the CreatePost transaction.
type MediaClaim interface {
	// Refs are the published refs in request order (AltText unset: the post owns the alt texts).
	Refs() []MediaRef
	// HasGIF reports whether any image is a GIF. The content-type table stays in media; posts only asks.
	HasGIF() bool
	// Attach marks every image as belonging to postID in the same batch that creates the post.
	Attach(b store.Batch, postID string)
}

// MediaAttacher is the consumer-side seam to the media module; apiserver adapts media.Library.
type MediaAttacher interface {
	// LoadForPost reads ids inside tx (before the transaction's first write) and returns the
	// claim, or ErrMediaNotReady.
	LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (MediaClaim, error)
}

// PostDeleteJobs publishes the post_delete background job (media, likes/reposts/quotes). It is
// called once, after DeletePost's commit, for every deleted post (mediaIDs may be empty). An error is logged and
// never fails the delete: the post is already gone and the dependants are also removed by the account purge.
type PostDeleteJobs interface {
	PostDeleted(ctx context.Context, uid, postID string, mediaIDs []string) error
}

// PostDeleteOutbox makes the post_delete job durable (*outbox.Outbox implements it). DeletePost stages one item
// (kind PostDeleteOutboxKind, key = the post id, payload = PostDeleteWork) in the delete batch itself, publishes after the
// commit as before and calls Done when the publish succeeded. A lost publish or a crash leaves the item, and the outbox
// sweep (apiserver) republishes it through the same PostDeleteJobs.PostDeleted; the job's steps are idempotent.
type PostDeleteOutbox interface {
	Stage(b store.Batch, e outbox.Entry) error
	Done(ctx context.Context, e outbox.Entry) error
}

// PostDeleteOutboxKind is the outbox kind of a deleted post's pending post_delete publish.
const PostDeleteOutboxKind = "post_delete"

// PostDeleteWork is the outbox payload: the PostDeleteJobs.PostDeleted arguments.
type PostDeleteWork struct {
	UID      string   `json:"uid"`
	PostID   string   `json:"postId"`
	MediaIDs []string `json:"mediaIds"`
}

// PostDeleteEntry builds the outbox entry of a deleted post (deterministic id post_delete:<postId>).
func PostDeleteEntry(uid, postID string, mediaIDs []string) (outbox.Entry, error) {
	w := PostDeleteWork{UID: uid, PostID: postID, MediaIDs: mediaIDs}
	if err := w.validate(); err != nil {
		return outbox.Entry{}, err
	}
	data, err := json.Marshal(w)
	if err != nil {
		return outbox.Entry{}, fmt.Errorf("posts: encode post_delete work: %w", err)
	}
	e := outbox.Entry{Kind: PostDeleteOutboxKind, Key: postID, UID: uid, Payload: data}
	return e, e.Validate()
}

// DecodePostDeleteWork parses and validates an outbox payload written by PostDeleteEntry.
func DecodePostDeleteWork(data []byte) (PostDeleteWork, error) {
	var w PostDeleteWork
	if err := json.Unmarshal(data, &w); err != nil {
		return w, fmt.Errorf("posts: decode post_delete work: %w", err)
	}
	return w, w.validate()
}

func (w PostDeleteWork) validate() error {
	if !ids.ValidUID(w.UID) || !ids.ValidPostID(w.PostID) {
		return errors.New("posts: post_delete work: invalid uid or post id")
	}
	return nil
}

// EngagementFlagName is the wire name of FEATURE_ENGAGEMENT. It gates the quote path of CreatePost
// and viewer-flag hydration here; engagement.FlagName is the same string and gates its own RPCs. FEATURE_POSTS is
// still required.
const EngagementFlagName = "engagement"

// BookmarksFlagName is the wire name of FEATURE_BOOKMARKS; engagement.BookmarksFlagName is the same
// string and gates its own RPCs. Here it only widens viewer-state hydration (HydrateViewer).
const BookmarksFlagName = "bookmarks"

// ViewerSet is what a viewer has liked, reposted and bookmarked, from one userLikes read.
// The zero value means "nothing", which is also what every flag is while FEATURE_ENGAGEMENT is off. A ViewerSet is
// read-only.
type ViewerSet struct {
	liked, reposted, bookmarked map[string]struct{}
	// pollChoice maps a poll post id to the 0-based choice the viewer made (userLikes.pollVotes). Read-only.
	pollChoice map[string]int
	// pollsOff is true when FEATURE_POLLS is globally off: nobody can vote, so every poll shows its results.
	pollsOff bool
	// communitiesOff is true when FEATURE_COMMUNITIES is globally off: ToView drops PostView.post.community (the kill switch).
	communitiesOff bool
	// blockedAuthors is the viewer's outgoing block set (graph snapshot.Blocked), set by the producers that show a post by an author the viewer
	// blocks (GetPost, GetThread, the author's profile timeline) and read only by ToViewAt for viewer_poll_vote_blocked. Read-only.
	blockedAuthors map[string]bool
	// beacons is the live plan state of the page (WithBeacons) and beaconsOff is FEATURE_POST_BEACON_EMBED globally off
	// (ToView drops Post.beacon). Read-only.
	beacons    map[string]BeaconLive
	beaconsOff bool
}

// NewViewerSet builds a ViewerSet from post-id lists (no bookmarks).
func NewViewerSet(liked, reposted []string) ViewerSet {
	return NewViewerSetWithBookmarks(liked, reposted, nil)
}

// NewViewerSetWithBookmarks is NewViewerSet plus the ids the viewer bookmarked (userLikes.bookmarks).
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
// FEATURE_ENGAGEMENT off may see, so the wider hydration never leaks like or repost flags.
// The poll choices go with them; the polls-globally-off mark stays (it is not viewer state).
func (v ViewerSet) BookmarksOnly() ViewerSet {
	return ViewerSet{bookmarked: v.bookmarked, pollsOff: v.pollsOff, communitiesOff: v.communitiesOff, beacons: v.beacons, beaconsOff: v.beaconsOff}
}

// WithPollVotes returns v plus the viewer's poll choices, from userLikes.pollVotes entries "<postId>:<index>[:<closesAtUnix>]" (newest last).
// A malformed entry is skipped. v itself is not changed (a ViewerSet is read-only and shared by the engagement cache).
func (v ViewerSet) WithPollVotes(votes []string) ViewerSet {
	if len(votes) == 0 {
		return v
	}
	m := make(map[string]int, len(votes))
	for _, e := range votes {
		id, rest, ok := strings.Cut(e, ":")
		if !ok || id == "" {
			continue
		}
		choice, _, _ := strings.Cut(rest, ":") // the optional third part is the closing time: not needed here
		n, err := strconv.Atoi(choice)
		if err != nil || n < 0 || n >= MaxPollChoices {
			continue
		}
		m[id] = n
	}
	v.pollChoice = m
	return v
}

// WithBlockedAuthors returns v plus the viewer's blocked authors (graph.Snapshot.Blocked, already in hand at the producer). ToViewAt reads it
// for PostView.viewer_poll_vote_blocked and nothing else. v itself is not changed; the map is shared and never written.
func (v ViewerSet) WithBlockedAuthors(blocked map[string]bool) ViewerSet {
	v.blockedAuthors = blocked
	return v
}

// PollVoteBlocked reports whether p carries a live poll the viewer cannot vote in because they block its author: the poll is open at now, the
// viewer is not the author and the author is in the blocked set. A REPOST or QUOTE row has no poll of its own (embedded polls are frozen, D5),
// so it is false there.
func (v ViewerSet) PollVoteBlocked(p *Post, viewer string, now time.Time) bool {
	return p.Poll != nil && !p.Poll.Closed(now) && viewer != p.AuthorID && v.blockedAuthors[p.AuthorID]
}

// WithPollsGloballyOff returns v marked so that every poll shows its results (FEATURE_POLLS is off for everyone).
func (v ViewerSet) WithPollsGloballyOff() ViewerSet {
	v.pollsOff = true
	return v
}

// WithCommunitiesGloballyOff returns v marked so that ToView carries no community label (FEATURE_COMMUNITIES is off for everyone).
func (v ViewerSet) WithCommunitiesGloballyOff() ViewerSet {
	v.communitiesOff = true
	return v
}

// PollChoice reports the 0-based choice the viewer made on the poll behind p; for a REPOST item it describes the original
// (embedded.post_id), as Flags does. voted is false for a viewer with no recorded vote, including one whose engagement flag is off.
func (v ViewerSet) PollChoice(p *Post) (index int, voted bool) {
	index, voted = v.pollChoice[viewerID(p)]
	return index, voted
}

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

// HydrateViewer is the one place that decides whether and how a request hydrates viewer state: nothing when
// neither FEATURE_ENGAGEMENT nor FEATURE_BOOKMARKS is on for uid, the full set with engagement on, and the bookmarks
// alone (liked and reposted stripped) with only FEATURE_BOOKMARKS on.
// Staleness bound: the userLikes instance cache TTL (60 s).
// A set from here also carries the polls-globally-off mark, flag lookups only, even when it is otherwise empty.
func HydrateViewer(ctx context.Context, fc FlagChecker, vf ViewerFlags, uid string) ViewerSet {
	if fc == nil {
		return ViewerSet{}
	}
	var base ViewerSet
	if g, ok := fc.(GloballyOffChecker); ok && g.GloballyOff(PollsFlagName) {
		base = base.WithPollsGloballyOff()
	}
	if g, ok := fc.(GloballyOffChecker); ok && g.GloballyOff(CommunitiesFlagName) {
		base = base.WithCommunitiesGloballyOff()
	}
	if vf == nil {
		return base
	}
	engagement := fc.Enabled(uid, EngagementFlagName)
	if !engagement && !fc.Enabled(uid, BookmarksFlagName) {
		return base
	}
	vs := vf.Viewer(ctx, uid)
	if !engagement {
		vs = vs.BookmarksOnly()
	}
	if base.pollsOff {
		vs = vs.WithPollsGloballyOff()
	}
	if base.communitiesOff {
		vs = vs.WithCommunitiesGloballyOff()
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

// Engagement is posts' read/cache seam for the engagement module. It is implemented by the
// concrete service returned by New (apiserver type-asserts it, like identity.Directory), so Service and every
// fake of it stay unchanged.
type Engagement interface {
	// Viewable returns the post if the caller may see it by the GetPost rules (missing, deleted, hidden, blocked
	// or non-ACTIVE author are the single ErrNotFound). It reads like GetPost (the post, its
	// author and the caller's graph) and sets no request-log fields.
	Viewable(ctx context.Context, callerUID, postID string) (*Post, error)
	// RefuseShare is the write rule, called by RepostPost on the post Viewable returned (CreatePost applies
	// it to a quote target itself): a protected author's post can be reposted or quoted only by that author; any other
	// caller who passed Viewable gets FAILED_PRECONDITION PROTECTED_ACCOUNT, with no read or write. UNAVAILABLE when the
	// protected set is unknown.
	RefuseShare(ctx context.Context, callerUID string, p *Post) error
	// CountsChanged applies deltas to the instance copy of a post (copy on write), after a commit.
	CountsChanged(postID string, likeDelta, repostDelta int64)
	// PollVoted applies one committed vote for choice (0-based) to the instance copy of the poll post (copy on write, a new Poll
	// with fresh counts) and returns the updated post, or nil when the post is not cached.
	PollVoted(postID string, choice int) *Post
	// PollVoteChanged applies one committed vote change from choice from to choice to (both 0-based) to the instance copy: Post.VoteChanged, a
	// new Poll, each count clamped at 0, total unchanged. nil when the post is not cached.
	PollVoteChanged(postID string, from, to int) *Post
	// RepostCreated caches a REPOST this instance just committed: posts cache, author-recent, and the author's
	// postsCount via identity.Directory.Forget.
	RepostCreated(p *Post)
	// RepostRemoved drops a REPOST this instance removed from the caches and Forgets the author's profile.
	RepostRemoved(authorID, repostID string)
}

// ErrIdempotencyKeyReused is returned by Repo.Create when the idempotency key was already used for a different
// request body (the service maps it to INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED).
var ErrIdempotencyKeyReused = errors.New("posts: idempotency key reused with a different request")

// Limits.
const (
	// MaxGetMany is the most ids one GetMany takes (Firestore GetAll batch, rule 6).
	MaxGetMany = 50
	// MaxByAuthors is the most authors one ByAuthors query takes (Firestore `in` limit).
	MaxByAuthors = 30
	// MaxLimit is the largest query Limit (the query-limit rule).
	MaxLimit = 50
	// MaxCreatedAfterLimit is the largest Reader.CreatedAfter page (trends sweep).
	MaxCreatedAfterLimit = 500
	// MaxRecent is how many newest root posts one author-recent entry holds.
	MaxRecent = 20
	// MaxMedia is the most images one post carries.
	MaxMedia = 4
)

// ErrNotFound is returned by Reader.Get for a missing or deleted post. Callers map it at their own boundary;
// GetPost uses one message for every not-found cause.
var ErrNotFound = errors.New("posts: post not found")

// ErrInvalidID is returned by Get and GetMany for an empty id or one containing "/": never a post id, and
// refused before any cache lookup or read. RPC handlers validate ids (^[0-9]{19}$) first; this is the backstop.
var ErrInvalidID = errors.New("posts: invalid post id")

// PostEvents is a post-commit hook, a no-op until notifications: "CreatePost calls
// PostEvents.Created after a commit; replays don't". Never called inside the transaction.
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
	// live in other users' REPOST and QUOTE docs are removed. A checkpoint written earlier
	// decodes as phase 0. Phase 2 deletes the user's postRemovals entries (amendment 2026-10-18 (b)).
	Phase int `json:"Phase,omitempty"`
	// Copies counts REPOST docs removed and QUOTE embeds tombstoned in phase 1.
	Copies int `json:"Copies,omitempty"`
}

// Eraser is the delete-cascade building block, used by opsctl purge-posts now and later the
// account-lifecycle job. PurgeUser is resumable: call again with the returned checkpoint until done is true.
// Implemented.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint Checkpoint) (next Checkpoint, done bool, err error)
}

// Exporter writes one user's posts as the manual data export ("Deletes & privacy"). Implemented.
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
	// PageCommunityPosts is an OUTPUT of HideAuthor, replaced on every call (an input value is ignored): the posts of the page it just
	// processed that carry a communityId, hidden by this call or already hidden, so that opsctl can append them to each community's
	// recentRemovals and a re-run after a crash between the two steps still finds them. A moderator-hidden community post
	// has no communityId (its log entry exists already) and is not listed. Empty for RestoreAuthor.
	PageCommunityPosts []CommunityPostRef
}

// CommunityPostRef names one community post of a HideAuthor page: the community it was created into and its id. No uid.
type CommunityPostRef struct {
	CommunityID string
	PostID      string
}

// ModerationResult is what Moderator.Takedown and Restore found.
type ModerationResult struct {
	// CommunityID is the community the post was created into (its communityId), "" for any other post, a REPOST, or a post a community
	// moderator hid (that hide already logged it). Read from the document the call already reads.
	CommunityID string
	AuthorID    string
	// Before and After are the moderation state before and after the call.
	Before, After Moderation
	// RepostReleased is set when a takedown hit a REPOST: the doc was deleted and its reposts record, the original's
	// repostCount and the reposter's postsCount were released (issue #153), so there is nothing left to restore.
	RepostReleased bool
}

// Moderator is the moderator-action seam used by opsctl. It never runs in the API process, so
// it does not touch the instance caches: serving instances converge within CACHE_TTL (60 s).
type Moderator interface {
	// Takedown sets TAKEN_DOWN on one post (ErrNotFound when it does not exist). A post already hidden by a
	// suspension becomes TAKEN_DOWN (the stronger state, which unsuspend does not undo). It writes the post and its
	// postRemovals entry, and nothing when already TAKEN_DOWN.
	// A REPOST is not hidden but removed: its doc is deleted and the reposts record and counters released (see
	// ModerationResult.RepostReleased); Restore then reports ErrNotFound and the user can repost again.
	Takedown(ctx context.Context, postID string, now time.Time) (ModerationResult, error)
	// Restore clears TAKEN_DOWN (ErrNotFound when missing). A SUSPENDED_AUTHOR post is left unchanged: only
	// unsuspend-user restores those. It writes the post and a RESTORED entry, and nothing when not TAKEN_DOWN.
	Restore(ctx context.Context, postID string, now time.Time) (ModerationResult, error)
	// HideAuthor sets SUSPENDED_AUTHOR on every post of uid whose moderation is empty, one page of up to 250 per
	// call, newest first. Resumable and idempotent: re-running from the zero checkpoint is safe. It writes two
	// documents per post changed (the update and its postRemovals entry, one atomic batch).
	HideAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (next ModerationCheckpoint, done bool, err error)
	// RestoreAuthor clears SUSPENDED_AUTHOR on uid's posts (TAKEN_DOWN posts are untouched), one page of up to 250
	// per call (now is the operator's clock, used only for the log entries' expireAt), writing two documents per post (the update and a RESTORED postRemovals entry). Cleared documents
	// leave the query, so it is self-resuming.
	RestoreAuthor(ctx context.Context, uid string, cp ModerationCheckpoint, now time.Time) (next ModerationCheckpoint, done bool, err error)
}
