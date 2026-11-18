//go:build integration

package messaging

// CommitConversation (Task 5) on the emulator: the exact documents of a commit and a reset, the strict order (one record
// per pair, first accepted wins) under real concurrency against another commit, a reset and an encrypted send, retry
// recognition, the refusals (nothing written, no device lookup) and records left over from an earlier conversation with
// the same id. Real goroutines on separate service instances, no sleeps: overlap is forced from inside a transaction
// through the in-transaction graph reader (signalTxSocial), which both the send and the commit transaction call right
// after their conversation read.

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

func (e *itEnv) commitOn(svc *service, uid string, req *messagingv1.CommitConversationRequest) (*messagingv1.CommitConversationResponse, error) {
	return svc.Commit(verifiedCtx(), uid, req)
}

// mustCommitIT commits and retries a busy answer with the same request (retry recognition makes that safe).
func (e *itEnv) mustCommitIT(svc *service, uid string, req *messagingv1.CommitConversationRequest) *messagingv1.CommitConversationResponse {
	e.t.Helper()
	resp, err := e.commitOn(svc, uid, req)
	if outcome(err) == "busy" {
		resp, err = e.commitOn(svc, uid, req)
	}
	if err != nil {
		e.t.Fatalf("commit: %v", err)
	}
	return resp
}

// signalledService is a new service instance whose transactions call fire right after their conversation read.
func (e *itEnv) signalledService(fire func()) *service {
	base := e.txSocial
	e.txSocial = signalTxSocial{TxReader: base, fire: fire}
	svc := e.newService()
	e.txSocial = base
	return svc
}

// commitsOf lists the conversation's commit records, by document id.
func (e *itEnv) commitsOf(convID string) map[string]map[string]any {
	return e.docsIn("conversations/" + convID + "/commits")
}

func isStale(t *testing.T, err error) bool {
	t.Helper()
	if err == nil {
		return false
	}
	_, reason, _ := reasonOf(t, err)
	return reason == commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH
}

