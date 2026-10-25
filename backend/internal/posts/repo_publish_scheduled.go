// repo_publish_scheduled.go is the publish transaction of the scheduled-post sweep (ADR-0021 Sweep step 3.3, CMP-D4):
// the sibling of createAttempt in repo_create.go. It reuses the CreatePost write helpers (toDoc, mediaWithAlts, the
// quota reservation, the identity.Counters seam, the media claim) but not its idempotency document: the scheduled
// doc is the idempotency record, and the transaction re-reads it as PENDING before it writes anything.
//
// One transaction, bounded by createTxTimeout (5 s, which TIMELINE_SETTLE_WINDOW assumes). Inside EACH attempt, all
// reads come before any write, in this order:
//
//	(a) users/{uid}/scheduled/{id}   must exist and be PENDING, else the attempt ends with 0 writes (another run, a
//	                                 Cancel or the eraser won)                                              1 read
//	(b) users/{uid}                  through identity.TxProfiles, never cached: a suspension or a DeleteAccount
//	                                 conflicts with this transaction, so the guarantee is exact (review L-7)  1 read
//	(c) quotas/{uid}                 the IST day reset applies (quota.Store.Get); `posts >= limit` is checked BEFORE
//	                                 any media or handle read (review L-4)                                    1 read
//	(d) media/*                      owned, READY or READY_UNSCREENED, unattached (LoadForPost, GetAll)       <= 4 reads
//	(e) handles/*                    mention resolution, last, cache-first, not transactional (handles change
//	                                 rarely and need no isolation)                                            <= 10 reads
//
// Worst case 17 reads (1+1+1+4+10), typical 3 (planning 4). A success writes the post, users.postsCount, quotas and
// the scheduled doc (PUBLISHED, postId, draft cleared) = 4, plus one media/{id}.postId update per image (<= 8).
//
// FAILURES COMMIT, THEY DO NOT ROLL BACK. A permanent cause found by (a) to (d) stages the one terminal transition of
// the scheduled doc on the transaction batch and returns nil, so the transaction commits with exactly 1 write:
// SUSPENDED (or any status other than ACTIVE or DELETING) -> FAILED ACCOUNT_RESTRICTED; DELETING or a missing users
// doc -> CANCELLED; the posts quota reached -> FAILED QUOTA_EXCEEDED; ErrMediaNotReady -> FAILED MEDIA_UNAVAILABLE.
// Every such decision is made before the first staged write. Any other error rolls the attempt back and is returned
// (transient): the sweep counts an attempt on it.
//
// Panic safety (review M-2): the Firestore client rolls a transaction back only when its callback RETURNS an error. A
// panic would skip that and leave the transaction open, holding the author's users and quotas docs until the server
// expires it. guardPublishPanic turns a panic into a returned *publishPanicError (errors.Is errPublishPanic) so the
// client rolls back; the sweep maps it to FAILED INTERNAL, never to the transient branch.
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// errPublishPanic is the sentinel a panic inside the publish transaction callback becomes (match with errors.Is).
var errPublishPanic = errors.New("posts: publish transaction panicked")

// publishPanicError carries the panic's TYPE only: its value could hold a uid or post text, so it is never kept.
type publishPanicError struct{ typ string }

func (e *publishPanicError) Error() string {
	return "posts: publish transaction panicked: panic of type " + e.typ
}
func (e *publishPanicError) Is(target error) bool { return target == errPublishPanic }

// guardPublishPanic wraps a transaction body so a panic inside it is returned as a *publishPanicError instead of
// unwinding past the Firestore client (which would skip the rollback). It is applied INSIDE the function handed to
// store.RunTransaction, which therefore still folds the attempt's reads into the request counter.
func guardPublishPanic(fn store.TxnFunc) store.TxnFunc {
	return func(ctx context.Context, tx *firestore.Transaction) (err error) {
		defer func() {
			if v := recover(); v != nil {
				err = &publishPanicError{typ: fmt.Sprintf("%T", v)}
			}
		}()
		return fn(ctx, tx)
	}
}

// PublishOutcome is how a publish transaction ended.
type PublishOutcome int

const (
	// PublishNoop: the scheduled doc was gone or no longer PENDING when read. Nothing was written.
	PublishNoop PublishOutcome = iota
	// PublishPublished: the post was created and the item is PUBLISHED. PublishResult.Post is set.
	PublishPublished
	// PublishCancelled: the author is DELETING or gone; the item was moved to CANCELLED (1 write).
	PublishCancelled
	// PublishFailed: a permanent cause; the item was moved to FAILED with PublishResult.Failure (1 write).
	PublishFailed
)

