// repo_create.go is the CreatePost transaction (mechanism 2 for idempotency).
//
// One transaction, bounded by createTxTimeout (5 s):
//
//	reads : idempotency/{hash}
//	        a community post: + communityMembers/{uid} (fresh, after the replay check; the community doc is read before the
//	        transaction through the 60 s cache)
//	        media/* (only with images: one GetAll over media_ids)
//	        a reply or quote to a hot parent (HOT_COUNTER_THRESHOLD): + posts/{parent} (GuardHot, the existence check the
//	        shard write lost)
//	writes: Create idempotency doc, Create posts/{id}, Update users.postsCount (+1)
//	        (+ one media/{id}.postId update per image, <= 4)
//	        a reply or quote: the parent's replyCount / quoteCount +1, a plain Increment when cold (its implicit Exists
//	        fails a gone parent at commit), or one shard of posts/{parent}/viewShards plus the counter marker when hot
//
// A poll is built here per attempt from the validated draft (closesAt = this attempt's createdAt + the duration); it
// needs no extra read or write.
//
// A replay reads only the idempotency doc and writes nothing. The post id (and so createdAt, the Snowflake's
// millisecond) is drawn inside every attempt, so a retried attempt never commits a stale timestamp, which the
// timeline's settle watermark depends on (D13).
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// createTxTimeout is the CreatePost transaction deadline. TIMELINE_SETTLE_WINDOW is validated
	// to be at least 3x this.
	createTxTimeout = 5 * time.Second
	// createRPC scopes the idempotency key (idempotency.Key(uid, rpc, key)).
	createRPC = "CreatePost"
	// idemPostID is the idempotency Record.Result key holding the created post's id.
	idemPostID = "postId"
	// maxIDCollisionRetries bounds the redraw after an AlreadyExists on posts/{id} (D18): practically never.
	maxIDCollisionRetries = 2
)

// ErrParentGone is returned by Repo.Create when the reply's parent (or the quoted post) no longer exists at
// commit time (the service maps it to the one NOT_FOUND "post not found" answer).
var ErrParentGone = errors.New("posts: reply parent no longer exists")

// IDGenerator draws post ids (*snowflake.Node).
type IDGenerator interface{ Generate() string }

// CreateParams is everything the transaction needs. Draft carries every post field except the id,
// conversationId and createdAt, which the transaction sets from the id drawn in each attempt.
type CreateParams struct {
	// TextAccessError is evaluated before the transaction, enforced only after
	// the replay lookup. A completed publication survives later plan expiry.
	TextAccessError    error
	ArticlePublication ArticlePublication
	AuthorID           string
	IdemKey            string // idempotency.Key(uid, "CreatePost", key)
	RequestHash        string
	// MediaIDs are the images to attach (validated, deduplicated, <= 4) and MediaAlts their alt texts (empty or
	// parallel). With MediaIDs the transaction adds len(MediaIDs) reads and as many media-doc updates.
	MediaIDs  []string
	MediaAlts []string
	// GifEnabled is CreateInput.GifEnabled: with it false a claim holding a GIF fails with ErrGifDisabled before any write.
	GifEnabled bool
	Draft      Post
	// ParentID is the post being replied to: its replyCount is incremented in the same transaction, which
	// fails with ErrParentGone if the parent was deleted in the meantime. Empty for root posts.
	ParentID string
	// ParentReplyCount is the parent's replyCount as the service read it (cache-first, for the visibility check): the
	// hot decision of the replyCount write (EngagementWriter.Hot). Never part of the request hash.
	ParentReplyCount int64
	// QuoteID is the post being quoted: its quoteCount is incremented the same way (ErrParentGone when it is
	// gone). A request carries a ParentID or a QuoteID, never both.
	QuoteID string
	// QuotedQuoteCount is ParentReplyCount for the quoted post's quoteCount.
	QuotedQuoteCount int64
	// Poll is the validated poll of a root post, nil for none. The transaction builds the stored Poll from it inside
	// every attempt: closesAt = that attempt's Snowflake createdAt + the duration, counts all 0.
	Poll *PollDraft
	// Community, when set, runs the gate inside the transaction (member doc fresh, the per-community daily cap). Nil for
	// every other post.
	Community *CommunityPost
}

// CommunityPost is the in-transaction half of a community post: the gate. The label and the conversation community are
// already in CreateParams.Draft.
type CommunityPost struct {
	Gate CommunityGate
	// capDrawn makes the per-community cap draw happen once per CreatePost call, not once per transaction attempt (the SDK re-runs the
	// function on contention), so a retry does not draw twice. A refusal before the draw and a replay never reach it.
	capDrawn bool
}

// CreateResult is the outcome of Repo.Create. Exactly one of Post (a new post, already committed) and ReplayID
// (the idempotency doc exists; the caller reads the post) is set.
type CreateResult struct {
	Post     *Post
	ReplayID string
	Attempts int
}