// A commit and then a reset store exactly: the conversation's pair (rev and everything else untouched), the record of the
// built-on pair, one welcome per device labelled with that pair, the earlier welcome of a re-addressed device replaced.
func TestCommitIT_StoresExactly(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	convID, _ := e.startMLSConversation(1, 1)
	ctx := context.Background()
	if _, err := e.fs.Collection("conversations").Doc(convID).Update(ctx, []firestore.Update{{Path: "rev", Value: 3}}); err != nil {
		t.Fatal(err)
	}
	before, _ := e.conv(convID)
	entriesBefore := e.snapshotState(convID).times
	at := e.tick(time.Second)

	wantPair(t, e.mustCommitIT(e.svc, alice, commitReq(ckey(1), convID, 1, 1, "c1", devBob1, devAlice2)), 1, 2)
	after, _ := e.conv(convID)
	if after.MlsGen != 1 || after.MlsEpoch != 2 || after.Rev != 3 || after.State != before.State || !slices.Equal(after.Participants, before.Participants) {
		t.Errorf("conversation = %+v", after)
	}
	if !after.UpdatedAt.Equal(at) {
		t.Errorf("updatedAt = %v, want %v", after.UpdatedAt, at)
	}
	for p, tm := range entriesBefore {
		if p == "conversations/"+convID {
			continue
		}
		if got := e.docSnap(p).UpdateTime; !got.Equal(tm) {
			t.Errorf("%s was written by a commit", p)
		}
	}
	recs := e.commitsOf(convID)
	rec := recs[commitDocID(1, 1)]
	if len(recs) != 1 || !slices.Equal(keysOf(rec), []string{"createdAt", "data", "epoch", "expireAt", "gen", "senderId"}) {
		t.Fatalf("records = %v", recs)
	}
	if rec["gen"] != int64(1) || rec["epoch"] != int64(1) || rec["senderId"] != alice || string(rec["data"].([]byte)) != "commit:c1" ||
		!asTime(t, rec["expireAt"]).Equal(asTime(t, rec["createdAt"]).Add(CommitRetention)) {
		t.Errorf("record = %v", rec)
	}
	st := e.mlsState(convID)
	bobW, aliceW := st.bobWelcomes[welcomeDocID(convID, 1, 1, devBob1)], st.aliceWelcomes[welcomeDocID(convID, 1, 1, devAlice2)]
	if len(st.bobWelcomes) != 1 || len(st.aliceWelcomes) != 1 || bobW == nil || aliceW == nil {
		t.Fatalf("welcomes alice %v bob %v", st.aliceWelcomes, st.bobWelcomes)
	}
	for _, w := range []map[string]any{bobW, aliceW} {
		if w["gen"] != int64(1) || w["epoch"] != int64(1) || string(w["data"].([]byte)) != "welcome:c1" || w["convId"] != convID {
			t.Errorf("welcome = %v", w)
		}
	}

	// A reset of generation 1 by bob, addressing devBob2 (his other device) and devAlice2 again: the record (2, 0), the
	// welcomes labelled (2, 0), devAlice2's earlier welcome replaced (one per conversation per device), devBob1's kept.
	e.tick(time.Second)
	wantPair(t, e.mustCommitIT(e.svc, bob, resetReq(ckey(2), convID, 1, "r", devAlice2, devBob2)), 2, 1)
	after, _ = e.conv(convID)
	if after.MlsGen != 2 || after.MlsEpoch != 1 || after.Rev != 3 {
		t.Errorf("after reset: %+v", after)
	}
	recs = e.commitsOf(convID)
	if r := recs[commitDocID(2, 0)]; len(recs) != 2 || r["gen"] != int64(2) || r["epoch"] != int64(0) || r["senderId"] != bob {
		t.Errorf("records = %v", recs)
	}
	st = e.mlsState(convID)
	if _, ok := st.aliceWelcomes[welcomeDocID(convID, 2, 0, devAlice2)]; !ok || len(st.aliceWelcomes) != 1 {
		t.Errorf("alice welcomes = %v, want only the reset's", keysOfMap(st.aliceWelcomes))
	}
	if _, ok := st.bobWelcomes[welcomeDocID(convID, 2, 0, devBob2)]; !ok || len(st.bobWelcomes) != 2 {
		t.Errorf("bob welcomes = %v", keysOfMap(st.bobWelcomes))
	}
	if w := st.bobWelcomes[welcomeDocID(convID, 2, 0, devBob2)]; w["gen"] != int64(2) || w["epoch"] != int64(0) {
		t.Errorf("reset welcome pair = (%v, %v)", w["gen"], w["epoch"])
	}
	// The send path still answers from the new pair: old generation STALE_EPOCH, the new one stored.
	_, err := e.send(alice, encByConv(skey(1), convID, 1, 2, "old gen"))
	wantStale(t, err, 2, 1)
	if _, err := e.send(alice, encByConv(skey(2), convID, 2, 1, "new gen")); err != nil {
		t.Fatalf("send at the new pair: %v", err)
	}
}

func keysOfMap(m map[string]map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// After a commit, a send at the old pair is STALE_EPOCH with the new pair (nothing stored); at the new pair it is stored.
func TestCommitIT_SendAfterCommit(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 1)
	e.mustCommitIT(e.svc, alice, commitReq(ckey(1), convID, 1, 1, "c"))
	u := e.snapshotState(convID)
	_, err := e.send(bob, encByConv(skey(1), convID, 1, 1, "late"))
	wantStale(t, err, 1, 2)
	u.check(t)
	if _, err := e.send(bob, encByConv(skey(2), convID, 1, 2, "on time")); err != nil {
		t.Fatal(err)
	}
}

