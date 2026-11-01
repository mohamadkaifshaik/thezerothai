//go:build integration

package apiserver

// W6-41 (ADR-0029 Amendment 1): the tests the W6-36 review (security-w6-36-poll-changes.md L-1) and the 60 x 3 race ask for that the
// developer's W6-36 / W6-17 files do not hold. Names start with TestW641_ so one -run regex selects them.
//   - L-1: the author blocks a voter who had voted; replay, change and stale shapes, by post id and by REPOST id, answer the bytes of a
//     missing post (0 writes), and nothing changes;
//   - the 60 voters x 3 choices race in two arms, asserting store invariants only (no exact winner count, no timing).

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"testing"
	"time"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// rawVoteExpecting is rawVote with expectedChoice in the JSON body (the exact bytes of the response are compared, not a decoded error).
func (p *pollChain) rawVoteExpecting(t *testing.T, u testUser, key, postID string, choice, expected int32) (int, string) {
	t.Helper()
	body := fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q,"choiceIndex":%d,"expectedChoice":%d}`, key, postID, choice, expected)
	req, err := http.NewRequest(http.MethodPost, p.url+rpcVotePoll, bytes.NewReader([]byte(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+u.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// L-1: a voter who HAD voted is then blocked by the author. Every shape of the request (replay, change, stale, old client), by the post id and
// by a REPOST id, is the NOT_FOUND of a missing post byte for byte, writes nothing, and leaves the vote, the counts and the userLikes entry as
// they were. The requests go to a fresh instance: the voting instance may serve a cached graph snapshot for up to 60 s (A1.1 staleness, a
// documented bound, not what is under test).
func TestW641_L1_AuthorBlocksAVoterWhoVoted_NotFoundBytes(t *testing.T) {
	e := newPollChain(t)
	a, voter, reposter, plain := e.user(t), e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)
	rp, err := e.eng.RepostPost(context.Background(), authed(reposter.token, &engagementv1.RepostPostRequest{IdempotencyKey: "w641-repost-key-0000001", PostId: pid}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()
	if _, err := e.vote(voter, "w641-l1-vote-key-000001", pid, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := e.graph.Block(context.Background(), authed(a.token, &graphv1.BlockRequest{IdempotencyKey: "w641-l1-block-key-0001", UserId: voter.uid})); err != nil {
		t.Fatal(err)
	}
	e2 := e.another(t)

	status, ref := e2.rawVoteExpecting(t, plain, "w641-l1-ref-key-000001", w617ID(), 0, 0)
	if status != http.StatusNotFound {
		t.Fatalf("reference = %d %s, want 404", status, ref)
	}
	// expected_choice is not echoed or branched on for a missing post either.
	if st, body := e2.rawVoteExpecting(t, plain, "w641-l1-ref-key-000002", w617ID(), 2, 2); st != status || body != ref {
		t.Fatalf("reference with expectedChoice = %d %s, want %d %s", st, body, status, ref)
	}
	shapes := []struct {
		name             string
		choice, expected int32
	}{
		{"replay with expected_choice", 1, 2},
		{"change with expected_choice", 2, 2},
		{"change with a stale expected_choice", 0, 3},
		{"stale, old client (expected_choice 0), another choice", 2, 0},
		{"old-client replay (expected_choice 0)", 1, 0},
	}
	n := 0
	for _, target := range []struct{ name, id string }{{"post id", pid}, {"REPOST id", repostID}} {
		for _, s := range shapes {
			n++
			st, body := e2.rawVoteExpecting(t, voter, fmt.Sprintf("w641-l1-key-%010d", n), target.id, s.choice, s.expected)
			if st != status || body != ref {
				t.Errorf("%s, %s: %d %s, want the missing-post bytes %d %s", target.name, s.name, st, body, status, ref)
			}
			got := e2.lineBudget(t, rpcVotePoll)
			if got.Writes() != 0 {
				t.Errorf("%s, %s: wrote %d, want 0", target.name, s.name, got.Writes())
			}
			budgettest.Assert(t, "VotePoll NOT_FOUND (author blocks voter)", got, budgettest.Budget{Reads: 7})
		}
	}
	d, ok := voteDocFor(t, e, pid, voter.uid)
	if !ok || d["choice"] != int64(1) || d["changes"] != nil {
		t.Errorf("vote doc = %v, %v, want the original choice 1 with no change", d, ok)
	}
	if total, counts := e.counts(t, pid); total != 1 || counts["1"] != 1 {
		t.Errorf("total=%d counts=%v, want the vote kept and counted (A1.1)", total, counts)
	}
	if ul, err := e.fs.Doc("userLikes/" + voter.uid).Get(context.Background()); err != nil {
		t.Fatal(err)
	} else if got, _ := ul.DataAt("pollVotes"); !onePollEntry(got, pid, 1) {
		t.Errorf("userLikes.pollVotes = %v, want the one entry for choice 1", got)
	}
}

// raceStore is the store's side of the invariants of A2.1 for one poll: stored choice and change count per uid, and the tally per choice.
type raceStore struct {
	stored  map[string]int64
	changes map[string]int64
	tally   map[string]int64
}

func (p *pollChain) raceStore(t *testing.T, pid string) raceStore {
	t.Helper()
	docs, err := p.fs.Collection("pollVotes").Where("postId", "==", pid).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	s := raceStore{map[string]int64{}, map[string]int64{}, map[string]int64{}}
	for _, d := range docs {
		uid, _ := d.DataAt("uid")
		ch, _ := d.DataAt("choice")
		n, _ := d.DataAt("changes")
		u := uid.(string)
		if _, dup := s.stored[u]; dup {
			t.Errorf("two vote docs for uid %s (I-V1)", u)
		}
		s.stored[u] = ch.(int64)
		s.tally[strconv.FormatInt(ch.(int64), 10)]++
		s.changes[u], _ = n.(int64)
	}
	return s
}

// checkRaceInvariants checks I-V1..I-V3 against the store itself (not against a constant): vote docs == total == sum of counts, every count
// equals the tally of vote docs, and a voter has exactly one three-part userLikes entry, equal to the stored choice, if and only if a vote doc exists.
func (p *pollChain) checkRaceInvariants(t *testing.T, pid string, us []testUser) raceStore {
	t.Helper()
	s := p.raceStore(t, pid)
	total, counts := p.counts(t, pid)
	var sum int64
	for _, c := range counts {
		sum += c
	}
	if int64(len(s.stored)) != total || sum != total {
		t.Errorf("vote docs=%d total=%d sum(counts)=%d, want all equal (I-V2)", len(s.stored), total, sum)
	}
	for _, k := range []string{"0", "1", "2"} {
		if counts[k] != s.tally[k] {
			t.Errorf("poll.counts[%s]=%d, vote docs say %d (I-V2)", k, counts[k], s.tally[k])
		}
	}
	for i, u := range us {
		ul, err := p.fs.Doc("userLikes/" + u.uid).Get(context.Background())
		var got any
		if err == nil {
			got, _ = ul.DataAt("pollVotes")
		}
		ch, voted := s.stored[u.uid]
		list, _ := got.([]any)
		switch {
		case !voted && len(list) != 0:
			t.Errorf("voter %d: no vote doc but userLikes.pollVotes = %v (I-V3)", i, got)
		case voted && !onePollEntry(got, pid, ch):
			t.Errorf("voter %d: stored %d but userLikes.pollVotes = %v, want the one entry (I-V3)", i, ch, got)
		}
	}
	return s
}

// retryUnavailable is the contract's retry on UNAVAILABLE (retry_after), bounded; the sleep is the backoff, not synchronisation.
func retryUnavailable(f func() (*postsv1.PostView, error)) (v *postsv1.PostView, err error) {
	for try := 0; try < 10; try++ {
		if v, err = f(); connect.CodeOf(err) != connect.CodeUnavailable {
			return v, err
		}
		time.Sleep(time.Duration(5<<min(try, 6)) * time.Millisecond)
	}
	return v, err
}

// TestW641_RaceInvariants is the 60 voters x 3 choices race (A2.3), both arms, asserting invariants of the store only. UNAVAILABLE after the
// bounded retries is an allowed answer (the emulator serialises writes, so it is rare); no exact number of winners is asserted, and no
// timing pattern of the old W6-17 test is copied. It replaces nothing: TestW617_ConcurrencyManyVotersRacingThemselves stays as it is.
func TestW641_RaceInvariants(t *testing.T) {
	const voters = 60
	setup := func(t *testing.T) (*pollChain, *pollChain, string, []testUser) {
		e1 := newPollChain(t)
		e2 := e1.another(t)
		pid := e1.poll(t, e1.user(t))
		us := make([]testUser, voters)
		for i := range us {
			us[i] = e1.user(t)
		}
		return e1, e2, pid, us
	}
	type call struct {
		choice int32
		view   *postsv1.PostView
		err    error
	}
	t.Run("arm a: new votes, three choices raced per voter, expected_choice 0", func(t *testing.T) {
		e1, e2, pid, us := setup(t)
		res := make([][3]call, voters)
		done := make(chan struct{}, voters*3)
		for i := range us {
			for c := range 3 {
				go func() {
					defer func() { done <- struct{}{} }()
					e := e1
					if (i+c)%2 == 1 {
						e = e2
					}
					r := call{choice: int32(c)}
					r.view, r.err = retryUnavailable(func() (*postsv1.PostView, error) {
						return e.vote(us[i], fmt.Sprintf("w641-race-a-%04d-%d", i, c), pid, int32(c))
					})
					res[i][c] = r
				}()
			}
		}
		for range voters * 3 {
			<-done
		}
		s := e1.checkRaceInvariants(t, pid, us)
		for i, u := range us {
			if s.changes[u.uid] != 0 {
				t.Errorf("voter %d: changes=%d on a first-vote arm", i, s.changes[u.uid])
			}
			for _, r := range res[i] {
				code := connect.Code(0)
				if r.err != nil {
					code = connect.CodeOf(r.err)
				}
				switch code {
				case 0:
					if got := int64(r.view.GetViewerPollChoice()) - 1; got != int64(r.choice) {
						t.Errorf("voter %d: success for choice %d answered viewer_poll_choice-1=%d", i, r.choice, got)
					}
					if s.stored[u.uid] != int64(r.choice) {
						t.Errorf("voter %d: success for choice %d but stored %d (one vote, I-V1)", i, r.choice, s.stored[u.uid])
					}
				case connect.CodeFailedPrecondition, connect.CodeUnavailable:
				default:
					t.Errorf("voter %d choice %d: %v", i, r.choice, r.err)
				}
			}
		}
	})
	t.Run("arm b: changes raced, first votes seeded sequentially", func(t *testing.T) {
		e1, e2, pid, us := setup(t)
		c0s := make([]int32, voters)
		for i := range us {
			c0s[i] = int32(i % 3)
			if _, err := retryUnavailable(func() (*postsv1.PostView, error) {
				return e1.vote(us[i], fmt.Sprintf("w641-b-first-%04d", i), pid, c0s[i])
			}); err != nil {
				t.Fatalf("seed vote %d: %v", i, err)
			}
		}
		res := make([][2]call, voters)
		done := make(chan struct{}, voters*2)
		for i := range us {
			for j := range 2 {
				go func() {
					defer func() { done <- struct{}{} }()
					e := e1
					if (i+j)%2 == 1 {
						e = e2
					}
					c := (c0s[i] + 1 + int32(j)) % 3
					r := call{choice: c}
					r.view, r.err = retryUnavailable(func() (*postsv1.PostView, error) {
						return e.voteExpecting(us[i], fmt.Sprintf("w641-b-change-%04d-%d", i, j), pid, c, c0s[i]+1)
					})
					res[i][j] = r
				}()
			}
		}
		for range voters * 2 {
			<-done
		}
		s := e1.checkRaceInvariants(t, pid, us)
		if len(s.stored) != voters {
			t.Errorf("vote docs=%d, want %d: a change never removes a vote", len(s.stored), voters)
		}
		for i, u := range us {
			ch := s.stored[u.uid]
			if (ch != int64(c0s[i])) != (s.changes[u.uid] == 1) || s.changes[u.uid] > 1 {
				t.Errorf("voter %d: stored %d (first %d) with changes=%d, want changes 1 iff the choice moved, never more (compare-and-set)", i, ch, c0s[i], s.changes[u.uid])
			}
			for _, r := range res[i] {
				code := connect.Code(0)
				if r.err != nil {
					code = connect.CodeOf(r.err)
				}
				switch code {
				case 0:
					if got := int64(r.view.GetViewerPollChoice()) - 1; got != int64(r.choice) || got != ch {
						t.Errorf("voter %d: success for choice %d answered %d, stored %d", i, r.choice, got, ch)
					}
				case connect.CodeFailedPrecondition:
					d := wireError(t, r.err, connect.CodeFailedPrecondition)
					if d.GetMetadata()["choice"] != strconv.FormatInt(ch, 10) {
						t.Errorf("voter %d: refusal metadata %v, stored %d", i, d.GetMetadata(), ch)
					}
				case connect.CodeUnavailable:
				default:
					t.Errorf("voter %d change to %d: %v", i, r.choice, r.err)
				}
			}
		}
	})
}
