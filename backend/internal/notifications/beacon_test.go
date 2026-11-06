package notifications

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// beaconA is a 19-digit beacon id (the same Snowflake shape as a post id).
const beaconA = "1234567890123456789"

func beaconEvent(t Type) Event {
	return Event{Type: t, ActorID: "alice", RecipientIDs: []string{"bob"}, BeaconID: beaconA, At: t0}
}

// TestDeliver_BeaconRowsAndPushes: each beacon type writes one row that names the beacon (never a post) under its
// natural key (R22), pushes once with ids only, and a redelivery is a duplicate: no second row, no second push.
func TestDeliver_BeaconRowsAndPushes(t *testing.T) {
	tests := []struct {
		t      Type
		wantID string
	}{
		{TypeBeaconRequest, "beacon_request_" + beaconA + "_alice"},
		{TypeBeaconAccepted, "beacon_accepted_" + beaconA},
		{TypeBeaconCancelled, "beacon_cancelled_" + beaconA},
	}
	for _, tt := range tests {
		t.Run(string(tt.t), func(t *testing.T) {
			r := newRig(t, nil)
			r.addDevice("bob", "d1", "tok-1")
			out, err := r.f.Deliver(context.Background(), beaconEvent(tt.t))
			mustNoErr(t, err)
			if out.Created != 1 || out.Pushed != 1 {
				t.Fatalf("outcome = %+v, want one row and one push", out)
			}
			row, ok := r.repo.rows["bob"][tt.wantID]
			if !ok {
				t.Fatalf("rows for bob = %v, want %s", r.repo.rows["bob"], tt.wantID)
			}
			if row.BeaconID != beaconA || row.PostID != "" || row.Type != tt.t || row.Actor.UserID != "alice" {
				t.Errorf("row = %+v", row)
			}
			if got, want := r.sender.sent[0].Push, (Push{Type: tt.t, NotificationID: tt.wantID, BeaconID: beaconA, ActorID: "alice"}); got != want {
				t.Errorf("push = %+v, want %+v", got, want)
			}
			out, err = r.f.Deliver(context.Background(), beaconEvent(tt.t))
			mustNoErr(t, err)
			if out.Duplicate != 1 || out.Created != 0 || out.Pushed != 0 || r.repo.creates != 2 {
				t.Errorf("redelivery = %+v creates=%d, want one duplicate and nothing else", out, r.repo.creates)
			}
		})
	}
}

// TestDeliver_BeaconSuppressionMatrix (spec 7.3): a cancellation never crosses a block or a mute in either direction;
// the other accepted participant still gets the row and the push.
func TestDeliver_BeaconSuppressionMatrix(t *testing.T) {
	tests := []struct {
		name string
		snap graphSnap
	}{
		{"participant blocked the organiser", graphSnap{Blocked: map[string]bool{"alice": true}}},
		{"organiser blocked the participant", graphSnap{BlockedBy: map[string]bool{"alice": true}}},
		{"participant muted the organiser", graphSnap{Muted: map[string]bool{"alice": true}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, nil)
			r.social.snaps["bob"] = tt.snap
			r.addDevice("bob", "d1", "tok-b")
			r.addDevice("carol", "d2", "tok-c")
			ev := beaconEvent(TypeBeaconCancelled)
			ev.RecipientIDs = []string{"bob", "carol"}
			out, err := r.f.Deliver(context.Background(), ev)
			mustNoErr(t, err)
			if out.Suppressed != 1 || out.Created != 1 || out.Pushed != 1 {
				t.Fatalf("outcome = %+v, want bob suppressed and carol delivered", out)
			}
			if len(r.repo.rows["bob"]) != 0 || len(r.repo.rows["carol"]) != 1 || r.sender.sent[0].Token != "tok-c" {
				t.Errorf("rows bob=%v carol=%v sent=%+v", r.repo.rows["bob"], r.repo.rows["carol"], r.sender.sent)
			}
		})
	}
}

