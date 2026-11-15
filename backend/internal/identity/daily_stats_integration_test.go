//go:build integration

package identity_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// TestDailyStatsRepo_StageReadExportPurge: staged increments land on the shard of their key and a day reads as the sum
// of its shards (undos included); a missing day reads as zeros and the neighbouring days outside the window are not
// read; the export lists one row per shard doc, oldest first, without expireAt; the purge empties the subcollection.
func TestDailyStatsRepo_StageReadExportPurge(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := identity.NewDailyStatsRepo(client, nil)
	uid := fmt.Sprintf("stats-%d", rand.Int63())
	// Two keys on different shards for the 15th.
	k1, k2 := "actor-0", ""
	for i := 1; k2 == ""; i++ {
		if c := fmt.Sprintf("actor-%d", i); identity.StatsShard(c) != identity.StatsShard(k1) {
			k2 = c
		}
	}
	for _, s := range []struct {
		day, key string
		d        identity.DailyDelta
	}{
		{"20261112", k1, identity.DailyDelta{Impressions: 99}}, // before the window: never read
		{"20261114", k1, identity.DailyDelta{Impressions: 4, FollowersGained: 1}},
		{"20261115", k1, identity.DailyDelta{Engagements: 2}},
		{"20261115", k2, identity.DailyDelta{Engagements: 1}},
		{"20261115", k1, identity.DailyDelta{Engagements: -1, FollowersLost: 1}},
		{"20261116", k2, identity.DailyDelta{Impressions: 99}}, // after the window: never read
	} {
		b := store.NewFirestoreBatch(client)
		r.StageDaily(b, uid, s.day, s.key, s.d)
		if err := b.Commit(ctx); err != nil {
			t.Fatalf("commit: %v", err)
		}
	}
	got, err := r.ReadDailyStats(ctx, uid, []string{"20261113", "20261114", "20261115"})
	if err != nil {
		t.Fatal(err)
	}
	want := []identity.DailyStats{
		{Date: "20261113"},
		{Date: "20261114", Impressions: 4, FollowersGained: 1},
		{Date: "20261115", Engagements: 2, FollowersLost: 1},
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("day %d = %+v, want %+v", i, got[i], want[i])
		}
	}

	var buf bytes.Buffer
	if err := r.ExportDailyStats(ctx, uid, &buf); err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(buf.Bytes(), &rows); err != nil {
		t.Fatalf("export is not a JSON array: %v (%s)", err, buf.String())
	}
	if len(rows) != 5 || rows[0]["date"] != "20261112" || rows[4]["date"] != "20261116" {
		t.Fatalf("export = %s, want 5 shard rows oldest first", buf.String())
	}
	var eng float64
	for _, row := range rows {
		if row["date"] == "20261115" {
			eng += row["engagements"].(float64)
		}
	}
	if eng != 2 {
		t.Fatalf("export engagements of the 15th = %v, want 2 over its shards", eng)
	}
	if bytes.Contains(buf.Bytes(), []byte("expireAt")) {
		t.Errorf("export carries expireAt: %s", buf.String())
	}

	e := identity.NewDailyStatsEraser(r)
	cp, done, err := e.PurgeUser(ctx, uid, identity.DailyStatsCheckpoint{})
	if err != nil || !done || cp.Deleted != 5 {
		t.Fatalf("purge: %+v %v %v", cp, done, err)
	}
	if left, err := r.PurgeDailyStatsPage(ctx, uid); err != nil || left != 0 {
		t.Fatalf("after the purge: %d docs, %v", left, err)
	}
	buf.Reset()
	if err := r.ExportDailyStats(ctx, uid, &buf); err != nil || string(bytes.TrimSpace(buf.Bytes())) != "[]" {
		t.Fatalf("export after the purge = %q, %v; want []", buf.String(), err)
	}
}
