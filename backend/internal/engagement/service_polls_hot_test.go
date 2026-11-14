package engagement

import "testing"

// TestVotePoll_KnownIsThePollTotal: the vote and the change pass the poll's total as the service read it (cache first) as
// Known, which routes a hot poll's counters to its shards; a REPOST id carries the original's total.
func TestVotePoll_KnownIsThePollTotal(t *testing.T) {
	t.Run("vote", func(t *testing.T) {
		e := newPollEnv(t) // pidA total 7
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 1, 0); err != nil {
			t.Fatal(err)
		}
		if e.pr.last.Known != 7 {
			t.Fatalf("vote Known = %d, want the poll total as read (7)", e.pr.last.Known)
		}
	})
	t.Run("vote through a repost id", func(t *testing.T) {
		e := newPollEnv(t)
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidRep, 0, 0); err != nil {
			t.Fatal(err)
		}
		if e.pr.last.PostID != pidA || e.pr.last.Known != 7 {
			t.Fatalf("vote = %+v, want the original %s with its total 7", e.pr.last, pidA)
		}
	})
	t.Run("change", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 1, 0)
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 2, 2); err != nil {
			t.Fatal(err)
		}
		if e.pr.changeWrites != 1 || e.pr.lastChange.Known != 7 {
			t.Fatalf("change writes=%d Known=%d, want one change with the poll total 7", e.pr.changeWrites, e.pr.lastChange.Known)
		}
	})
}
