// repo_firestore.go is the Firestore implementation of Repo (`posts/{postId}`).
//
// Every query has a Limit and orders `createdAt DESC, __name__ DESC` explicitly. A composite index carries
// __name__ in the direction of its last field, so these shapes map to the indexes in firebase/firestore.indexes.json:
//
//	Q-H  ByAuthors, authorId in [...] AND isReply == false      -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-P  ByAuthor,  authorId == X AND isReply == false          -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-R  ByAuthor,  authorId == X (Replies tab)                 -> (authorId ASC, createdAt DESC)
//	Q-M ListAuthorMedia, authorId == X AND hasMedia == true -> (authorId ASC, hasMedia ASC, createdAt DESC) []
//	Q-B ListAuthorReposts, authorId == X AND kind == "REPOST" -> (authorId ASC, kind ASC, createdAt DESC) []
package posts

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"cloud.google.com/go/firestore"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const postsCollection = "posts"

// Repo is posts' storage seam; service.go depends on it, FirestoreRepo implements it, and unit tests use an
// in-memory fake. Argument limits (ids <= MaxGetMany, authors <= MaxByAuthors, limit 1..MaxLimit) are
// enforced by the service before the repo is called.
type Repo interface {
	// GetAll fetches posts/{id} for every id in one GetAll. Missing ids are absent from the result.
	GetAll(ctx context.Context, ids []string) (map[string]*Post, error)
	// ByAuthors is Q-H.
	ByAuthors(ctx context.Context, authorIDs []string, w Window, limit int) ([]*Post, error)
	// ByAuthor is Q-P (includeReplies=false) or Q-R (true).
	ByAuthor(ctx context.Context, authorID string, includeReplies bool, w Window, limit int) ([]*Post, error)
	// ByAuthorMedia is Q-M and ByAuthorKind is Q-B (kind is KindRepost for the Reposts tab).
	// They need the composite indexes READY (the emulator does not enforce indexes).
	ByAuthorMedia(ctx context.Context, authorID string, w Window, limit int) ([]*Post, error)
	ByAuthorKind(ctx context.Context, authorID string, kind Kind, w Window, limit int) ([]*Post, error)
	// ByHashtag is Q-T (existing composite index) and CreatedAfter is Q-W (projected, ascending, automatic indexes).
	ByHashtag(ctx context.Context, tag string, w Window, limit int) ([]*Post, error)
	// ByCommunity is the community feed query (repo_community.go): its own `communityId == C ORDER BY __name__ DESC` shape, never run().
	ByCommunity(ctx context.Context, cid string, w Window, limit int) ([]*Post, error)
	CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error)
	// Create runs the CreatePost transaction (repo_create.go). A replay writes
	// nothing. It returns ErrIdempotencyKeyReused for a key used with
	// another request.
	// A community post (p.Community) also reads the member doc fresh in the transaction and writes nothing extra.
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	// DeleteOwn deletes posts/{id} and decrements the author's postsCount in one batch, with an Exists
	// precondition on the post. deleted=false (and nothing is written) when the post is already gone (a concurrent
	// delete won). The batch writes the counter and deletes the post only when deleted.
	//
	// stage functions append further writes to the same batch (DeletePost of a REPOST adds the blind delete of
	// its reposts doc through RepostLinks); they must not add a guarded write of their own.
	DeleteOwn(ctx context.Context, id, authorID string, stage ...func(store.Batch)) (deleted bool, err error)
	// Conversation is Q-T (repo_thread.go): the posts of one conversation, oldest first, strictly after `after`
	// (nil = from the start), at most limit.
	Conversation(ctx context.Context, conversationID string, after *Position, limit int) ([]*Post, error)
	// AddReplyCount applies FieldValue.Increment(delta) to a parent's replyCount. A parent that is gone is not an
	// error. Used by DeletePost for a reply (the create path does it inside the CreatePost transaction).
	AddReplyCount(ctx context.Context, parentID string, delta int64) error
	// AddQuoteCount is AddReplyCount for quoteCount (DeletePost of a QUOTE, best effort).
	AddQuoteCount(ctx context.Context, quotedID string, delta int64) error
}