// TestValidateBeaconEvent: a beacon event without a 19-digit beacon id can never be delivered; the handler acknowledges
// it (no retry, no DLQ) and writes nothing.
func TestValidateBeaconEvent(t *testing.T) {
	base := func(ty Type) Event { return Event{Type: ty, ActorID: "alice", RecipientIDs: []string{"bob"}} }
	with := func(e Event, f func(*Event)) Event { f(&e); return e }
	tests := []struct {
		name string
		ev   Event
		want string
	}{
		{"valid", beaconEvent(TypeBeaconRequest), ""},
		{"empty id", base(TypeBeaconAccepted), "invalid_beacon"},
		{"short id", with(base(TypeBeaconCancelled), func(e *Event) { e.BeaconID = "123" }), "invalid_beacon"},
		{"letter", with(base(TypeBeaconRequest), func(e *Event) { e.BeaconID = "12345678901234567a9" }), "invalid_beacon"},
		{"post instead of beacon", with(base(TypeBeaconRequest), func(e *Event) { e.PostID = postA }), "invalid_beacon"},
	}
	for _, tt := range tests {
		if got := validateEvent(tt.ev); got != tt.want {
			t.Errorf("%s: validateEvent = %q, want %q", tt.name, got, tt.want)
		}
	}
	r := newRig(t, nil)
	r.addDevice("bob", "d1", "tok-1")
	w := httptest.NewRecorder()
	r.f.Handler().ServeHTTP(w, envelope(t, []byte(`{"v":1,"type":"beacon_request","actorId":"alice","recipientIds":["bob"],"beaconId":"123","at":1}`)))
	if w.Code != http.StatusNoContent || len(r.repo.rows) != 0 || len(r.sender.sent) != 0 {
		t.Errorf("code=%d rows=%d sent=%d, want an ack and nothing else", w.Code, len(r.repo.rows), len(r.sender.sent))
	}
	if !strings.Contains(r.logs.String(), `"dropped":1`) {
		t.Errorf("delivery line does not count the drop: %s", r.logs.String())
	}
}

// TestBeaconPushPayloadAndText (R26): a beacon push's data is type, notificationId, beaconId and actorId (no postId);
// the text is generic and names no title, venue or account.
func TestBeaconPushPayloadAndText(t *testing.T) {
	want := map[Type][2]string{
		TypeBeaconRequest:   {"New join request", "Someone asked to join your plan"},
		TypeBeaconAccepted:  {"Request accepted", "Your request to join a plan was accepted"},
		TypeBeaconCancelled: {"Plan cancelled", "A plan you joined was cancelled"},
	}
	for ty, text := range want {
		m := buildMessage("tok", Push{Type: ty, NotificationID: "n1", BeaconID: beaconA, ActorID: "alice"})
		if len(m.Data) != 4 || m.Data["type"] != string(ty) || m.Data["notificationId"] != "n1" || m.Data["beaconId"] != beaconA || m.Data["actorId"] != "alice" {
			t.Errorf("%s: data = %v, want type, notificationId, beaconId, actorId", ty, m.Data)
		}
		if _, has := m.Data["postId"]; has {
			t.Errorf("%s: data carries postId", ty)
		}
		if m.Notification.Title != text[0] || m.Notification.Body != text[1] {
			t.Errorf("%s: text = %q / %q, want %q / %q", ty, m.Notification.Title, m.Notification.Body, text[0], text[1])
		}
		if strings.Contains(m.Notification.Title+m.Notification.Body, "@") {
			t.Errorf("%s: push text names an account", ty)
		}
	}
}

// TestEmitterBeaconNeedsOnlyNotificationsFlag (R21): a beacon event is published when the recipient has `notifications`
// on, with no second flag; the wire event names the beacon and no post.
func TestEmitterBeaconNeedsOnlyNotificationsFlag(t *testing.T) {
	pub := &fakePublisher{}
	e := NewPubSubEmitter(pub, flagSet{"bob|" + FlagName: true}, nil)
	mustNoErr(t, e.Emit(context.Background(), beaconEvent(TypeBeaconRequest)))
	if len(pub.data) != 1 {
		t.Fatalf("published = %d, want 1", len(pub.data))
	}
	var raw map[string]any
	mustNoErr(t, json.Unmarshal(pub.data[0], &raw))
	if raw["type"] != "beacon_request" || raw["beaconId"] != beaconA || raw["postId"] != nil {
		t.Errorf("wire = %v", raw)
	}
	var w wireEvent
	mustNoErr(t, json.Unmarshal(pub.data[0], &w))
	if w.BeaconID != beaconA {
		t.Errorf("wireEvent.BeaconID = %q", w.BeaconID)
	}
	e = NewPubSubEmitter(pub, flagSet{}, nil)
	mustNoErr(t, e.Emit(context.Background(), beaconEvent(TypeBeaconAccepted)))
	if len(pub.data) != 1 {
		t.Errorf("published with notifications off for the recipient")
	}
}
