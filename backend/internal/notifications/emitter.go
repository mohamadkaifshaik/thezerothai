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

// prepare applies the producer-side filters: drop self-actions and recipients the flag is off
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
		if !recipientFlagsOn(fl, r, e.Type) {
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

// recipientFlagsOn reports whether uid may receive an event of type t: `notifications` for every type, and also
// `messaging` for the push-only message type. A nil checker allows everything (tests).
func recipientFlagsOn(fl FlagChecker, uid string, t Type) bool {
	if fl == nil {
		return true
	}
	if !fl.Enabled(uid, FlagName) {
		return false
	}
	return t != TypeMessage || fl.Enabled(uid, MessagingFlagName)
}

// RecipientCap is the per-actor daily cap on notification recipients (security audit N-1). Every
// recipient makes the fan-out handler read and write documents (more with devices), so the actor is limited at the
// producer, in memory and before the publish. An event is admitted or dropped whole. The count is per Cloud Run instance lifetime and resets at IST
// midnight (ratelimit.DailyCap; the same accepted approximation as every in-memory cap here).
type RecipientCap struct {
	established, newAccount *ratelimit.DailyCap
	establishedLimit        int64
	newAccountLimit         int64
	isNew                   func(uid string) bool
}

// NewRecipientCap builds the cap: established accounts get `established` recipients per day, accounts for which
// isNew is true get `newAccount`. isNew must be a 0-read lookup (a cache peek); nil, or an answer of false for an
// unknown account, means established. A non-positive limit returns nil (no cap), like NewPushLimiter: config.Load
// rejects it in deployed builds, and a hand-built zero Config must not silently allow one recipient a day.
func NewRecipientCap(established, newAccount int64, isNew func(uid string) bool) *RecipientCap {
	if established <= 0 || newAccount <= 0 {
		return nil
	}
	return &RecipientCap{
		established: ratelimit.NewDailyCap(established), newAccount: ratelimit.NewDailyCap(newAccount),
		establishedLimit: established, newAccountLimit: newAccount, isNew: isNew,
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

// capExempt reports whether events of type t bypass the per-actor social recipient cap and are not charged to it
// (B07). TypeBeaconCancelled: a safety notice sent once per cancelled beacon, only to its accepted participants,
// so its recipients are bounded by the beacon's capacity (beacons.Limits.MaxOpenSpots) and by the beacon create
// limits rather than by the organiser's social reach. Charging it all-or-nothing per 10-recipient chunk silently
// dropped whole chunks for an organiser with less than a chunk of budget left. TypeBeaconUpdated (F28) for the same
// reasons: the same bounded audience, and a dropped "the time changed" notice leaves people at the wrong time; its
// volume is bounded by the beacons write rate limit (RATE_LIMIT_BEACONS_WRITE_PER_MIN) and the edit-before-start rule.
func capExempt(t Type) bool {
	return t == TypeBeaconCancelled || t == TypeBeaconUpdated
}

// admit applies the cap to an event that survived prepare and logs a drop with its own message so an abuse spike
// is queryable (jsonPayload.message="notification_fanout_capped"). It never logs the raw uid. A capExempt type is
// admitted without being counted.
func admit(ctx context.Context, log *slog.Logger, c *RecipientCap, ev Event) bool {
	if capExempt(ev.Type) {
		return true
	}
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

// Emit implements Emitter. It touches no Firestore document and makes one Pub/Sub publish when there is at least one eligible recipient
// and the actor is under the daily recipient cap (N-1; an over-cap event is dropped and logged, nothing published).
// A failed publish is logged and returned, never fatal to the producer.
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
	// The delivery is its own unit of work (a push request in production), so the producer's cancellation must not end it.
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
