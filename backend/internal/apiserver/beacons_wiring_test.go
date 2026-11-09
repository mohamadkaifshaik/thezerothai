package apiserver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const beaconNotifID = "1234567890123456789"

// TestBeaconNotifier_RequestAndAccept: a join request becomes one beacon_request event from the requester to the
// organiser; an acceptance one beacon_accepted event from the organiser to the requester. Neither names a post. An
// empty slot drops them.
func TestBeaconNotifier_RequestAndAccept(t *testing.T) {
	at := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	rec := &recordingEmitter{}
	n := beaconNotifier{slot: &emitterSlot{em: rec}}
	ev := beacons.ParticipationEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUID: "uid-p", At: at}
	n.JoinRequested(context.Background(), ev)
	n.RequestAccepted(context.Background(), ev)
	want := []notifications.Event{
		{Type: notifications.TypeBeaconRequest, ActorID: "uid-p", RecipientIDs: []string{"uid-o"}, BeaconID: beaconNotifID, At: at},
		{Type: notifications.TypeBeaconAccepted, ActorID: "uid-o", RecipientIDs: []string{"uid-p"}, BeaconID: beaconNotifID, At: at},
	}
	if !reflect.DeepEqual(rec.events, want) {
		t.Errorf("events = %+v, want %+v", rec.events, want)
	}
	empty := beaconNotifier{slot: &emitterSlot{}}
	empty.JoinRequested(context.Background(), ev)
	empty.RequestAccepted(context.Background(), ev)
	empty.Cancelled(context.Background(), beacons.CancelEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUIDs: []string{"uid-p"}})
}

// TestBeaconNotifier_CancelChunks (R24): a cancellation reaches every accepted participant in events of at most
// notifications.MaxRecipientsPerEvent, in order; nobody accepted means no event.
func TestBeaconNotifier_CancelChunks(t *testing.T) {
	at := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct{ n, wantEvents int }{{0, 0}, {1, 1}, {10, 1}, {11, 2}, {20, 2}} {
		uids := make([]string, tc.n)
		for i := range uids {
			uids[i] = fmt.Sprintf("p%02d", i)
		}
		rec := &recordingEmitter{}
		beaconNotifier{slot: &emitterSlot{em: rec}}.Cancelled(context.Background(), beacons.CancelEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUIDs: uids, At: at})
		if len(rec.events) != tc.wantEvents {
			t.Errorf("%d participants: events = %d, want %d", tc.n, len(rec.events), tc.wantEvents)
			continue
		}
		var got []string
		for _, e := range rec.events {
			if e.Type != notifications.TypeBeaconCancelled || e.ActorID != "uid-o" || e.BeaconID != beaconNotifID || e.PostID != "" || !e.At.Equal(at) {
				t.Errorf("%d participants: event = %+v", tc.n, e)
			}
			if len(e.RecipientIDs) == 0 || len(e.RecipientIDs) > notifications.MaxRecipientsPerEvent {
				t.Errorf("%d participants: chunk of %d recipients", tc.n, len(e.RecipientIDs))
			}
			got = append(got, e.RecipientIDs...)
		}
		if strings.Join(got, ",") != strings.Join(uids, ",") {
			t.Errorf("%d participants: recipients = %v, want %v in order", tc.n, got, uids)
		}
	}
}

// TestBeaconEvent_ReachesTheFanout (R21): the real emitter publishes a beacon event that names the beacon and no post
// when the recipient has `notifications` on, whatever their `beacons` flag; nothing with notifications off.
func TestBeaconEvent_ReachesTheFanout(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	send := func(reg *flags.Registry) *capturingPublisher {
		pub := &capturingPublisher{}
		em := notifications.NewPubSubEmitter(pub, reg, log)
		beaconNotifier{slot: &emitterSlot{em: em}}.JoinRequested(context.Background(), beacons.ParticipationEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUID: "uid-p", At: time.Now()})
		return pub
	}
	on := flags.Spec{Name: notifications.FlagName, Mode: flags.On}
	for name, reg := range map[string]*flags.Registry{
		"beacons on":  flags.NewRegistry(on, flags.Spec{Name: beacons.FlagName, Mode: flags.On}),
		"beacons off": flags.NewRegistry(on, flags.Spec{Name: beacons.FlagName, Mode: flags.Off}),
	} {
		pub := send(reg)
		if len(pub.data) != 1 {
			t.Fatalf("%s: published %d events, want 1", name, len(pub.data))
		}
		var wire map[string]any
		if err := json.Unmarshal(pub.data[0], &wire); err != nil {
			t.Fatal(err)
		}
		if wire["v"] != float64(1) || wire["type"] != "beacon_request" || wire["beaconId"] != beaconNotifID || wire["postId"] != nil || wire["actorId"] != "uid-p" {
			t.Errorf("%s: wire event = %v", name, wire)
		}
	}
	if pub := send(flags.NewRegistry(flags.Spec{Name: notifications.FlagName, Mode: flags.Off})); len(pub.data) != 0 {
		t.Errorf("published %d events with notifications off, want 0", len(pub.data))
	}
}

// TestBeaconCancel_BypassesRecipientCap (B07): a cancellation notice reaches every accepted participant whatever the
// organiser's remaining per-actor daily recipient budget, and is not charged to it. Before the exemption each chunk
// of 10 passed the all-or-nothing cap, so a remaining budget of 10-14 reached 10 people and under 10 reached nobody.
func TestBeaconCancel_BypassesRecipientCap(t *testing.T) {
	const limit = 15
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := flags.NewRegistry(flags.Spec{Name: notifications.FlagName, Mode: flags.On})
	for _, n := range []int{0, 1, 10, 11, 20} {
		for _, remaining := range []int{0, 5, 10, 15} {
			t.Run(fmt.Sprintf("%d recipients, %d left", n, remaining), func(t *testing.T) {
				recipCap := notifications.NewRecipientCap(limit, limit, nil)
				if spend := limit - remaining; spend > 0 {
					if ok, _, _ := recipCap.Admit("uid-o", spend); !ok {
						t.Fatalf("pre-spend %d refused", spend)
					}
				}
				pub := &capturingPublisher{}
				em := notifications.NewPubSubEmitter(pub, reg, log).WithRecipientCap(recipCap)
				uids := make([]string, n)
				for i := range uids {
					uids[i] = fmt.Sprintf("p%02d", i)
				}
				beaconNotifier{slot: &emitterSlot{em: em}}.Cancelled(context.Background(),
					beacons.CancelEvent{BeaconID: beaconNotifID, OrganiserUID: "uid-o", ParticipantUIDs: uids, At: time.Now()})
				var got []string
				for _, data := range pub.data {
					var wire struct {
						Type         string   `json:"type"`
						RecipientIDs []string `json:"recipientIds"`
					}
					if err := json.Unmarshal(data, &wire); err != nil {
						t.Fatal(err)
					}
					if wire.Type != "beacon_cancelled" {
						t.Errorf("type = %q", wire.Type)
					}
					got = append(got, wire.RecipientIDs...)
				}
				if strings.Join(got, ",") != strings.Join(uids, ",") {
					t.Errorf("delivered to %d of %d participants: %v", len(got), n, got)
				}
				// The organiser's budget is untouched: exactly `remaining` more social recipients are still admitted.
				if remaining > 0 {
					if ok, _, _ := recipCap.Admit("uid-o", remaining); !ok {
						t.Errorf("remaining budget %d was charged by the cancellation", remaining)
					}
				}
				if ok, _, _ := recipCap.Admit("uid-o", 1); ok {
					t.Errorf("budget exceeds the limit after the cancellation")
				}
			})
		}
	}
}
