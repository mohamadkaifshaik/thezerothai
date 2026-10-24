//go:build integration

package quota

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func quotaTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

// reserveSchedule runs the transaction shape of SchedulePost's quota part: Get, then CheckAndReserve on the batch.
func reserveSchedule(t *testing.T, client *firestore.Client, s *Store, uid string, limit int64) error {
	t.Helper()
	ctx, _ := budget.WithCounter(context.Background())
	_, err := store.RunTransaction(ctx, client, func(ctx context.Context, tx *firestore.Transaction) error {
		rec, err := s.Get(ctx, tx, uid)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if err := CheckAndReserve(b, s.Ref(uid), rec, Schedules, limit); err != nil {
			return err
		}
		return b.Err()
	})
	return err
}

// TestSchedules_Integration_CapAndDayReset: the counter persists through quotas/{uid}, stops at the cap, and a record
// stamped with another IST day reads as a fresh day with schedules back at 0 (the daily reset).
func TestSchedules_Integration_CapAndDayReset(t *testing.T) {
	client := quotaTestClient(t)
	s := New(client)
	for i := 0; i < 3; i++ {
		if err := reserveSchedule(t, client, s, "u1", 3); err != nil {
			t.Fatalf("schedule %d: %v", i+1, err)
		}
	}
	if err := reserveSchedule(t, client, s, "u1", 3); err == nil {
		t.Fatal("the 4th schedule of the day was accepted at a cap of 3")
	}
	snap, err := s.Ref("u1").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var rec Record
	if err := snap.DataTo(&rec); err != nil || rec.Schedules != 3 || rec.Day != Today() {
		t.Fatalf("stored record = %+v err=%v, want schedules 3 on today", rec, err)
	}

	// Yesterday's record: Get reports a fresh day, so the cap is available again.
	if _, err := s.Ref("u1").Set(context.Background(), Record{Day: TodayAt(time.Now().Add(-26 * time.Hour)), Schedules: 3}); err != nil {
		t.Fatal(err)
	}
	if err := reserveSchedule(t, client, s, "u1", 3); err != nil {
		t.Fatalf("a new IST day must reset the counter: %v", err)
	}
}

// legacyRecord is quotas/{uid} as a revision built before ADR-0021 knew it: no schedules field.
type legacyRecord struct {
	Day           string `firestore:"day"`
	Posts         int64  `firestore:"posts"`
	Follows       int64  `firestore:"follows"`
	Uploads       int64  `firestore:"uploads"`
	Exports       int64  `firestore:"exports"`
	Blocks        int64  `firestore:"blocks"`
	Reports       int64  `firestore:"reports"`
	Likes         int64  `firestore:"likes"`
	SnapshotEdits int64  `firestore:"snapshotEdits"`
}

// TestSchedules_Integration_OldRevisionResets pins review I-3: a record written without the field decodes as 0, and
// the whole-record Set of a revision that does not know `schedules` zeroes it on that user's next quota'd call.
// This is why a rollback past the first release holding the field resets the day's count (bounded by the cap), and
// why a persistent counter must never live on quotas/{uid}.
func TestSchedules_Integration_OldRevisionResets(t *testing.T) {
	client := quotaTestClient(t)
	s := New(client)
	ctx := context.Background()
	if err := reserveSchedule(t, client, s, "u2", 50); err != nil {
		t.Fatal(err)
	}
	if err := reserveSchedule(t, client, s, "u2", 50); err != nil {
		t.Fatal(err)
	}

	// The old revision reads the record (the unknown field is ignored) and Sets the whole thing back after a like.
	snap, err := s.Ref("u2").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var old legacyRecord
	if err := snap.DataTo(&old); err != nil {
		t.Fatalf("an older struct must still decode the new document: %v", err)
	}
	old.Likes++
	if _, err := s.Ref("u2").Set(ctx, old); err != nil {
		t.Fatal(err)
	}

	snap, err = s.Ref("u2").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var rec Record
	if err := snap.DataTo(&rec); err != nil {
		t.Fatal(err)
	}
	if rec.Schedules != 0 || rec.Likes != 1 {
		t.Fatalf("record = %+v, want schedules reset to 0 by the old revision's Set (I-3)", rec)
	}
}