// Two commits on one pair, from both users on separate instances, rounds on successive pairs: exactly one record per pair
// (the winner's bytes and sender), the loser STALE_EPOCH with the winner's successor pair and nothing of its own stored
// (no welcome). Even rounds release both together; odd rounds release the second from inside the first's transaction.
func TestCommitIT_ConcurrentCommitsOneWins(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	convID, _ := e.startMLSConversation(1, 1)
	tally := map[string]int{}
	for round := range 8 {
		epoch := uint64(1 + round)
		start, second := make(chan struct{}), make(chan struct{})
		var once sync.Once
		release := func() { once.Do(func() { close(second) }) }
		first := e.newService()
		if round%2 == 1 {
			first = e.signalledService(release)
		} else {
			release()
		}
		svcs := [2]*service{first, e.newService()}
		reqs := [2]*messagingv1.CommitConversationRequest{
			commitReq(ckey(10*round), convID, 1, epoch, fmt.Sprintf("a%d", round), devBob1),
			commitReq(ckey(10*round+1), convID, 1, epoch, fmt.Sprintf("b%d", round), devAlice1),
		}
		froms := [2]string{alice, bob}
		var errs [2]error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, errs[0] = e.commitOn(svcs[0], froms[0], reqs[0])
			release()
		}()
		go func() {
			defer wg.Done()
			<-start
			<-second
			_, errs[1] = e.commitOn(svcs[1], froms[1], reqs[1])
		}()
		close(start)
		wg.Wait()
		for i := range errs {
			if outcome(errs[i]) == "busy" {
				tally["busy"]++
				_, errs[i] = e.commitOn(svcs[i], froms[i], reqs[i])
			}
		}
		winner := -1
		for i, err := range errs {
			switch {
			case err == nil:
				if winner >= 0 {
					t.Fatalf("round %d: both commits succeeded", round)
				}
				winner = i
			case isStale(t, err):
				wantStale(t, err, 1, int64(epoch)+1)
			default:
				t.Fatalf("round %d: racer %d: %v", round, i, err)
			}
		}
		if winner < 0 {
			t.Fatalf("round %d: no commit won: %v", round, errs)
		}
		tally[fmt.Sprintf("winner%d", winner)]++
		rec := e.commitsOf(convID)[commitDocID(1, int64(epoch))]
		if rec["senderId"] != froms[winner] || string(rec["data"].([]byte)) != string(reqs[winner].GetCommit()) {
			t.Errorf("round %d: record = %v, want the winner's", round, rec)
		}
		if n := len(e.commitsOf(convID)); n != round+1 {
			t.Errorf("round %d: %d records, want %d", round, n, round+1)
		}
		st := e.mlsState(convID)
		loserDevice, loserOwner := devAlice1, st.aliceWelcomes
		if winner == 1 {
			loserDevice, loserOwner = devBob1, st.bobWelcomes
		}
		if _, ok := loserOwner[welcomeDocID(convID, 1, int64(epoch), loserDevice)]; ok {
			t.Errorf("round %d: the loser's welcome was stored", round)
		}
		if c, _ := e.conv(convID); c.MlsGen != 1 || c.MlsEpoch != int64(epoch)+1 {
			t.Errorf("round %d: conversation at (%d, %d)", round, c.MlsGen, c.MlsEpoch)
		}
	}
	t.Logf("tally %v", tally)
}

