//go:build integration

package messaging

// W7-20 (ADR-0027 W7-5 "concurrent first messages", D13): sends racing on one conversation from several Cloud Run
// instances (one service per goroutine, one shared Firestore). The invariants are the ones a client relies on: one message
// per idempotency key, the request cap never exceeded, and no lost unread increment. The 50 sends/s load shape is W7-23.

import (
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
				case "busy": // a lost transaction is retryable by the client; it must not have written anything
				default:
					t.Errorf("racer %d: %v", i, err)
				}
			}
			if ok == 0 {
				t.Fatal("no racer succeeded")
			}
			convID := ConversationID(alice, bob)
			if n := len(e.msgs(convID)); n != 1 {
				t.Errorf("messages stored = %d, want 1", n)
			}
			if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 1 {
				t.Errorf("bob's unreadCount = %d, want 1", ent.UnreadCount)
			}
			if n := len(e.events.got); n != 1 {
				t.Errorf("message events = %d, want 1 (a replay pushes nothing)", n)
			}
			if n := e.dmNew(alice); n != 1 {
				t.Errorf("dmNew charged %d, want 1", n)
			}
		})
	}
}

// Six instances send six different messages into one non-mutual conversation at once: the request cap of 3 holds. At most
// 3 are stored, every refusal is LIMIT_REACHED request_unanswered (or a retryable busy), requestCount equals what was
// stored, the recipient's unread count equals it, and no request pushed.
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
			ok, busy := 0, 0
			for i, err := range errs {
				switch outcome(err) {
				case "ok":
					ok++
				case "request_unanswered":
				case "busy":
					busy++
				default:
					t.Errorf("racer %d: %v", i, err)
				}
			}
			convID := ConversationID(alice, bob)
			stored := len(e.msgs(convID))
			if stored != ok || ok > 3 {
				t.Errorf("stored %d messages for %d successes, want equal and at most 3", stored, ok)
			}
			if busy == 0 && ok != 3 {
				t.Errorf("no racer was busy yet %d succeeded, want exactly 3", ok)
			}
			conv, found := e.conv(convID)
			if !found || conv.RequestCount != int64(ok) {
				t.Errorf("requestCount = %d, want %d (found=%v)", conv.RequestCount, ok, found)
			}
			if ent, _ := e.entry(bob, dmRequestsCollection, convID); ent.UnreadCount != int64(ok) {
				t.Errorf("bob's dmRequests unreadCount = %d, want %d", ent.UnreadCount, ok)
			}
			if n := len(e.events.got); n != 0 {
				t.Errorf("a request pushed %d events, want 0", n)
			}
		})
	}
}

// Eight instances send into one accepted conversation at once: every send that succeeds is stored and counted, with no lost
// Increment on the recipient's unread count and one push per stored message. (Contention beyond this, 50 sends a second
// into one conversation, is the W7-23 load shape.)
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
	if ok == 0 {
		t.Fatal("no racer succeeded")
	}
	t.Logf("%d of %d concurrent sends succeeded", ok, racers)
	convID := ConversationID(alice, bob)
	if n := len(e.msgs(convID)); n != ok {
		t.Errorf("stored %d messages for %d successes", n, ok)
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != int64(ok) {
		t.Errorf("bob's unreadCount = %d, want %d (a lost increment)", ent.UnreadCount, ok)
	}
	if n := len(e.events.got); n != ok {
		t.Errorf("message events = %d, want %d", n, ok)
	}
}
