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
