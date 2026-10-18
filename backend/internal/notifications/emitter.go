package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
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

// RecipientCap is the per-actor daily cap on notification recipients (security audit N-1, CLAUDE.md rule 11). Every
// recipient costs the project at least 1 + R reads and 1 write in the fan-out handler (more with devices), paid
// from the shared free quota, so the actor is charged for them at the producer: 0 reads, in memory, before the
// publish. An event is admitted or dropped whole. The count is per Cloud Run instance lifetime and resets at IST
// midnight (ratelimit.DailyCap; the same accepted approximation as every in-memory cap here).
type RecipientCap struct {
	established, newAccount *ratelimit.DailyCap
	establishedLimit        int64
	newAccountLimit         int64
	isNew                   func(uid string) bool
}

// NewRecipientCap builds the cap: established accounts get `established` recipients per day, accounts for which
// isNew is true get `newAccount`. isNew must be a 0-read lookup (a cache peek); nil, or an answer of false for an
// unknown account, means established. Non-positive limits are clamped to 1 by the underlying cap.
func NewRecipientCap(established, newAccount int64, isNew func(uid string) bool) *RecipientCap {
	return &RecipientCap{
		established: ratelimit.NewDailyCap(established), newAccount: ratelimit.NewDailyCap(newAccount),
		establishedLimit: max(established, 1), newAccountLimit: max(newAccount, 1), isNew: isNew,
	}
}

// Admit charges n recipients to actor and reports whether the event may proceed. limit is the cap that applied
// and newAccount which tier it was. A nil cap admits everything.
func (c *RecipientCap) Admit(actor string, n int) (ok bool, limit int64, newAccount bool) {
	if c == nil {
		return true, 0, false
	}
	if c.isNew != nil && c.isNew(actor) {
		return c.newAccount.AllowN(actor, int64(n)), c.newAccountLimit, true
	}
	return c.established.AllowN(actor, int64(n)), c.establishedLimit, false
}

// admit applies the cap to an event that survived prepare and logs a drop with its own message so an abuse spike
// is queryable (jsonPayload.message="notification_fanout_capped"). It never logs the raw uid.
func admit(ctx context.Context, log *slog.Logger, c *RecipientCap, ev Event) bool {
	ok, limit, isNew := c.Admit(ev.ActorID, len(ev.RecipientIDs))
	if !ok {
		log.WarnContext(ctx, "notification_fanout_capped", "type", string(ev.Type), "actor_hash", logger.HashUID(ev.ActorID),
			"recipients", len(ev.RecipientIDs), "limit_per_day", limit, "new_account", isNew)
	}
	return ok
}

// PubSubEmitter publishes events on the notifications-fanout topic (production wiring).
type PubSubEmitter struct {
	pub      Publisher
	flags    FlagChecker
	log      *slog.Logger
	now      func() time.Time
	recipCap *RecipientCap
}

// NewPubSubEmitter builds the emitter. A nil logger uses slog.Default().
func NewPubSubEmitter(pub Publisher, fl FlagChecker, log *slog.Logger) *PubSubEmitter {
	if log == nil {
		log = slog.Default()
	}
	return &PubSubEmitter{pub: pub, flags: fl, log: log, now: time.Now}
}

// WithRecipientCap sets the per-actor daily recipient cap (nil = unlimited) and returns e.
func (e *PubSubEmitter) WithRecipientCap(c *RecipientCap) *PubSubEmitter {
	e.recipCap = c
	return e
}

var _ Emitter = (*PubSubEmitter)(nil)

// Emit implements Emitter. Reads 0, writes 0, one Pub/Sub publish when there is at least one eligible recipient
// and the actor is under the daily recipient cap (N-1; an over-cap event is dropped and logged, nothing published).
// A failed publish is logged and returned, never fatal to the producer (ADR-0017 D2).
func (e *PubSubEmitter) Emit(ctx context.Context, ev Event) error {
	ev, ok := prepare(ev, e.flags, e.now())
	if !ok || !admit(ctx, e.log, e.recipCap, ev) {
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
	fanout   *Fanout
	flags    FlagChecker
	log      *slog.Logger
	now      func() time.Time
	sem      chan struct{}
	wg       sync.WaitGroup
	recipCap *RecipientCap
}

// NewInlineEmitter builds the local-dev emitter.
func NewInlineEmitter(f *Fanout, fl FlagChecker, log *slog.Logger) *InlineEmitter {
	if log == nil {
		log = slog.Default()
	}
	return &InlineEmitter{fanout: f, flags: fl, log: log, now: time.Now, sem: make(chan struct{}, maxInlineDeliveries)}
}

// WithRecipientCap sets the per-actor daily recipient cap (nil = unlimited) and returns e.
func (e *InlineEmitter) WithRecipientCap(c *RecipientCap) *InlineEmitter {
	e.recipCap = c
	return e
}

// Wait blocks until every in-flight inline delivery finished (tests and graceful shutdown).
func (e *InlineEmitter) Wait() { e.wg.Wait() }

var _ Emitter = (*InlineEmitter)(nil)

// Emit implements Emitter.
func (e *InlineEmitter) Emit(ctx context.Context, ev Event) error {
	ev, ok := prepare(ev, e.flags, e.now())
	if !ok || !admit(ctx, e.log, e.recipCap, ev) {
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
