// Package outbox makes "do X after this commit" durable. A producer stages a work item in the SAME batch or transaction as
// the change that needs the follow-up (so the item exists if and only if the change committed), tries the follow-up inline
// after the commit, and calls Done when it succeeded. Anything left over (a lost publish, a crash between commit and
// publish, a failed Done) is picked up by Sweep, which a cron route runs, and re-run with exponential backoff until it
// succeeds or the item's TTL (expireAt) removes it.
//
// Collection `outbox/{kind}:{key}`, owned by this package (like idempotency and quotas):
//
//	kind, key       the item's identity; the doc id is deterministic, so a retried producer overwrites, never duplicates
//	uid             the user the item is about (right-to-delete: PurgeUser deletes by it)
//	payload         opaque bytes for the kind's Handler (at most MaxPayloadBytes)
//	attempts        sweep attempts so far (the inline attempt is not counted)
//	nextAttemptAt   when Sweep may run it next; Stage sets now + InitialDelay so the inline attempt goes first
//	createdAt       when it was staged
//	expireAt        createdAt + TTL: the Firestore TTL policy's backstop (infra/terraform/modules/firestore)
//
// The due query is `nextAttemptAt <= now ORDER BY nextAttemptAt LIMIT BatchSize` and PurgeUser's is `uid == ?`: both use
// single-field indexes only, so the collection needs no composite index. Never add a kind filter to the due query.
//
// Delivery is at least once: a Handler MUST be idempotent (two overlapping sweeps, or the inline attempt and a sweep,
// can both run one item). Sweep claims an item before running it (attempts+1 and the next backoff, with a LastUpdateTime
// precondition) and removes it afterwards only if nobody re-staged it in between.
//
// The API, for producers:
//
//	Stage(b, e)   in the producer's batch/transaction (no reads, so it is legal after a transaction's reads)
//	Done(ctx, e)  after the inline follow-up succeeded
//	RunNow(ctx, e) re-run a still-present item at once (a replayed request that wants its follow-up retried)
//
// and for wiring: Handle(kind, h) at startup, Sweep(ctx) from a cron route, PurgeUser from the account-deletion step.
package outbox

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Collection is the outbox's Firestore collection.
const Collection = "outbox"

// Defaults of Config. Backoff after the n-th failed sweep attempt is min(BaseBackoff * 2^(n-1), MaxBackoff): 1, 2, 4 ...
// 128 min (attempt 8, about 4 h 15 min after the first sweep attempt, is where StuckAfter reports it), then 4 h 16 min,
// then every 6 h until the 30-day TTL.
const (
	DefaultInitialDelay = 2 * time.Minute
	DefaultBaseBackoff  = time.Minute
	DefaultMaxBackoff   = 6 * time.Hour
	DefaultTTL          = 30 * 24 * time.Hour
	DefaultBatchSize    = 100
	DefaultStuckAfter   = 8
)

// MaxPayloadBytes bounds an item's payload (it is a pointer to work, not the work's data).
const MaxPayloadBytes = 8 << 10

// ErrInvalidEntry is wrapped by every Entry validation error.
var ErrInvalidEntry = errors.New("outbox: invalid entry")

var (
	kindPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	keyPattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
)

// Entry is one work item as a producer describes it.
type Entry struct {
	// Kind selects the Handler: [a-z][a-z0-9_]{0,31}, for example "post_delete".
	Kind string
	// Key is unique within Kind and deterministic (the post id, the beacon id): [A-Za-z0-9_-]{1,128}.
	Key string
	// UID is the user the item is about; PurgeUser deletes the user's items. Required.
	UID string
	// Payload is handed to the Handler unchanged (at most MaxPayloadBytes).
	Payload []byte
}

// ID is the document id, kind ":" key. ':' is legal in neither part, so two (kind, key) pairs never share an id.
func (e Entry) ID() string { return e.Kind + ":" + e.Key }

// Validate reports whether e can be staged. Call it before building a batch whose stage func cannot return an error.
func (e Entry) Validate() error {
	switch {
	case !kindPattern.MatchString(e.Kind):
		return fmt.Errorf("%w: kind must match %s", ErrInvalidEntry, kindPattern)
	case !keyPattern.MatchString(e.Key):
		return fmt.Errorf("%w: key must match %s", ErrInvalidEntry, keyPattern)
	case e.UID == "":
		return fmt.Errorf("%w: uid is required", ErrInvalidEntry)
	case len(e.Payload) > MaxPayloadBytes:
		return fmt.Errorf("%w: payload is %d bytes, max %d", ErrInvalidEntry, len(e.Payload), MaxPayloadBytes)
	}
	return nil
}

// Item is a stored entry as a Handler sees it.
type Item struct {
	Entry
	// Attempts counts sweep attempts including the current one (1 on the first sweep run).
	Attempts      int
	NextAttemptAt time.Time
	CreatedAt     time.Time

	id         string
	updateTime time.Time // the claim precondition
}

// Handler runs one item. A nil error removes the item; an error keeps it for the next backoff step. It must be idempotent.
// An item whose payload can never succeed (malformed) should be logged and answered with nil, or it retries until its TTL.
type Handler func(ctx context.Context, it Item) error

// Config tunes an Outbox. Zero fields take the Default* values; Now nil means time.Now.
type Config struct {
	InitialDelay time.Duration
	BaseBackoff  time.Duration
	MaxBackoff   time.Duration
	TTL          time.Duration
	BatchSize    int
	StuckAfter   int
	Now          func() time.Time
	// OnStuck, when set, is called once per item whose failed attempt crosses StuckAfter, on both the Sweep and the
	// RunNow path (Sweep also lists them in Result.StuckItems). It must not block.
	OnStuck func(ctx context.Context, s StuckItem)
}

