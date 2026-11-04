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

// reserveDM runs the transaction shape of SendMessage's quota part: Get, then CheckAndReserve on the batch.
func reserveDM(t *testing.T, client *firestore.Client, s *Store, uid string, limit int64) error {
	t.Helper()
	_, err := store.RunTransaction(context.Background(), client, func(ctx context.Context, tx *firestore.Transaction) error {
		rec, err := s.Get(ctx, tx, uid)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		if err := CheckAndReserve(b, s.Ref(uid), rec, DMNew, limit); err != nil {
			return err
		}
		return b.Err()
	})
	return err
}

// TestDMNew_Integration_CapAndDayReset: the counter persists through quotas/{uid}, stops at the cap, and a record
// stamped with another IST day reads as a fresh day with the counter back at 0 (the daily reset).
func TestDMNew_Integration_CapAndDayReset(t *testing.T) {
	client := quotaTestClient(t)
	s := New(client)
	for i := 0; i < 3; i++ {
		if err := reserveDM(t, client, s, "u1", 3); err != nil {
			t.Fatalf("conversation %d: %v", i+1, err)
		}
	}
	if err := reserveDM(t, client, s, "u1", 3); err == nil {
		t.Fatal("the 4th new conversation of the day was accepted at a cap of 3")
	}
	snap, err := s.Ref("u1").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var rec Record
	if err := snap.DataTo(&rec); err != nil || rec.DMNew != 3 || rec.Day != Today() {
		t.Fatalf("stored record = %+v err=%v, want dmNew 3 on today", rec, err)
	}

	// Yesterday's record: Get reports a fresh day, so the cap is available again.
	if _, err := s.Ref("u1").Set(context.Background(), Record{Day: TodayAt(time.Now().Add(-26 * time.Hour)), DMNew: 3}); err != nil {
		t.Fatal(err)
	}
	if err := reserveDM(t, client, s, "u1", 3); err != nil {
		t.Fatalf("a new IST day must reset the counter: %v", err)
	}
}

// TestRecord_Integration_DropsRemovedCounters: a document written by an older revision, still holding the removed
// counters (posts, follows, likes...), decodes into the current Record, and the next whole-record Set leaves only the
// kept fields.
func TestRecord_Integration_DropsRemovedCounters(t *testing.T) {
	client := quotaTestClient(t)
	s := New(client)
	ctx := context.Background()
	old := map[string]any{"day": Today(), "posts": int64(7), "follows": int64(3), "likes": int64(40), "reports": int64(2), "dmNew": int64(1)}
	if _, err := s.Ref("u2").Set(ctx, old); err != nil {
		t.Fatal(err)
	}
	if err := reserveDM(t, client, s, "u2", 20); err != nil {
		t.Fatal(err)
	}
	snap, err := s.Ref("u2").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got := snap.Data()
	for _, gone := range []string{"posts", "follows", "likes"} {
		if _, ok := got[gone]; ok {
			t.Errorf("field %q survived the Set: %v", gone, got)
		}
	}
	if got["reports"] != int64(2) || got["dmNew"] != int64(2) {
		t.Errorf("record = %v, want reports 2 and dmNew 2", got)
	}
}
