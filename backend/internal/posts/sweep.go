// sweep.go holds the types of the scheduled-post publish sweep (ADR-0021 "Sweep", CMP-D4): the storage seam, the
// limits and collaborators the wiring supplies, the Sweeper interface the cron route calls, and the per-run counters.
// The orchestration is service_sweep.go, the per-item rules service_sweep_item.go, the HTTP route sweep_http.go and the
// publish transaction repo_publish_scheduled.go.
package posts

import (
	"context"
	"errors"
	"log/slog"
	"time"
)

// Sweep outcomes (the `outcome` field of the scheduled_sweep line).
const (
	// SweepOK: the run queried the due items and processed them (some may have failed individually).
	SweepOK = "ok"
	// SweepFlagOff: FEATURE_SCHEDULED_POSTS or FEATURE_POSTS is switched off for everyone (the kill switch). 0 reads.
	SweepFlagOff = "flag_off"
	// SweepDegraded: DEGRADED_MODE=readonly. 0 reads.
	SweepDegraded = "degraded"
	// SweepError: a due query page failed. Page 1: Sweep returns the error, nothing was processed and the route answers 500
	// (Cloud Scheduler retries, which is harmless). A later page: the earlier pages were processed, Sweep returns a nil
	// error with SweepResult.LaterPageErr set, and the route answers 204 and reports the error (a retry seconds later would
	// burn the attempt ladder of items that failed transiently).
	SweepError = "error"
)

// sweepOp names the route in Error Reporting entries (the rpc field).
const sweepOp = "cron/publish-scheduled"

const (
	// sweepRunDeadline is the whole run's budget (ADR-0021 D1: a 25 s context deadline).
	sweepRunDeadline = 25 * time.Second
	// sweepMinRemaining is the least time that must remain to fetch another page or to start another item: one item's
	// publish transaction has its own 5 s bound (createTxTimeout), plus the post-commit effects.
	sweepMinRemaining = 6 * time.Second
	// sweepBookkeepingTimeout bounds a write outside the publish transaction (attempts++, FAILED, CANCELLED) on a context
	// detached from the run's deadline, so an item that hit the 25 s limit can still be counted (review M-2).
	sweepBookkeepingTimeout = 3 * time.Second
)

// SweepRepo is the sweep's storage seam. *FirestoreRepo implements it; the sweep depends on this narrow interface (not
// on ScheduledRepo) so its fakes stay small and a test can wrap the real repository to inject a fault between two steps.
type SweepRepo interface {
	// DueScheduled is the collection-group query of PENDING items due at now (path-shape filtered). Reads len(items),
	// minimum 1, per page.
	DueScheduled(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error)
	// TransitionScheduled moves an item to a terminal state, conditional on it being unchanged since ref.UpdateTime
	// (applied=false is a quiet no-op). Reads 0, writes 1.
	TransitionScheduled(ctx context.Context, ref ScheduledRef, t ScheduledTransition, now time.Time, ttl time.Duration) (next ScheduledRef, applied bool, err error)
	// BumpScheduledAttempts counts one transient failure under the same precondition. Reads 0, writes 1.
	BumpScheduledAttempts(ctx context.Context, ref ScheduledRef, now time.Time) (next ScheduledRef, applied bool, err error)
	// PublishScheduled is the publish transaction (repo_publish_scheduled.go).
	PublishScheduled(ctx context.Context, p PublishParams) (PublishResult, error)
}

var _ SweepRepo = (*FirestoreRepo)(nil)

// SweepLimits are the plain-value SCHEDULED_* limits of the sweep, filled by the wiring from config.Scheduled (posts
// does not import config). PerAuthorPerRun, Limit (also capped at MaxLimit), MaxPages, Concurrency and MaxAttempts are
// clamped to at least 1 when used and a zero AuthorReadsWarn disables that warning, but MaxLateness and TerminalTTL are NOT
// clamped: a zero MaxLateness expires every due item and a zero TerminalTTL makes every terminal transition fail its
// validation. config.loadScheduled enforces the ranges of every SCHEDULED_* key at startup, so only a hand-built SweepLimits
// can get that wrong.
type SweepLimits struct {
	// PerAuthorPerRun is the most items of one author a run processes (SCHEDULED_PER_AUTHOR_PER_RUN, review L-3); the
	// rest are deferred to the next run without a write.
	PerAuthorPerRun int
	// AuthorReadsWarn is the reads one author's items may spend in a run before a scheduled_author_reads warning
	// (SCHEDULED_AUTHOR_READS_WARN, review L-4).
	AuthorReadsWarn int
	// Limit is the due query's Limit (SCHEDULED_SWEEP_LIMIT, at most MaxLimit), MaxPages the pages per run
	// (SCHEDULED_SWEEP_MAX_PAGES) and Concurrency the author workers at once (SCHEDULED_SWEEP_CONCURRENCY).
	Limit, MaxPages, Concurrency int
	// MaxLateness is how overdue an item may be before it is FAILED EXPIRED (SCHEDULED_MAX_LATENESS).
	MaxLateness time.Duration
	// MaxAttempts is the transient failures after which an item is FAILED INTERNAL (SCHEDULED_MAX_ATTEMPTS).
	MaxAttempts int
	// TerminalTTL is SCHEDULED_TERMINAL_TTL: how long a terminal doc is kept before the Firestore TTL deletes it.
	TerminalTTL time.Duration
}