// FirestoreRepo implements Repo against the shared Firestore client.
type FirestoreRepo struct {
	client *firestore.Client
	w      WriteDeps     // CreatePost collaborators, set by SetWriters
	links  ReleaseStager // engagement's reposts-doc seam (P5), set by SetRepostLinks
	// attemptHook is a test seam: called inside every CreatePost attempt after the id is drawn (and at the start of every
	// CreateScheduled attempt, before its first read, with the scheduled id); an Aborted error makes the SDK retry the
	// transaction. Never set outside tests.
	attemptHook func(attempt int, id string) error
	// moderationReadHook is a test seam: HideAuthor/RestoreAuthor call it between reading a page and committing
	// its batch, so a test can change a post in that window. Never set outside tests.
	moderationReadHook func()
	// Test seams for DeleteOwn's retry loop (store.RetryConfig); nil means real commit and jittered wait.
	commitBatch func(ctx context.Context, b *store.FirestoreBatch) error
	backoff     func(ctx context.Context, ceiling time.Duration) error
}

// NewFirestoreRepo builds the repo on the process-wide Firestore client.
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client}
}

var _ Repo = (*FirestoreRepo)(nil)

// postDoc is the posts/{postId} shape; counters start at 0. Embedded and mentionIds are not
// written yet; media is written from (empty unless the post has images).
type postDoc struct {
	// BeaconID and Beacon are the plan a root post shares and its frozen snapshot; absent = none. Never queried: exempt-able
	// from indexing (see the PR follow-ups).
	BeaconID       string          `firestore:"beaconId,omitempty"`
	Beacon         *beaconDoc      `firestore:"beacon,omitempty"`
	HasArticle     bool            `firestore:"hasArticle"`
	Article        *ArticlePreview `firestore:"article,omitempty"`
	AuthorID       string          `firestore:"authorId"`
	Author         authorDoc       `firestore:"author"`
	Kind           string          `firestore:"kind"`
	IsReply        bool            `firestore:"isReply"`
	Text           string          `firestore:"text"`
	ReplyToID      string          `firestore:"replyToId,omitempty"`
	ReplyToHandle  string          `firestore:"replyToHandle,omitempty"`
	ConversationID string          `firestore:"conversationId"`
	QuoteOfID      string          `firestore:"quoteOfId,omitempty"`
	RepostOfID     string          `firestore:"repostOfId,omitempty"`
	// Embedded is the QUOTE/REPOST snapshot; EmbeddedAuthorID is its top-level, indexed author id.
	Embedded         *embeddedDoc `firestore:"embedded,omitempty"`
	EmbeddedAuthorID string       `firestore:"embeddedAuthorId,omitempty"`
	Hashtags         []string     `firestore:"hashtags"`
	Mentions         []mentionDoc `firestore:"mentions"`
	Media            []mediaDoc   `firestore:"media,omitempty"`
	LikeCount        int64        `firestore:"likeCount"`
	RepostCount      int64        `firestore:"repostCount"`
	ReplyCount       int64        `firestore:"replyCount"`
	QuoteCount       int64        `firestore:"quoteCount"`
	Visibility       string       `firestore:"visibility"`
	SnapshotVersion  int64        `firestore:"snapshotVersion"`
	// Moderation is absent for a visible post; ModeratedAt is when the state last changed.
	Moderation  string     `firestore:"moderation,omitempty"`
	ModeratedAt *time.Time `firestore:"moderatedAt,omitempty"`
	CreatedAt   time.Time  `firestore:"createdAt"`
	// Disclosure labels; absent (omitempty) = false, no backfill.
	PaidPartnership bool `firestore:"paidPartnership,omitempty"`
	MadeWithAI      bool `firestore:"madeWithAi,omitempty"`
	// The conversation's effective reply policy (FOLLOWING | MENTIONED_ONLY); absent = EVERYONE, no
	// backfill. Replies store the value inherited from the parent, never a user id. Exempt from indexing.
	ReplyPolicy string `firestore:"replyPolicy,omitempty"`
	// HasMedia is: len(media) > 0, false for a REPOST. NOT omitempty: the field is stored as an explicit false
	// too, so a doc that lacks it is exactly a pre-W3 doc the backfill still has to visit (a rerun writes nothing) and the
	// (authorId, hasMedia, createdAt) index holds every post. Indexed.
	HasMedia bool `firestore:"hasMedia"`
	// Poll is: root posts with a poll only; absent otherwise, no backfill. The whole map is index-exempt (fieldOverride
	// posts.poll). A vote increments poll.counts.<i> and poll.total with field paths, never a whole-map write.
	Poll *pollDoc `firestore:"poll,omitempty"`
	// CommunityId (the community feed key, root POST or QUOTE only), community {id, name} (label snapshot) and
	// conversationCommunityId (the conversation's community). All omitempty: absent = not a community post, no backfill.
	CommunityID             string        `firestore:"communityId,omitempty"`
	Community               *communityDoc `firestore:"community,omitempty"`
	ConversationCommunityID string        `firestore:"conversationCommunityId,omitempty"`
	CommunityHidden         bool          `firestore:"communityHidden,omitempty"`
}

