package notifications

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const convA = "0123456789abcdef0123456789abcdef"

// flagSet is a FlagChecker over "uid|flag" keys.
type flagSet map[string]bool

func (f flagSet) Enabled(uid, name string) bool { return f[uid+"|"+name] }

func bothOn(uids ...string) flagSet {
	f := flagSet{}
	for _, u := range uids {
		f[u+"|"+FlagName] = true
		f[u+"|"+MessagingFlagName] = true
	}
	return f
}

func msgEvent() Event {
	return Event{Type: TypeMessage, ActorID: "alice", RecipientIDs: []string{"bob"}, ConversationID: convA, At: t0}
}

func TestDeliver_MessageIsPushOnly(t *testing.T) {
	r := newRig(t, bothOn("alice", "bob"))
	r.addDevice("bob", "d1", "tok-1")
	r.addDevice("bob", "d2", "tok-2")
	out, err := r.f.Deliver(context.Background(), msgEvent())
	mustNoErr(t, err)
	if out.Pushed != 2 || out.Created != 0 || out.Duplicate != 0 {
		t.Fatalf("outcome = %+v, want 2 pushed, no row", out)
	}
	if r.repo.creates != 0 || len(r.repo.rows) != 0 || len(r.dir.forgottenUnread) != 0 {
		t.Errorf("a message wrote a row or moved the badge: creates=%d rows=%v unread=%v", r.repo.creates, r.repo.rows, r.dir.forgottenUnread)
	}
	if got := r.sender.sent[0].Push; got != (Push{Type: TypeMessage, ConversationID: convA}) {
		t.Errorf("push = %+v, want type and conversation only", got)
	}
	// ListNotifications never sees one: there is no row to list.
	rows, err := r.repo.List(context.Background(), "bob", ListQuery{Limit: 50})
	mustNoErr(t, err)
	if len(rows) != 0 {
		t.Errorf("listed %d rows", len(rows))
	}
	// A redelivery sends at most one more push per device (collapsed on the device), never a row.
	out, err = r.f.Deliver(context.Background(), msgEvent())
	mustNoErr(t, err)
	if out.Pushed != 2 || r.repo.creates != 0 {
		t.Errorf("redelivery = %+v creates=%d", out, r.repo.creates)
	}
}

func TestDeliver_MessageSuppressionAndFlags(t *testing.T) {
	tests := []struct {
		name   string
		flags  FlagChecker
		snap   map[string]graphSnap
		pushed int
		event  string
	}{
		{name: "sent", flags: bothOn("alice", "bob"), pushed: 1},
		{name: "recipient muted the sender", flags: bothOn("bob"), snap: map[string]graphSnap{"bob": {Muted: map[string]bool{"alice": true}}}, event: "suppressed"},
		{name: "recipient blocked the sender", flags: bothOn("bob"), snap: map[string]graphSnap{"bob": {Blocked: map[string]bool{"alice": true}}}, event: "suppressed"},
		{name: "sender blocked the recipient", flags: bothOn("bob"), snap: map[string]graphSnap{"bob": {BlockedBy: map[string]bool{"alice": true}}}, event: "suppressed"},
		{name: "notifications off", flags: flagSet{"bob|" + MessagingFlagName: true}},
		{name: "messaging off", flags: flagSet{"bob|" + FlagName: true}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, tt.flags)
			r.addDevice("bob", "d1", "tok-1")
			for k, v := range tt.snap {
				r.social.snaps[k] = v
			}
			out, err := r.f.Deliver(context.Background(), msgEvent())
			mustNoErr(t, err)
			if out.Pushed != tt.pushed || len(r.sender.sent) != tt.pushed {
				t.Errorf("pushed = %d (%d sent), want %d", out.Pushed, len(r.sender.sent), tt.pushed)
			}
			if tt.event == "suppressed" && out.Suppressed != 1 {
				t.Errorf("outcome = %+v, want suppressed", out)
			}
		})
	}
}

// TestDeliver_MessageOwnLimiterBucket: 20 pushes an hour for messages, separate from the shared bucket in both directions.
func TestDeliver_MessageOwnLimiterBucket(t *testing.T) {
	r := newRig(t, bothOn("alice", "bob"))
	r.f.d.MessagePushLimit = NewPushLimiter(20)
	r.f.d.PushLimit = NewPushLimiter(10)
	r.addDevice("bob", "d1", "tok-1")
	for i := 1; i <= 21; i++ {
		out, err := r.f.Deliver(context.Background(), msgEvent())
		mustNoErr(t, err)
		if want := i <= 20; (out.Pushed == 1) != want || (out.Throttled == 1) == want {
			t.Fatalf("message %d: outcome = %+v", i, out)
		}
	}
	// The exhausted message bucket does not throttle a follow, which has its own 10/h.
	out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "carol", RecipientIDs: []string{"bob"}, At: t0})
	mustNoErr(t, err)
	if out.Pushed != 1 || out.Throttled != 0 {
		t.Errorf("follow after 21 messages = %+v", out)
	}
	// And exhausting the shared bucket leaves messages alone.
	r2 := newRig(t, bothOn("alice", "bob"))
	r2.f.d.MessagePushLimit = NewPushLimiter(20)
	r2.f.d.PushLimit = NewPushLimiter(1)
	r2.addDevice("bob", "d1", "tok-1")
	_, _ = r2.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "carol", RecipientIDs: []string{"bob"}, At: t0})
	out, _ = r2.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0})
	if out.Throttled != 1 {
		t.Fatalf("second follow = %+v, want throttled", out)
	}
	out, _ = r2.f.Deliver(context.Background(), msgEvent())
	if out.Pushed != 1 {
		t.Errorf("message with the shared bucket exhausted = %+v", out)
	}
}

