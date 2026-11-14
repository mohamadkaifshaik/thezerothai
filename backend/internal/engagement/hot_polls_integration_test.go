//go:build integration

package engagement

import (
	"context"
	"strconv"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// pollShardSum adds up poll.<path...> over posts/{id}/viewShards, by FieldPath (the counts keys are numeric strings,
// never a dotted path).
func (e *repoEnv) pollShardSum(t *testing.T, postID string, path ...string) int64 {
	t.Helper()
	fp := append(firestore.FieldPath{"poll"}, path...)
	var total int64
	for i := range posts.ViewShardCount {
		s, err := e.client.Doc("posts/" + postID + "/" + posts.ViewShardsSubcollection + "/" + strconv.Itoa(i)).Get(context.Background())
		if err != nil {
			continue // a shard never written
		}
		v, err := s.DataAtPath(fp)
		if err != nil {
			continue
		}
		n, _ := v.(int64)
		total += n
	}
	return total
}

// TestHotCounters_PollVotesChangesThenRollup: on a poll whose total is at HOT_COUNTER_THRESHOLD, hot votes and a hot
// change go to its shards (counts and total in one shard write, the change's -1 and +1 together) with a counter marker and
// leave the plain fields alone; a cold vote (a total read below the threshold) Increments the plain fields; the rollup
// then makes poll.counts.* and poll.total exact and nets the shards to 0, and a redelivered fold changes nothing.
func TestHotCounters_PollVotesChangesThenRollup(t *testing.T) {
	e := newRepoEnv(t)
	e.posts.SetHotCounterThreshold(hotThreshold)
	ctx := context.Background()
	const pid = "0000000000000000041"
	e.seedPoll(t, pid, map[string]int64{"0": hotThreshold, "1": 0, "2": 0}, hotThreshold)
	closes := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	exp := closes.Add(48 * time.Hour)
	vote := func(uid string, choice int, known int64) {
		t.Helper()
		if out, err := e.repo.Vote(ctx, VoteParams{UID: uid, PostID: pid, Choice: choice, ExpireAt: exp, ClosesAt: closes, Known: known}); err != nil || out != VoteWritten {
			t.Fatalf("Vote %s = %v, %v", uid, out, err)
		}
	}
	vote("h1", 0, hotThreshold)
	vote("h2", 1, hotThreshold)
	vote("h3", 2, hotThreshold)
	if out, err := e.repo.Vote(ctx, VoteParams{UID: "h1", PostID: pid, Choice: 2, ExpireAt: exp, ClosesAt: closes, Known: hotThreshold}); err != nil || out != VoteExists {
		t.Fatalf("hot Vote again = %v, %v; want VoteExists", out, err)
	}
	st, found, err := e.repo.GetVote(ctx, "h2", pid)
	if err != nil || !found {
		t.Fatal(err, found)
	}
	change := ChangeParams{UID: "h2", PostID: pid, From: 1, To: 2, Version: st.UpdateTime, ClosesAt: closes, ExpireAt: exp, Known: hotThreshold}
	if out, err := e.repo.ChangeVote(ctx, change); err != nil || out != ChangeWritten {
		t.Fatalf("hot ChangeVote = %v, %v", out, err)
	}
	// The same change again: the vote doc moved, so its LastUpdateTime precondition fails inside the transaction.
	if out, err := e.repo.ChangeVote(ctx, change); err != nil || out != ChangeStale {
		t.Fatalf("stale hot ChangeVote = %v, %v; want ChangeStale", out, err)
	}
	vote("c1", 1, hotThreshold-1) // cold

	// Before the rollup: the plain fields moved only by the cold vote; the shards hold the hot deltas (choice 1 nets to 0:
	// +1 by h2's vote, -1 by its change).
	if total, counts := e.pollCounts(t, pid); total != 11 || counts["0"] != 10 || counts["1"] != 1 || counts["2"] != 0 {
		t.Fatalf("plain before the rollup: total %d counts %v, want 11 / 10 1 0", total, counts)
	}
	if tot, c0, c1, c2 := e.pollShardSum(t, pid, "total"), e.pollShardSum(t, pid, "counts", "0"), e.pollShardSum(t, pid, "counts", "1"), e.pollShardSum(t, pid, "counts", "2"); tot != 3 || c0 != 1 || c1 != 0 || c2 != 2 {
		t.Fatalf("shards before the rollup: total %d counts %d %d %d, want 3 / 1 0 2", tot, c0, c1, c2)
	}
	if n := e.counterMarkers(t, pid); n != 1 {
		t.Fatalf("counter markers = %d, want 1", n)
	}

	roll := &posts.ViewRollup{Repo: e.posts, Off: func() bool { return true }, Now: func() time.Time { return time.Now().Add(2 * posts.ViewWindow) }}
	rr, err := roll.Run(ctx)
	if err != nil || rr.CountersFolded != 1 {
		t.Fatalf("rollup = %+v, %v; want 1 post folded", rr, err)
	}
	exact := func(when string) {
		t.Helper()
		if total, counts := e.pollCounts(t, pid); total != 14 || counts["0"] != 11 || counts["1"] != 1 || counts["2"] != 2 {
			t.Fatalf("%s: total %d counts %v, want 14 / 11 1 2", when, total, counts)
		}
		for _, path := range [][]string{{"total"}, {"counts", "0"}, {"counts", "1"}, {"counts", "2"}} {
			if n := e.pollShardSum(t, pid, path...); n != 0 {
				t.Fatalf("%s: shard poll.%v = %d, want 0", when, path, n)
			}
		}
	}
	exact("after the rollup")
	if n := e.counterMarkers(t, pid); n != 0 {
		t.Fatalf("counter markers after the rollup = %d, want 0", n)
	}
	for range 2 {
		if done, folded, _, err := e.posts.FoldCounters(ctx, []string{pid}); err != nil || folded != 1 || len(done) != 1 {
			t.Fatalf("refold = %v %d %v", done, folded, err)
		}
	}
	exact("after the redelivered folds")
}

// TestHotCounters_PollVoteOfDeletedPost: a hot vote on a poll deleted since the service read it is VotePostGone and
// writes nothing (no vote doc, no userLikes, no shard, no marker); a hot change of a surviving vote doc on a deleted post
// is ChangeStale and leaves the vote doc as it was.
func TestHotCounters_PollVoteOfDeletedPost(t *testing.T) {
	e := newRepoEnv(t)
	e.posts.SetHotCounterThreshold(hotThreshold)
	ctx := context.Background()
	const pid, uid, voter = "0000000000000000042", "g1", "g2"
	e.seedPoll(t, pid, map[string]int64{"0": hotThreshold, "1": 0, "2": 0}, hotThreshold)
	closes := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	exp := closes.Add(48 * time.Hour)
	if out, err := e.repo.Vote(ctx, VoteParams{UID: voter, PostID: pid, Choice: 0, ExpireAt: exp, ClosesAt: closes}); err != nil || out != VoteWritten {
		t.Fatalf("cold Vote = %v, %v", out, err)
	}
	st, found, err := e.repo.GetVote(ctx, voter, pid)
	if err != nil || !found {
		t.Fatal(err, found)
	}
	if _, err := e.client.Doc("posts/" + pid).Delete(ctx); err != nil {
		t.Fatal(err)
	}

	if out, err := e.repo.Vote(ctx, VoteParams{UID: uid, PostID: pid, Choice: 1, ExpireAt: exp, ClosesAt: closes, Known: hotThreshold}); err != nil || out != VotePostGone {
		t.Fatalf("hot Vote of a deleted post = %v, %v; want VotePostGone", out, err)
	}
	for _, path := range []string{"pollVotes/" + pid + "_" + uid, "userLikes/" + uid, "posts/" + pid} {
		if e.exists(t, path) {
			t.Errorf("%s was written", path)
		}
	}

	out, err := e.repo.ChangeVote(ctx, ChangeParams{UID: voter, PostID: pid, From: 0, To: 2, Version: st.UpdateTime, ClosesAt: closes, ExpireAt: exp, Known: hotThreshold})
	if err != nil || out != ChangeStale {
		t.Fatalf("hot ChangeVote of a deleted post = %v, %v; want ChangeStale", out, err)
	}
	after, found, err := e.repo.GetVote(ctx, voter, pid)
	if err != nil || !found || after.Choice != 0 || after.Changes != 0 || !after.UpdateTime.Equal(st.UpdateTime) {
		t.Errorf("vote doc after the refused change = %+v,%v,%v; want it unmoved (the service then answers NOT_FOUND)", after, found, err)
	}

	for _, path := range [][]string{{"total"}, {"counts", "0"}, {"counts", "1"}, {"counts", "2"}} {
		if n := e.pollShardSum(t, pid, path...); n != 0 {
			t.Errorf("shard poll.%v = %d, want nothing written", path, n)
		}
	}
	if n := e.counterMarkers(t, pid); n != 0 {
		t.Errorf("counter markers = %d, want 0", n)
	}
}