// communityDoc is the stored label snapshot of a community post.
type communityDoc struct {
	ID   string `firestore:"id"`
	Name string `firestore:"name"`
}

// pollDoc is the stored poll: counts is keyed "0".."n-1" so a vote is Increment(poll.counts.<i>) plus Increment(poll.total).
type pollDoc struct {
	Options     []string         `firestore:"options"`
	DurationMin int              `firestore:"durationMin"`
	ClosesAt    time.Time        `firestore:"closesAt"`
	Counts      map[string]int64 `firestore:"counts"`
	Total       int64            `firestore:"total"`
}

// embeddedPollDoc is the frozen poll definition inside an embed: no counts.
type embeddedPollDoc struct {
	Options  []string  `firestore:"options"`
	ClosesAt time.Time `firestore:"closesAt"`
}

func pollToDoc(p *Poll) *pollDoc {
	if p == nil {
		return nil
	}
	d := &pollDoc{Options: p.Options, DurationMin: p.DurationMin, ClosesAt: p.ClosesAt, Counts: make(map[string]int64, len(p.Options)), Total: p.Total}
	for i := range p.Options {
		var c int64
		if i < len(p.Counts) {
			c = p.Counts[i]
		}
		d.Counts[strconv.Itoa(i)] = c
	}
	return d
}

func (d *pollDoc) toPoll() *Poll {
	if d == nil {
		return nil
	}
	p := &Poll{Options: d.Options, DurationMin: d.DurationMin, ClosesAt: d.ClosesAt.UTC(), Counts: make([]int64, len(d.Options)), Total: d.Total}
	for i := range p.Counts {
		p.Counts[i] = d.Counts[strconv.Itoa(i)]
	}
	return p
}

type authorDoc struct {
	UserID      string `firestore:"userId"`
	Handle      string `firestore:"handle"`
	DisplayName string `firestore:"displayName"`
	AvatarURL   string `firestore:"avatarUrl"`
	Verified    bool   `firestore:"verified"`
}

// embeddedDoc is the stored Embedded snapshot. A tombstone keeps only PostID and Unavailable.
type embeddedDoc struct {
	Article     *ArticlePreview `firestore:"article,omitempty"`
	PostID      string          `firestore:"postId"`
	Author      *authorDoc      `firestore:"author,omitempty"`
	Text        string          `firestore:"text,omitempty"`
	Media       []mediaDoc      `firestore:"media,omitempty"`
	CreatedAt   *time.Time      `firestore:"createdAt,omitempty"`
	Unavailable bool            `firestore:"unavailable,omitempty"`
	// The embedded post's labels, copied by snapshotOf; absent = false.
	PaidPartnership bool `firestore:"paidPartnership,omitempty"`
	MadeWithAI      bool `firestore:"madeWithAi,omitempty"`
	// The embedded post's effective reply policy, copied by snapshotOf; absent = EVERYONE.
	ReplyPolicy string `firestore:"replyPolicy,omitempty"`
	// The embedded post's poll definition, copied by snapshotOf; absent = none.
	Poll *embeddedPollDoc `firestore:"poll,omitempty"`
}

// beaconDoc is the frozen plan snapshot of postDoc.Beacon.
type beaconDoc struct {
	Title       string    `firestore:"title"`
	Activity    int32     `firestore:"activity"`
	StartAt     time.Time `firestore:"startAt"`
	CommunityID string    `firestore:"communityId,omitempty"`
}

