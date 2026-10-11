// repo_firestore.go is the Firestore implementation of Repo (ADR-0003 `posts/{postId}`; ADR-0010 D18, D19).
//
// Every query has a Limit and orders `createdAt DESC, __name__ DESC` explicitly. A composite index carries
// __name__ in the direction of its last field, so these shapes map to the existing indexes (no index change):
//
//	Q-H  ByAuthors, authorId in [...] AND isReply == false      -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-P  ByAuthor,  authorId == X AND isReply == false          -> (authorId ASC, isReply ASC, createdAt DESC)
//	Q-R  ByAuthor,  authorId == X (Replies tab)                 -> (authorId ASC, createdAt DESC)
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
	// Create runs the CreatePost transaction (repo_create.go). Reads 2 (idempotency, quotas) and 4 writes on a
	// first call, 1 read and 0 writes on a replay. It returns ErrIdempotencyKeyReused for a key used with
	// another request, and the quota package's RESOURCE_EXHAUSTED apierr when the daily quota is spent.
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	// DeleteOwn deletes posts/{id} and decrements the author's postsCount in one batch, with an Exists
	// precondition on the post. deleted=false (and 0 writes) when the post is already gone (a concurrent delete
	// won). Reads 0; writes 1 + deletes 1 only when deleted.
	DeleteOwn(ctx context.Context, id, authorID string) (deleted bool, err error)
}

// FirestoreRepo implements Repo against the shared Firestore client.
type FirestoreRepo struct {
	client *firestore.Client
	w      WriteDeps // CreatePost collaborators, set by SetWriters
	// attemptHook is a test seam: called inside every CreatePost attempt after the id is drawn; an Aborted
	// error makes the SDK retry the transaction. Never set outside tests.
	attemptHook func(attempt int, id string) error
	// Test seams for DeleteOwn's retry loop (store.RetryConfig); nil means real commit and jittered wait.
	commitBatch func(ctx context.Context, b *store.FirestoreBatch) error
	backoff     func(ctx context.Context, ceiling time.Duration) error
}

// NewFirestoreRepo builds the repo on the process-wide Firestore client.
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client}
}

var _ Repo = (*FirestoreRepo)(nil)

// postDoc is the posts/{postId} shape (ADR-0003); counters start at 0. Media, embedded and mentionIds are not
// written in this slice (ADR-0010 D2, D12).
type postDoc struct {
	AuthorID        string       `firestore:"authorId"`
	Author          authorDoc    `firestore:"author"`
	Kind            string       `firestore:"kind"`
	IsReply         bool         `firestore:"isReply"`
	Text            string       `firestore:"text"`
	ReplyToID       string       `firestore:"replyToId,omitempty"`
	ReplyToHandle   string       `firestore:"replyToHandle,omitempty"`
	ConversationID  string       `firestore:"conversationId"`
	QuoteOfID       string       `firestore:"quoteOfId,omitempty"`
	RepostOfID      string       `firestore:"repostOfId,omitempty"`
	Hashtags        []string     `firestore:"hashtags"`
	Mentions        []mentionDoc `firestore:"mentions"`
	LikeCount       int64        `firestore:"likeCount"`
	RepostCount     int64        `firestore:"repostCount"`
	ReplyCount      int64        `firestore:"replyCount"`
	QuoteCount      int64        `firestore:"quoteCount"`
	Visibility      string       `firestore:"visibility"`
	SnapshotVersion int64        `firestore:"snapshotVersion"`
	// Moderation is absent for a visible post (ADR-0016 D3); ModeratedAt is when the state last changed.
	Moderation  string     `firestore:"moderation,omitempty"`
	ModeratedAt *time.Time `firestore:"moderatedAt,omitempty"`
	CreatedAt   time.Time  `firestore:"createdAt"`
}

type authorDoc struct {
	UserID      string `firestore:"userId"`
	Handle      string `firestore:"handle"`
	DisplayName string `firestore:"displayName"`
	AvatarURL   string `firestore:"avatarUrl"`
	Verified    bool   `firestore:"verified"`
}

type mentionDoc struct {
	UserID string `firestore:"userId"`
	Handle string `firestore:"handle"`
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
		QuoteOfID: p.QuoteOfID, RepostOfID: p.RepostOfID,
		Hashtags:  p.Hashtags,
		LikeCount: p.LikeCount, RepostCount: p.RepostCount, ReplyCount: p.ReplyCount, QuoteCount: p.QuoteCount,
		Visibility: string(p.Visibility), SnapshotVersion: p.SnapshotVersion, CreatedAt: p.CreatedAt,
		Moderation: string(p.Moderation),
	}
	if d.Hashtags == nil {
		d.Hashtags = []string{}
	}
	d.Mentions = make([]mentionDoc, 0, len(p.Mentions))
	for _, m := range p.Mentions {
		d.Mentions = append(d.Mentions, mentionDoc(m))
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
		QuoteOfID: d.QuoteOfID, RepostOfID: d.RepostOfID,
		Hashtags:  d.Hashtags,
		LikeCount: d.LikeCount, RepostCount: d.RepostCount, ReplyCount: d.ReplyCount, QuoteCount: d.QuoteCount,
		Visibility: Visibility(d.Visibility), SnapshotVersion: d.SnapshotVersion, CreatedAt: d.CreatedAt.UTC(),
		Moderation: Moderation(d.Moderation),
	}
	if len(d.Mentions) > 0 {
		p.Mentions = make([]Mention, len(d.Mentions))
		for i, m := range d.Mentions {
			p.Mentions[i] = Mention(m)
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
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
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
