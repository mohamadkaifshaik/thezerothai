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
	// common.proto: retry_after is set for QUOTA_EXCEEDED and runs to the next IST midnight (at most one day).
	if ae.RetryAfter <= 0 || ae.RetryAfter > 24*time.Hour {
		t.Errorf("RetryAfter = %v, want in (0, 24h]", ae.RetryAfter)
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

// TestCheckAndReserveN: n units are reserved together, or the whole call is rejected with nothing written.
func TestCheckAndReserveN(t *testing.T) {
	tests := []struct {
		name     string
		have     int64
		n        int64
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"fits exactly", 16, 4, 20, false, 20},
		{"one unit over rejects the whole call", 17, 4, 20, true, 17},
		{"empty day", 0, 4, 20, false, 4},
		{"single unit equals CheckAndReserve", 19, 1, 20, false, 20},
		{"already at the limit", 20, 1, 20, true, 20},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
			b := &fakeBatch{}
			err := CheckAndReserveN(b, ref, Record{Day: Today(), Uploads: tt.have}, Uploads, tt.limit, tt.n)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				if len(b.sets) != 0 {
					t.Fatalf("a rejected call wrote %d docs", len(b.sets))
				}
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["quota"] != "uploads" {
					t.Fatalf("err = %v, want QUOTA_EXCEEDED for uploads", err)
				}
				return
			}
			if len(b.sets) != 1 || b.sets[0].(Record).Uploads != tt.wantUsed {
				t.Fatalf("sets = %+v, want Uploads %d", b.sets, tt.wantUsed)
			}
		})
	}
}

// TestSchedulesKind: the schedules counter (ADR-0021 D4) reserves like the others, is independent of posts, rejects
// with QUOTA_EXCEEDED metadata quota=schedules, and the only thing it writes is the one whole-record Set.
func TestSchedulesKind(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first schedule of the day", Record{Day: Today()}, 50, false, 1},
		{"last one that fits", Record{Day: Today(), Schedules: 49}, 50, false, 50},
		{"at the daily cap", Record{Day: Today(), Schedules: 50}, 50, true, 50},
		{"new-account cap of 10", Record{Day: Today(), Schedules: 10}, 10, true, 10},
		{"posts at its own cap do not block schedules", Record{Day: Today(), Posts: 100}, 50, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, Schedules, tt.limit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["quota"] != "schedules" || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED quota=schedules and nothing written", err, len(b.sets))
				}
				return
			}
			got := b.sets[0].(Record)
			if got.Schedules != tt.wantUsed || got.Posts != tt.rec.Posts {
				t.Errorf("record = %+v, want Schedules %d and Posts untouched", got, tt.wantUsed)
			}
		})
	}
	if got := (Record{Schedules: 7}).valueFor(Schedules); got != 7 {
		t.Errorf("valueFor(Schedules) = %d, want 7", got)
	}
	if got := (Record{Schedules: 7}).valueFor(Posts); got != 0 {
		t.Errorf("valueFor(Posts) = %d, want 0: schedules must not leak into other kinds", got)
	}
}

// TestBookmarksKind: the bookmarks counter (ADR-0023 D4) reserves like the others, is independent of every other kind
// (including likes and schedules, which share the whole-record Set), and rejects with QUOTA_EXCEEDED quota=bookmarks.
func TestBookmarksKind(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first bookmark of the day", Record{Day: Today()}, 200, false, 1},
		{"last one that fits", Record{Day: Today(), Bookmarks: 199}, 200, false, 200},
		{"at the daily cap", Record{Day: Today(), Bookmarks: 200}, 200, true, 200},
		{"new-account cap of 50", Record{Day: Today(), Bookmarks: 50}, 50, true, 50},
		{"likes at their own cap do not block bookmarks", Record{Day: Today(), Likes: 500}, 200, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, Bookmarks, tt.limit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["quota"] != "bookmarks" || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED quota=bookmarks and nothing written", err, len(b.sets))
				}
				return
			}
			got := b.sets[0].(Record)
			if got.Bookmarks != tt.wantUsed || got.Likes != tt.rec.Likes || got.Schedules != tt.rec.Schedules {
				t.Errorf("record = %+v, want Bookmarks %d and the other kinds untouched", got, tt.wantUsed)
			}
		})
	}
	if got := (Record{Bookmarks: 7}).valueFor(Bookmarks); got != 7 {
		t.Errorf("valueFor(Bookmarks) = %d, want 7", got)
	}
	if got := (Record{Bookmarks: 7}).valueFor(Likes); got != 0 {
		t.Errorf("valueFor(Likes) = %d, want 0: bookmarks must not leak into other kinds", got)
	}
}

