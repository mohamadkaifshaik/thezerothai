package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// publishTimeout bounds the producer-side publish so a slow Pub/Sub can never stall a follow or a post.
const publishTimeout = 3 * time.Second

// prepare applies the producer-side filters (ADR-0017 D2, D7): drop self-actions and recipients the flag is off
// for. ok=false means there is nothing to send (0 cost).
func prepare(e Event, fl FlagChecker, now time.Time) (Event, bool) {
	out := e
	out.RecipientIDs = make([]string, 0, len(e.RecipientIDs))
	seen := map[string]bool{}
	for _, r := range e.RecipientIDs {
		if r == "" || r == e.ActorID || seen[r] {
			continue
		}
		seen[r] = true
		if fl != nil && !fl.Enabled(r, FlagName) {
			continue
		}
		out.RecipientIDs = append(out.RecipientIDs, r)
	}
	if len(out.RecipientIDs) > MaxRecipientsPerEvent {
		out.RecipientIDs = out.RecipientIDs[:MaxRecipientsPerEvent]
	}
	if out.At.IsZero() {
		out.At = now
	}
	return out, len(out.RecipientIDs) > 0 && validateEvent(out) == ""
}

// PubSubEmitter publishes events on the notifications-fanout topic (production wiring).
type PubSubEmitter struct {
	pub   Publisher
	flags FlagChecker
	log   *slog.Logger
	now   func() time.Time
}

// NewPubSubEmitter builds the emitter. A nil logger uses slog.Default().
func NewPubSubEmitter(pub Publisher, fl FlagChecker, log *slog.Logger) *PubSubEmitter {
	if log == nil {
		log = slog.Default()
	}
	return &PubSubEmitter{pub: pub, flags: fl, log: log, now: time.Now}
}

var _ Emitter = (*PubSubEmitter)(nil)

// Emit implements Emitter. Reads 0, writes 0, one Pub/Sub publish when there is at least one eligible recipient.
// A failed publish is logged and returned, never fatal to the producer (ADR-0017 D2).
func (e *PubSubEmitter) Emit(ctx context.Context, ev Event) error {
	ev, ok := prepare(ev, e.flags, e.now())
	if !ok {
		return nil
	}
	data, err := encodeEvent(ev)
	if err != nil {
		return fmt.Errorf("notifications: encode event: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()
	if err := e.pub.Publish(ctx, data); err != nil {
		e.log.WarnContext(ctx, "notification_publish_failed", "type", string(ev.Type), "actor_hash", logger.HashUID(ev.ActorID), "err", err)
		return fmt.Errorf("notifications: publish: %w", err)
	}
	return nil
}

// maxInlineDeliveries bounds the goroutines InlineEmitter runs at once; further events are dropped (local dev only).
const maxInlineDeliveries = 8

// InlineEmitter delivers in-process on a bounded goroutine, for local dev and emulator tests where no Pub/Sub push
// subscription exists. It runs work after the response, which Cloud Run would throttle: config.Load refuses it
// outside ENV=local.
type InlineEmitter struct {
	fanout *Fanout
	flags  FlagChecker
	log    *slog.Logger
	now    func() time.Time
	sem    chan struct{}
	wg     sync.WaitGroup
}

// NewInlineEmitter builds the local-dev emitter.
func NewInlineEmitter(f *Fanout, fl FlagChecker, log *slog.Logger) *InlineEmitter {
	if log == nil {
		log = slog.Default()
	}
	return &InlineEmitter{fanout: f, flags: fl, log: log, now: time.Now, sem: make(chan struct{}, maxInlineDeliveries)}
}

// Wait blocks until every in-flight inline delivery finished (tests and graceful shutdown).
func (e *InlineEmitter) Wait() { e.wg.Wait() }

var _ Emitter = (*InlineEmitter)(nil)

// Emit implements Emitter.
func (e *InlineEmitter) Emit(ctx context.Context, ev Event) error {
	ev, ok := prepare(ev, e.flags, e.now())
	if !ok {
		return nil
	}
	select {
	case e.sem <- struct{}{}:
	default:
		e.log.WarnContext(ctx, "notification_inline_dropped", "type", string(ev.Type), "reason", "busy")
		return nil
	}
	bg := context.WithoutCancel(ctx)
	e.wg.Add(1)
	go func() {
		defer e.wg.Done()
		defer func() { <-e.sem }()
		bg, cancel := context.WithTimeout(bg, handlerBudget)
		defer cancel()
		if _, err := e.fanout.Deliver(bg, ev); err != nil {
			e.log.WarnContext(bg, "notification_inline_delivery_failed", "type", string(ev.Type), "err", logger.RedactErr(err, append([]string{ev.ActorID}, ev.RecipientIDs...)...))
		}
	}()
	return nil
}

// NopEmitter drops every event (flag wiring tests, and the zero value of an unset seam).
type NopEmitter struct{}

// Emit implements Emitter.
func (NopEmitter) Emit(context.Context, Event) error { return nil }

var _ Emitter = NopEmitter{}