// PublishResult is the outcome of FirestoreRepo.PublishScheduled. It describes a COMMITTED transaction: on an error
// the result is the zero value and nothing was written.
type PublishResult struct {
	Outcome PublishOutcome
	// Post is the created post (PublishPublished only), complete as written.
	Post *Post
	// Failure is the reason of a PublishFailed outcome.
	Failure ScheduledFailure
	// Attempts is how many times the transaction body ran (1 unless Firestore retried it).
	Attempts int
	// AuthorCreatedAt is the author's account creation time as read INSIDE the transaction (PublishPublished only). The
	// sweep hands it to SweepDeps.RecordAuthorAge so the notification recipient cap can tell a first-day account with 0
	// reads: a sweep has no authenticated request that would have recorded it.
	AuthorCreatedAt time.Time
}

// PublishParams is everything the publish transaction needs. The service parses the draft and decides the limits; the
// author snapshot, the new-account tier, the mentions, the media refs and the post id are all produced INSIDE each
// attempt from fresh reads.
type PublishParams struct {
	// UID and ID are the owner and the document id of the scheduled item, taken from the query path.
	UID, ID string
	// Draft is the post template: Kind, Text, Hashtags, Visibility, ReplyPolicy and both disclosure labels. Author,
	// SnapshotVersion, Mentions, Media, ID, ConversationID and CreatedAt are set per attempt.
	Draft Post
	// MediaIDs and MediaAlts are the draft's images and their alt texts (parallel). The published refs come from the
	// fresh media claim, never from the URLs stored in the draft.
	MediaIDs  []string
	MediaAlts []string
	// ResolveMentions resolves the draft's @mention candidates (nil: none). It runs last in each attempt, cache-first,
	// outside transactional isolation.
	ResolveMentions func(ctx context.Context) ([]Mention, error)
	// PostsLimit and NewAccountPostsLimit are the daily posts quota tiers; NewAccountWindow decides the tier from the
	// author's createdAt read inside the transaction (never from the cached directory profile).
	PostsLimit, NewAccountPostsLimit int64
	NewAccountWindow                 time.Duration
	// Now stamps the transition (updatedAt, expireAt) and decides the account tier; TerminalTTL is
	// SCHEDULED_TERMINAL_TTL.
	Now         time.Time
	TerminalTTL time.Duration
}

