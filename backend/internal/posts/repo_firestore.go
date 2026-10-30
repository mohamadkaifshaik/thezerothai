// repo_firestore.go is the Firestore implementation of Repo (ADR-0003 `posts/{postId}`; ADR-0010 D18, D19).
//
// Every query has a Limit and orders `createdAt DESC, __name__ DESC` explicitly. A composite index carries
// __name__ in the direction of its last field, so these shapes map to the indexes in firebase/firestore.indexes.json:
//
//	Q-H  ByAuthors, authorId in [...] AND isReply == false      -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-P  ByAuthor,  authorId == X AND isReply == false          -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-R  ByAuthor,  authorId == X (Replies tab)                 -> (authorId ASC, createdAt DESC)
//	Q-M  ListAuthorMedia,   authorId == X AND hasMedia == true  -> (authorId ASC, hasMedia ASC, createdAt DESC)  [W3-2]
//	Q-B  ListAuthorReposts, authorId == X AND kind == "REPOST"  -> (authorId ASC, kind ASC, createdAt DESC)      [W3-2]
//
// Reads are charged to the request's budget.Counter: one per document returned, and 1 for a query that
// returns nothing (Firestore bills an empty query as one read).
package posts

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const postsCollection = "posts"

// Repo is posts' storage seam; service.go depends on it, FirestoreRepo implements it, and unit tests use an
// in-memory fake. Argument limits (ids <= MaxGetMany, authors <= MaxByAuthors, limit 1..MaxLimit) are
// enforced by the service before the repo is called.
type Repo interface {
	// GetAll fetches posts/{id} for every id in one GetAll. Missing ids are absent from the result. Reads: len(ids).
	GetAll(ctx context.Context, ids []string) (map[string]*Post, error)
	// ByAuthors is Q-H. Reads: len(result), minimum 1.
	ByAuthors(ctx context.Context, authorIDs []string, w Window, limit int) ([]*Post, error)
	// ByAuthor is Q-P (includeReplies=false) or Q-R (true). Reads: len(result), minimum 1.
	ByAuthor(ctx context.Context, authorID string, includeReplies bool, w Window, limit int) ([]*Post, error)
	// ByAuthorMedia is Q-M and ByAuthorKind is Q-B (kind is KindRepost for the Reposts tab). Reads: len(result), minimum 1.
	// They need the W3-2 composite indexes READY (the emulator does not enforce indexes).
	ByAuthorMedia(ctx context.Context, authorID string, w Window, limit int) ([]*Post, error)
	ByAuthorKind(ctx context.Context, authorID string, kind Kind, w Window, limit int) ([]*Post, error)
	// ByHashtag is Q-T (existing composite index) and CreatedAfter is Q-W (projected, ascending, automatic indexes).
	// Reads: len(result), minimum 1.
	ByHashtag(ctx context.Context, tag string, w Window, limit int) ([]*Post, error)
	CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error)
	// Create runs the CreatePost transaction (repo_create.go). Reads 2 (idempotency, quotas) and 4 writes on a
	// first call, 1 read and 0 writes on a replay. It returns ErrIdempotencyKeyReused for a key used with
	// another request, and the quota package's RESOURCE_EXHAUSTED apierr when the daily quota is spent.
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	// DeleteOwn deletes posts/{id} and decrements the author's postsCount in one batch, with an Exists
	// precondition on the post. deleted=false (and 0 writes) when the post is already gone (a concurrent delete
	// won). Reads 0; writes 1 + deletes 1 only when deleted.
	//
	// stage functions append further writes to the same batch (DeletePost of a REPOST adds the blind delete of
	// its reposts doc through RepostLinks); they must not add a guarded write of their own.
	DeleteOwn(ctx context.Context, id, authorID string, stage ...func(store.Batch)) (deleted bool, err error)
	// Conversation is Q-T (repo_thread.go): the posts of one conversation, oldest first, strictly after `after`
	// (nil = from the start), at most limit. Reads: len(result), minimum 1.
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