// SweepDeps enables the publish sweep (Deps.Sweep). A zero value leaves Sweep returning an error; the wiring always
// supplies it, so only a unit test of something else omits it.
type SweepDeps struct {
	Repo   SweepRepo
	Limits SweepLimits
	// Flags tells the kill switch (a flag off for everyone) from a rollout (*flags.Registry). Nil fails closed: the
	// sweep is a no-op. Besides the two scheduling flags it is asked once per run whether FEATURE_MEDIA is globally off,
	// which holds the items that carry images (SweepResult.HeldMedia).
	Flags GloballyOffChecker
	// ReadOnly is DEGRADED_MODE=readonly: the sweep is a no-op with 0 reads.
	ReadOnly bool
	// Log carries the per-item and per-author lines and the Error Reporting entries (nil: discarded).
	Log *slog.Logger
	// RecordAuthorAge (optional) is told the author's createdAt, from the publish transaction's own read (0 reads), right
	// before the post event is emitted. The wiring points it at the memo the notification recipient cap consults: a post
	// published by a sweep has no authenticated request behind it, and the profile cache entry was just evicted, so
	// without this a first-day account would be charged to the ESTABLISHED recipient bucket.
	RecordAuthorAge func(uid string, createdAt time.Time)
}

var errNoSweepRepo = errors.New("posts: the publish sweep is not configured")

// SweepResult counts what one sweep run did. The buckets are not a partition of Due: Deferred items are only counted, and
// an item can land in two buckets because its outcome and its bookkeeping are counted separately (see Transient, Noop and
// WriteFailed). Published, Cancelled and the Failed reasons count items that really moved out of PENDING in this run.
type SweepResult struct {
	// Outcome is one of the Sweep* constants.
	Outcome string
	// Due is the number of valid due items the query returned (over all pages), before the per-author cap.
	Due int
	// Published, Cancelled and Failed (by reason) are items moved out of PENDING by this run. Failed includes EXPIRED.
	Published, Cancelled int
	Failed               map[ScheduledFailure]int
	// Transient counts items whose publish hit a transient error. The follow-up write is counted again where it ends up:
	// attempts++ applied (nowhere else), FAILED INTERNAL on the last attempt (also in Failed), the precondition lost (also
	// in Noop) or the write failed (also in WriteFailed).
	Transient int
	// Deferred counts items left PENDING without a write: over the per-author cap, or not started for lack of time.
	Deferred int
	// HeldMedia counts due items left PENDING, with no read and no write, because they carry images while FEATURE_MEDIA is
	// globally off (the kill switch; allowlist and percent are rollouts and hold nothing). They are in Due, not in Deferred,
	// and do not count toward the per-author cap. An item the expiry, UNSUPPORTED or INVALID_CONTENT check would retire is
	// retired as always, not held. Next run asks again, so they are re-read every run until the flag returns or they expire.
	HeldMedia int
	// Noop counts state writes that found the item already moved on (another run, a Cancel, the eraser): nothing was
	// written. The item can also be counted elsewhere: Published when the publish committed and a later panic's FAILED write
	// then lost its precondition, Transient when the attempts++ lost it.
	Noop int
	// WriteFailed counts state writes (a terminal transition or attempts++) that failed with an error: the item stays
	// as it was and is re-read next run. A failed attempts++ is also counted in Transient.
	WriteFailed int
	// SkippedBadPath and Undecodable are results the query returned that were not valid scheduled docs.
	SkippedBadPath, Undecodable int
	// MaxLateness is the largest now - publishAt among the due items.
	MaxLateness time.Duration
	// LaterPageErr is the (scrubbed) error of a due-query page that failed AFTER an earlier page was fetched; the run
	// processed what it had and Outcome is SweepError. Nil otherwise. A page-1 failure is Sweep's returned error instead.
	LaterPageErr error
}

// Expired is the items failed EXPIRED.
func (r SweepResult) Expired() int { return r.Failed[FailureExpired] }

// Sweeper is the publish sweep the cron route calls. The concrete service returned by New implements it (reached by
// type assertion in the wiring, like Scheduler), so Service and its fakes stay unchanged.
type Sweeper interface {
	// Sweep publishes the scheduled posts that are due (ADR-0021 "Sweep"). The error is non-nil only when the FIRST due
	// page failed (nothing was processed: the route answers 500 and Cloud Scheduler retries). An item that fails is counted
	// in the result, never returned. When a LATER page fails the earlier pages are processed and the failure comes back as
	// SweepResult.LaterPageErr with a nil error (the route answers 204: a retry would burn the items' attempt ladder).
	//
	// Firestore, worst case: flag off, readonly: 0 reads. Nothing due: 1 read. N due: N (<= SCHEDULED_SWEEP_LIMIT x
	// SCHEDULED_SWEEP_MAX_PAGES = 100; deferred, held (FEATURE_MEDIA globally off: 0 reads, 0 writes beyond the query) and
	// skipped items are re-read next run) + per item: publish 17 worst /
	// 3 typical reads and 4 writes + media; an expiry, UNSUPPORTED, INVALID_CONTENT, transient or panic outcome 0 reads
	// and 1 write (LastUpdateTime precondition); a failure inside the publish transaction 2 to 7 reads and 1 write.
	Sweep(ctx context.Context) (SweepResult, error)
}
