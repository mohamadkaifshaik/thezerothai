package apiserver

import (
	"context"
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
	if e.Type != messageEventType || string(e.Type) != "message" || e.ActorID != "uid-a" || len(e.RecipientIDs) != 1 || e.RecipientIDs[0] != "uid-b" || !e.At.Equal(at) {
		t.Errorf("event = %+v", e)
	}
	messageNotifier{slot: &emitterSlot{}}.MessageSent(context.Background(), messaging.MessageEvent{ActorUID: "uid-a", RecipientUID: "uid-b"}) // no panic
}

type countingPublisher struct{ n int }

func (p *countingPublisher) Publish(context.Context, []byte) error { p.n++; return nil }

// TestMessageEvent_IsDroppedUntilW7_10: notifications has no `message` type yet (W7-10), so the real emitter drops the
// event before it publishes (0 cost, nothing for the fan-out to receive), and a fan-out that is handed one anyway drops
// it as invalid and counts it, the ack-and-drop of ADR-0027 D9 (an older revision meets an unknown type the same way).
func TestMessageEvent_IsDroppedUntilW7_10(t *testing.T) {
	if messageEventType.Valid() {
		t.Fatal("notifications now knows the `message` type: replace messageEventType with notifications.TypeMessage and fill Event.ConversationID (W7-10)")
	}
	pub := &countingPublisher{}
	em := notifications.NewPubSubEmitter(pub, flags.NewRegistry(flags.Spec{Name: notifications.FlagName, Mode: flags.On}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	messageNotifier{slot: &emitterSlot{em: em}}.MessageSent(context.Background(), messaging.MessageEvent{ActorUID: "uid-a", RecipientUID: "uid-b", ConversationID: "c", At: time.Now()})
	if pub.n != 0 {
		t.Errorf("published %d events for an unknown type, want 0", pub.n)
	}
	out, err := notifications.NewFanout(notifications.FanoutDeps{Log: slog.New(slog.NewTextHandler(io.Discard, nil))}).Deliver(context.Background(),
		notifications.Event{Type: messageEventType, ActorID: "uid-a", RecipientIDs: []string{"uid-b"}})
	if err != nil || out.Dropped != 1 || out.Created != 0 || out.Pushed != 0 {
		t.Errorf("fan-out outcome = %+v, %v; want one dropped event and no row or push", out, err)
	}
}
