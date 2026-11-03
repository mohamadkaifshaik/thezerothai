//go:build integration

package messaging

// ADR-0027 "concurrent first messages", D13: sends racing on one conversation from several Cloud Run
// instances (one service per goroutine, one shared Firestore). The invariants are the ones a client relies on: one message
// per idempotency key, the request cap never exceeded, and no lost unread increment. The 50 sends/s load shape comes later.

import (
	"context"
	"fmt"
	"sync"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// raceSends runs one send per request, all released together, each on its own service instance, and returns the errors.
func (e *itEnv) raceSends(from string, reqs []*messagingv1.SendMessageRequest) (resps []*messagingv1.SendMessageResponse, errs []error) {
	resps, errs = make([]*messagingv1.SendMessageResponse, len(reqs)), make([]error, len(reqs))
	svcs := make([]*service, len(reqs))
	for i := range reqs {
		svcs[i] = e.newService()
	}
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range reqs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			resps[i], _, errs[i] = e.sendOn(svcs[i], from, reqs[i])
		}()
	}
	close(start)
	wg.Wait()
	return resps, errs
}

// outcome names an error for the invariants below: "ok", "request_unanswered" (LIMIT_REACHED), "busy" (the
// UNAVAILABLE a lost transaction maps to, safe to retry) or the raw error.
func outcome(err error) string {
	if err == nil {
		return "ok"
	}
	ce := apierr.ToConnect(err)
	if ce.Code() == connect.CodeUnavailable {
		return "busy"
	}
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok && ed.GetReason() == commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED {
				return ed.GetMetadata()["limit"]
			}
		}
	}
	return err.Error()
}

// The same idempotency key sent from six instances at once, as the first message of a new conversation, is one message:
// every call that succeeds returns the same message id, one document exists, the recipient has one unread and was pushed
// once, and the new-conversation quota was charged once.
func TestSend_ConcurrentSameKeyIsOneMessage(t *testing.T) {
	for round := range 3 {
		t.Run(fmt.Sprintf("round %d", round), func(t *testing.T) {
			e := newIT(t, func(e *itEnv) { e.mutual(alice, bob) })
			const racers = 6
			reqs := make([]*messagingv1.SendMessageRequest, racers)
			for i := range reqs {
				reqs[i] = toUser(skey(900+round), bob, "exactly once")
			}
			resps, errs := e.raceSends(alice, reqs)
			ok := 0
			for i, err := range errs {
				switch outcome(err) {
				case "ok":
					ok++
					if resps[i].GetMessage().GetId() != MessageID(alice, skey(900+round)) {
						t.Errorf("racer %d got message id %q", i, resps[i].GetMessage().GetId())
					}
				case "busy": // may have committed (txTimeout); the same-key retry below replays it
				default:
					t.Errorf("racer %d: %v", i, err)
				}
			}
			// Every racer can be busy (a slow emulator runs into txTimeout) and a busy racer may have committed. The
			// client's answer is a same-key retry: it must succeed, as a replay of a committed message or as the first write.
			if ok == 0 {
				resp, _, err := e.send(alice, reqs[0])
				if err != nil || resp.GetMessage().GetId() != MessageID(alice, skey(900+round)) {
					t.Fatalf("same-key retry after all racers were busy: %v", err)
				}
			}
			convID := ConversationID(alice, bob)
			if n := len(e.msgs(convID)); n != 1 {
				t.Errorf("messages stored = %d, want 1", n)
			}
			if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 1 {
				t.Errorf("bob's unreadCount = %d, want 1", ent.UnreadCount)
			}
			// A message that committed while its sender saw busy pushes nothing (the push is the sender's own post-commit
			// step, and the retry is a replay): at most one event, exactly one when a racer saw the commit.
			if n := len(e.events.got); n > 1 || (ok > 0 && n != 1) {
				t.Errorf("message events = %d, want 1 (a replay pushes nothing)", n)
			}
			if n := e.dmNew(alice); n != 1 {
				t.Errorf("dmNew charged %d, want 1", n)
			}
		})
	}
}

