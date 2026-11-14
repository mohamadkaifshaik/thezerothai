//go:build integration

package engagement

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

// viewShardSum sums posts/{id}/viewShards/*.count on the emulator.
func (e *repoEnv) viewShardSum(t *testing.T, postID string) int64 {
	t.Helper()
	docs, err := e.client.Collection("posts").Doc(postID).Collection("viewShards").Limit(20).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	var n int64
	for _, d := range docs {
		v, _ := d.DataAt("count")
		c, _ := v.(int64)
		n += c
	}
	return n
}

// RecordImpressions on the emulator: one impression doc per (viewer, post, IST day) with expireAt = createdAt + 48 h,
// one shard increment per counted view, a rollup marker per post; a repeat the same day counts nothing; concurrent calls
// of one viewer count once; the next IST day counts again.
func TestRepo_RecordImpressionsDedupe(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const p1, p2, uid = "0000000000000000061", "0000000000000000062", "viewer61"
	e.seedPost(t, p1, "author", 0, 0)
	e.seedPost(t, p2, "author", 0, 0)
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) // IST 2026-11-14 17:30

	n, err := e.repo.RecordImpressions(ctx, uid, []string{p1, p2}, now)
	if err != nil || n != 2 {
		t.Fatalf("first = %d, %v; want 2", n, err)
	}
	s, err := e.client.Doc("users/" + uid + "/impressions/" + p1 + "_20261114").Get(ctx)
	if err != nil {
		t.Fatalf("impression doc: %v", err)
	}
	var d impressionDoc
	if err := s.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.PostID != p1 || d.Day != "20261114" || !d.ExpireAt.Equal(d.CreatedAt.Add(48*time.Hour)) || len(s.Data()) != 4 {
		t.Fatalf("impression doc = %+v (%v), want the TTL field expireAt = createdAt + 48h", d, s.Data())
	}
	markers, err := e.client.Collection("viewDirty").Where("postId", "==", p1).Limit(5).Documents(ctx).GetAll()
	if err != nil || len(markers) != 1 {
		t.Fatalf("rollup markers = %d, %v; want 1", len(markers), err)
	}

	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := e.repo.RecordImpressions(ctx, uid, []string{p1, p2}, now.Add(time.Minute)); err != nil {
				t.Errorf("repeat: %v", err)
			}
		}()
	}
	wg.Wait()
	if e.viewShardSum(t, p1) != 1 || e.viewShardSum(t, p2) != 1 {
		t.Fatalf("shard sums %d/%d, want 1/1 after same-day repeats", e.viewShardSum(t, p1), e.viewShardSum(t, p2))
	}

	// 18:30 UTC is IST midnight: a new day counts again, concurrently from five calls exactly once.
	tomorrow := time.Date(2026, 11, 14, 18, 31, 0, 0, time.UTC)
	counted := make([]int, 5)
	for i := range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var err error
			if counted[i], err = e.repo.RecordImpressions(ctx, uid, []string{p1}, tomorrow); err != nil {
				t.Errorf("tomorrow: %v", err)
			}
		}()
	}
	wg.Wait()
	total := 0
	for _, c := range counted {
		total += c
	}
	if total != 1 || e.viewShardSum(t, p1) != 2 {
		t.Fatalf("next day counted %d (shards %d), want exactly 1 more", total, e.viewShardSum(t, p1))
	}
	if !e.exists(t, "users/"+uid+"/impressions/"+p1+"_20261115") {
		t.Fatal("no impression doc for the next IST day")
	}
}

// The erasure step deletes every users/{uid}/impressions doc (more than one page) and leaves another viewer's alone.
func TestRepo_PurgeImpressionsCoversTheSubcollection(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const uid, other = "erased62", "kept62"
	col := e.client.Collection("users").Doc(uid).Collection("impressions")
	for start := 0; start < impressionPage+20; start += 400 {
		b := e.client.BulkWriter(ctx)
		for i := start; i < min(start+400, impressionPage+20); i++ {
			if _, err := b.Set(col.Doc(fmt.Sprintf("%019d_20261114", i)), newImpressionDoc(fmt.Sprintf("%019d", i), "20261114", time.Now())); err != nil {
				t.Fatal(err)
			}
		}
		b.End()
	}
	if _, err := e.repo.RecordImpressions(ctx, other, []string{"0000000000000000063"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	er := NewImpressionEraser(e.repo)
	cp, done := ImpressionCheckpoint{}, false
	for i := 0; !done && i < 5; i++ {
		var err error
		if cp, done, err = er.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
	}
	if !done || cp.Deleted != impressionPage+20 {
		t.Fatalf("purge: done %v, deleted %d, want %d", done, cp.Deleted, impressionPage+20)
	}
	left, err := col.Limit(1).Documents(ctx).GetAll()
	if err != nil || len(left) != 0 {
		t.Fatalf("impressions left: %d, %v", len(left), err)
	}
	kept, err := e.client.Collection("users").Doc(other).Collection("impressions").Limit(5).Documents(ctx).GetAll()
	if err != nil || len(kept) != 1 {
		t.Fatalf("other viewer's impressions = %d, %v; want 1", len(kept), err)
	}
}
