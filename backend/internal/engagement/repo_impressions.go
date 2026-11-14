// repo_impressions.go is the Firestore side of RecordImpressions (F1 post views): users/{uid}/impressions/{postId}_{day}
// {postId, day, createdAt, expireAt}, one per viewer, post and IST day. It is the dedupe record of a view and holds no
// one else's uid. expireAt = createdAt + 48 h is the Firestore TTL field (the TTL policy is an owner step); the account
// erasure deletes the subcollection outright (purge_impressions.go), because TTL alone is not erasure. The shard
// increment and the rollup marker are posts' writes, staged through posts.ViewWriter in the same batch.
//
//	Q-I1 users/{uid}/impressions LIMIT 500   -> no index (a plain collection read; erasure)
//
// No field of an impression doc is ever queried: createdAt, day and expireAt can be exempt from indexing (owner step).
package engagement

import (
	"context"
	"fmt"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// ImpressionsSubcollection is users/{uid}/impressions (lifecycle tables).
	ImpressionsSubcollection = "impressions"
	// ImpressionTTL is expireAt - createdAt: two days, so yesterday's doc still dedupes until today's IST day is over.
	ImpressionTTL = 48 * time.Hour
	// impressionAttempts is how many times RecordImpressions re-reads after losing a Create to a concurrent call.
	impressionAttempts = 2
)

var _ ImpressionRepo = (*FirestoreRepo)(nil)

// ImpressionDay is the IST day key (yyyymmdd) of t: the dedupe period of one viewer's views of one post. The day
// rolls over at IST midnight (18:30 UTC), the same boundary as the daily quotas.
func ImpressionDay(t time.Time) string {
	return strings.ReplaceAll(quota.TodayAt(t), "-", "")
}

// impressionID is the doc id {postId}_{yyyymmdd}.
func impressionID(postID, day string) string { return postID + "_" + day }

// impressionDoc is users/{uid}/impressions/{postId}_{day}.
type impressionDoc struct {
	PostID    string    `firestore:"postId"`
	Day       string    `firestore:"day"`
	CreatedAt time.Time `firestore:"createdAt"`
	// ExpireAt is the TTL field: CreatedAt + ImpressionTTL.
	ExpireAt time.Time `firestore:"expireAt"`
}

func newImpressionDoc(postID, day string, now time.Time) impressionDoc {
	now = now.UTC()
	return impressionDoc{PostID: postID, Day: day, CreatedAt: now, ExpireAt: now.Add(ImpressionTTL)}
}

func (r *FirestoreRepo) impressionRef(uid, postID, day string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(ImpressionsSubcollection).Doc(impressionID(postID, day))
}

// RecordImpressions implements ImpressionRepo.
func (r *FirestoreRepo) RecordImpressions(ctx context.Context, uid string, postIDs []string, now time.Time) (int, error) {
	if r.w.Views == nil {
		return 0, fmt.Errorf("engagement: repo has no posts view writer configured")
	}
	if len(postIDs) == 0 {
		return 0, nil
	}
	day := ImpressionDay(now)
	pending := postIDs
	for attempt := 0; ; attempt++ {
		fresh, err := r.unseen(ctx, uid, pending, day)
		if err != nil || len(fresh) == 0 {
			return 0, err
		}
		var committed func()
		res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
			for _, id := range fresh {
				b.Create(r.impressionRef(uid, id, day), newImpressionDoc(id, day, now))
			}
			committed = r.w.Views.StageViews(b, fresh, now)
		})
		store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
		switch {
		case err == nil && res.Committed:
			committed()
			return len(fresh), nil
		case err == nil:
			return 0, nil // no precondition other than the Creates: nothing was written
		case status.Code(err) == codes.AlreadyExists && attempt+1 < impressionAttempts:
			pending = fresh // a concurrent call of the same viewer won some Creates: re-read and count the rest
		case status.Code(err) == codes.AlreadyExists:
			return 0, nil
		default:
			return 0, fmt.Errorf("engagement: record impressions: %w", err)
		}
	}
}

// unseen is one GetAll of the day's impression docs of postIDs; it returns the ids without one, in order.
func (r *FirestoreRepo) unseen(ctx context.Context, uid string, postIDs []string, day string) ([]string, error) {
	refs := make([]*firestore.DocumentRef, len(postIDs))
	for i, id := range postIDs {
		refs[i] = r.impressionRef(uid, id, day)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("engagement: read impressions: %w", err)
	}
	out := make([]string, 0, len(postIDs))
	for i, s := range snaps {
		if s == nil || !s.Exists() {
			out = append(out, postIDs[i])
		}
	}
	return out, nil
}
