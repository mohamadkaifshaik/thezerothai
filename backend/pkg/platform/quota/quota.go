// Package quota implements the per-user daily quotas at quotas/{uid} (ADR-0003, ADR-0006 §4). The
// mutating RPC reads the doc inside its own transaction (1 read), rejects RESOURCE_EXHAUSTED if the
// caller is already at the limit, and appends the updated counters to the same atomic batch/transaction
// it's already using for the entity write (1 write, no extra round trip).
package quota

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const collection = "quotas"

// Kind names one of the daily counters on quotas/{uid}.
type Kind string

const (
	Posts   Kind = "posts"
	Follows Kind = "follows"
	Uploads Kind = "uploads"
	Exports Kind = "exports"
	// Blocks counts both Block and Mute calls (ADR-0008 D7): they share one daily counter. Unblock/Unmute
	// are never quota-gated.
	Blocks Kind = "blocks"
)

// istOffset is the fixed IST (+05:30) offset the quota day boundary rolls over at (ADR-0003).
var ist = time.FixedZone("IST", 5*3600+30*60)

// Today returns the current quota day key ("YYYY-MM-DD") in IST.
func Today() string {
	return TodayAt(time.Now())
}

// TodayAt is Today for an explicit instant (tests).
func TodayAt(t time.Time) string {
	return t.In(ist).Format("2006-01-02")
}

// UntilNextDay is the time from t until the next IST midnight, i.e. when a per-IST-day counter resets.
func UntilNextDay(t time.Time) time.Duration {
	y, m, d := t.In(ist).Date()
	return time.Date(y, m, d+1, 0, 0, 0, 0, ist).Sub(t)
}

// Record is the quotas/{uid} document shape.
type Record struct {
	Day     string `firestore:"day"`
	Posts   int64  `firestore:"posts"`
	Follows int64  `firestore:"follows"`
	Uploads int64  `firestore:"uploads"`
	Exports int64  `firestore:"exports"`
	// Blocks counts Block + Mute calls (ADR-0008 D7).
	Blocks int64 `firestore:"blocks"`
}

func (r Record) valueFor(k Kind) int64 {
	switch k {
	case Posts:
		return r.Posts
	case Follows:
		return r.Follows
	case Uploads:
		return r.Uploads
	case Exports:
		return r.Exports
	case Blocks:
		return r.Blocks
	default:
		return 0
	}
}

func (r *Record) increment(k Kind, n int64) {
	switch k {
	case Posts:
		r.Posts += n
	case Follows:
		r.Follows += n
	case Uploads:
		r.Uploads += n
	case Exports:
		r.Exports += n
	case Blocks:
		r.Blocks += n
	}
}

// Store builds quotas/{uid} refs against one Firestore client.
type Store struct {
	client *firestore.Client
}

func New(client *firestore.Client) *Store {
	return &Store{client: client}
}

func (s *Store) Ref(uid string) *firestore.DocumentRef {
	return s.client.Collection(collection).Doc(uid)
}

// Get reads today's counters for uid inside tx, treating "not found" and "rolled over to a new day" the
// same way: a fresh Record for today with all counters at 0. Counts against ctx's budget.Counter.
func (s *Store) Get(ctx context.Context, tx *firestore.Transaction, uid string) (Record, error) {
	today := Today()
	snap, err := tx.Get(s.Ref(uid))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Record{Day: today}, nil
		}
		return Record{}, fmt.Errorf("quota: get %s: %w", uid, err)
	}
	var rec Record
	if err := snap.DataTo(&rec); err != nil {
		return Record{}, fmt.Errorf("quota: decode %s: %w", uid, err)
	}
	if rec.Day != today {
		return Record{Day: today}, nil
	}
	return rec, nil
}

// CheckAndReserve verifies uid is under limit for kind and, if so, appends the incremented record to b
// (same atomic unit of work as the caller's entity write). rec must be the value returned by Get for the
// same uid in the same transaction.
func CheckAndReserve(b store.Batch, ref *firestore.DocumentRef, rec Record, kind Kind, limit int64) error {
	return CheckAndReserveN(b, ref, rec, kind, limit, 1)
}

// CheckAndReserveN is CheckAndReserve for a call that consumes n units at once (CreateUpload reserves one
// `uploads` unit per image, up to 4). It is rejected when the n units would not all fit under limit, so a
// 4-image call at 18/20 fails as a whole instead of half-reserving.
func CheckAndReserveN(b store.Batch, ref *firestore.DocumentRef, rec Record, kind Kind, limit, n int64) error {
	if rec.valueFor(kind)+n > limit {
		return apierr.New(
			connect.CodeResourceExhausted,
			commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED,
			"daily limit reached, please try again tomorrow",
		).WithMeta("quota", string(kind)).WithRetryAfter(UntilNextDay(time.Now()))
	}
	rec.increment(kind, n)
	b.Set(ref, rec)
	return nil
}