// An encrypted send racing a commit on its pair, 20 rounds of four kinds:
//   - "together": both released at once (either order is legal);
//   - "commit inside send": the commit released from inside the send transaction, after the send read the conversation:
//     the send must win (it holds the conversation it read until it commits; the commit's write of that document waits or
//     re-runs, then the commit is built on a pair that is still current, and the send is stored first);
//   - "send inside commit": the send released from inside the commit transaction, after the commit read the conversation
//     and before its commit (either order is legal: it depends on whether the send reads the conversation before the
//     commit commits);
//   - "send after commit": the send released the moment the commit's transaction committed (the repo's post-commit seam),
//     so it must answer STALE_EPOCH.
//
// Each round ends in one of the two legal orders, checked on the documents: the send is stored at (g, e) and its document
// was created (server commit time) BEFORE the commit record of (g, e); or the send is STALE_EPOCH with (g, e + 1) and no
// message is stored. Never a message stored at a pair after the commit that closed it. The commit always succeeds (busy is
// retried with the same request). Both orders must be observed.
func TestCommitIT_SendRacingACommit(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 1)
	ctx := context.Background()
	var sendHook, commitHook, afterCommitHook func()
	var hookMu sync.Mutex
	fire := func(h *func()) func() {
		return func() {
			hookMu.Lock()
			f := *h
			hookMu.Unlock()
			if f != nil {
				f()
			}
		}
	}
	sendSvc := e.signalledService(fire(&sendHook))
	// The commit's instance has its own repo whose post-commit seam fires afterCommitHook (and returns no error).
	commitRepo := NewFirestoreRepo(e.fs, quota.New(e.fs))
	commitRepo.hooks = &raceHooks{commitThenFail: func() error { fire(&afterCommitHook)(); return nil }}
	commitSvc := New(e.reg, Deps{
		Repo: commitRepo, Social: e.social, TxSocial: signalTxSocial{TxReader: e.txSocial, fire: fire(&commitHook)}, TxProfiles: e.txProfs,
		AllowAnonymous: true, Profiles: e.profs, Devices: e.devices, Limits: e.limits, CursorKey: testCursorKey, Now: e.now,
	}).(*service)
	kinds := []string{"together", "commit inside send", "send inside commit", "send after commit"}
	tally := map[string]int{}
	for round := range 20 {
		kind := kinds[round%4]
		epoch := int64(1 + round)
		sendReq := encByConv(skey(700+round), convID, 1, uint64(epoch), fmt.Sprintf("round %d", round))
		commit := commitReq(ckey(700+round), convID, 1, uint64(epoch), fmt.Sprintf("c%d", round))
		sendGo, commitGo := make(chan struct{}), make(chan struct{})
		var o1, o2 sync.Once
		releaseSend := func() { o1.Do(func() { close(sendGo) }) }
		releaseCommit := func() { o2.Do(func() { close(commitGo) }) }
		hookMu.Lock()
		sendHook, commitHook, afterCommitHook = nil, nil, nil
		switch round % 4 {
		case 1:
			sendHook = releaseCommit
		case 2:
			commitHook = releaseSend
		case 3:
			afterCommitHook = releaseSend
		}
		hookMu.Unlock()
		var (
			wg        sync.WaitGroup
			sendErr   error
			commitErr error
		)
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-sendGo
			_, sendErr = e.sendOn(sendSvc, bob, sendReq)
			releaseCommit()
		}()
		go func() {
			defer wg.Done()
			<-commitGo
			_, commitErr = e.commitOn(commitSvc, alice, commit)
			releaseSend()
		}()
		switch round % 4 {
		case 0:
			releaseSend()
			releaseCommit()
		case 1:
			releaseSend()
		default:
			releaseCommit()
		}
		wg.Wait()
		hookMu.Lock()
		sendHook, commitHook, afterCommitHook = nil, nil, nil
		hookMu.Unlock()
		if outcome(commitErr) == "busy" {
			tally["commit busy"]++
			_, commitErr = e.commitOn(commitSvc, alice, commit)
		}
		if commitErr != nil {
			t.Fatalf("round %d (%s): commit: %v", round, kind, commitErr)
		}
		if outcome(sendErr) == "busy" {
			tally["send busy"]++
			_, sendErr = e.sendOn(sendSvc, bob, sendReq)
		}
		recSnap := e.docSnap("conversations/" + convID + "/commits/" + commitDocID(1, epoch))
		msgSnap, gerr := e.fs.Doc("conversations/" + convID + "/messages/" + MessageID(bob, sendReq.GetIdempotencyKey())).Get(ctx)
		stored := gerr == nil && msgSnap.Exists()
		switch {
		case sendErr == nil:
			tally[kind+": send first"]++
			if kind == "send after commit" {
				t.Errorf("round %d: a send released after the commit committed was stored", round)
			}
			if !stored {
				t.Fatalf("round %d: send ok but nothing stored", round)
			}
			var m MsgDoc
			if err := msgSnap.DataTo(&m); err != nil {
				t.Fatal(err)
			}
			if m.MlsGen != 1 || m.MlsEpoch != epoch {
				t.Errorf("round %d: stored pair (%d, %d), want (1, %d)", round, m.MlsGen, m.MlsEpoch, epoch)
			}
			if !msgSnap.CreateTime.Before(recSnap.CreateTime) {
				t.Errorf("round %d (%s): message committed at %v, not before the commit record at %v", round, kind, msgSnap.CreateTime, recSnap.CreateTime)
			}
		case isStale(t, sendErr):
			tally[kind+": commit first"]++
			if kind == "commit inside send" {
				t.Errorf("round %d: the send had read the conversation before the commit started, yet answered STALE_EPOCH", round)
			}
			wantStale(t, sendErr, 1, epoch+1)
			if stored {
				t.Errorf("round %d: STALE_EPOCH but the message was stored", round)
			}
		default:
			t.Fatalf("round %d (%s): send: %v", round, kind, sendErr)
		}
		if c, _ := e.conv(convID); c.MlsEpoch != epoch+1 {
			t.Fatalf("round %d: conversation epoch %d, want %d", round, c.MlsEpoch, epoch+1)
		}
	}
	// Invariant over every stored message: its pair was current when it committed, i.e. created before the record that
	// closed its epoch.
	recs := map[int64]time.Time{}
	for id := range e.commitsOf(convID) {
		var g, ep int64
		if _, err := fmt.Sscanf(id, "%010d_%010d", &g, &ep); err != nil {
			t.Fatal(err)
		}
		recs[ep] = e.docSnap("conversations/" + convID + "/commits/" + id).CreateTime
	}
	docs, err := e.fs.Collection("conversations").Doc(convID).Collection("messages").Documents(ctx).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range docs {
		var m MsgDoc
		if err := d.DataTo(&m); err != nil {
			t.Fatal(err)
		}
		if closed, ok := recs[m.MlsEpoch]; m.MlsGen == 1 && ok && !d.CreateTime.Before(closed) {
			t.Errorf("message %s at (1, %d) committed after the commit that closed its epoch", d.Ref.ID, m.MlsEpoch)
		}
	}
	t.Logf("outcomes: %v", tally)
	first, second := 0, 0
	for k, n := range tally {
		switch {
		case strings.HasSuffix(k, "send first"):
			first += n
		case strings.HasSuffix(k, "commit first"):
			second += n
		}
	}
	if first == 0 || second == 0 {
		t.Errorf("only one order observed (send first %d, commit first %d): the race is not exercised", first, second)
	}
}

