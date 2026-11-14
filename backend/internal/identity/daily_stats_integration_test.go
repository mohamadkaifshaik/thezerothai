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

// TestDailyStatsRepo_StageReadExportPurge: staged increments add up per day (undos included), a missing day reads as
// zeros, the export lists the docs oldest first without expireAt, and the purge empties the subcollection.
func TestDailyStatsRepo_StageReadExportPurge(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := identity.NewDailyStatsRepo(client, nil)
	uid := fmt.Sprintf("stats-%d", rand.Int63())
	for _, s := range []struct {
		day string
		d   identity.DailyDelta
	}{
		{"20261114", identity.DailyDelta{Impressions: 4, FollowersGained: 1}},
		{"20261115", identity.DailyDelta{Engagements: 2}},
		{"20261115", identity.DailyDelta{Engagements: -1, FollowersLost: 1}},
	} {
		b := store.NewFirestoreBatch(client)
		r.StageDaily(b, uid, s.day, s.d)
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
		{Date: "20261115", Engagements: 1, FollowersLost: 1},
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
	if len(rows) != 2 || rows[0]["date"] != "20261114" || rows[1]["date"] != "20261115" || rows[1]["engagements"] != float64(1) {
		t.Fatalf("export = %s", buf.String())
	}
	if bytes.Contains(buf.Bytes(), []byte("expireAt")) {
		t.Errorf("export carries expireAt: %s", buf.String())
	}

	e := identity.NewDailyStatsEraser(r)
	cp, done, err := e.PurgeUser(ctx, uid, identity.DailyStatsCheckpoint{})
	if err != nil || !done || cp.Deleted != 2 {
		t.Fatalf("purge: %+v %v %v", cp, done, err)
	}
	if left, err := r.PurgeDailyStatsPage(ctx, uid); err != nil || left != 0 {
		t.Fatalf("after the purge: %d docs, %v", left, err)
	}
	buf.Reset()
	if err := r.ExportDailyStats(ctx, uid, &buf); err != nil || bytes.TrimSpace(buf.Bytes())[0] != '[' || len(bytes.TrimSpace(buf.Bytes())) != 2 {
		t.Fatalf("export after the purge = %q, %v; want []", buf.String(), err)
	}
}
