// Package quota implements the per-user daily counters at quotas/{uid}. Only two remain: ReportContent writes and new
// direct-message conversations, both kept against spam rather than cost. The mutating RPC reads the doc inside its own
// transaction, rejects RESOURCE_EXHAUSTED if the caller is already at the limit, and appends the updated counters to the
// same atomic batch/transaction it's already using for the entity write (no extra round trip).
//
// SchedulePost, CreateList and RequestAccountExport also read and rewrite the doc, counting nothing (Touch): that makes two
// racing calls by one user conflict, which keeps the scheduled window cap, the per-owner list cap and the one running
// export per user exact.
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const collection = "quotas"

// Kind names one of the daily counters on quotas/{uid}.
type Kind string

const (
	// Reports counts ReportContent calls that wrote a report. A repeat report is a no-op and is not
	// charged.
	Reports Kind = "reports"
	// DMNew counts new direct-message conversations the caller opened: charged in the SendMessage
	// transaction that creates the conversation. Messages in an existing conversation are not charged here.
	DMNew Kind = "dmNew"
)

// ist is the fixed IST (+05:30) offset the day boundary rolls over at.
var ist = time.FixedZone("IST", 5*3600+30*60)

// Today returns the current day key ("YYYY-MM-DD") in IST.
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

// Record is the quotas/{uid} document shape. Every write Sets the whole record, so counters that older revisions kept
// on the doc (posts, follows, likes...) are dropped on the user's next write here.
type Record struct {
	Day string `firestore:"day"`
	// Reports counts ReportContent writes. Absent in older docs, so it decodes as 0.
	Reports int64 `firestore:"reports"`
	// DMNew counts new conversations opened. Absent in older docs, so it decodes as 0.
	DMNew int64 `firestore:"dmNew"`
	// Seq is bumped by every Touch so the write always changes the doc. A Set that leaves the doc unchanged keeps its old
	// update_time, and under optimistic concurrency a racing transaction that read it would then still commit.
	Seq int64 `firestore:"seq"`
}

func (r Record) valueFor(k Kind) int64 {
	switch k {
	case Reports:
		return r.Reports
	case DMNew:
		return r.DMNew
	default:
		return 0
	}
}

func (r *Record) increment(k Kind, n int64) {
	switch k {
	case Reports:
		r.Reports += n
	case DMNew:
		r.DMNew += n
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
// same way: a fresh Record for today with all counters at 0.
func (s *Store) Get(ctx context.Context, tx *firestore.Transaction, uid string) (Record, error) {
	today := Today()
	snap, err := tx.Get(s.Ref(uid))
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
	if rec.valueFor(kind)+1 > limit {
		return ExceededError(kind, time.Now())
	}
	rec.increment(kind, 1)
	b.Set(ref, rec)
	return nil
}

// Touch appends rec to b with Seq bumped and no counter changed. A transaction that read the doc with Get and writes it
// back conflicts with every other such transaction for the same uid, so of two racing calls only one commits and the other
// retries after it. rec must be the value returned by Get for the same uid in the same transaction.
func Touch(b store.Batch, ref *firestore.DocumentRef, rec Record) {
	rec.Seq++
	b.Set(ref, rec)
}

// ExceededError is the RESOURCE_EXHAUSTED / QUOTA_EXCEEDED error for kind at instant now, retry-after the next IST
// midnight. CheckAndReserve returns it; a module that remembers "this uid is out of quota until midnight" in its
// instance cache (moderation) builds the identical error from it without a Firestore read.
func ExceededError(kind Kind, now time.Time) *apierr.Error {
	return apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED,
		"daily limit reached, please try again tomorrow",
	).WithMeta("quota", string(kind)).WithRetryAfter(UntilNextDay(now))
}
