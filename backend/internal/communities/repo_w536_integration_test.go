//go:build integration

package communities

// The join burst of the stage-ladder load shape (many distinct accounts joining one community document at once), on the emulator.
// The existing TestJoin_TenJoinsBurstKeepMemberCountExact covers 10; this one is 50 on one document, with the contention metric read from
// the request line of every call.

import (
	"context"
	"fmt"
	"sync"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TestW536_JoinBurstOfFiftyKeepsMemberCountExact: 50 distinct users join one community at once. memberCount is a blind Increment that never
// enters the transaction's read set, so the joins should not abort each other; if the emulator does return ABORTED after the repository's
// retries, the service answers UNAVAILABLE with outcome "contention" (the metric under test), never a wrong count. Whatever happens, after
// the failed callers retry with the SAME key (the client's retry), memberCount equals the number of member docs equals 1 + 50, and
// every user's memberships doc names the community once.
func TestW536_JoinBurstOfFiftyKeepsMemberCountExact(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	const n = 50
	type result struct {
		err      error
		attempts string
		outcome  string
	}
	res := make([]result, n)
	uids := make([]string, n)
	for i := range n {
		uids[i] = e.user(fmt.Sprintf("w536burst%02d", i))
	}
	join := func(i int) {
		ctx, info := logger.WithRequestInfo(context.Background())
		_, err := e.join(ctx, uids[i], 5000+i, joinCID)
		a, _ := info.Get(fieldCommunityTxn)
		o, _ := info.Get(fieldOutcome)
		res[i] = result{err: err, attempts: fmt.Sprint(a), outcome: fmt.Sprint(o)}
	}
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() { defer wg.Done(); join(i) }()
	}
	wg.Wait()

	var ok, contended int
	attempts := map[string]int{}
	for i, r := range res {
		attempts[r.attempts]++
		switch {
		case r.err == nil:
			ok++
		case connect.CodeOf(r.err) == connect.CodeUnavailable && r.outcome == outcomeContention:
			contended++
		default:
			t.Fatalf("join %d: %v (outcome %q), want success or UNAVAILABLE with outcome %q", i, r.err, r.outcome, outcomeContention)
		}
	}
	if got := e.count(t, joinCID); got != int64(1+ok) {
		t.Fatalf("memberCount = %d after %d successes, want %d", got, ok, 1+ok)
	}
	// The failed callers retry with the same key: each lands exactly once.
	for i, r := range res {
		if r.err == nil {
			continue
		}
		for try := 0; try < 5; try++ {
			if join(i); res[i].err == nil {
				break
			}
		}
		if res[i].err != nil {
			t.Fatalf("retry of join %d: %v", i, res[i].err)
		}
	}
	if got := e.count(t, joinCID); got != 1+n {
		t.Errorf("memberCount = %d, want %d", got, 1+n)
	}
	docs, err := e.client.Collection("communities").Doc(joinCID).Collection(membersSubcollection).Where("state", "==", "JOINED").Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1+n {
		t.Errorf("JOINED member docs = %d (err %v), want %d", len(docs), err, 1+n)
	}
	for _, uid := range uids {
		ms, _ := e.memberships(t, uid)
		if len(ms.Joined) != 1 || ms.Joined[0] != joinCID {
			t.Fatalf("%s joined = %v, want exactly the community (a retry must not duplicate)", uid, ms.Joined)
		}
	}
	t.Logf("50-join burst: %d succeeded at once, %d aborted into outcome=%s (retried); %s distribution: %v", ok, contended, outcomeContention, fieldCommunityTxn, attempts)
}
