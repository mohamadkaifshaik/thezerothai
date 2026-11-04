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
func (f *fakeBatch) Update(_ *firestore.DocumentRef, _ []firestore.Update, _ ...firestore.Precondition) store.Batch {
	return f
}
func (f *fakeBatch) Delete(_ *firestore.DocumentRef, _ ...firestore.Precondition) store.Batch {
	return f
}

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
	// One hour earlier is still 2026-01-01 in IST.
	if got := TodayAt(utc.Add(-time.Hour)); got != "2026-01-01" {
		t.Errorf("TodayAt() = %q, want 2026-01-01", got)
	}
}

func TestUntilNextDay(t *testing.T) {
	ist := time.FixedZone("IST", 5*3600+30*60)
	tests := []struct {
		name string
		at   time.Time
		want time.Duration
	}{
		{"one minute before midnight", time.Date(2026, 1, 1, 23, 59, 0, 0, ist), time.Minute},
		{"exactly midnight", time.Date(2026, 1, 2, 0, 0, 0, 0, ist), 24 * time.Hour},
		{"noon", time.Date(2026, 1, 1, 12, 0, 0, 0, ist), 12 * time.Hour},
		{"month end, given in UTC", time.Date(2026, 1, 31, 18, 29, 0, 0, time.UTC), time.Minute},
	}
	for _, tt := range tests {
		if got := UntilNextDay(tt.at); got != tt.want {
			t.Errorf("%s: UntilNextDay = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestCheckAndReserve covers both kept kinds: a reservation under the limit increments only its own counter and
// writes once; at the limit nothing is written and the error is QUOTA_EXCEEDED naming the kind.
func TestCheckAndReserve(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		kind     Kind
		rec      Record
		limit    int64
		wantErr  bool
		wantRec  Record
		wantMeta string
	}{
		{"first report of the day", Reports, Record{Day: "d"}, 20, false, Record{Day: "d", Reports: 1}, ""},
		{"last report that fits", Reports, Record{Day: "d", Reports: 19, DMNew: 4}, 20, false, Record{Day: "d", Reports: 20, DMNew: 4}, ""},
		{"reports at the cap", Reports, Record{Day: "d", Reports: 5}, 5, true, Record{}, "reports"},
		{"first new conversation", DMNew, Record{Day: "d", Reports: 20}, 20, false, Record{Day: "d", Reports: 20, DMNew: 1}, ""},
		{"new conversations at the cap", DMNew, Record{Day: "d", DMNew: 20}, 20, true, Record{}, "dmNew"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, tt.kind, tt.limit)
			if !tt.wantErr {
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				if len(b.sets) != 1 || b.sets[0].(Record) != tt.wantRec {
					t.Fatalf("sets = %+v, want one Set of %+v", b.sets, tt.wantRec)
				}
				return
			}
			if len(b.sets) != 0 {
				t.Fatalf("expected no writes when over quota, got %d", len(b.sets))
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) {
				t.Fatalf("error is %T, want *apierr.Error", err)
			}
			if ae.Code != connect.CodeResourceExhausted || ae.Reason != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED {
				t.Errorf("Code/Reason = %v/%v", ae.Code, ae.Reason)
			}
			if ae.Metadata["quota"] != tt.wantMeta {
				t.Errorf("Metadata[quota] = %q, want %q", ae.Metadata["quota"], tt.wantMeta)
			}
			// common.proto: retry_after is set for QUOTA_EXCEEDED and runs to the next IST midnight (at most one day).
			if ae.RetryAfter <= 0 || ae.RetryAfter > 24*time.Hour {
				t.Errorf("RetryAfter = %v, want in (0, 24h]", ae.RetryAfter)
			}
		})
	}
}

// TestTouch: the record is written back once with only Seq bumped, so the write always changes the doc (an unchanged doc
// would not invalidate a racing transaction's read under optimistic concurrency).
func TestTouch(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	b := &fakeBatch{}
	rec := Record{Day: "d", Reports: 3, DMNew: 2, Seq: 7}
	Touch(b, ref, rec)
	want := Record{Day: "d", Reports: 3, DMNew: 2, Seq: 8}
	if len(b.sets) != 1 || b.sets[0].(Record) != want {
		t.Fatalf("sets = %+v, want one Set of %+v", b.sets, want)
	}
}
