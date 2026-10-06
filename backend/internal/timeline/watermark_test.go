package timeline

import (
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

func TestWatermark(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 10, 5, 12, 0, 0, 123_000_000, time.UTC)
	tests := []struct {
		name   string
		loaded []time.Time
		settle time.Duration
		want   time.Time
	}{
		{"no entries: start - settle", nil, 15 * time.Second, start.Add(-15 * time.Second).Truncate(time.Millisecond)},
		{"entry loaded 40 s ago lowers W to loadedAt - settle", []time.Time{start.Add(-40 * time.Second)}, 15 * time.Second, start.Add(-55 * time.Second)},
		{"entry newer than start is ignored", []time.Time{start.Add(time.Second)}, 15 * time.Second, start.Add(-15 * time.Second)},
		{"the oldest entry wins", []time.Time{start.Add(-10 * time.Second), start.Add(-50 * time.Second), start.Add(-20 * time.Second)}, 15 * time.Second, start.Add(-65 * time.Second)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Watermark(start, tc.loaded, tc.settle)
			if !got.CreatedAt.Equal(tc.want.Truncate(time.Millisecond)) || got.ID != zeroID {
				t.Fatalf("W = %v/%s, want %v/%s", got.CreatedAt, got.ID, tc.want, zeroID)
			}
		})
	}
}

func TestNextSince(t *testing.T) {
	t.Parallel()
	w := pos(10_000, 0)
	w.ID = zeroID
	tests := []struct {
		name        string
		old, newest *int64 // ms
		wantMS      int64
		wantID      string
		wantClamped bool
	}{
		{name: "newest later than W encodes W", newest: i64(12_000), wantMS: 10_000, wantID: zeroID, wantClamped: true},
		{name: "newest earlier than W encodes the newest", newest: i64(9_000), wantMS: 9_000, wantID: pid(9)},
		{name: "empty result advances to W", wantMS: 10_000, wantID: zeroID},
		{name: "empty result never moves back before the old since", old: i64(11_000), wantMS: 11_000, wantID: pid(11)},
		{name: "old since beats an older newest", old: i64(9_500), newest: i64(9_000), wantMS: 9_500, wantID: pid(9)},
		{name: "newest at the same instant as W is newer (id > zeroID) so W wins", newest: i64(10_000), wantMS: 10_000, wantID: zeroID, wantClamped: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var old, newest *posts.Position
			if tc.old != nil {
				p := pos(*tc.old, *tc.old/1000)
				old = &p
			}
			if tc.newest != nil {
				p := pos(*tc.newest, *tc.newest/1000)
				newest = &p
			}
			got, clamped := NextSince(old, newest, w)
			if got.CreatedAt.UnixMilli() != tc.wantMS || got.ID != tc.wantID || clamped != tc.wantClamped {
				t.Fatalf("got (%d,%s,%v), want (%d,%s,%v)", got.CreatedAt.UnixMilli(), got.ID, clamped, tc.wantMS, tc.wantID, tc.wantClamped)
			}
		})
	}
}

func i64(v int64) *int64 { return &v }