// PublishScheduled runs the publish transaction (see the file comment). Reads and writes are in the file comment; the
// no-op and every commit-on-failure outcome write nothing or exactly one document. A collision of the freshly drawn
// post id (AlreadyExists at commit) redraws and retries, like Create.
func (r *FirestoreRepo) PublishScheduled(ctx context.Context, p PublishParams) (PublishResult, error) {
	if r.w.IDs == nil || r.w.Quotas == nil || r.w.Counters == nil || r.w.Profiles == nil {
		return PublishResult{}, errors.New("posts: repo has no publish writers configured")
	}
	if _, err := r.scheduledRef(p.UID, p.ID); err != nil {
		return PublishResult{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, createTxTimeout)
	defer cancel()

	var (
		res      PublishResult
		attempts int
		err      error
	)
	for try := 0; try <= maxIDCollisionRetries; try++ {
		res = PublishResult{}
		_, err = store.RunTransaction(ctx, r.client, guardPublishPanic(func(ctx context.Context, tx *firestore.Transaction) error {
			attempts++
			res = PublishResult{} // an Aborted retry starts from nothing: the doc may have changed since the last body run
			var err error
			res, err = r.publishAttempt(ctx, tx, p, attempts)
			return err
		}))
		// AlreadyExists at commit is a posts/{id} collision: the next run draws a new id.
		if status.Code(err) != codes.AlreadyExists {
			break
		}
	}
	if err != nil {
		return PublishResult{}, err
	}
	res.Attempts = attempts
	return res, nil
}

func (r *FirestoreRepo) publishAttempt(ctx context.Context, tx *firestore.Transaction, p PublishParams, attempt int) (PublishResult, error) {
	// (a) The scheduled doc: the exactly-once guard.
	sched, err := r.GetScheduledInTx(ctx, tx, p.UID, p.ID)
	switch {
	case errors.Is(err, ErrScheduledNotFound):
		return PublishResult{Outcome: PublishNoop}, nil
	case err != nil:
		return PublishResult{}, err
	case sched.Status != ScheduledPending:
		return PublishResult{Outcome: PublishNoop}, nil
	}
	b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))

	// (b) The account, read inside the transaction. DELETING or missing cancels, anything but ACTIVE fails.
	prof, err := r.w.Profiles.ProfileInTx(ctx, tx, p.UID)
	switch {
	case errors.Is(err, identity.ErrNotFound):
		return r.stageEnd(b, p, ScheduledCancelled, "")
	case err != nil:
		return PublishResult{}, fmt.Errorf("posts: publish author lookup: %w", err)
	}
	switch prof.Status {
	case identity.AccountStatusActive:
	case identity.AccountStatusDeleting:
		return r.stageEnd(b, p, ScheduledCancelled, "")
	default: // SUSPENDED, or a status this revision does not know: never publish
		return r.stageEnd(b, p, ScheduledFailed, FailureAccountRestricted)
	}

	// (c) The posts quota, before any media or handle read.
	qrec, err := r.w.Quotas.Get(ctx, tx, p.UID)
	if err != nil {
		return PublishResult{}, fmt.Errorf("posts: publish quota lookup: %w", err)
	}
	limit := p.PostsLimit
	if !prof.CreatedAt.IsZero() && p.Now.Sub(prof.CreatedAt) < p.NewAccountWindow {
		limit = p.NewAccountPostsLimit
	}
	if qrec.Posts >= limit {
		return r.stageEnd(b, p, ScheduledFailed, FailureQuotaExceeded)
	}

	// (d) The images, read before the first write: one GetAll of len(ids) reads.
	var claim MediaClaim
	if len(p.MediaIDs) > 0 {
		if r.w.Media == nil {
			return r.stageEnd(b, p, ScheduledFailed, FailureMediaUnavailable)
		}
		claim, err = r.w.Media.LoadForPost(ctx, tx, p.UID, p.MediaIDs)
		if errors.Is(err, ErrMediaNotReady) {
			return r.stageEnd(b, p, ScheduledFailed, FailureMediaUnavailable)
		}
		if err != nil {
			return PublishResult{}, fmt.Errorf("posts: publish media load: %w", err)
		}
	}

	// (e) The mentions, last: handles may have changed since the post was scheduled.
	var mentions []Mention
	if p.ResolveMentions != nil {
		if mentions, err = p.ResolveMentions(ctx); err != nil {
			return PublishResult{}, err
		}
	}

	// Every read is done and nothing has been staged: build and stage the writes. The id (and so createdAt, the
	// Snowflake millisecond) is drawn in THIS attempt, so a retried attempt never commits a stale timestamp (D13).
	id := r.w.IDs.Generate()
	createdAt, err := snowflake.Time(id)
	if err != nil {
		return PublishResult{}, fmt.Errorf("posts: %w", err)
	}
	if r.attemptHook != nil {
		if err := r.attemptHook(attempt, id); err != nil {
			return PublishResult{}, err
		}
	}
	post := p.Draft
	post.ID, post.CreatedAt, post.ConversationID = id, createdAt, id
	post.AuthorID = p.UID
	post.Author = AuthorSnapshot{
		UserID: p.UID, Handle: prof.Handle, DisplayName: prof.DisplayName, AvatarURL: prof.AvatarThumbURL, Verified: prof.Verified,
	}
	post.SnapshotVersion = prof.SnapshotVersion
	post.Mentions = mentions
	if claim != nil {
		post.Media = mediaWithAlts(claim.Refs(), p.MediaAlts)
	}

	if err := quota.CheckAndReserve(b, r.w.Quotas.Ref(p.UID), qrec, quota.Posts, limit); err != nil {
		return PublishResult{}, err // unreachable after the pre-check above; never stage a partial write
	}
	b.Create(r.ref(id), toDoc(&post))
	if claim != nil {
		claim.Attach(b, id)
	}
	r.w.Counters.AddPostsCount(b, p.UID, 1)
	if err := r.StageScheduledTransition(b, p.UID, p.ID, ScheduledTransition{To: ScheduledPublished, PostID: id}, p.Now, p.TerminalTTL); err != nil {
		return PublishResult{}, err
	}
	if err := b.Err(); err != nil {
		return PublishResult{}, err
	}
	return PublishResult{Outcome: PublishPublished, Post: &post, AuthorCreatedAt: prof.CreatedAt}, nil
}

// stageEnd stages the one terminal transition of a permanent failure or a cancellation and reports it. The caller
// returns the result with a nil error, so the transaction COMMITS (1 write) instead of rolling back.
func (r *FirestoreRepo) stageEnd(b *store.FirestoreTxBatch, p PublishParams, to ScheduledStatus, failure ScheduledFailure) (PublishResult, error) {
	if err := r.StageScheduledTransition(b, p.UID, p.ID, ScheduledTransition{To: to, Failure: failure}, p.Now, p.TerminalTTL); err != nil {
		return PublishResult{}, err
	}
	if err := b.Err(); err != nil {
		return PublishResult{}, err
	}
	if to == ScheduledCancelled {
		return PublishResult{Outcome: PublishCancelled}, nil
	}
	return PublishResult{Outcome: PublishFailed, Failure: failure}, nil
}