// Six instances send six different messages into one non-mutual conversation at once: the request cap of 3 holds. At most
// 3 are stored, every refusal is LIMIT_REACHED request_unanswered (or a busy), requestCount equals what was stored, the
// recipient's unread count equals it, and no request pushed.
//
// A busy racer is NOT guaranteed to have written nothing. A transaction that ran into txTimeout (5 s, a slow CI
// emulator) answers UNAVAILABLE busy from the client's side while its commit may already have applied (in production too:
// DEADLINE_EXCEEDED does not say the commit failed). So the true invariant is: stored == requestCount == unread <= 3, where
// "stored" is the racers that answered ok plus the busy racers whose message is stored; and the client's answer to busy, a
// retry with the same idempotency key, replays a committed message (ok, no second write, no second count) and only a
// message that was never stored is decided afresh against the cap. Every busy racer is retried below to prove that.
func TestSend_ConcurrentRequestCapHolds(t *testing.T) {
	for round := range 3 {
		t.Run(fmt.Sprintf("round %d", round), func(t *testing.T) {
			e := newIT(t, nil)
			const racers = 6
			reqs := make([]*messagingv1.SendMessageRequest, racers)
			for i := range reqs {
				reqs[i] = toUser(skey(800+10*round+i), bob, fmt.Sprintf("request %d", i))
			}
			_, errs := e.raceSends(alice, reqs)
			convID := ConversationID(alice, bob)
			var busy []int
			for i, err := range errs {
				switch outcome(err) {
				case "ok", "request_unanswered":
				case "busy":
					busy = append(busy, i)
				default:
					t.Errorf("racer %d: %v", i, err)
				}
			}
			// Settle: the racers are done, so the retries run alone. Each busy racer's message is either stored (committed
			// before the client gave up) or not; the same-key retry must replay the first and decide the second afresh.
			before := e.msgs(convID)
			for _, i := range busy {
				_, stored := before[MessageID(alice, skey(800+10*round+i))]
				resp, _, err := e.send(alice, reqs[i])
				switch got := outcome(err); {
				case stored && got != "ok":
					t.Errorf("busy racer %d committed, but its same-key retry answered %q, want a replay", i, got)
				case stored && resp.GetMessage().GetId() != MessageID(alice, skey(800+10*round+i)):
					t.Errorf("busy racer %d replay returned message id %q", i, resp.GetMessage().GetId())
				case !stored && got != "ok" && got != "request_unanswered":
					t.Errorf("busy racer %d (not stored) retry answered %q", i, got)
				}
			}
			after := e.msgs(convID)
			for id := range before {
				if _, ok := after[id]; !ok {
					t.Errorf("message %s vanished", id)
				}
			}
			stored := len(after)
			if stored > 3 {
				t.Errorf("stored %d messages, the request cap is 3", stored)
			}
			// A retry of a stored message adds nothing; a retry of an unstored one may fill a free slot, but never beyond 3.
			if len(busy) == 0 && stored != 3 {
				t.Errorf("no racer was busy yet %d messages stored, want exactly 3", stored)
			}
			conv, found := e.conv(convID)
			if !found || conv.RequestCount != int64(stored) {
				t.Errorf("requestCount = %d, want %d stored (found=%v)", conv.RequestCount, stored, found)
			}
			if ent, _ := e.entry(bob, dmRequestsCollection, convID); ent.UnreadCount != int64(stored) {
				t.Errorf("bob's dmRequests unreadCount = %d, want %d", ent.UnreadCount, stored)
			}
			if n := len(e.events.got); n != 0 {
				t.Errorf("a request pushed %d events, want 0", n)
			}
		})
	}
}

