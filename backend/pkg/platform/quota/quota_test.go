package quota

import (
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeBatch records Set/Create/Update/Delete calls without touching Firestore.
type fakeBatch struct {
	sets    []interface{}
	creates []interface{}
}

func (f *fakeBatch) Set(_ *firestore.DocumentRef, data interface{}, _ ...firestore.SetOption) store.Batch {
	f.sets = append(f.sets, data)
	return f
}
func (f *fakeBatch) Create(_ *firestore.DocumentRef, data interface{}) store.Batch {
	f.creates = append(f.creates, data)
	return f
}
func (f *fakeBatch) Update(_ *firestore.DocumentRef, _ []firestore.Update) store.Batch { return f }
func (f *fakeBatch) Delete(_ *firestore.DocumentRef) store.Batch                       { return f }

func TestStore_RefPath(t *testing.T) {
	client := &firestore.Client{}
	s := New(client)
	if got, want := s.Ref("uid-1").Path, client.Collection(collection).Doc("uid-1").Path; got != want {
		t.Errorf("Ref path = %q, want %q", got, want)
	}
}

func TestTodayAt_ISTBoundary(t *testing.T) {
	// 2026-01-01T18:35:00Z = 2026-01-02T00:05:00+05:30: already rolled over to the next IST day.
	utc := time.Date(2026, 1, 1, 18, 35, 0, 0, time.UTC)
	if got := TodayAt(utc); got != "2026-01-02" {
		t.Errorf("TodayAt() = %q, want 2026-01-02", got)
	}
	// One minute earlier is still 2026-01-01 in IST.
	if got := TodayAt(utc.Add(-time.Hour)); got != "2026-01-01" {
		t.Errorf("TodayAt() = %q, want 2026-01-01", got)
	}
}

func TestCheckAndReserve_UnderLimitIncrementsAndWrites(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	b := &fakeBatch{}
	rec := Record{Day: Today(), Posts: 2}

	if err := CheckAndReserve(b, ref, rec, Posts, 5); err != nil {
		t.Fatalf("CheckAndReserve() error = %v", err)
	}
	if len(b.sets) != 1 {
		t.Fatalf("expected 1 Set call, got %d", len(b.sets))
	}
	got := b.sets[0].(Record)
	if got.Posts != 3 {
		t.Errorf("Posts = %d, want 3 (incremented)", got.Posts)
	}
}

func TestCheckAndReserve_AtLimitRejectsWithoutWriting(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	b := &fakeBatch{}
	rec := Record{Day: Today(), Follows: 200}

	err := CheckAndReserve(b, ref, rec, Follows, 200)
	if err == nil {
		t.Fatal("expected quota exceeded error")
	}
	if len(b.sets) != 0 {
		t.Fatalf("expected no writes when over quota, got %d", len(b.sets))
	}

	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeResourceExhausted {
		t.Errorf("Code = %v, want ResourceExhausted", ae.Code)
	}
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED {
		t.Errorf("Reason = %v", ae.Reason)
	}
	if ae.Metadata["quota"] != "follows" {
		t.Errorf("Metadata[quota] = %q, want follows", ae.Metadata["quota"])
	}
}

func TestCheckAndReserve_KindsAreIndependent(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	rec := Record{Day: Today(), Posts: 100, Follows: 1, Uploads: 1, Exports: 0}

	// Posts is at its limit, but Exports is a separate counter and should still succeed.
	if err := CheckAndReserve(&fakeBatch{}, ref, rec, Exports, 1); err != nil {
		t.Fatalf("Exports should not be blocked by Posts being at its own limit: %v", err)
	}
	if err := CheckAndReserve(&fakeBatch{}, ref, rec, Posts, 100); err == nil {
		t.Fatal("expected Posts to be at its limit")
	}
}