// Resets: the generation bumps; a send at the old generation and a reset naming the old generation are STALE_EPOCH; two
// resets racing on one generation make one generation (one (g + 1, 0) record, the loser STALE_EPOCH, nothing of its own).
func TestCommitIT_Resets(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	convID, _ := e.startMLSConversation(1, 3)
	// A single-device caller: only the peer's device is addressed.
	e.devices.mu.Lock()
	e.devices.active[alice] = []string{devAlice1}
	e.devices.mu.Unlock()
	wantPair(t, e.mustCommitIT(e.svc, alice, resetReq(ckey(1), convID, 1, "r1", devBob1)), 2, 1)
	_, err := e.send(bob, encByConv(skey(1), convID, 1, 3, "old"))
	wantStale(t, err, 2, 1)
	_, err = e.commitOn(e.svc, bob, resetReq(ckey(2), convID, 1, "stale", devAlice1))
	wantStale(t, err, 2, 1)
	_, err = e.commitOn(e.svc, bob, commitReq(ckey(3), convID, 1, 3, "old commit"))
	wantStale(t, err, 2, 1)
	if n := len(e.commitsOf(convID)); n != 1 {
		t.Errorf("records = %d, want 1", n)
	}

	for round := range 4 {
		gen := uint64(2 + round)
		start, second := make(chan struct{}), make(chan struct{})
		var once sync.Once
		release := func() { once.Do(func() { close(second) }) }
		first := e.newService()
		if round%2 == 1 {
			first = e.signalledService(release)
		} else {
			release()
		}
		svcs := [2]*service{first, e.newService()}
		reqs := [2]*messagingv1.CommitConversationRequest{
			resetReq(ckey(100+round), convID, gen, fmt.Sprintf("ra%d", round), devBob1),
			resetReq(ckey(200+round), convID, gen, fmt.Sprintf("rb%d", round), devAlice1),
		}
		froms := [2]string{alice, bob}
		var errs [2]error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, errs[0] = e.commitOn(svcs[0], froms[0], reqs[0])
			release()
		}()
		go func() {
			defer wg.Done()
			<-start
			<-second
			_, errs[1] = e.commitOn(svcs[1], froms[1], reqs[1])
		}()
		close(start)
		wg.Wait()
		winner := -1
		for i := range errs {
			if outcome(errs[i]) == "busy" {
				_, errs[i] = e.commitOn(svcs[i], froms[i], reqs[i])
			}
			if errs[i] != nil {
				wantStale(t, errs[i], int64(gen)+1, 1)
				continue
			}
			if winner >= 0 {
				t.Fatalf("round %d: both resets won", round)
			}
			winner = i
		}
		if winner < 0 {
			t.Fatalf("round %d: no reset won", round)
		}
		rec := e.commitsOf(convID)[commitDocID(int64(gen)+1, 0)]
		if rec["senderId"] != froms[winner] {
			t.Errorf("round %d: record from %v", round, rec["senderId"])
		}
		if c, _ := e.conv(convID); c.MlsGen != int64(gen)+1 || c.MlsEpoch != 1 {
			t.Errorf("round %d: conversation (%d, %d)", round, c.MlsGen, c.MlsEpoch)
		}
		for id := range e.commitsOf(convID) {
			if id == commitDocID(int64(gen)+2, 0) {
				t.Errorf("round %d: two generations made", round)
			}
		}
	}
}