func beaconToDoc(b *BeaconSnapshot) *beaconDoc {
	if b == nil {
		return nil
	}
	return &beaconDoc{Title: b.Title, Activity: int32(b.Activity), StartAt: b.StartAt, CommunityID: b.CommunityID}
}

func (d *beaconDoc) snapshot() *BeaconSnapshot {
	if d == nil {
		return nil
	}
	return &BeaconSnapshot{Title: d.Title, Activity: beaconsv1.BeaconActivity(d.Activity), StartAt: d.StartAt.UTC(), CommunityID: d.CommunityID}
}

type mentionDoc struct {
	UserID string `firestore:"userId"`
	Handle string `firestore:"handle"`
}

// mediaDoc is one stored image (data model: url/thumbUrl/width/height/blurhash copied from media/{id}).
type mediaDoc struct {
	MediaID     string `firestore:"mediaId"`
	URL         string `firestore:"url"`
	ThumbURL    string `firestore:"thumbUrl"`
	Width       int    `firestore:"width"`
	Height      int    `firestore:"height"`
	Blurhash    string `firestore:"blurhash,omitempty"`
	AltText     string `firestore:"altText,omitempty"`
	ContentType string `firestore:"contentType,omitempty"`
}

// toDoc converts a domain Post to its stored shape (used by writers, and by integration-test seeding).
func toDoc(p *Post) postDoc {
	d := postDoc{
		BeaconID: p.BeaconID, Beacon: beaconToDoc(p.Beacon),
		HasArticle: p.Kind == KindPost && !p.IsReply && p.Article != nil && p.Article.ArticleID != "",
		Article:    cloneArticle(p.Article),
		AuthorID:   p.AuthorID,
		Author: authorDoc{
			UserID: p.Author.UserID, Handle: p.Author.Handle, DisplayName: p.Author.DisplayName,
			AvatarURL: p.Author.AvatarURL, Verified: p.Author.Verified,
		},
		Kind: string(p.Kind), IsReply: p.IsReply, Text: p.Text,
		ReplyToID: p.ReplyToID, ReplyToHandle: p.ReplyToHandle, ConversationID: p.ConversationID,
		QuoteOfID: p.QuoteOfID, RepostOfID: p.RepostOfID, EmbeddedAuthorID: p.EmbeddedAuthorID,
		Hashtags:  p.Hashtags,
		LikeCount: p.LikeCount, RepostCount: p.RepostCount, ReplyCount: p.ReplyCount, QuoteCount: p.QuoteCount,
		Visibility: string(p.Visibility), SnapshotVersion: p.SnapshotVersion, CreatedAt: p.CreatedAt,
		Moderation:      string(p.Moderation),
		PaidPartnership: p.PaidPartnership, MadeWithAI: p.MadeWithAI,
		ReplyPolicy: string(p.ReplyPolicy),
		HasMedia:    HasMediaFor(p.Kind, len(p.Media)),
		Poll:        pollToDoc(p.Poll),
		CommunityID: p.CommunityID, ConversationCommunityID: p.ConversationCommunityID, CommunityHidden: p.CommunityHidden,
	}
	if p.Community != nil {
		d.Community = &communityDoc{ID: p.Community.ID, Name: p.Community.Name}
	}
	if e := p.Embedded; e != nil {
		ed := &embeddedDoc{PostID: e.PostID, Unavailable: e.Unavailable}
		if !e.Unavailable {
			ed.Article = cloneArticle(e.Article)
			ed.PaidPartnership, ed.MadeWithAI = e.PaidPartnership, e.MadeWithAI
			ed.ReplyPolicy = string(e.ReplyPolicy)
			if e.Poll != nil {
				ed.Poll = &embeddedPollDoc{Options: e.Poll.Options, ClosesAt: e.Poll.ClosesAt}
			}
			ed.Author = &authorDoc{UserID: e.Author.UserID, Handle: e.Author.Handle, DisplayName: e.Author.DisplayName, AvatarURL: e.Author.AvatarURL, Verified: e.Author.Verified}
			ed.Text = e.Text
			t := e.CreatedAt
			ed.CreatedAt = &t
			for _, m := range e.Media {
				ed.Media = append(ed.Media, mediaDoc{MediaID: m.ID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText, ContentType: m.ContentType})
			}
		}
		d.Embedded = ed
	}
	if d.Hashtags == nil {
		d.Hashtags = []string{}
	}
	d.Mentions = make([]mentionDoc, 0, len(p.Mentions))
	for _, m := range p.Mentions {
		d.Mentions = append(d.Mentions, mentionDoc(m))
	}
	if len(p.Media) > 0 {
		d.Media = make([]mediaDoc, 0, len(p.Media))
	}
	for _, m := range p.Media {
		d.Media = append(d.Media, mediaDoc{MediaID: m.ID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText, ContentType: m.ContentType})
	}
	return d
}

