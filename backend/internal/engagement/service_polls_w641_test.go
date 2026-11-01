package engagement

import (
	"fmt"
	"reflect"
	"testing"

	"connectrpc.com/connect"
)

// W6-41, security-w6-36-poll-changes.md L-1 at the service: the author blocks a voter who HAD voted. Viewable answers the one NOT_FOUND (the fake
// models it with a hidden post), so every shape of the request, replay, change, stale and old client, is the whole error of a missing post: code,
// reason, message, metadata and retry_after, and nothing is read from the vote doc or written.
func TestW641_L1_AuthorBlocksAVoterWhoVoted_SameErrorAsAMissingPost(t *testing.T) {
	e := newPollEnv(t)
	if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 0); err != nil {
		t.Fatal(err)
	}
	e.posts.hidden[pidA] = true
	e.graph.block(voterKey, "author") // a mutual block is the same answer

	_, missing := e.m.VotePoll(e.ctx, voterKey, keyOK, "0000000000000000099", 1, 2)
	ref := requireCode(t, missing, connect.CodeNotFound)
	writes, gets, changes := e.pr.writes, e.pr.gets, e.pr.changeCalls

	for i, s := range []struct{ choice, expected int32 }{{1, 2}, {1, 0}, {2, 2}, {2, 0}, {0, 3}, {2, 4}} {
		_, err := e.m.VotePoll(e.ctx, voterKey, fmt.Sprintf("w641-l1-key-%08d", i), pidA, s.choice, s.expected)
		got := requireCode(t, err, connect.CodeNotFound)
		if got.Code != ref.Code || got.Reason != ref.Reason || got.Message != ref.Message || got.RetryAfter != ref.RetryAfter || !reflect.DeepEqual(got.Metadata, ref.Metadata) {
			t.Errorf("choice %d expected %d: %+v, want the error of a missing post %+v", s.choice, s.expected, got, ref)
		}
	}
	if e.pr.writes != writes || e.pr.gets != gets || e.pr.changeCalls != changes {
		t.Errorf("a NOT_FOUND touched the vote store: writes %d -> %d, gets %d -> %d, changes %d -> %d", writes, e.pr.writes, gets, e.pr.gets, changes, e.pr.changeCalls)
	}
	if e.pr.votes[docID(pidA, voterKey)] != 1 || e.pr.changeWrites != 0 {
		t.Errorf("the vote was moved: votes=%v changeWrites=%d", e.pr.votes, e.pr.changeWrites)
	}
}