// WriteDeps are the cross-module collaborators of the CreatePost transaction.
type WriteDeps struct {
	Idempotency *idempotency.Store
	Quotas      *quota.Store
	Counters    identity.Counters
	IDs         IDGenerator
	// Media loads and claims a post's images inside the CreatePost transaction. Nil rejects media ids.
	Media MediaAttacher
	// Profiles reads the author's users/{uid} inside the scheduled-post publish transaction. Only
	// PublishScheduled needs it; CreatePost reads the cached directory profile instead.
	Profiles identity.TxProfiles
	// Stats stages the creator daily stats (F2, identity owns users/{uid}/dailyStats) next to a counter write: a reply's
	// or quote's engagement on the cold path, the view rollup's impressions, the counter rollup's folded engagements.
	// Nil stages nothing (opsctl, tests).
	Stats identity.StatsWriter
}

// stageStats stages d on uid's dailyStats doc for today (IST, the repo clock) when Stats is wired. Call it only in a
// unit of work that also carries an Exists-preconditioned write on the post (identity.StatsWriter).
func (r *FirestoreRepo) stageStats(b store.Batch, uid string, d identity.DailyDelta) {
	if r.w.Stats == nil || uid == "" {
		return
	}
	r.w.Stats.StageDaily(b, uid, identity.StatsDay(r.clock()), d)
}

// engagementStat is the stat of one engagement (+1) or its undo (-1) received by author from actor: nothing for
// the author's own engagement (a self-reply thread is not reach).
func (r *FirestoreRepo) stageEngagementStat(b store.Batch, author, actor string, delta int64) {
	if author == actor {
		return
	}
	r.stageStats(b, author, identity.DailyDelta{Engagements: delta})
}

// SetWriters supplies the CreatePost collaborators (a setter, like graph.FirestoreRepo.SetCounters, so the read
// path and its tests need none of them). Call once at startup.
func (r *FirestoreRepo) SetWriters(d WriteDeps) { r.w = d }

// Create implements Repo.
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if r.w.IDs == nil || r.w.Idempotency == nil || r.w.Counters == nil {
		return CreateResult{}, errors.New("posts: repo has no CreatePost writers configured")
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()

	var (
		res       CreateResult
		attempts  int
		err       error
		committed func()
	)
	for try := 0; try <= maxIDCollisionRetries; try++ {
		res = CreateResult{}
		_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
			attempts++
			var err error
			res, committed, err = r.createAttempt(ctx, tx, p, attempts)
			return err
		})
		if (p.ParentID != "" || p.QuoteID != "") && status.Code(err) == codes.NotFound {
			// The parent's replyCount Update carries an implicit Exists precondition: the parent was deleted
			// after the visibility check. Nothing was written.
			err = ErrParentGone
			break
		}
		// AlreadyExists at commit is a posts/{id} collision (or a concurrent first call of the same key, whose
		// idempotency doc now exists): the next run draws a new id or takes the replay path.
		if status.Code(err) != codes.AlreadyExists {
			break
		}
	}
	res.Attempts = attempts
	if err != nil {
		return CreateResult{Attempts: attempts}, err
	}
	if res.Post != nil && committed != nil {
		committed() // the last attempt's hot counter marker is now committed (a no-op when cold)
	}
	return res, nil
}

