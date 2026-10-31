//go:build integration

package apiserver

// W6-17 lifecycle chain tests for poll votes (ADR-0029 D8, W6-8): real votes cast through VotePoll, then the account deletes itself
// through the production jobs handler (Build's lifecycle registry, which holds the poll_votes step), with the export taken first.
// The developers' tests cover the eraser and exporter at repo level with seeded votes (engagement/repo_polls_integration_test.go).
//
// Note: the crash-resume harness (newCrashChain) builds its own step list without poll_votes, so the existing crash tests do not run
// the step; the repo-level TestPollVoteEraser_CrashResume covers the checkpoint instead.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

func newW617Life(t *testing.T) (*lifecycleEnv, *pollChain) {
	t.Helper()
	le := newLifecycleEnvCfg(t, nil, pollsOn)
	return le, &pollChain{
		chainEnv: le.chainEnv, eng: engagementv1connect.NewEngagementServiceClient(http.DefaultClient, le.url), graph: le.graph,
	}
}

// runDeletion requests the deletion, passes the start gate and plays Pub/Sub against the real jobs endpoint until the job is acked
// with nothing left queued. It returns the number of deliveries.
func (e *lifecycleEnv) runDeletion(t *testing.T, u testUser, key string) int {
	t.Helper()
	msg := e.beginDeletion(t, richAccount{a: u}, key)
	e.pastGate(t, u.uid)
	queue := []func() int{func() int { return e.deliverJSON(t, msg) }}
	deliveries := 0
	for len(queue) > 0 {
		if deliveries++; deliveries > 100 {
			t.Fatal("the deletion job did not finish in 100 deliveries")
		}
		switch code := queue[0](); code {
		case http.StatusNoContent:
			queue = queue[1:]
		case http.StatusTooManyRequests, http.StatusServiceUnavailable:
			time.Sleep(20 * time.Millisecond) // a retryable answer: Pub/Sub would redeliver
		default:
			t.Fatalf("delivery %d answered %d", deliveries, code)
		}
		for _, m := range e.pull(t) {
			queue = append(queue, func() int { return e.deliver(t, m) })
		}
	}
	return deliveries
}

type w617Export struct {
	PollVotes struct {
		PollVotes []struct {
			PostID    string `json:"postId"`
			Choice    int    `json:"choice"`
			CreatedAt string `json:"createdAt"`
		} `json:"poll_votes"`
	} `json:"poll_votes"`
	Posts struct {
		Posts []struct {
			ID   string `json:"id"`
			Poll *struct {
				Choices  []string `json:"choices"`
				ClosesAt string   `json:"closesAt"`
				Counts   []int64  `json:"counts"`
				Total    int64    `json:"total"`
			} `json:"poll"`
		} `json:"posts"`
	} `json:"posts"`
}

func (e *lifecycleEnv) pollExport(t *testing.T, u testUser, key string) (w617Export, string) {
	t.Helper()
	_, raw := e.exportOf(t, u, key)
	var out w617Export
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("export is not JSON: %v\n%s", err, raw)
	}
	return out, string(raw)
}

func voteDocFor(t *testing.T, e *pollChain, postID, uid string) (map[string]any, bool) {
	t.Helper()
	snap, err := e.fs.Doc("pollVotes/" + postID + "_" + uid).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), true
}

