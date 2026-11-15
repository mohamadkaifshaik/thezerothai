//go:build integration

package engagement

// F2 creator stats with HOT_COUNTER_THRESHOLD > 0: a hot like or unlike stages no stat itself; the counter fold stages
// the shard's delta on the author's day (once: a redelivered fold moves nothing); a cold like undone hot nets to 0; a
// post deleted with hot deltas pending, and an unlike after the delete, leave no stat doc.

import (
	"context"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// newStatsEnv is newRepoEnv with the creator stats wired into posts (the fold) and engagement (the cold path) and the
// hot threshold on.
func newStatsEnv(t *testing.T) *repoEnv {
	t.Helper()
	e := newRepoEnv(t)
	stats := identity.NewDailyStatsRepo(e.client, nil)
	e.posts.SetWriters(posts.WriteDeps{Stats: stats})
	e.posts.SetHotCounterThreshold(hotThreshold)
	e.repo.w.Stats = stats
	return e
}

// engagementsOf sums uid's dailyStats engagements over every shard doc; docs is how many there are.
func (e *repoEnv) engagementsOf(t *testing.T, uid string) (sum int64, docs int) {
	t.Helper()
	ds, err := e.client.Collection("users").Doc(uid).Collection(identity.DailyStatsSubcollection).Limit(50).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range ds {
		v, _ := d.DataAt("engagements")
		n, _ := v.(int64)
		sum += n
	}
	return sum, len(ds)
}

func (e *repoEnv) fold(t *testing.T, pid string) {
	t.Helper()
	if _, _, _, err := e.posts.FoldCounters(context.Background(), []string{pid}); err != nil {
		t.Fatalf("fold: %v", err)
	}
}

func TestCreatorStatsHot_LikeFoldRedeliveryUnlike(t *testing.T) {
	e := newStatsEnv(t)
	ctx := context.Background()
	const pid, author = "0000000000000000071", "author-hot"
	e.seedPost(t, pid, author, hotThreshold, 0)

	if _, err := e.repo.Like(ctx, LikeParams{UID: "liker", PostID: pid, Known: hotThreshold, AuthorID: author}); err != nil {
		t.Fatal(err)
	}
	if n, docs := e.engagementsOf(t, author); n != 0 || docs != 0 {
		t.Fatalf("a hot like staged a stat itself: %d over %d docs", n, docs)
	}
	e.fold(t, pid)
	if n, _ := e.engagementsOf(t, author); n != 1 {
		t.Fatalf("after the fold: engagements %d, want 1", n)
	}
	e.fold(t, pid) // redelivery
	if n, _ := e.engagementsOf(t, author); n != 1 {
		t.Fatalf("after a redelivered fold: engagements %d, want still 1", n)
	}
	if removed, err := e.repo.Unlike(ctx, "liker", pid, hotThreshold, author); err != nil || !removed {
		t.Fatalf("hot unlike: %v %v", removed, err)
	}
	e.fold(t, pid)
	if n, _ := e.engagementsOf(t, author); n != 0 {
		t.Fatalf("after the hot unlike's fold: engagements %d, want 0", n)
	}
}

func TestCreatorStatsHot_ColdLikeHotUnlike(t *testing.T) {
	e := newStatsEnv(t)
	ctx := context.Background()
	const pid, author = "0000000000000000072", "author-mixed"
	e.seedPost(t, pid, author, hotThreshold-1, 0)
	if _, err := e.repo.Like(ctx, LikeParams{UID: "liker", PostID: pid, Known: hotThreshold - 1, AuthorID: author}); err != nil {
		t.Fatal(err)
	}
	if n, _ := e.engagementsOf(t, author); n != 1 {
		t.Fatalf("cold like: engagements %d, want 1", n)
	}
	// Another instance reads the count at the threshold: the unlike goes to a shard.
	if removed, err := e.repo.Unlike(ctx, "liker", pid, hotThreshold, author); err != nil || !removed {
		t.Fatalf("hot unlike: %v %v", removed, err)
	}
	if n, _ := e.engagementsOf(t, author); n != 1 {
		t.Fatalf("before the fold: engagements %d, want 1 (the undo waits on the shard)", n)
	}
	e.fold(t, pid)
	if n, _ := e.engagementsOf(t, author); n != 0 {
		t.Fatalf("after the fold: engagements %d, want 0", n)
	}
}

func TestCreatorStatsHot_DeletedPostLeavesNoStat(t *testing.T) {
	e := newStatsEnv(t)
	ctx := context.Background()
	const pid, author = "0000000000000000073", "author-gone"
	e.seedPost(t, pid, author, hotThreshold, 0)
	if _, err := e.repo.Like(ctx, LikeParams{UID: "liker", PostID: pid, Known: hotThreshold, AuthorID: author}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Doc("posts/" + pid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	e.fold(t, pid) // the gone path: shards deleted, nothing folded, no stat
	// Unlike after the delete: the service passes no author (post not found, cold), and even with one the counter
	// Update's Exists fails and the retry without the counter drops the stat.
	for _, a := range []string{"", author} {
		if _, err := e.repo.Unlike(ctx, "liker", pid, 0, a); err != nil {
			t.Fatalf("unlike after the delete: %v", err)
		}
	}
	if n, docs := e.engagementsOf(t, author); docs != 0 {
		t.Fatalf("a deleted post left %d stat docs (engagements %d)", docs, n)
	}
}
