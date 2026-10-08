// repo_create.go is the CreatePost transaction (ADR-0010 D13, D18; ADR-0003 mechanism 2 for idempotency).
//
// One transaction, bounded by createTxTimeout (5 s):
//
//	reads : idempotency/{hash} (1), then, only on a first attempt, quotas/{uid} (1)
//	writes: Create idempotency doc, Create posts/{id}, Update users.postsCount (+1), Set quotas/{uid}  (4)
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// createTxTimeout is the CreatePost transaction deadline (ADR-0010 D13). TIMELINE_SETTLE_WINDOW is validated
	// to be at least 3x this.
	createTxTimeout = 5 * time.Second
	// createRPC scopes the idempotency key (idempotency.Key(uid, rpc, key)).
	createRPC = "CreatePost"
	// idemPostID is the idempotency Record.Result key holding the created post's id.
	idemPostID = "postId"
	// maxIDCollisionRetries bounds the redraw after an AlreadyExists on posts/{id} (D18): practically never.
	maxIDCollisionRetries = 2
)

// IDGenerator draws post ids (*snowflake.Node).
type IDGenerator interface{ Generate() string }

// CreateParams is everything the transaction needs. Draft carries every post field except the id,
// conversationId and createdAt, which the transaction sets from the id drawn in each attempt.
type CreateParams struct {
	AuthorID    string
	IdemKey     string // idempotency.Key(uid, "CreatePost", key)
	RequestHash string
	QuotaLimit  int64
	Draft       Post
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
}

// SetWriters supplies the CreatePost collaborators (a setter, like graph.FirestoreRepo.SetCounters, so the read
// path and its tests need none of them). Call once at startup.
func (r *FirestoreRepo) SetWriters(d WriteDeps) { r.w = d }

// Create implements Repo.
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if r.w.IDs == nil || r.w.Idempotency == nil || r.w.Quotas == nil || r.w.Counters == nil {
		return CreateResult{}, errors.New("posts: repo has no CreatePost writers configured")
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()

	var (
		res      CreateResult
		attempts int
		err      error
	)
	for try := 0; try <= maxIDCollisionRetries; try++ {
		res = CreateResult{}
		_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
			attempts++
			var err error
			res, err = r.createAttempt(ctx, tx, p, attempts)
			return err
		})
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
	return res, nil
}

func (r *FirestoreRepo) createAttempt(ctx context.Context, tx *firestore.Transaction, p CreateParams, attempt int) (CreateResult, error) {
	rec, err := r.w.Idempotency.Get(ctx, tx, p.IdemKey)
	switch {
	case err == nil:
		if rec.RequestHash != p.RequestHash {
			return CreateResult{}, ErrIdempotencyKeyReused
		}
		id := rec.Result[idemPostID]
		if id == "" {
			return CreateResult{}, fmt.Errorf("posts: idempotency record %s has no post id", p.IdemKey)
		}
		return CreateResult{ReplayID: id}, nil
	case !errors.Is(err, idempotency.ErrNotFound):
		return CreateResult{}, fmt.Errorf("posts: idempotency lookup: %w", err)
	}

	qrec, err := r.w.Quotas.Get(ctx, tx, p.AuthorID)
	if err != nil {
		return CreateResult{}, fmt.Errorf("posts: quota lookup: %w", err)
	}

	// Drawn inside the attempt: createdAt is the Snowflake ms of THIS attempt (D13, D18).
	id := r.w.IDs.Generate()
	createdAt, err := snowflake.Time(id)
	if err != nil {
		return CreateResult{}, fmt.Errorf("posts: %w", err)
	}
	if r.attemptHook != nil {
		if err := r.attemptHook(attempt, id); err != nil {
			return CreateResult{}, err
		}
	}
	post := p.Draft
	post.ID, post.ConversationID, post.CreatedAt = id, id, createdAt

	b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
	if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.AuthorID), qrec, quota.Posts, p.QuotaLimit); err != nil {
		return CreateResult{}, err
	}
	b.Create(r.ref(id), toDoc(&post))
	r.w.Counters.AddPostsCount(b, p.AuthorID, 1)
	r.w.Idempotency.Put(b, p.IdemKey, idempotency.Record{
		UID: p.AuthorID, RPC: createRPC, RequestHash: p.RequestHash,
		Result:   map[string]string{idemPostID: id},
		ExpireAt: createdAt.Add(idempotency.TTL),
	})
	if err := b.Err(); err != nil {
		return CreateResult{}, err
	}
	return CreateResult{Post: &post}, nil
}