// The voter deletes the account: the export names the votes first (0-based choices); the job erases every pollVotes doc and
// userLikes; the poll keeps its counts as anonymous totals (D8, F6); other voters are untouched; no doc names the uid.
func TestW617_LifecycleVoterDeletes(t *testing.T) {
	ctx := context.Background()
	le, e := newW617Life(t)
	a, v, w := e.user(t), e.user(t), e.user(t)
	p1, p2 := e.poll(t, a), e.poll(t, a)
	for i, vote := range []struct {
		u    testUser
		post string
		ch   int32
	}{{v, p1, 2}, {v, p2, 0}, {w, p1, 1}} {
		if _, err := e.vote(vote.u, fmt.Sprintf("w617-life-vote-key-%03d", i), vote.post, vote.ch); err != nil {
			t.Fatalf("vote %d: %v", i, err)
		}
	}

	// --- export before deletion ---
	vx, rawV := le.pollExport(t, v, "w617-life-export-v-0001")
	got := map[string]int{}
	for _, row := range vx.PollVotes.PollVotes {
		got[row.PostID] = row.Choice
		if row.CreatedAt == "" {
			t.Errorf("export row %s has no createdAt", row.PostID)
		}
	}
	if len(vx.PollVotes.PollVotes) != 2 || got[p1] != 2 || got[p2] != 0 {
		t.Errorf("voter export poll_votes = %v, want {%s:2, %s:0} (0-based choice)", got, p1, p2)
	}
	if strings.Contains(rawV, w.uid) {
		t.Error("the voter's export names another voter")
	}
	ax, _ := le.pollExport(t, a, "w617-life-export-a-0001")
	if len(ax.Posts.Posts) != 2 {
		t.Fatalf("author export has %d posts, want 2", len(ax.Posts.Posts))
	}
	for _, p := range ax.Posts.Posts {
		want := map[string]struct {
			counts string
			total  int64
		}{p1: {"[0 1 1]", 2}, p2: {"[1 0 0]", 1}}[p.ID]
		if p.Poll == nil || len(p.Poll.Choices) != 3 || p.Poll.ClosesAt == "" || fmt.Sprint(p.Poll.Counts) != want.counts || p.Poll.Total != want.total {
			t.Errorf("author export of poll %s = %+v, want counts %s total %d", p.ID, p.Poll, want.counts, want.total)
		}
	}

	// --- deletion through the real job chain ---
	n := le.runDeletion(t, v, "w617-life-delete-v-0001")
	t.Logf("voter deletion took %d deliveries", n)

	if fsDocExists(t, le.fs, "users/"+v.uid) {
		t.Error("users doc survived")
	}
	if present, _ := le.authUser(t, v.uid); present {
		t.Error("the Auth user survived")
	}
	for _, id := range []string{p1, p2} {
		if _, ok := voteDocFor(t, e, id, v.uid); ok {
			t.Errorf("pollVotes/%s_%s survived", id, v.uid)
		}
	}
	if docs, err := le.fs.Collection("pollVotes").Where("uid", "==", v.uid).Limit(5).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("pollVotes where uid == deleted: %d docs, err %v", len(docs), err)
	}
	if fsDocExists(t, le.fs, "userLikes/"+v.uid) {
		t.Error("userLikes survived (it carries pollVotes)")
	}
	le.requireNoResidue(t, v.uid)

	// Counts are kept as anonymous totals; the other voter's vote and view are untouched.
	for id, want := range map[string]struct {
		total  int64
		counts map[string]int64
	}{p1: {2, map[string]int64{"0": 0, "1": 1, "2": 1}}, p2: {1, map[string]int64{"0": 1, "1": 0, "2": 0}}} {
		total, counts := e.counts(t, id)
		if total != want.total || fmt.Sprint(counts) != fmt.Sprint(want.counts) {
			t.Errorf("poll %s after the voter's deletion: total=%d counts=%v, want %d %v (D8 keeps the counts)", id, total, counts, want.total, want.counts)
		}
	}
	if d, ok := voteDocFor(t, e, p1, w.uid); !ok || d["choice"] != int64(1) {
		t.Errorf("the other voter's vote doc = %v, %v", d, ok)
	}
	gw := e.getPost(t, w, p1)
	if gw.GetViewerPollChoice() != 2 || gw.GetPost().GetPoll().GetTotalVotes() != 2 || !gw.GetPost().GetPoll().GetResultsVisible() {
		t.Errorf("other voter's view = choice %d total %d", gw.GetViewerPollChoice(), gw.GetPost().GetPoll().GetTotalVotes())
	}
	if le.logContains(v.uid) {
		t.Error("a log line carries the raw uid of the deleted voter")
	}
}

// The author deletes the account: the post goes with it; the others' vote docs hold no uid of the author and expire by TTL at
// closesAt + 30 d (D8), so they stay until then and the sweep does not flag them. The poll is unreachable.
func TestW617_LifecycleAuthorDeletes(t *testing.T) {
	le, e := newW617Life(t)
	a, v, w := e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)
	if _, err := e.vote(v, "w617-life-vote-key-a01", pid, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := e.vote(w, "w617-life-vote-key-a02", pid, 2); err != nil {
		t.Fatal(err)
	}
	post, err := le.fs.Doc("posts/" + pid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	poll, _ := post.DataAt("poll")
	closesAt := poll.(map[string]any)["closesAt"].(time.Time)
	cfg, _ := config.Load()

	le.runDeletion(t, a, "w617-life-delete-a-0001")

	if fsDocExists(t, le.fs, "posts/"+pid) {
		t.Error("the poll post survived its author")
	}
	le.requireNoResidue(t, a.uid)
	for _, voter := range []testUser{v, w} {
		d, ok := voteDocFor(t, e, pid, voter.uid)
		if !ok {
			t.Errorf("vote doc of %s was erased with the author's account", voter.uid)
			continue
		}
		if strings.Contains(fmt.Sprint(d), a.uid) {
			t.Errorf("a vote doc names the deleted author: %v", d)
		}
		if exp, _ := d["expireAt"].(time.Time); exp.Sub(closesAt) != cfg.Composer.PollVoteTTLAfterClose {
			t.Errorf("vote doc expireAt = %v, want closesAt + %v (%v)", exp, cfg.Composer.PollVoteTTLAfterClose, closesAt)
		}
	}
	_, err = e.vote(w, "w617-life-vote-key-a03", pid, 2)
	wireError(t, err, connect.CodeNotFound)
	if _, err := e.posts.GetPost(context.Background(), authed(v.token, &postsv1.GetPostRequest{PostId: pid})); connect.CodeOf(err) != connect.CodeNotFound {
		t.Errorf("GetPost of the deleted author's poll = %v, want NOT_FOUND", err)
	}
	// The voter's own export still lists the vote (until the TTL) and carries no content of the gone post.
	vx, raw := le.pollExport(t, v, "w617-life-export-v-0002")
	if len(vx.PollVotes.PollVotes) != 1 || vx.PollVotes.PollVotes[0].PostID != pid || strings.Contains(raw, "which one?") {
		t.Errorf("voter export after the author left = %s", raw)
	}
}