func (d postDoc) toPost(id string) *Post {
	p := &Post{
		Article:  cloneArticle(d.Article),
		BeaconID: d.BeaconID, Beacon: d.Beacon.snapshot(),
		ID: id, AuthorID: d.AuthorID,
		Author: AuthorSnapshot{
			UserID: d.Author.UserID, Handle: d.Author.Handle, DisplayName: d.Author.DisplayName,
			AvatarURL: d.Author.AvatarURL, Verified: d.Author.Verified,
		},
		Kind: Kind(d.Kind), IsReply: d.IsReply, Text: d.Text,
		ReplyToID: d.ReplyToID, ReplyToHandle: d.ReplyToHandle, ConversationID: d.ConversationID,
		QuoteOfID: d.QuoteOfID, RepostOfID: d.RepostOfID, EmbeddedAuthorID: d.EmbeddedAuthorID,
		Hashtags:  d.Hashtags,
		LikeCount: d.LikeCount, RepostCount: d.RepostCount, ReplyCount: d.ReplyCount, QuoteCount: d.QuoteCount,
		Visibility: Visibility(d.Visibility), SnapshotVersion: d.SnapshotVersion, CreatedAt: d.CreatedAt.UTC(),
		Moderation:      Moderation(d.Moderation),
		PaidPartnership: d.PaidPartnership, MadeWithAI: d.MadeWithAI,
		ReplyPolicy: ReplyPolicy(d.ReplyPolicy),
		HasMedia:    d.HasMedia,
		Poll:        d.Poll.toPoll(),
		CommunityID: d.CommunityID, ConversationCommunityID: d.ConversationCommunityID, CommunityHidden: d.CommunityHidden,
	}
	if d.Community != nil {
		p.Community = &CommunityLabel{ID: d.Community.ID, Name: d.Community.Name}
	}
	if e := d.Embedded; e != nil {
		pe := &Embedded{PostID: e.PostID, Text: e.Text, Unavailable: e.Unavailable,
			PaidPartnership: e.PaidPartnership, MadeWithAI: e.MadeWithAI, ReplyPolicy: ReplyPolicy(e.ReplyPolicy)}
		if !e.Unavailable {
			pe.Article = cloneArticle(e.Article)
		}
		if e.Author != nil {
			pe.Author = AuthorSnapshot{UserID: e.Author.UserID, Handle: e.Author.Handle, DisplayName: e.Author.DisplayName, AvatarURL: e.Author.AvatarURL, Verified: e.Author.Verified}
		}
		if e.CreatedAt != nil {
			pe.CreatedAt = e.CreatedAt.UTC()
		}
		if e.Poll != nil {
			pe.Poll = &EmbeddedPoll{Options: e.Poll.Options, ClosesAt: e.Poll.ClosesAt.UTC()}
		}
		for _, m := range e.Media {
			pe.Media = append(pe.Media, MediaRef{ID: m.MediaID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText, ContentType: m.ContentType})
		}
		p.Embedded = pe
	}
	if len(d.Mentions) > 0 {
		p.Mentions = make([]Mention, len(d.Mentions))
		for i, m := range d.Mentions {
			p.Mentions[i] = Mention(m)
		}
	}
	if len(d.Media) > 0 {
		p.Media = make([]MediaRef, len(d.Media))
		for i, m := range d.Media {
			p.Media[i] = MediaRef{ID: m.MediaID, URL: m.URL, ThumbURL: m.ThumbURL, Width: m.Width, Height: m.Height, Blurhash: m.Blurhash, AltText: m.AltText, ContentType: m.ContentType}
		}
	}
	return p
}

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef {
	return r.client.Collection(postsCollection).Doc(id)
}