// Retry recognition: a commit and a reset retried after another commit landed answer the current pair and store no
// second record; a retry whose welcome device went inactive meanwhile still succeeds (the retry beats the device check)
// and looks up no device.
func TestCommitIT_Retries(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	convID, _ := e.startMLSConversation(1, 1)
	c1 := commitReq(ckey(1), convID, 1, 1, "c1", devBob2)
	e.mustCommitIT(e.svc, alice, c1)
	e.mustCommitIT(e.svc, bob, commitReq(ckey(2), convID, 1, 2, "c2"))
	e.devices.mu.Lock()
	e.devices.active[bob] = []string{devBob1}
	calls := len(e.devices.calls)
	e.devices.mu.Unlock()
	wantPair(t, e.mustCommitIT(e.svc, alice, c1), 1, 3)
	if n := len(e.commitsOf(convID)); n != 2 {
		t.Errorf("records = %d, want 2", n)
	}
	e.devices.mu.Lock()
	if len(e.devices.calls) != calls {
		t.Errorf("a retry looked up devices")
	}
	e.devices.mu.Unlock()

	r := resetReq(ckey(3), convID, 1, "r", devBob1)
	wantPair(t, e.mustCommitIT(e.svc, alice, r), 2, 1)
	e.mustCommitIT(e.svc, bob, commitReq(ckey(4), convID, 2, 1, "after reset"))
	wantPair(t, e.mustCommitIT(e.svc, alice, r), 2, 2)
	if n := len(e.commitsOf(convID)); n != 4 {
		t.Errorf("records = %d, want 4", n)
	}
	// Other bytes for a stored pair, or the same bytes from the other user: not a retry, so STALE_EPOCH at the latest.
	_, err := e.commitOn(e.svc, alice, commitReq(ckey(5), convID, 1, 1, "other"))
	wantStale(t, err, 2, 2)
	_, err = e.commitOn(e.svc, bob, commitReq(ckey(6), convID, 1, 1, "c1"))
	wantStale(t, err, 2, 2)
	// Not a retry, so the device check (step 4) applies before the pair: c1's welcome device is inactive now.
	_, err = e.commitOn(e.svc, bob, c1)
	wantField(t, err, "welcome_device_ids")
}

