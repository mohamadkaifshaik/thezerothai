package identity

import (
	"context"
	"errors"
	"reflect"
	"strconv"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// statsBatch records the Sets of StageDaily.
type statsBatch struct {
	sets []statsSet
}

type statsSet struct {
	path string
	data map[string]any
	opts []firestore.SetOption
}

func (b *statsBatch) Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) store.Batch {
	m, _ := data.(map[string]any)
	b.sets = append(b.sets, statsSet{path: ref.Path, data: m, opts: opts})
	return b
}
func (b *statsBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return b }
func (b *statsBatch) Update(*firestore.DocumentRef, []firestore.Update, ...firestore.Precondition) store.Batch {
	return b
}
func (b *statsBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return b }

// TestStatsDay: the IST day key, rolling over at 18:30 UTC.
func TestStatsDay(t *testing.T) {
	for _, tc := range []struct {
		at   time.Time
		want string
	}{
		{time.Date(2026, 11, 15, 18, 29, 59, 0, time.UTC), "20261115"},
		{time.Date(2026, 11, 15, 18, 30, 0, 0, time.UTC), "20261116"},
		{time.Date(2026, 12, 31, 20, 0, 0, 0, time.UTC), "20270101"},
		{time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), "20260101"},
	} {
		if got := StatsDay(tc.at); got != tc.want {
			t.Errorf("StatsDay(%v) = %s, want %s", tc.at, got, tc.want)
		}
	}
}

// TestDailyStatsIncrement: date, expireAt = the IST day's start + 400 days (the same on every write of the day), and an
// Increment only for the non-zero fields; a malformed day stages nothing.
func TestDailyStatsIncrement(t *testing.T) {
	data, ok := dailyStatsIncrement("20261115", 2, DailyDelta{Engagements: -1, FollowersGained: 2})
	if !ok {
		t.Fatal("a valid day was refused")
	}
	start := time.Date(2026, 11, 15, 0, 0, 0, 0, ist)
	want := map[string]any{
		"date": "20261115", "shard": int64(2), "expireAt": start.Add(DailyStatsTTL).UTC(),
		"engagements": firestore.Increment(int64(-1)), "followersGained": firestore.Increment(int64(2)),
	}
	if !reflect.DeepEqual(data, want) {
		t.Fatalf("data = %v\nwant %v", data, want)
	}
	if got := data["expireAt"].(time.Time); got != time.Date(2027, 12, 19, 18, 30, 0, 0, time.UTC) {
		t.Fatalf("expireAt = %v", got)
	}
	for _, bad := range []string{"", "2026-11-15", "20261332", "2026111", "202611150"} {
		if _, ok := dailyStatsIncrement(bad, 0, DailyDelta{Impressions: 1}); ok {
			t.Errorf("day %q accepted", bad)
		}
	}
}

// TestStatsShard: deterministic, in range, and the keys spread over every shard.
func TestStatsShard(t *testing.T) {
	seen := map[int]bool{}
	for i := 0; i < 200; i++ {
		k := "uid-" + strconv.Itoa(i)
		s := StatsShard(k)
		if s < 0 || s >= DailyStatsShards || s != StatsShard(k) {
			t.Fatalf("StatsShard(%q) = %d", k, s)
		}
		seen[s] = true
	}
	if len(seen) != DailyStatsShards {
		t.Fatalf("200 keys hit shards %v, want all %d", seen, DailyStatsShards)
	}
}

// TestStageDaily: one MergeAll Set on users/{uid}/dailyStats/{day}_{shard of the key}; nothing for an empty uid, a zero
// delta, a malformed day, or while the flag is globally off (Off).
func TestStageDaily(t *testing.T) {
	client := &firestore.Client{}
	off := false
	r := NewDailyStatsRepo(client, func() bool { return off })
	b := &statsBatch{}
	r.StageDaily(b, "author1", "20261115", "liker", DailyDelta{Impressions: 3})
	if len(b.sets) != 1 {
		t.Fatalf("sets = %d, want 1", len(b.sets))
	}
	want := client.Collection("users").Doc("author1").Collection("dailyStats").Doc("20261115_" + strconv.Itoa(StatsShard("liker"))).Path
	if s := b.sets[0]; s.path != want || len(s.opts) != 1 || !reflect.DeepEqual(s.data["impressions"], firestore.Increment(int64(3))) {
		t.Fatalf("set = %+v, want a MergeAll Increment at %s", s, want)
	}
	for _, tc := range []struct {
		name     string
		uid, day string
		d        DailyDelta
		off      bool
	}{
		{"empty uid", "", "20261115", DailyDelta{Impressions: 1}, false},
		{"zero delta", "a", "20261115", DailyDelta{}, false},
		{"malformed day", "a", "x", DailyDelta{Impressions: 1}, false},
		{"globally off", "a", "20261115", DailyDelta{Impressions: 1}, true},
	} {
		off = tc.off
		b := &statsBatch{}
		r.StageDaily(b, tc.uid, tc.day, "k", tc.d)
		if len(b.sets) != 0 {
			t.Errorf("%s: staged %+v", tc.name, b.sets)
		}
		if r.Off() != tc.off {
			t.Errorf("%s: Off = %v", tc.name, r.Off())
		}
	}
	var nilRepo *DailyStatsRepo
	nilRepo.StageDaily(&statsBatch{}, "a", "20261115", "k", DailyDelta{Impressions: 1}) // no panic
	if !nilRepo.Off() {
		t.Error("a nil repo must be off")
	}
}

type fakeStatsPurger struct {
	pages []int
	err   error
}

func (f *fakeStatsPurger) PurgeDailyStatsPage(context.Context, string) (int, error) {
	if f.err != nil {
		return 0, f.err
	}
	n := f.pages[0]
	f.pages = f.pages[1:]
	return n, nil
}

// TestDailyStatsEraser: a full page is not done, a short page is, the count carries over, an error keeps the checkpoint.
func TestDailyStatsEraser(t *testing.T) {
	e := NewDailyStatsEraser(&fakeStatsPurger{pages: []int{dailyStatsPage, 3}})
	cp, done, err := e.PurgeUser(context.Background(), "u", DailyStatsCheckpoint{})
	if err != nil || done || cp.Deleted != dailyStatsPage {
		t.Fatalf("first page: %+v %v %v", cp, done, err)
	}
	cp, done, err = e.PurgeUser(context.Background(), "u", cp)
	if err != nil || !done || cp.Deleted != dailyStatsPage+3 {
		t.Fatalf("second page: %+v %v %v", cp, done, err)
	}
	boom := errors.New("boom")
	got, _, err := NewDailyStatsEraser(&fakeStatsPurger{err: boom}).PurgeUser(context.Background(), "u", cp)
	if !errors.Is(err, boom) || got != cp {
		t.Fatalf("error: %+v %v", got, err)
	}
}