// TestPrivacyTogglesKind: the privacyToggles counter (ADR-0025 D8) reserves like the others, rejects with QUOTA_EXCEEDED
// metadata quota=privacy_toggles, never touches another kind, and the Record field, valueFor and increment ship together
// (ADR-0021 I-3: the whole-record Set of CheckAndReserveN would zero a field one of them forgot).
func TestPrivacyTogglesKind(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first toggle of the day", Record{Day: Today()}, 4, false, 1},
		{"fourth toggle fits", Record{Day: Today(), PrivacyToggles: 3}, 4, false, 4},
		{"fifth toggle is refused", Record{Day: Today(), PrivacyToggles: 4}, 4, true, 4},
		{"other kinds at their cap do not block", Record{Day: Today(), Follows: 200, Bookmarks: 200, Schedules: 50}, 4, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, PrivacyToggles, tt.limit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["quota"] != "privacy_toggles" || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED quota=privacy_toggles and nothing written", err, len(b.sets))
				}
				return
			}
			got := b.sets[0].(Record)
			if got.PrivacyToggles != tt.wantUsed || got.Follows != tt.rec.Follows || got.Bookmarks != tt.rec.Bookmarks || got.Schedules != tt.rec.Schedules {
				t.Errorf("record = %+v, want PrivacyToggles %d and the other kinds untouched", got, tt.wantUsed)
			}
		})
	}
	if got := (Record{PrivacyToggles: 7}).valueFor(PrivacyToggles); got != 7 {
		t.Errorf("valueFor(PrivacyToggles) = %d, want 7", got)
	}
	if got := (Record{PrivacyToggles: 7}).valueFor(Follows); got != 0 {
		t.Errorf("valueFor(Follows) = %d, want 0: toggles must not leak into other kinds", got)
	}
	var r Record
	r.increment(PrivacyToggles, 2)
	if r.PrivacyToggles != 2 || r.Follows != 0 {
		t.Errorf("increment(PrivacyToggles, 2) = %+v", r)
	}
}

// TestDMNewKind: the dmNew counter (ADR-0027 D13) reserves like the others, never touches another kind, and the Record
// field, valueFor and increment ship together (ADR-0021 I-3: the whole-record Set of CheckAndReserveN would zero a field
// one of them forgot). The Firestore field name is dmNew.
func TestDMNewKind(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first new conversation of the day", Record{Day: Today()}, 20, false, 1},
		{"last one that fits", Record{Day: Today(), DMNew: 19}, 20, false, 20},
		{"at the daily cap", Record{Day: Today(), DMNew: 20}, 20, true, 20},
		{"new-account cap of 5", Record{Day: Today(), DMNew: 5}, 5, true, 5},
		{"other kinds at their cap do not block", Record{Day: Today(), Posts: 100, Follows: 200, Bookmarks: 200}, 20, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, DMNew, tt.limit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				var ae *apierr.Error
				if !errors.As(err, &ae) || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED and nothing written", err, len(b.sets))
				}
				return
			}
			got := b.sets[0].(Record)
			if got.DMNew != tt.wantUsed {
				t.Errorf("DMNew = %d, want %d", got.DMNew, tt.wantUsed)
			}
			if got.Posts != tt.rec.Posts || got.Follows != tt.rec.Follows || got.Bookmarks != tt.rec.Bookmarks || got.PrivacyToggles != tt.rec.PrivacyToggles {
				t.Errorf("record = %+v, want the other kinds untouched", got)
			}
		})
	}
	if got := (Record{DMNew: 7}).valueFor(DMNew); got != 7 {
		t.Errorf("valueFor(DMNew) = %d, want 7", got)
	}
	if got := (Record{DMNew: 7}).valueFor(Follows); got != 0 {
		t.Errorf("valueFor(Follows) = %d, want 0: dmNew must not leak into other kinds", got)
	}
	var r Record
	r.increment(DMNew, 2)
	if r.DMNew != 2 || r.Follows != 0 || r.PrivacyToggles != 0 {
		t.Errorf("increment(DMNew, 2) = %+v", r)
	}
}
