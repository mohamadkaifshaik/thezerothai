//go:build integration

package engagement

import (
	"context"
	"errors"
	"strconv"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

const hotThreshold = 10

// shardSum adds up field over posts/{id}/viewShards (the hot counter shards).
func (e *repoEnv) shardSum(t *testing.T, postID, field string) int64 {
	t.Helper()
	var total int64
	for i := range posts.ViewShardCount {
		s, err := e.client.Doc("posts/" + postID + "/" + posts.ViewShardsSubcollection + "/" + strconv.Itoa(i)).Get(context.Background())
		if err != nil {
			continue // a shard never written
		}
		v, _ := s.DataAt(field)
		n, _ := v.(int64)
		total += n
	}
	return total
}

// counterMarkers counts the viewDirty counter markers of postID (posts' rollup markers carry postId).
func (e *repoEnv) counterMarkers(t *testing.T, postID string) int {
	t.Helper()
	docs, err := e.client.Collection("viewDirty").Where("postId", "==", postID).Limit(20).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, d := range docs {
		if _, err := d.DataAt("counterWindow"); err == nil {
			n++
		}
	}
	return n
}

// TestHotCounters_LikeRepostShareThenRollup: on a post at HOT_COUNTER_THRESHOLD, likes, an unlike, a repost and a share
// go to its shards with a counter marker and leave the plain fields alone; a cold like on the same post (a caller that
// read a count below the threshold) Increments the plain field; the rollup then makes every plain field exact and nets
// the shards to 0, and a redelivered fold changes nothing.
func TestHotCounters_LikeRepostShareThenRollup(t *testing.T) {
	e := newRepoEnv(t)
	e.posts.SetHotCounterThreshold(hotThreshold)
	ctx := context.Background()
	const pid = "0000000000000000031"
	e.seedPost(t, pid, "author", hotThreshold, hotThreshold)
	if _, err := e.client.Doc("posts/"+pid).Update(ctx, []firestore.Update{{Path: "shareCount", Value: int64(hotThreshold)}}); err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{"h1", "h2", "h3"} {
		if replay, err := e.repo.Like(ctx, LikeParams{UID: uid, PostID: pid, Known: hotThreshold}); err != nil || replay {
			t.Fatalf("hot Like %s: replay=%v err=%v", uid, replay, err)
		}
	}
	if replay, err := e.repo.Like(ctx, LikeParams{UID: "h1", PostID: pid, Known: hotThreshold}); err != nil || !replay {
		t.Fatalf("hot Like replay: replay=%v err=%v", replay, err)
	}
	if removed, err := e.repo.Unlike(ctx, "h2", pid, hotThreshold, ""); err != nil || !removed {
		t.Fatalf("hot Unlike: removed=%v err=%v", removed, err)
	}
	if removed, err := e.repo.Unlike(ctx, "never", pid, hotThreshold, ""); err != nil || removed {
		t.Fatalf("hot Unlike of nothing: removed=%v err=%v", removed, err)
	}
	if replay, err := e.repo.Like(ctx, LikeParams{UID: "c1", PostID: pid, Known: hotThreshold - 1}); err != nil || replay {
		t.Fatalf("cold Like: replay=%v err=%v", replay, err)
	}
	if _, err := e.client.Doc("users/r1").Set(ctx, map[string]any{"postsCount": int64(0)}); err != nil {
		t.Fatal(err)
	}
	res, err := e.repo.Repost(ctx, RepostParams{UID: "r1", Original: &posts.Post{ID: pid, AuthorID: "author", RepostCount: hotThreshold},
		Author: posts.AuthorSnapshot{UserID: "r1", Handle: "h"}})
	if err != nil || res.Post == nil {
		t.Fatalf("hot Repost: %+v %v", res, err)
	}
	if o, err := e.repo.CreateShare(ctx, "s1", pid, hotThreshold); err != nil || o != ShareCreated {
		t.Fatalf("hot CreateShare = %v, %v", o, err)
	}
	if o, err := e.repo.CreateShare(ctx, "s1", pid, hotThreshold); err != nil || o != ShareExists {
		t.Fatalf("hot CreateShare again = %v, %v; want ShareExists", o, err)
	}

	// Before the rollup: the plain fields moved only by the cold like; the shards hold the hot deltas.
	if l, r, s := e.intField(t, "posts/"+pid, "likeCount"), e.intField(t, "posts/"+pid, "repostCount"), e.intField(t, "posts/"+pid, "shareCount"); l != 11 || r != 10 || s != 10 {
		t.Fatalf("plain before the rollup: like %d repost %d share %d, want 11 10 10", l, r, s)
	}
	if l, r, s := e.shardSum(t, pid, "likeCount"), e.shardSum(t, pid, "repostCount"), e.shardSum(t, pid, "shareCount"); l != 2 || r != 1 || s != 1 {
		t.Fatalf("shards before the rollup: like %d repost %d share %d, want 2 1 1", l, r, s)
	}
	if n := e.counterMarkers(t, pid); n != 1 {
		t.Fatalf("counter markers = %d, want 1 (once per window and instance)", n)
	}

	// The rollup, on a tick whose window is past the writes' (post_views off: the counter half still runs).
	roll := &posts.ViewRollup{Repo: e.posts, Off: func() bool { return true }, Now: func() time.Time { return time.Now().Add(2 * posts.ViewWindow) }}
	rr, err := roll.Run(ctx)
	if err != nil || rr.CountersFolded != 1 {
		t.Fatalf("rollup = %+v, %v; want 1 post folded", rr, err)
	}
	exact := func(when string) {
		t.Helper()
		if l, r, s := e.intField(t, "posts/"+pid, "likeCount"), e.intField(t, "posts/"+pid, "repostCount"), e.intField(t, "posts/"+pid, "shareCount"); l != 13 || r != 11 || s != 11 {
			t.Fatalf("%s: like %d repost %d share %d, want 13 11 11", when, l, r, s)
		}
		if l, r, s := e.shardSum(t, pid, "likeCount"), e.shardSum(t, pid, "repostCount"), e.shardSum(t, pid, "shareCount"); l != 0 || r != 0 || s != 0 {
			t.Fatalf("%s: shards like %d repost %d share %d, want all 0", when, l, r, s)
		}
	}
	exact("after the rollup")
	if n := e.counterMarkers(t, pid); n != 0 {
		t.Fatalf("counter markers after the rollup = %d, want 0", n)
	}
	// A redelivered fold (the same post folded again, as a retried or overlapping run would) does not double-count.
	for range 2 {
		if done, folded, _, err := e.posts.FoldCounters(ctx, []string{pid}); err != nil || folded != 1 || len(done) != 1 {
			t.Fatalf("refold = %v %d %v", done, folded, err)
		}
	}
	exact("after the redelivered folds")
}

// TestHotCounters_LikeOfDeletedPost: a hot like (or share, or repost) of a post deleted since the service read it is
// ErrPostGone (SharePostGone) and writes nothing: no like doc, no userLikes, no shard, no marker.
func TestHotCounters_LikeOfDeletedPost(t *testing.T) {
	e := newRepoEnv(t)
	e.posts.SetHotCounterThreshold(hotThreshold)
	ctx := context.Background()
	const pid, uid = "0000000000000000032", "g1"
	e.seedPost(t, pid, "author", hotThreshold, hotThreshold)
	if _, err := e.client.Doc("posts/" + pid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.Like(ctx, LikeParams{UID: uid, PostID: pid, Known: hotThreshold}); !errors.Is(err, ErrPostGone) {
		t.Fatalf("hot Like of a deleted post = %v, want ErrPostGone", err)
	}
	if o, err := e.repo.CreateShare(ctx, uid, pid, hotThreshold); err != nil || o != SharePostGone {
		t.Fatalf("hot CreateShare of a deleted post = %v, %v; want SharePostGone", o, err)
	}
	if _, err := e.client.Doc("users/"+uid).Set(ctx, map[string]any{"postsCount": int64(0)}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.Repost(ctx, RepostParams{UID: uid, Original: &posts.Post{ID: pid, AuthorID: "author", RepostCount: hotThreshold},
		Author: posts.AuthorSnapshot{UserID: uid, Handle: "h"}}); !errors.Is(err, ErrPostGone) {
		t.Fatalf("hot Repost of a deleted post = %v, want ErrPostGone", err)
	}
	for _, path := range []string{"likes/" + pid + "_" + uid, "userLikes/" + uid, "postShares/" + pid + "_" + uid, "reposts/" + pid + "_" + uid, "posts/" + pid} {
		if e.exists(t, path) {
			t.Errorf("%s was written", path)
		}
	}
	if got := e.intField(t, "users/"+uid, "postsCount"); got != 0 {
		t.Errorf("postsCount = %d, want 0", got)
	}
	for _, f := range []string{"likeCount", "repostCount", "shareCount"} {
		if n := e.shardSum(t, pid, f); n != 0 {
			t.Errorf("shard %s = %d, want nothing written", f, n)
		}
	}
	if n := e.counterMarkers(t, pid); n != 0 {
		t.Errorf("counter markers = %d, want 0", n)
	}
}

// TestHotCounters_ThresholdOffIsCold: with the threshold at 0 (the default) any known count takes the plain Increment.
func TestHotCounters_ThresholdOffIsCold(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid = "0000000000000000033"
	e.seedPost(t, pid, "author", 1_000_000, 0)
	if _, err := e.repo.Like(ctx, LikeParams{UID: "o1", PostID: pid, Known: 1_000_000}); err != nil {
		t.Fatal(err)
	}
	if got := e.intField(t, "posts/"+pid, "likeCount"); got != 1_000_001 {
		t.Fatalf("likeCount = %d, want the plain Increment", got)
	}
	if n := e.shardSum(t, pid, "likeCount"); n != 0 {
		t.Fatalf("shards = %d, want none", n)
	}
}