func (r *FirestoreRepo) createAttempt(ctx context.Context, tx *firestore.Transaction, p CreateParams, attempt int) (CreateResult, func(), error) {
	rec, err := r.w.Idempotency.Get(ctx, tx, p.IdemKey)
	switch {
	case err == nil:
		if rec.RequestHash != p.RequestHash {
			return CreateResult{}, nil, ErrIdempotencyKeyReused
		}
		id := rec.Result[idemPostID]
		if id == "" {
			return CreateResult{}, nil, fmt.Errorf("posts: idempotency record %s has no post id", p.IdemKey)
		}
		return CreateResult{ReplayID: id}, nil, nil
	case !errors.Is(err, idempotency.ErrNotFound):
		return CreateResult{}, nil, fmt.Errorf("posts: idempotency lookup: %w", err)
	}

	if p.TextAccessError != nil {
		return CreateResult{}, nil, p.TextAccessError
	}

	var articleClaim ArticlePublicationClaim
	if p.ArticlePublication != nil {
		articleClaim, err = p.ArticlePublication.LoadForPublish(ctx, tx)
		if err != nil {
			return CreateResult{}, nil, err
		}
	}

	// Step 3: the caller's member doc, read fresh after the replay check (a replay never reads it) and before anything is
	// staged. The gate maps a missing doc to not_member itself, so a QUOTE into a community cannot be mistaken for a vanished parent.
	if p.Community != nil {
		if err := p.Community.Gate.CheckMember(ctx, tx, p.Draft.CommunityID, p.AuthorID); err != nil {
			return CreateResult{}, nil, err
		}
	}

	// Images are read before the first write (a Firestore transaction rule): one GetAll of len(ids) reads.
	var claim MediaClaim
	if len(p.MediaIDs) > 0 {
		if r.w.Media == nil {
			return CreateResult{}, nil, ErrMediaNotReady
		}
		claim, err = r.w.Media.LoadForPost(ctx, tx, p.AuthorID, p.MediaIDs)
		if err != nil {
			return CreateResult{}, nil, err
		}
		if claim.HasGIF() { // The second gate, then the only-image rule; nothing is staged yet
			if !p.GifEnabled {
				return CreateResult{}, nil, ErrGifDisabled
			}
			if len(p.MediaIDs) > 1 {
				return CreateResult{}, nil, ErrGifNotAlone
			}
		}
	}

	// A hot parent counter write goes to a shard and so loses the Update's implicit Exists: read the parent here, the last
	// read before any write, so a gone parent still writes nothing and answers ErrParentGone (cold reads nothing).
	if err := r.guardParent(tx, p); err != nil {
		return CreateResult{}, nil, err
	}

	// Drawn inside the attempt: createdAt is the Snowflake ms of THIS attempt (D13, D18).
	id := r.w.IDs.Generate()
	createdAt, err := snowflake.Time(id)
	if err != nil {
		return CreateResult{}, nil, fmt.Errorf("posts: %w", err)
	}
	if r.attemptHook != nil {
		if err := r.attemptHook(attempt, id); err != nil {
			return CreateResult{}, nil, err
		}
	}
	post := p.Draft
	post.ID, post.CreatedAt = id, createdAt
	if p.Poll != nil {
		post.Poll = p.Poll.newPoll(createdAt) // fresh per attempt: a retry never reuses a closesAt from an earlier id
	}
	if post.ConversationID == "" { // a reply's conversation is its parent's (P3); a root's is its own id
		post.ConversationID = id
	}
	if claim != nil {
		post.Media = mediaWithAlts(claim.Refs(), p.MediaAlts)
		post.HasMedia = HasMediaFor(post.Kind, len(post.Media)) // the cached copy matches the doc toDoc writes
		if post.Article != nil && len(post.Media) > 0 {
			post.Article = cloneArticle(post.Article)
			post.Article.CoverURL = post.Media[0].URL
		}
	}

	b := store.NewFirestoreTxBatch(tx)
	if p.Community != nil && !p.Community.capDrawn {
		if err := p.Community.Gate.AllowPost(ctx, p.AuthorID, p.Draft.CommunityID); err != nil {
			return CreateResult{}, nil, err
		}
		p.Community.capDrawn = true
	}
	b.Create(r.ref(id), toDoc(&post))
	if articleClaim != nil {
		articleClaim.Publish(b, id)
	}
	if claim != nil {
		claim.Attach(b, id)
	}
	r.w.Counters.AddPostsCount(b, p.AuthorID, 1)
	committed := func() {}
	// The creator stat rides the cold counter Update (its Exists fails a gone parent, stat included); a hot parent's
	// engagement is staged by the counter rollup when it folds the shard (repo_view_rollup.go), never here too.
	if p.ParentID != "" {
		committed = r.stageCounter(b, p.ParentID, replyCountField, 1, p.ParentReplyCount)
		if !r.Hot(p.ParentReplyCount) {
			r.stageEngagementStat(b, p.Draft.ReplyToAuthorID, p.AuthorID, 1)
		}
	}
	if p.QuoteID != "" {
		committed = r.stageCounter(b, p.QuoteID, quoteCountField, 1, p.QuotedQuoteCount)
		if !r.Hot(p.QuotedQuoteCount) {
			r.stageEngagementStat(b, p.Draft.EmbeddedAuthorID, p.AuthorID, 1)
		}
	}
	r.w.Idempotency.Put(b, p.IdemKey, idempotency.Record{
		UID: p.AuthorID, RPC: createRPC, RequestHash: p.RequestHash,
		Result:   map[string]string{idemPostID: id},
		ExpireAt: createdAt.Add(idempotency.TTL),
	})
	if err := b.Err(); err != nil {
		return CreateResult{}, nil, err
	}
	return CreateResult{Post: &post}, committed, nil
}

// guardParent is GuardHot for the reply parent or the quoted post: nil when the counter write is cold or the post
// exists, ErrParentGone when a hot write's post is gone (the same answer the cold path's commit gives).
func (r *FirestoreRepo) guardParent(tx *firestore.Transaction, p CreateParams) error {
	id, known := p.ParentID, p.ParentReplyCount
	if id == "" {
		id, known = p.QuoteID, p.QuotedQuoteCount
	}
	if id == "" {
		return nil
	}
	err := r.GuardHot(tx, id, known)
	if errors.Is(err, ErrNotFound) {
		return ErrParentGone
	}
	return err
}

// mediaWithAlts copies refs and sets each AltText from the parallel alts slice (empty means none).
func mediaWithAlts(refs []MediaRef, alts []string) []MediaRef {
	out := make([]MediaRef, len(refs))
	copy(out, refs)
	for i := range out {
		if i < len(alts) {
			out[i].AltText = alts[i]
		}
	}
	return out
}