// Refusals write nothing, look up no device and say nothing about devices: an unknown conversation and a non-participant
// are the one NOT_FOUND; a gone peer and a block either way are a send's CANNOT_MESSAGE, with the same bytes for valid and
// invalid device ids.
func TestCommitIT_Refusals(t *testing.T) {
	notFoundBytes := wireBytes(t, notFound())
	cannotBytes := wireBytes(t, cannotMessage())
	cases := []struct {
		name   string
		caller string
		setup  func(e *itEnv, convID string)
		want   []byte
	}{
		{"non-participant", carolUID, func(e *itEnv, _ string) { e.addUser(carolUID, "carol", false) }, notFoundBytes},
		{"peer gone", alice, func(e *itEnv, convID string) {
			if _, err := e.fs.Collection("conversations").Doc(convID).Update(context.Background(), []firestore.Update{{Path: "gone", Value: []string{bob}}}); err != nil {
				e.t.Fatal(err)
			}
		}, cannotBytes},
		{"peer blocks the caller", alice, func(e *itEnv, _ string) {
			e.setSocial(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Blocked: map[string]bool{alice: true}})
		}, cannotBytes},
		{"caller blocks the peer", alice, func(e *itEnv, _ string) {
			e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}, Blocked: map[string]bool{bob: true}})
		}, cannotBytes},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, ids := range [][]string{{devBob1}, {devCarol1}} {
				e := newIT(t, nil)
				e.withDevices()
				convID, _ := e.startMLSConversation(1, 1)
				tc.setup(e, convID)
				u := e.snapshotState(convID)
				_, err := e.commitOn(e.svc, tc.caller, commitReq(ckey(1), convID, 1, 1, "c", ids...))
				if got := wireBytes(t, err); !bytes.Equal(got, tc.want) {
					t.Errorf("ids %v: wire = %q, want %q", ids, got, tc.want)
				}
				u.check(t)
				if n := len(e.commitsOf(convID)); n != 0 {
					t.Errorf("records = %d", n)
				}
				if len(e.devices.calls) != 0 {
					t.Errorf("device lookups %v", e.devices.calls)
				}
			}
		})
	}
	t.Run("unknown conversation", func(t *testing.T) {
		e := newIT(t, nil)
		_, err := e.commitOn(e.svc, alice, commitReq(ckey(1), ConversationID(alice, carolUID), 1, 1, "c"))
		if got := wireBytes(t, err); !bytes.Equal(got, notFoundBytes) {
			t.Errorf("wire = %q", got)
		}
	})
	t.Run("plaintext conversation", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		convID := e.must(alice, toUser(skey(1), bob, "plain")).GetConversation().GetId()
		_, err := e.commitOn(e.svc, alice, commitReq(ckey(1), convID, 1, 1, "c"))
		wantField(t, err, "conversation_id")
		if n := len(e.commitsOf(convID)); n != 0 {
			t.Errorf("records = %d", n)
		}
	})
	t.Run("device check after the refusals, before the pair", func(t *testing.T) {
		e := newIT(t, nil)
		e.withDevices()
		convID, _ := e.startMLSConversation(1, 5)
		u := e.snapshotState(convID)
		_, err := e.commitOn(e.svc, alice, commitReq(ckey(1), convID, 1, 1, "c", devCarol1))
		wantField(t, err, "welcome_device_ids")
		_, err = e.commitOn(e.svc, alice, resetReq(ckey(2), convID, 1, "c", devAlice2))
		wantField(t, err, "welcome_device_ids")
		u.check(t)
		if len(e.commitsOf(convID)) != 0 || len(e.docsIn("users/"+alice+"/dmWelcomes")) != 0 {
			t.Error("a refused commit wrote")
		}
	})
}

// A record left over from an earlier conversation with the same id (both participants erased, the tree deleted without
// its commits, the conversation created again) never blocks the new one: an mls_init writes over a leftover (1, 0), and a
// commit on the current pair writes over a leftover record of that pair, which is never taken for a retry.
func TestCommitIT_LeftoverRecords(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	ctx := context.Background()
	old := e.now().Add(-90 * 24 * time.Hour)
	for _, pair := range [][2]int64{{1, 0}, {1, 1}} {
		if _, err := e.fs.Collection("conversations").Doc(convID).Collection("commits").Doc(commitDocID(pair[0], pair[1])).Set(ctx,
			CommitDoc{Data: []byte("commit:c"), SenderID: alice, Gen: pair[0], Epoch: pair[1], CreatedAt: old, ExpireAt: old.Add(CommitRetention)}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.send(alice, initTo(skey(1), bob, "fresh", devBob1)); err != nil {
		t.Fatalf("init over a leftover (1, 0): %v", err)
	}
	if rec := e.commitsOf(convID)[commitDocID(1, 0)]; string(rec["data"].([]byte)) != "commit:fresh" || asTime(t, rec["createdAt"]).Before(old.Add(time.Hour)) {
		t.Errorf("(1, 0) = %v, want the init's", rec)
	}
	// The leftover (1, 1) has this request's very bytes and sender, but the conversation is AT (1, 1): not a retry.
	wantPair(t, e.mustCommitIT(e.svc, alice, commitReq(ckey(1), convID, 1, 1, "c")), 1, 2)
	if c, _ := e.conv(convID); c.MlsEpoch != 2 {
		t.Errorf("conversation epoch %d, want 2", c.MlsEpoch)
	}
	if rec := e.commitsOf(convID)[commitDocID(1, 1)]; asTime(t, rec["createdAt"]).Before(old.Add(time.Hour)) {
		t.Errorf("(1, 1) still the leftover: %v", rec)
	}
	// And now it is a retry.
	wantPair(t, e.mustCommitIT(e.svc, alice, commitReq(ckey(2), convID, 1, 1, "c")), 1, 2)
}
