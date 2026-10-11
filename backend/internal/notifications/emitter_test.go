package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestPrepare(t *testing.T) {
	tests := []struct {
		name  string
		ev    Event
		flags FlagChecker
		want  []string // recipients; nil = nothing to send
	}{
		{"plain follow", Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"b"}}, allFlags{}, []string{"b"}},
		{"self dropped", Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"a"}}, allFlags{}, nil},
		{"duplicates and empties dropped", Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"b", "", "b"}}, allFlags{}, []string{"b"}},
		{"flag off for some recipients", Event{Type: TypeMention, ActorID: "a", PostID: postA, RecipientIDs: []string{"b", "c"}}, fakeFlags{"c": true}, []string{"c"}},
		{"flag off for everyone", Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"b"}}, fakeFlags{}, nil},
		{"nil flag checker means on", Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"b"}}, nil, []string{"b"}},
		{"capped at 10", Event{Type: TypeMention, ActorID: "a", PostID: postA, RecipientIDs: strings.Split("b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12", ",")}, allFlags{},
			strings.Split("b1,b2,b3,b4,b5,b6,b7,b8,b9,b10", ",")},
		{"post required for mention", Event{Type: TypeMention, ActorID: "a", RecipientIDs: []string{"b"}}, allFlags{}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := prepare(tt.ev, tt.flags, t0)
			if ok != (tt.want != nil) {
				t.Fatalf("ok = %v, want %v", ok, tt.want != nil)
			}
			if ok && strings.Join(got.RecipientIDs, ",") != strings.Join(tt.want, ",") {
				t.Errorf("recipients = %v, want %v", got.RecipientIDs, tt.want)
			}
			if ok && !got.At.Equal(t0) && tt.ev.At.IsZero() {
				t.Errorf("At = %v, want the emitter clock", got.At)
			}
		})
	}
}

func TestPubSubEmitter(t *testing.T) {
	t.Run("publishes one compact message", func(t *testing.T) {
		pub := &fakePublisher{}
		em := NewPubSubEmitter(pub, allFlags{}, nil)
		em.now = func() time.Time { return t0 }
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob", "carol"}, PostID: postA}))
		if len(pub.data) != 1 {
			t.Fatalf("publishes = %d", len(pub.data))
		}
		if len(pub.data[0]) > 400 {
			t.Errorf("message is %d bytes, want < 400", len(pub.data[0]))
		}
		var m wireEvent
		mustNoErr(t, json.Unmarshal(pub.data[0], &m))
		if m.V != eventVersion || m.Type != TypeMention || m.ActorID != "alice" || len(m.RecipientIDs) != 2 || m.PostID != postA || m.AtMillis != t0.UnixMilli() {
			t.Errorf("message = %+v", m)
		}
		if strings.Contains(string(pub.data[0]), "text") {
			t.Errorf("the event must carry no post text: %s", pub.data[0])
		}
	})
	t.Run("nothing eligible publishes nothing", func(t *testing.T) {
		pub := &fakePublisher{}
		em := NewPubSubEmitter(pub, fakeFlags{}, nil)
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}))
		if len(pub.data) != 0 {
			t.Errorf("publishes = %d, want 0 (flag off: 0 cost)", len(pub.data))
		}
	})
	t.Run("a publish failure is logged and returned", func(t *testing.T) {
		var buf bytes.Buffer
		em := NewPubSubEmitter(&fakePublisher{err: errBoom}, allFlags{}, slog.New(slog.NewJSONHandler(&buf, nil)))
		err := em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}})
		if !errors.Is(err, errBoom) {
			t.Fatalf("err = %v", err)
		}
		if !strings.Contains(buf.String(), "notification_publish_failed") || strings.Contains(buf.String(), `"alice"`) {
			t.Errorf("log = %s (want the failure line, with a hashed actor)", buf.String())
		}
	})
}

func TestInlineEmitter(t *testing.T) {
	t.Run("delivers in process", func(t *testing.T) {
		r := newRig(t, nil)
		em := NewInlineEmitter(r.f, allFlags{}, nil)
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}))
		em.Wait()
		if _, ok := r.repo.rows["bob"]["follow_alice"]; !ok {
			t.Fatalf("rows = %+v", r.repo.rows)
		}
	})
	t.Run("work is bounded: a full emitter drops instead of spawning", func(t *testing.T) {
		r := newRig(t, nil)
		var buf bytes.Buffer
		em := NewInlineEmitter(r.f, allFlags{}, slog.New(slog.NewJSONHandler(&buf, nil)))
		for i := 0; i < maxInlineDeliveries; i++ {
			em.sem <- struct{}{}
		}
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}))
		em.Wait()
		if len(r.repo.rows) != 0 || !strings.Contains(buf.String(), "notification_inline_dropped") {
			t.Errorf("rows = %v log = %s", r.repo.rows, buf.String())
		}
	})
}

func TestNopEmitter(t *testing.T) {
	if err := (NopEmitter{}).Emit(context.Background(), Event{}); err != nil {
		t.Fatal(err)
	}
}

func TestType(t *testing.T) {
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote} {
		if !ty.Valid() {
			t.Errorf("%s not valid", ty)
		}
		if got, want := ty.needsPost(), ty != TypeFollow; got != want {
			t.Errorf("%s needsPost = %v", ty, got)
		}
	}
	if Type("").Valid() || Type("poke").Valid() {
		t.Error("unknown types must be invalid")
	}
}