func (c Config) withDefaults() Config {
	if c.InitialDelay <= 0 {
		c.InitialDelay = DefaultInitialDelay
	}
	if c.BaseBackoff <= 0 {
		c.BaseBackoff = DefaultBaseBackoff
	}
	if c.MaxBackoff <= 0 {
		c.MaxBackoff = DefaultMaxBackoff
	}
	if c.TTL <= 0 {
		c.TTL = DefaultTTL
	}
	if c.BatchSize <= 0 {
		c.BatchSize = DefaultBatchSize
	}
	if c.StuckAfter <= 0 {
		c.StuckAfter = DefaultStuckAfter
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	return c
}

// itemDoc is the stored shape.
type itemDoc struct {
	Kind          string    `firestore:"kind"`
	Key           string    `firestore:"key"`
	UID           string    `firestore:"uid"`
	Payload       []byte    `firestore:"payload"`
	Attempts      int       `firestore:"attempts"`
	NextAttemptAt time.Time `firestore:"nextAttemptAt"`
	CreatedAt     time.Time `firestore:"createdAt"`
	ExpireAt      time.Time `firestore:"expireAt"`
}

func (d itemDoc) item(id string, ut time.Time) Item {
	return Item{
		Entry:    Entry{Kind: d.Kind, Key: d.Key, UID: d.UID, Payload: d.Payload},
		Attempts: d.Attempts, NextAttemptAt: d.NextAttemptAt, CreatedAt: d.CreatedAt,
		id: id, updateTime: ut,
	}
}

// backend is the storage seam (firestoreBackend in production, an in-memory fake in unit tests).
type backend interface {
	stage(b store.Batch, id string, d itemDoc)
	get(ctx context.Context, id string) (Item, bool, error)
	// due returns the decodable due items; undecodable ones are pushed back and counted in dueStats.
	due(ctx context.Context, now time.Time, limit int) ([]Item, dueStats, error)
	// claim sets attempts and nextAttemptAt if the doc is unchanged since it.updateTime; ok=false when it changed or is gone.
	claim(ctx context.Context, it Item, attempts int, next time.Time) (ut time.Time, ok bool, err error)
	// remove deletes id (only if unchanged since *ifUpdated when non-nil); a missing or changed doc is not an error.
	remove(ctx context.Context, id string, ifUpdated *time.Time) error
	// purgeUID deletes up to limit items of uid and returns how many it deleted.
	purgeUID(ctx context.Context, uid string, limit int) (int, error)
}

// dueStats reports the due-query docs that were not returned: undecodable ones, and failed push-backs of them. The causes
// are the first of each, already free of document paths (Firestore's own text), for Result.Errors.
type dueStats struct {
	undecodable    int
	decodeCause    string
	pushBackFailed int
	pushBackCause  string
}

// Outbox stages, sweeps and erases work items. Build one per process with New; register handlers before serving.
type Outbox struct {
	b        backend
	cfg      Config
	handlers map[string]Handler
}

// New builds the Firestore-backed outbox. It does no I/O.
func New(client *firestore.Client, cfg Config) *Outbox {
	return newOutbox(firestoreBackend{client: client}, cfg)
}

func newOutbox(b backend, cfg Config) *Outbox {
	return &Outbox{b: b, cfg: cfg.withDefaults(), handlers: map[string]Handler{}}
}

// Handle registers h for kind. Startup only (not safe concurrently with Sweep); a kind has one handler.
func (o *Outbox) Handle(kind string, h Handler) error {
	if !kindPattern.MatchString(kind) {
		return fmt.Errorf("%w: kind %q", ErrInvalidEntry, kind)
	}
	if h == nil {
		return fmt.Errorf("outbox: nil handler for %s", kind)
	}
	if _, dup := o.handlers[kind]; dup {
		return fmt.Errorf("outbox: kind %s already has a handler", kind)
	}
	o.handlers[kind] = h
	return nil
}

// Stage adds e to b, the caller's batch or transaction (store.NewFirestoreBatch / NewFirestoreTxBatch). It reads nothing.
// The item overwrites any earlier one with the same id (attempts reset), so re-staging re-arms it. Its only error is
// ErrInvalidEntry.
func (o *Outbox) Stage(b store.Batch, e Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	now := o.cfg.Now()
	o.b.stage(b, e.ID(), itemDoc{
		Kind: e.Kind, Key: e.Key, UID: e.UID, Payload: e.Payload,
		NextAttemptAt: now.Add(o.cfg.InitialDelay), CreatedAt: now, ExpireAt: now.Add(o.cfg.TTL),
	})
	return nil
}

// Done removes e's item after the producer's inline follow-up succeeded. A missing item is not an error. A failure only
// means a sweep will re-run the (idempotent) follow-up, so callers log it and move on.
func (o *Outbox) Done(ctx context.Context, e Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	if err := o.b.remove(ctx, e.ID(), nil); err != nil {
		return fmt.Errorf("outbox: done %s: %w", e.Kind, err)
	}
	return nil
}

// backoff is the delay after the attempts-th failed attempt.
func (o *Outbox) backoff(attempts int) time.Duration {
	d := o.cfg.BaseBackoff
	for i := 1; i < attempts; i++ {
		d *= 2
		if d >= o.cfg.MaxBackoff {
			return o.cfg.MaxBackoff
		}
	}
	return min(d, o.cfg.MaxBackoff)
}