// GetAll implements Repo.
func (r *FirestoreRepo) GetAll(ctx context.Context, ids []string) (map[string]*Post, error) {
	if len(ids) == 0 {
		return map[string]*Post{}, nil
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = r.ref(id)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("posts: get %d posts: %w", len(ids), err)
	}
	out := make(map[string]*Post, len(snaps))
	for _, s := range snaps {
		if !s.Exists() {
			continue
		}
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: decode post %s: %w", s.Ref.ID, err)
		}
		out[s.Ref.ID] = d.toPost(s.Ref.ID)
	}
	return out, nil
}

// ByAuthors implements Repo (Q-H).
func (r *FirestoreRepo) ByAuthors(ctx context.Context, authorIDs []string, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).
		Where("authorId", "in", authorIDs).
		Where("isReply", "==", false)
	return r.run(ctx, q, w, limit)
}

// ByAuthor implements Repo (Q-P and Q-R).
func (r *FirestoreRepo) ByAuthor(ctx context.Context, authorID string, includeReplies bool, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("authorId", "==", authorID)
	if !includeReplies {
		q = q.Where("isReply", "==", false)
	}
	return r.run(ctx, q, w, limit)
}

// run applies the shared ordering, window bounds and Limit, executes the query and charges the reads.
// Descending order: StartAfter resumes strictly below Before; EndBefore stops strictly above After.
func (r *FirestoreRepo) run(ctx context.Context, q firestore.Query, w Window, limit int) ([]*Post, error) {
	q = q.OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
	if w.Before != nil {
		q = q.StartAfter(w.Before.CreatedAt, r.ref(w.Before.ID))
	}
	if w.After != nil {
		q = q.EndBefore(w.After.CreatedAt, r.ref(w.After.ID))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("posts: query: %w", err)
	}
	out := make([]*Post, 0, len(docs))
	for _, s := range docs {
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: decode post %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toPost(s.Ref.ID))
	}
	return out, nil
}

// HasMediaFor is the one definition of posts.hasMedia: a post's own stored images are non-empty, and a
// REPOST never has its own (the original's images are in `embedded`). toDoc writes it on every create path (CreatePost
// root, reply and quote, the scheduled publish sweep, the REPOST doc); `opsctl backfill-has-media` must call it
// with a legacy doc's kind and len(media), so there is exactly one rule.
func HasMediaFor(kind Kind, storedMedia int) bool {
	return kind != KindRepost && storedMedia > 0
}

// ByAuthorMedia implements Repo (Q-M).
func (r *FirestoreRepo) ByAuthorMedia(ctx context.Context, authorID string, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("authorId", "==", authorID).Where("hasMedia", "==", true)
	return r.run(ctx, q, w, limit)
}

// ByAuthorKind implements Repo (Q-B).
func (r *FirestoreRepo) ByAuthorKind(ctx context.Context, authorID string, kind Kind, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("authorId", "==", authorID).Where("kind", "==", string(kind))
	return r.run(ctx, q, w, limit)
}

// ByHashtag implements Repo (Q-T): `hashtags array-contains tag ORDER BY createdAt DESC, __name__ DESC`, served by
// the existing composite index posts(hashtags CONTAINS, createdAt DESC) (a composite carries __name__ in its last
// field's direction). A REPOST stores hashtags [] so it never matches.
func (r *FirestoreRepo) ByHashtag(ctx context.Context, tag string, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("hashtags", "array-contains", tag)
	return r.run(ctx, q, w, limit)
}

// createdAfterFields is the projection of CreatedAfter.
var createdAfterFields = []string{"hashtags", "authorId", "moderation", "createdAt", "kind"}

// CreatedAfter implements Repo (Q-W): `createdAt > after ORDER BY createdAt ASC, __name__ ASC` with the projection
// above, on the automatic single-field indexes (no composite). With an empty after.ID the bound is createdAt only;
// otherwise it resumes strictly after the (createdAt, id) pair.
func (r *FirestoreRepo) CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Select(createdAfterFields...).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after.ID == "" {
		q = q.Where("createdAt", ">", after.CreatedAt)
	} else {
		q = q.StartAfter(after.CreatedAt, r.ref(after.ID))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("posts: query: %w", err)
	}
	out := make([]*Post, 0, len(docs))
	for _, s := range docs {
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: decode post %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toPost(s.Ref.ID))
	}
	return out, nil
}