func TestValidateMessageEvent(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*Event)
		want string
	}{
		{"valid", func(*Event) {}, ""},
		{"no conversation", func(e *Event) { e.ConversationID = "" }, "invalid_conversation"},
		{"short conversation", func(e *Event) { e.ConversationID = "abc" }, "invalid_conversation"},
		{"upper-case conversation", func(e *Event) { e.ConversationID = strings.ToUpper(convA) }, "invalid_conversation"},
		{"a post id is not required", func(e *Event) { e.PostID = "" }, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := msgEvent()
			tt.mut(&e)
			if got := validateEvent(e); got != tt.want {
				t.Errorf("validateEvent = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestMessagePushPayload(t *testing.T) {
	m := buildMessage("tok", Push{Type: TypeMessage, ConversationID: convA})
	if len(m.Data) != 2 || m.Data["type"] != "message" || m.Data["conversationId"] != convA {
		t.Errorf("data = %v, want type and conversationId only", m.Data)
	}
	if m.Notification.Title != "New message" || m.Notification.Body != "You have a new message" {
		t.Errorf("notification = %+v", m.Notification)
	}
	if m.Android.CollapseKey != "message" || m.Android.Notification.Tag != "message" || m.APNS.Headers["apns-collapse-id"] != "message" {
		t.Errorf("collapse = %q / %q / %q", m.Android.CollapseKey, m.Android.Notification.Tag, m.APNS.Headers["apns-collapse-id"])
	}
	golden, err := json.Marshal(m.Data)
	mustNoErr(t, err)
	if string(golden) != `{"conversationId":"`+convA+`","type":"message"}` {
		t.Errorf("data golden = %s", golden)
	}
}

func TestEmitterRequiresMessagingFlag(t *testing.T) {
	pub := &fakePublisher{}
	e := NewPubSubEmitter(pub, flagSet{"bob|" + FlagName: true}, nil)
	mustNoErr(t, e.Emit(context.Background(), msgEvent()))
	if len(pub.data) != 0 {
		t.Fatal("published for a recipient with messaging off")
	}
	e = NewPubSubEmitter(pub, bothOn("bob"), nil)
	mustNoErr(t, e.Emit(context.Background(), msgEvent()))
	if len(pub.data) != 1 {
		t.Fatalf("published = %d, want 1", len(pub.data))
	}
	var w wireEvent
	mustNoErr(t, json.Unmarshal(pub.data[0], &w))
	if w.V != 1 || w.Type != TypeMessage || w.ConversationID != convA || w.PostID != "" {
		t.Errorf("wire = %+v", w)
	}
}

// TestHandler_MessageAndOldRevision: the handler forwards conversationId; an event an older revision cannot parse
// into a valid type (unknown type) is acknowledged with no row or push, as ADR-0027 D9 requires.
func TestHandler_MessageAndOldRevision(t *testing.T) {
	r := newRig(t, bothOn("alice", "bob"))
	r.addDevice("bob", "d1", "tok-1")
	body, err := encodeEvent(msgEvent())
	mustNoErr(t, err)
	w := httptest.NewRecorder()
	r.f.Handler().ServeHTTP(w, envelope(t, body))
	if w.Code != http.StatusNoContent || len(r.sender.sent) != 1 || r.sender.sent[0].Push.ConversationID != convA {
		t.Fatalf("code=%d sent=%+v", w.Code, r.sender.sent)
	}
	// The old revision's view: Type "message" is unknown there. Simulate with a type this revision does not know.
	for _, raw := range []string{
		`{"v":1,"type":"message_v2","actorId":"alice","recipientIds":["bob"],"conversationId":"` + convA + `","at":1}`,
		`{"v":1,"type":"message","actorId":"alice","recipientIds":["bob"],"at":1}`, // missing conversation id
	} {
		w := httptest.NewRecorder()
		r.f.Handler().ServeHTTP(w, envelope(t, []byte(raw)))
		if w.Code != http.StatusNoContent || len(r.sender.sent) != 1 || len(r.repo.rows) != 0 {
			t.Errorf("%s: code=%d sent=%d rows=%d, want an ack and nothing else", raw, w.Code, len(r.sender.sent), len(r.repo.rows))
		}
	}
	if !strings.Contains(r.logs.String(), `"type":"message"`) {
		t.Error("delivery line lacks type=message")
	}
}
