//go:build integration

package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func (e *repoEnv) seedPoll(t *testing.T, id string, counts map[string]int64, total int64) {
	t.Helper()
	_, err := e.client.Collection("posts").Doc(id).Set(context.Background(), map[string]any{
		"authorId": "author", "kind": "POST", "text": "t", "createdAt": time.UnixMilli(1_700_000_000_000).UTC(),
		"poll": map[string]any{"options": []string{"a", "b", "c"}, "durationMin": 60, "closesAt": time.Now().Add(time.Hour).UTC(), "counts": counts, "total": total},
	})
	if err != nil {
		t.Fatal(err)
	}
}

func (e *repoEnv) pollCounts(t *testing.T, id string) (int64, map[string]int64) {
	t.Helper()
	s, err := e.client.Doc("posts/" + id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	p := s.Data()["poll"].(map[string]any)
	out := map[string]int64{}
	for k, v := range p["counts"].(map[string]any) {
		out[k], _ = v.(int64)
	}
	return p["total"].(int64), out
}

// The vote batch: 3 writes and 0 reads, the counters move by field path, userLikes is merged field-level (the other lists survive),
// a second Vote is VoteExists with 0 writes (a concurrent loser too), and a deleted post is VotePostGone.
func TestRepoVote_BatchBudgetAndOutcomes(t *testing.T) {
	e := newRepoEnv(t)
	const pid, uid = "0000000000000000021", "voter"
	e.seedPoll(t, pid, map[string]int64{"0": 4, "1": 0, "2": 0}, 4)
	if _, err := e.client.Doc("userLikes/"+uid).Set(context.Background(), map[string]any{"recent": []string{"x"}, "bookmarks": []string{"y"}}); err != nil {
		t.Fatal(err)
	}
	exp := time.Now().Add(48 * time.Hour).UTC()

	ctx, c := budget.WithCounter(context.Background())
	out, err := e.repo.Vote(ctx, VoteParams{UID: uid, PostID: pid, Choice: 1, ExpireAt: exp})
	if err != nil || out != VoteWritten {
		t.Fatalf("Vote = %v, %v", out, err)
	}
	budgettest.Assert(t, "Vote", c, budgettest.Budget{Reads: 0, Writes: 3})
	if c.Writes() != 3 {
		t.Errorf("writes = %d, want 3", c.Writes())
	}
	if total, counts := e.pollCounts(t, pid); total != 5 || counts["1"] != 1 || counts["0"] != 4 {
		t.Errorf("total=%d counts=%v", total, counts)
	}
	ul, _ := e.client.Doc("userLikes/" + uid).Get(context.Background())
	for field, want := range map[string]string{"pollVotes": "[" + pid + ":1]", "recent": "[x]", "bookmarks": "[y]"} {
		if got, _ := ul.DataAt(field); fmt.Sprint(got) != want {
			t.Errorf("userLikes.%s = %v, want %s", field, got, want)
		}
	}
	vd, _ := e.client.Doc("pollVotes/" + pid + "_" + uid).Get(context.Background())
	if got, _ := vd.DataAt("expireAt"); got.(time.Time).Sub(exp).Abs() > time.Millisecond {
		t.Errorf("expireAt = %v, want %v", got, exp)
	}

	ctx, c = budget.WithCounter(context.Background())
	if out, err = e.repo.Vote(ctx, VoteParams{UID: uid, PostID: pid, Choice: 2, ExpireAt: exp}); err != nil || out != VoteExists {
		t.Fatalf("second Vote = %v, %v, want VoteExists", out, err)
	}
	if c.Writes() != 0 {
		t.Errorf("a refused batch counted %d writes", c.Writes())
	}
	if total, counts := e.pollCounts(t, pid); total != 5 || counts["2"] != 0 {
		t.Errorf("a second vote moved the counters: %d %v", total, counts)
	}

	ctx, c = budget.WithCounter(context.Background())
	choice, found, err := e.repo.GetVote(ctx, uid, pid)
	if err != nil || !found || choice != 1 || c.Reads() != 1 {
		t.Errorf("GetVote = %d,%v,%v reads=%d", choice, found, err, c.Reads())
	}
	if _, found, _ := e.repo.GetVote(ctx, "nobody", pid); found {
		t.Error("GetVote found a vote nobody cast")
	}

	// A post that is gone fails the whole batch: no vote doc, no userLikes entry.
	out, err = e.repo.Vote(context.Background(), VoteParams{UID: "late", PostID: "0000000000000000022", Choice: 0, ExpireAt: exp})
	if err != nil || out != VotePostGone {
		t.Fatalf("Vote on a missing post = %v, %v", out, err)
	}
	if e.exists(t, "pollVotes/0000000000000000022_late") || e.exists(t, "userLikes/late") {
		t.Error("a vote on a missing post left documents")
	}
}

// Trim removes only the named entries, field-level.
func TestRepoTrimPollVotes(t *testing.T) {
	e := newRepoEnv(t)
	if _, err := e.client.Doc("userLikes/u").Set(context.Background(), map[string]any{"recent": []string{"x"}, "pollVotes": []string{"a:0", "b:1", "c:2"}}); err != nil {
		t.Fatal(err)
	}
	ctx, c := budget.WithCounter(context.Background())
	if err := e.repo.TrimPollVotes(ctx, "u", []string{"a:0", "b:1"}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "TrimPollVotes", c, budgettest.Budget{Reads: 0, Writes: 1})
	s, _ := e.client.Doc("userLikes/u").Get(context.Background())
	if v, _ := s.DataAt("pollVotes"); fmt.Sprint(v) != "[c:2]" {
		t.Errorf("pollVotes = %v", v)
	}
	if v, _ := s.DataAt("recent"); fmt.Sprint(v) != "[x]" {
		t.Errorf("recent = %v, the trim must be field-level", v)
	}
}

func (e *repoEnv) seedVotes(t *testing.T, uid string, n int) {
	t.Helper()
	b := e.client.Batch()
	for i := 0; i < n; i++ {
		post := fmt.Sprintf("%019d", 5000+i)
		b.Set(e.client.Doc("pollVotes/"+post+"_"+uid), map[string]any{"postId": post, "uid": uid, "choice": i % 3, "createdAt": time.Now().UTC(), "expireAt": time.Now().Add(time.Hour).UTC()})
		if (i+1)%400 == 0 || i == n-1 {
			if _, err := b.Commit(context.Background()); err != nil {
				t.Fatal(err)
			}
			b = e.client.Batch()
		}
	}
}

// 120 votes: one page, 120 reads and 120 deletes; another user's votes, the counters and the posts stay.
func TestPollVoteEraser_120Votes(t *testing.T) {
	e := newRepoEnv(t)
	e.seedVotes(t, "gone", 120)
	e.seedVotes(t, "keeper", 3)
	e.seedPoll(t, "0000000000000000023", map[string]int64{"0": 9}, 9)
	ctx, c := budget.WithCounter(context.Background())
	cp, done, err := NewPollVoteEraser(e.repo).PurgeUser(ctx, "gone", PollVoteCheckpoint{})
	if err != nil || !done || cp.Deleted != 120 {
		t.Fatalf("PurgeUser = %+v %v %v", cp, done, err)
	}
	budgettest.Assert(t, "poll_votes erase of 120", c, budgettest.Budget{Reads: 120, Writes: 0, Deletes: 120})
	if c.Deletes() != 120 {
		t.Errorf("deletes = %d", c.Deletes())
	}
	if n := countWhere(t, e.client, "pollVotes", "uid", "gone"); n != 0 {
		t.Errorf("%d vote docs still name the erased uid", n)
	}
	if n := countWhere(t, e.client, "pollVotes", "uid", "keeper"); n != 3 {
		t.Errorf("another user's votes: %d, want 3", n)
	}
	if total, _ := e.pollCounts(t, "0000000000000000023"); total != 9 {
		t.Errorf("the poll's anonymous total changed to %d (F6: counts stay)", total)
	}
	// Re-run: 1 read, nothing to do.
	ctx, c = budget.WithCounter(context.Background())
	if _, done, err := NewPollVoteEraser(e.repo).PurgeUser(ctx, "gone", PollVoteCheckpoint{}); err != nil || !done || c.Reads() != 1 || c.Deletes() != 0 {
		t.Errorf("re-run done=%v err=%v reads=%d deletes=%d", done, err, c.Reads(), c.Deletes())
	}
}

func countWhere(t *testing.T, c *firestore.Client, col, field, value string) int {
	t.Helper()
	docs, err := c.Collection(col).Where(field, "==", value).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

// Crash and resume: a step that stops after the first page (a crash before the checkpoint is saved) re-runs the page from the
// start and still ends with every doc deleted exactly once (deleted docs leave the query, so the redo is idempotent).
func TestPollVoteEraser_CrashResume(t *testing.T) {
	e := newRepoEnv(t)
	e.seedVotes(t, "u", 1100)
	er := NewPollVoteEraser(e.repo)
	cp, done, err := er.PurgeUser(context.Background(), "u", PollVoteCheckpoint{})
	if err != nil || done || cp.Deleted != 500 {
		t.Fatalf("first page = %+v %v %v", cp, done, err)
	}
	// "Crash": the checkpoint is lost, the step restarts from the zero value.
	total := 0
	for cp = (PollVoteCheckpoint{}); ; {
		var d bool
		if cp, d, err = er.PurgeUser(context.Background(), "u", cp); err != nil {
			t.Fatal(err)
		}
		if d {
			total = cp.Deleted
			break
		}
	}
	if total != 600 || countWhere(t, e.client, "pollVotes", "uid", "u") != 0 {
		t.Errorf("resumed deleted %d (want the remaining 600), %d docs left", total, countWhere(t, e.client, "pollVotes", "uid", "u"))
	}
}

// The export lists every vote (120), by document id, 1 read each, and nothing of another user.
func TestPollVoteExporter_120Votes(t *testing.T) {
	e := newRepoEnv(t)
	e.seedVotes(t, "me", 120)
	e.seedVotes(t, "other", 5)
	ctx, c := budget.WithCounter(context.Background())
	var buf bytes.Buffer
	if err := NewPollVoteExporter(e.repo).ExportUser(ctx, "me", &buf); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "poll_votes export of 120", c, budgettest.Budget{Reads: 120})
	var doc struct {
		Votes []struct {
			PostID string `json:"postId"`
			Choice int    `json:"choice"`
		} `json:"poll_votes"`
	}
	if err := json.Unmarshal(buf.Bytes(), &doc); err != nil || len(doc.Votes) != 120 {
		t.Fatalf("export: %v rows=%d", err, len(doc.Votes))
	}
	// Paging past a full page: 501 votes in two queries.
	e.seedVotes(t, "big", 501)
	var big bytes.Buffer
	if err := NewPollVoteExporter(e.repo).ExportUser(context.Background(), "big", &big); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(big.Bytes(), &doc); err != nil || len(doc.Votes) != 501 {
		t.Fatalf("paged export: %v rows=%d", err, len(doc.Votes))
	}
	if doc.Votes[0].PostID >= doc.Votes[500].PostID {
		t.Errorf("rows are not in document-id order: %s .. %s", doc.Votes[0].PostID, doc.Votes[500].PostID)
	}
}
