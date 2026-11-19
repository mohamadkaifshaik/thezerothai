package apiserver

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestMessageNotifier: a delivered message becomes one `message` event from the sender to the recipient, through the
// emitter slot; an empty slot drops it.
func TestMessageNotifier(t *testing.T) {
	at := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	rec := &recordingEmitter{}
	messageNotifier{slot: &emitterSlot{em: rec}}.MessageSent(context.Background(), messaging.MessageEvent{
		ActorUID: "uid-a", RecipientUID: "uid-b", ConversationID: "0123456789abcdef0123456789abcdef", At: at,
	})
	if len(rec.events) != 1 {
		t.Fatalf("events = %d, want 1", len(rec.events))
	}
	e := rec.events[0]
	if e.Type != notifications.TypeMessage || string(e.Type) != "message" || e.ConversationID != "0123456789abcdef0123456789abcdef" || e.ActorID != "uid-a" || len(e.RecipientIDs) != 1 || e.RecipientIDs[0] != "uid-b" || !e.At.Equal(at) {
		t.Errorf("event = %+v", e)
	}
	messageNotifier{slot: &emitterSlot{}}.MessageSent(context.Background(), messaging.MessageEvent{ActorUID: "uid-a", RecipientUID: "uid-b"}) // no panic
}

type capturingPublisher struct{ data [][]byte }

func (p *capturingPublisher) Publish(_ context.Context, b []byte) error {
	p.data = append(p.data, b)
	return nil
}

// TestMessageEvent_ReachesTheFanoutAsPushOnly: `message` is a valid notifications type now, so the
// real emitter publishes one event that names the conversation (and no post) when the recipient has both `notifications`
// and `messaging` on, and nothing when messaging is off. The flag name notifications checks is messaging's own.
func TestMessageEvent_ReachesTheFanoutAsPushOnly(t *testing.T) {
	if notifications.MessagingFlagName != messaging.FlagName {
		t.Fatalf("notifications.MessagingFlagName = %q, messaging.FlagName = %q", notifications.MessagingFlagName, messaging.FlagName)
	}
	const conv = "0123456789abcdef0123456789abcdef"
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	send := func(reg *flags.Registry) *capturingPublisher {
		pub := &capturingPublisher{}
		em := notifications.NewPubSubEmitter(pub, reg, log)
		messageNotifier{slot: &emitterSlot{em: em}}.MessageSent(context.Background(), messaging.MessageEvent{ActorUID: "uid-a", RecipientUID: "uid-b", ConversationID: conv, At: time.Now()})
		return pub
	}
	pub := send(flags.NewRegistry(flags.Spec{Name: notifications.FlagName, Mode: flags.On}, flags.Spec{Name: messaging.FlagName, Mode: flags.On}))
	if len(pub.data) != 1 {
		t.Fatalf("published %d events, want 1", len(pub.data))
	}
	var wire map[string]any
	if err := json.Unmarshal(pub.data[0], &wire); err != nil {
		t.Fatal(err)
	}
	if wire["v"] != float64(1) || wire["type"] != "message" || wire["conversationId"] != conv || wire["postId"] != nil {
		t.Errorf("wire event = %v", wire)
	}
	if pub := send(flags.NewRegistry(flags.Spec{Name: notifications.FlagName, Mode: flags.On}, flags.Spec{Name: messaging.FlagName, Mode: flags.Off})); len(pub.data) != 0 {
		t.Errorf("published %d events with messaging off, want 0", len(pub.data))
	}
	// A message event without a valid conversation id can never be delivered: dropped and acknowledged.
	out, err := notifications.NewFanout(notifications.FanoutDeps{Log: log}).Deliver(context.Background(),
		notifications.Event{Type: notifications.TypeMessage, ActorID: "uid-a", RecipientIDs: []string{"uid-b"}})
	if err != nil || out.Dropped != 1 || out.Created != 0 || out.Pushed != 0 {
		t.Errorf("fan-out outcome = %+v, %v; want one dropped event and no row or push", out, err)
	}
}

// stubDeviceDirectory answers every lookup from ids, or err.
type stubDeviceDirectory struct {
	ids  map[string][]string
	err  error
	asks []string
}

func (s *stubDeviceDirectory) ActiveDeviceIDs(_ context.Context, uid string) ([]string, error) {
	s.asks = append(s.asks, "active|"+uid)
	return s.ids[uid], s.err
}

func (s *stubDeviceDirectory) DeviceIDs(_ context.Context, uid string) ([]string, error) {
	s.asks = append(s.asks, "all|"+uid)
	return s.ids[uid], s.err
}

// TestLateKeyDevices: unbound, the mls_init device lookup fails (never "no devices"); bound, it asks the key directory's
// ACTIVE ids and passes its answer and its error through.
func TestLateKeyDevices(t *testing.T) {
	l := &lateKeyDevices{}
	if got, err := l.ActiveDeviceIDs(context.Background(), "uid-a"); !errors.Is(err, errKeyDevicesUnbound) || got != nil {
		t.Fatalf("unbound = %v, %v; want errKeyDevicesUnbound", got, err)
	}
	dir := &stubDeviceDirectory{ids: map[string][]string{"uid-a": {"device-aaaaaaaaaaaa"}}}
	l.dir = dir
	if got, err := l.ActiveDeviceIDs(context.Background(), "uid-a"); err != nil || len(got) != 1 || got[0] != "device-aaaaaaaaaaaa" {
		t.Fatalf("bound = %v, %v", got, err)
	}
	if len(dir.asks) != 1 || dir.asks[0] != "active|uid-a" {
		t.Fatalf("directory calls = %v, want one ActiveDeviceIDs", dir.asks)
	}
	boom := errors.New("boom")
	dir.err = boom
	if _, err := l.ActiveDeviceIDs(context.Background(), "uid-a"); !errors.Is(err, boom) {
		t.Fatalf("failure = %v, want it passed through", err)
	}
}

// TestLateKeyDevices_DeviceIDs: the ListWelcomes / AckWelcomes ownership lookup asks the directory's REGISTERED ids (active
// or not), never the active ones; unbound it fails (never "not one of your devices"); errors pass through.
func TestLateKeyDevices_DeviceIDs(t *testing.T) {
	l := &lateKeyDevices{}
	if got, err := l.DeviceIDs(context.Background(), "uid-a"); !errors.Is(err, errKeyDevicesUnbound) || got != nil {
		t.Fatalf("unbound = %v, %v; want errKeyDevicesUnbound", got, err)
	}
	dir := &stubDeviceDirectory{ids: map[string][]string{"uid-a": {"device-aaaaaaaaaaaa", "device-bbbbbbbbbbbb"}}}
	l.dir = dir
	if got, err := l.DeviceIDs(context.Background(), "uid-a"); err != nil || len(got) != 2 {
		t.Fatalf("bound = %v, %v", got, err)
	}
	if len(dir.asks) != 1 || dir.asks[0] != "all|uid-a" {
		t.Fatalf("directory calls = %v, want one DeviceIDs", dir.asks)
	}
	boom := errors.New("boom")
	dir.err = boom
	if _, err := l.DeviceIDs(context.Background(), "uid-a"); !errors.Is(err, boom) {
		t.Fatalf("failure = %v, want it passed through", err)
	}
}