// Eight instances send into one accepted conversation at once: every send that succeeds is stored and counted, with no lost
// Increment on the recipient's unread count and one push per stored message. (Contention beyond this, 50 sends a second
// into one conversation, is the load shape.)
func TestSend_ConcurrentSendsLoseNoUnreadIncrement(t *testing.T) {
	e := newIT(t, func(e *itEnv) { e.mutual(alice, bob) })
	const racers = 8
	reqs := make([]*messagingv1.SendMessageRequest, racers)
	for i := range reqs {
		reqs[i] = toUser(skey(700+i), bob, fmt.Sprintf("burst %d", i))
	}
	_, errs := e.raceSends(alice, reqs)
	ok := 0
	for i, err := range errs {
		switch outcome(err) {
		case "ok":
			ok++
		case "busy":
		default:
			t.Errorf("racer %d: %v", i, err)
		}
	}
	t.Logf("%d of %d concurrent sends succeeded first time", ok, racers)
	// A busy racer may have committed. The client retries with the same key, so every busy racer is retried: a
	// committed message replays, an uncommitted one is written now. Afterwards all sends exist exactly once.
	for i, err := range errs {
		if outcome(err) != "busy" {
			continue
		}
		if _, _, rerr := e.send(alice, reqs[i]); rerr != nil {
			t.Errorf("racer %d same-key retry: %v", i, rerr)
		}
	}
	convID := ConversationID(alice, bob)
	if n := len(e.msgs(convID)); n != racers {
		t.Errorf("stored %d messages for %d sends, each answered ok or retried", n, racers)
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != racers {
		t.Errorf("bob's unreadCount = %d, want %d (a lost or doubled increment)", ent.UnreadCount, racers)
	}
	// One push per first write seen by its sender; a message that committed while its sender saw busy pushes nothing.
	if n := len(e.events.got); n < ok || n > racers {
		t.Errorf("message events = %d, want between %d and %d", n, ok, racers)
	}
}

// The root cause made deterministic: the send transaction COMMITS and the caller then gets a deadline error (the
// 5 s txTimeout, or the request deadline, expiring while the Commit RPC is in flight; Firestore keeps the commit). The
// service answers UNAVAILABLE busy, so "busy" cannot promise "nothing was written". What it does promise is that the
// same-key retry is safe: it replays the stored message (ok, same id), writes nothing, pushes nothing and charges neither
// the unread count nor the new-conversation quota a second time.
func TestSend_BusyAfterCommitRetryReplays(t *testing.T) {
	e := newIT(t, func(e *itEnv) { e.mutual(alice, bob) })
	req := toUser(skey(950), bob, "committed, then a deadline")
	fail := true
	e.repo.hooks = &raceHooks{commitThenFail: func() error {
		if fail {
			return context.DeadlineExceeded
		}
		return nil
	}}
	_, _, err := e.send(alice, req)
	if got := outcome(err); got != "busy" {
		t.Fatalf("first send answered %q, want busy", got)
	}
	convID := ConversationID(alice, bob)
	if n := len(e.msgs(convID)); n != 1 {
		t.Fatalf("stored %d messages after a busy answer whose commit applied, want 1", n)
	}
	fail = false
	resp, _, err := e.send(alice, req)
	if err != nil {
		t.Fatalf("same-key retry: %v", err)
	}
	if resp.GetMessage().GetId() != MessageID(alice, skey(950)) {
		t.Errorf("retry returned message id %q", resp.GetMessage().GetId())
	}
	if n := len(e.msgs(convID)); n != 1 {
		t.Errorf("stored %d messages after the retry, want 1", n)
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 1 {
		t.Errorf("bob's unreadCount = %d, want 1", ent.UnreadCount)
	}
	if n := e.dmNew(alice); n != 1 {
		t.Errorf("dmNew = %d, want 1", n)
	}
	if n := len(e.events.got); n != 0 {
		t.Errorf("message events = %d, want 0 (the busy call never pushed, the replay pushes nothing)", n)
	}
}