// postDoc is the posts/{postId} shape (ADR-0003); counters start at 0. Embedded and mentionIds are not
// written yet (ADR-0010 D2, D12); media is written from P4 (empty unless the post has images).
type postDoc struct {
	AuthorID       string    `firestore:"authorId"`
	Author         authorDoc `firestore:"author"`
	Kind           string    `firestore:"kind"`
	IsReply        bool      `firestore:"isReply"`
	Text           string    `firestore:"text"`
	ReplyToID      string    `firestore:"replyToId,omitempty"`
	ReplyToHandle  string    `firestore:"replyToHandle,omitempty"`
	ConversationID string    `firestore:"conversationId"`
	QuoteOfID      string    `firestore:"quoteOfId,omitempty"`
	RepostOfID     string    `firestore:"repostOfId,omitempty"`
	// Embedded is the QUOTE/REPOST snapshot (ADR-0018); EmbeddedAuthorID is its top-level, indexed author id.
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
	// Moderation is absent for a visible post (ADR-0016 D3); ModeratedAt is when the state last changed.
	Moderation  string     `firestore:"moderation,omitempty"`
	ModeratedAt *time.Time `firestore:"moderatedAt,omitempty"`
	CreatedAt   time.Time  `firestore:"createdAt"`
	// ADR-0021 D3 disclosure labels; absent (omitempty) = false, no backfill.
	PaidPartnership bool `firestore:"paidPartnership,omitempty"`
	MadeWithAI      bool `firestore:"madeWithAi,omitempty"`
	// ADR-0021 D2: the conversation's effective reply policy (FOLLOWING | MENTIONED_ONLY); absent = EVERYONE, no
	// backfill. Replies store the value inherited from the parent, never a user id. Exempt from indexing.
	ReplyPolicy string `firestore:"replyPolicy,omitempty"`
	// HasMedia is ADR-0024 D4: len(media) > 0, false for a REPOST. NOT omitempty: the field is stored as an explicit false
	// too, so a doc that lacks it is exactly a pre-W3 doc the backfill still has to visit (rerun writes 0) and the
	// (authorId, hasMedia, createdAt) index holds every post. Indexed.
	HasMedia bool `firestore:"hasMedia"`
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
	PostID      string     `firestore:"postId"`
	Author      *authorDoc `firestore:"author,omitempty"`
	Text        string     `firestore:"text,omitempty"`
	Media       []mediaDoc `firestore:"media,omitempty"`
	CreatedAt   *time.Time `firestore:"createdAt,omitempty"`
	Unavailable bool       `firestore:"unavailable,omitempty"`
	// ADR-0021 D3: the embedded post's labels, copied by snapshotOf; absent = false.
	PaidPartnership bool `firestore:"paidPartnership,omitempty"`
	MadeWithAI      bool `firestore:"madeWithAi,omitempty"`
	// ADR-0021 D2: the embedded post's effective reply policy, copied by snapshotOf; absent = EVERYONE.
	ReplyPolicy string `firestore:"replyPolicy,omitempty"`
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

// toDoc converts a domain Post to its stored shape (used by writers, T8, and by integration-test seeding).
func toDoc(p *Post) postDoc {
	d := postDoc{
		AuthorID: p.AuthorID,
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
	}
	if e := p.Embedded; e != nil {
		ed := &embeddedDoc{PostID: e.PostID, Unavailable: e.Unavailable}
		if !e.Unavailable {
			ed.PaidPartnership, ed.MadeWithAI = e.PaidPartnership, e.MadeWithAI
			ed.ReplyPolicy = string(e.ReplyPolicy)
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
	}
	if e := d.Embedded; e != nil {
		pe := &Embedded{PostID: e.PostID, Text: e.Text, Unavailable: e.Unavailable,
			PaidPartnership: e.PaidPartnership, MadeWithAI: e.MadeWithAI, ReplyPolicy: ReplyPolicy(e.ReplyPolicy)}
		if e.Author != nil {
			pe.Author = AuthorSnapshot{UserID: e.Author.UserID, Handle: e.Author.Handle, DisplayName: e.Author.DisplayName, AvatarURL: e.Author.AvatarURL, Verified: e.Author.Verified}
		}
		if e.CreatedAt != nil {
			pe.CreatedAt = e.CreatedAt.UTC()
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

// GetAll implements Repo. A missing doc is billed as a read too, so reads = len(ids).
func (r *FirestoreRepo) GetAll(ctx context.Context, ids []string) (map[string]*Post, error) {
	if len(ids) == 0 {
		return map[string]*Post{}, nil
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = r.ref(id)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	budget.FromContext(ctx).AddReads(int64(len(ids)))
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
	budget.FromContext(ctx).AddQueryReads(len(docs))
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

// HasMediaFor is the one definition of posts.hasMedia (ADR-0024 D4): a post's own stored images are non-empty, and a
// REPOST never has its own (the original's images are in `embedded`). toDoc writes it on every create path (CreatePost
// root, reply and quote, the scheduled publish sweep, the REPOST doc); `opsctl backfill-has-media` (W3-8) must call it
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

// createdAfterFields is the projection of CreatedAfter (ADR-0028 D6). A projected read still bills 1 read per doc.
var createdAfterFields = []string{"hashtags", "authorId", "moderation", "createdAt", "kind"}

// CreatedAfter implements Repo (Q-W): `createdAt > after ORDER BY createdAt ASC, __name__ ASC` with the projection
// above, on the automatic single-field indexes (no composite). With an empty after.ID the bound is createdAt only;
// otherwise it resumes strictly after the (createdAt, id) pair. Reads: len(result), minimum 1.
func (r *FirestoreRepo) CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Select(createdAfterFields...).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after.ID == "" {
		q = q.Where("createdAt", ">", after.CreatedAt)
	} else {
		q = q.StartAfter(after.CreatedAt, r.ref(after.ID))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
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
