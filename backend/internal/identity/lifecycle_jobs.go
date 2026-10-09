// lifecycle_jobs.go is the job side of the account lifecycle (ADR-0011 D-A): the `/internal/pubsub/jobs` push
// handler, the self-chaining deletion orchestrator, and the daily-maintenance backstop. Nothing here is gated by
// FEATURE_ACCOUNT_LIFECYCLE or DEGRADED_MODE (Q8, Q9): turning the flag off can never strand a DELETING account.
//
// A delivery of {account_delete, uid, seq}:
//  1. reads users/{uid} fresh (the job-state read, 1 read) and applies IAM control C1 (DELETING + deletionRequestedAt);
//  2. dedupes on seq: seq == state.seq works; seq == state.seq-1 re-publishes state.seq (the state was saved but
//     the continuation may not have been published); anything else is dropped;
//  3. before 120 s after deletionRequestedAt it only disables the Auth user and answers 429 (gated nack);
//  4. otherwise runs steps for <= 20 s, saves the next state with an UpdateTime precondition (so of two
//     concurrent same-seq deliveries exactly one advances it), publishes seq+1 and acks. The last step deletes
//     users/{uid}, which is the final write, so a finished job leaves nothing to save.
package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"sync/atomic"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpush"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// The identity step's page sizes (rule 5: every query has a Limit): 50 exports docs and 500 private docs per
	// call, the latter being the batch bound of an ops path.
	identityExportsPage = 50
	identityPrivatePage = 500
	// saveRetries bounds the re-read-and-retry of a state save that lost its precondition to an unrelated write
	// on users/{uid} (for example another account's purge decrementing this one's counters).
	saveRetries = 3
	// backstopPage bounds each backstop query; stuckAfter is the no-progress age that triggers a re-publish and
	// exportFailAfter the PENDING age after which an export is given up.
	backstopPage = 50
	// backstopMaxPages bounds the cursor walk of one scan (L-6): 4 pages of 50.
	backstopMaxPages = 4
	stuckAfter       = time.Hour
	exportFailAfter  = 24 * time.Hour
	// backstopPublishers bounds concurrent re-publishes.
	backstopPublishers = 8
	// handlerBudget bounds a whole delivery (read + work + save + publish) inside Pub/Sub's 30 s ack deadline and
	// Cloud Run's 30 s request timeout: work gets at most workBudget+stepGrace (25 s) and never the last saveReserve
	// (5 s) of the handler deadline, which the save and publish keep.
	handlerBudget = 27 * time.Second
	// defaultRetryBackoff is the first full-jitter ceiling between retries of one failing step (doubled per retry).
	defaultRetryBackoff = 200 * time.Millisecond
)

// jobResult is what a delivery decided: the HTTP status Pub/Sub sees (2xx acks, anything else retries) and the
// fields of the one log line.
type jobResult struct {
	status  int
	outcome string
	job     string
	uid     string
	seq     int64
	step    string
	err     error
	// Observability (ADR-0011 T6, T7, T10): step calls and identity-owned deletions of a delete delivery; sections
	// and bytes of an export. Counts only, never ids.
	stepCalls, deletedDocs, deletedObjects int
	sections                               int
	bytes                                  int64
}

// jobStats is what the steps of one delivery add up, reported on its log line.
type jobStats struct{ calls, docs, objects int }

func ack(r jobResult, outcome string) jobResult {
	r.status, r.outcome = http.StatusNoContent, outcome
	return r
}

// retry nacks the delivery. Every error that leaves a job goes through here, so ScrubErr is applied once for all of
// them: the uid, third-party uids in Firestore document paths and edge ids, and export ids never reach a log line.
func retry(r jobResult, outcome string, err error) jobResult {
	r.status, r.outcome, r.err = http.StatusInternalServerError, outcome, logger.ScrubErr(err, r.uid)
	return r
}

// recoverPanic turns a panic in a job handler into a 500 (Pub/Sub or Scheduler retries) and an Error Reporting
// entry. Only the panic type is logged: its value could carry a uid.
func (l *Lifecycle) recoverPanic(op string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, l.projectID))
				mw.ReportError(ctx, l.log.With(logger.TraceAttrs(ctx)...), op, logger.ScrubErr(fmt.Errorf("panic of type %T", v)))
				w.WriteHeader(http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// JobsHandler is the `/internal/pubsub/jobs` push handler. Mount it behind the OIDC verifier.
func (l *Lifecycle) JobsHandler() http.Handler {
	return l.recoverPanic("jobs/panic", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, l.projectID))
		d, err := pubsubpush.ReadDelivery(w, r)
		if err != nil {
			// A body that is not a push envelope never becomes valid: ack it instead of feeding the DLQ.
			l.log.WarnContext(ctx, "job_dropped", append([]any{"reason", "malformed_envelope"}, logger.TraceAttrs(ctx)...)...)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		ctx, cancel := context.WithTimeout(ctx, handlerBudget)
		defer cancel()
		ctx, counter := budget.WithCounter(ctx)
		started := l.now()
		res := l.dispatch(ctx, d)
		l.logDelivery(ctx, res, d, counter, l.now().Sub(started))
		// No body: nothing about the job or the user is echoed back.
		w.WriteHeader(res.status)
	}))
}

func (l *Lifecycle) dispatch(ctx context.Context, d pubsubpush.Delivery) jobResult {
	var msg JobMessage
	if err := json.Unmarshal(d.Data, &msg); err != nil {
		return ack(jobResult{job: "unknown"}, "dropped:malformed_message")
	}
	switch msg.Kind {
	case JobKindAccountDelete:
		res := jobResult{job: "delete", seq: msg.Seq}
		if !ValidUserID(msg.UID) || msg.Seq < 0 {
			return ack(res, "dropped:invalid_message")
		}
		res.uid = msg.UID
		return l.runDelete(ctx, msg, res)
	case JobKindAccountExport:
		res := jobResult{job: "export"}
		if !exportIDPattern.MatchString(msg.ExportID) {
			return ack(res, "dropped:invalid_message")
		}
		return l.runExport(ctx, msg, res)
	default:
		return ack(jobResult{job: "unknown"}, "dropped:unknown_kind")
	}
}

// logDelivery writes the one line per delivery: account_job, step, seq, delivery_attempt, fs_reads/fs_writes/
// fs_deletes, outcome, uid_hash, elapsed_ms, plus step_calls/deleted_docs/deleted_objects (delete) or sections/bytes
// (export). Never a raw uid, an export id or a URL. A failing delivery is WARN, and ERROR (Error Reporting) from the
// attempt that would dead-letter it.
func (l *Lifecycle) logDelivery(ctx context.Context, res jobResult, d pubsubpush.Delivery, c *budget.Counter, elapsed time.Duration) {
	attrs := append([]any{
		"account_job", res.job, "step", res.step, "seq", res.seq, "delivery_attempt", d.Attempt,
		"fs_reads", c.Reads(), "fs_writes", c.Writes(), "fs_deletes", c.Deletes(),
		"outcome", res.outcome, "uid_hash", logger.HashUID(res.uid), "elapsed_ms", elapsed.Milliseconds(),
	}, logger.TraceAttrs(ctx)...)
	switch res.job {
	case "delete":
		attrs = append(attrs, "step_calls", res.stepCalls, "deleted_docs", res.deletedDocs, "deleted_objects", res.deletedObjects)
	case "export":
		attrs = append(attrs, "sections", res.sections, "bytes", res.bytes)
	}
	switch {
	case res.err != nil && d.Attempt >= maxDeliveryAttempts:
		mw.ReportError(ctx, l.log.With(attrs...), "jobs/account_"+res.job, res.err)
	case res.err != nil:
		l.log.WarnContext(ctx, "account_job", append(attrs, "error", logger.CauseChain(res.err))...)
	default:
		l.log.InfoContext(ctx, "account_job", attrs...)
	}
}

// runDelete handles one {account_delete} delivery (see the file comment).
func (l *Lifecycle) runDelete(ctx context.Context, msg JobMessage, res jobResult) jobResult {
	p, updateTime, err := l.repo.GetJobState(ctx, msg.UID)
	switch {
	case isNotFound(err):
		return ack(res, "duplicate") // users/{uid} is gone: the deletion finished
	case err != nil:
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: read job state: %w", err), msg.UID))
	}
	target, err := l.auth.deletionTarget(ctx, p, msg.Seq)
	if err != nil {
		return ack(res, "refused") // C1: a message never makes a non-DELETING uid deletable
	}
	job := *p.DeletionJob
	res.step = job.Step
	switch msg.Seq {
	case job.Seq:
	case job.Seq - 1:
		// The state was saved but the continuation may not have been published: publish it again (deduped).
		if err := l.publish(ctx, JobMessage{Kind: JobKindAccountDelete, UID: msg.UID, Seq: job.Seq}); err != nil {
			return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: republish job: %w", err), msg.UID))
		}
		return ack(res, "duplicate")
	default:
		return ack(res, "duplicate")
	}

	// gateWait only errors for a non-DELETING profile, which deletionTarget above already refused (C1).
	wait, _ := gateWait(p, l.now(), l.startGate)
	if wait > 0 {
		// Gated: disable the account now (idempotent, free) but erase nothing until every instance has expired its
		// cached ACTIVE profile. 429 is a nack that does not count as a 5xx; Pub/Sub redelivers after its backoff.
		if err := l.auth.disableAndRevoke(ctx, target); err != nil {
			return retry(res, "error", err)
		}
		res.status, res.outcome = http.StatusTooManyRequests, "gated"
		return res
	}

	var st jobStats
	next, done, err := l.work(ctx, p, target, job, &st)
	res.stepCalls, res.deletedDocs, res.deletedObjects = st.calls, st.docs, st.objects
	switch {
	case errors.Is(err, ErrJobConflict):
		// The final delete found the account no longer DELETING at this seq: another delivery or a restore won.
		return ack(res, "duplicate")
	case err != nil:
		return retry(res, "error", err)
	}
	if done {
		l.cache.InvalidateProfile(msg.UID)
		res.step = stepUserDoc
		return ack(res, "done")
	}
	res.step = next.Step
	if res2, ok := l.saveState(ctx, msg, res, updateTime, next); !ok {
		return res2
	}
	if err := l.publish(ctx, JobMessage{Kind: JobKindAccountDelete, UID: msg.UID, Seq: next.Seq}); err != nil {
		// The state is saved; the redelivery of this seq (state.seq-1) re-publishes it.
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: publish continuation: %w", err), msg.UID))
	}
	return ack(res, "progressed")
}

// saveState writes next with the read's update time. A lost precondition means either another delivery advanced
// the job (stop: duplicate) or an unrelated write touched users/{uid} (re-read and retry, bounded). ok=false means
// the returned jobResult is final.
func (l *Lifecycle) saveState(ctx context.Context, msg JobMessage, res jobResult, updateTime time.Time, next DeletionJob) (jobResult, bool) {
	for range saveRetries {
		err := l.repo.SaveJobState(ctx, msg.UID, updateTime, next)
		switch {
		case err == nil:
			return res, true
		case isNotFound(err):
			return ack(res, "duplicate"), false
		case !errors.Is(err, ErrJobConflict):
			return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: save job state: %w", err), msg.UID)), false
		}
		p, ut, rerr := l.repo.GetJobState(ctx, msg.UID)
		switch {
		case isNotFound(rerr):
			return ack(res, "duplicate"), false
		case rerr != nil:
			return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: re-read job state: %w", rerr), msg.UID)), false
		case p.Status != AccountStatusDeleting || p.DeletionJob == nil || p.DeletionJob.Seq != msg.Seq:
			return ack(res, "duplicate"), false // another delivery won
		}
		updateTime = ut
	}
	return retry(res, "error", fmt.Errorf("identity: job state kept changing under %d save attempts", saveRetries)), false
}

// runner is one step of a deletion slice.
type runner struct {
	name string
	run  func(ctx context.Context, checkpoint []byte) (next []byte, done bool, err error)
}

// deletionSteps is the fixed order of ADR-0011 Q1: Auth disable, the registered erasers (posts, graph, later
// slices), the identity step, the Auth user, and users/{uid} last (it is the marker the backstop finds).
//
// The step names are a persisted contract: the name of the step a slice stopped at is stored in users/{uid}
// deletionJob.step, so renaming or removing one strands in-flight deletions (StepNames exposes them to a test).
func (l *Lifecycle) deletionSteps(p Profile, t deletionTarget, seq int64, st *jobStats) []runner {
	erasers, _ := l.registered()
	steps := make([]runner, 0, len(erasers)+4)
	steps = append(steps, runner{stepAuthDisable, func(ctx context.Context, _ []byte) ([]byte, bool, error) {
		return nil, true, l.auth.disableAndRevoke(ctx, t)
	}})
	for _, e := range erasers {
		steps = append(steps, runner{e.Name(), func(ctx context.Context, cp []byte) ([]byte, bool, error) {
			return e.Run(ctx, p.UserID, cp)
		}})
	}
	steps = append(steps,
		runner{stepIdentity, func(ctx context.Context, _ []byte) ([]byte, bool, error) { return l.identityStep(ctx, p, st) }},
		runner{stepAuthDelete, func(ctx context.Context, _ []byte) ([]byte, bool, error) {
			return nil, true, l.auth.deleteUser(ctx, t)
		}},
		runner{stepUserDoc, func(ctx context.Context, _ []byte) ([]byte, bool, error) {
			// Conditional on DELETING at this delivery's seq (ErrJobConflict otherwise).
			if err := l.repo.DeleteUserDoc(ctx, p.UserID, seq); err != nil {
				return nil, false, err
			}
			st.docs++
			return nil, true, nil
		}},
	)
	return steps
}

// work runs steps from job's resume point until the work budget is spent, the job is done, or one step fails
// maxStepErrors times in a row (with a jittered, doubling pause between those retries). At least one step call runs
// per delivery. A step that fails because the work context ran out is not a failing step: the loop stops and the
// last good checkpoint is returned to be saved, so the next delivery resumes there instead of burning retries.
// (A step that always outlasts 25 s would chain forever; steps are page-bounded, so none should.) ErrJobConflict
// from a step (the conditional final delete) is returned at once. It returns the state to save.
func (l *Lifecycle) work(ctx context.Context, p Profile, t deletionTarget, job DeletionJob, st *jobStats) (DeletionJob, bool, error) {
	steps := l.deletionSteps(p, t, job.Seq, st)
	idx := 0
	if job.Step != "" {
		idx = slices.IndexFunc(steps, func(r runner) bool { return r.name == job.Step })
		if idx < 0 {
			return DeletionJob{}, false, fmt.Errorf("identity: saved deletion step %q is not registered", job.Step)
		}
	}
	started := l.now()
	limit := l.workBudget + stepGrace
	if dl, ok := ctx.Deadline(); ok {
		if room := time.Until(dl) - saveReserve; room > 0 && room < limit {
			limit = room
		}
	}
	wctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	cp := job.Checkpoint
	failures := 0
	for idx < len(steps) {
		if st.calls > 0 && l.now().Sub(started) >= l.workBudget {
			break
		}
		next, done, err := steps[idx].run(wctx, cp)
		st.calls++
		if err != nil {
			if errors.Is(err, ErrJobConflict) {
				return DeletionJob{}, false, logger.ScrubErr(fmt.Errorf("identity: step %s: %w", steps[idx].name, err), p.UserID)
			}
			if wctx.Err() != nil {
				break
			}
			failures++
			if failures >= maxStepErrors {
				return DeletionJob{}, false, logger.ScrubErr(fmt.Errorf("identity: step %s failed %d times in a row: %w", steps[idx].name, failures, err), p.UserID)
			}
			if store.Wait(wctx, l.retryBackoff<<(failures-1)) != nil {
				break
			}
			continue
		}
		failures = 0
		if done {
			idx++
			cp = nil
			continue
		}
		cp = next
	}
	if idx == len(steps) {
		return DeletionJob{}, true, nil
	}
	return DeletionJob{Seq: job.Seq + 1, Step: steps[idx].name, Checkpoint: cp, ProgressAt: l.now().UTC()}, false, nil
}

// identityStep erases what identity itself owns (ADR-0011 Q1 step 5): the user's exports (objects first, then
// docs), users/{uid}/private/*, handles/{handleLower} (only when it is theirs) and quotas/{uid}. users/{uid} is a
// later step. Idempotent; a page that comes back full asks for another call. Reads 2 + max(E, 1), deletes 2 + E.
func (l *Lifecycle) identityStep(ctx context.Context, p Profile, st *jobStats) ([]byte, bool, error) {
	exports, err := l.repo.ListExports(ctx, p.UserID, identityExportsPage)
	if err != nil {
		return nil, false, logger.RedactErr(fmt.Errorf("identity: list exports: %w", err), p.UserID)
	}
	if len(exports) > 0 {
		ids := make([]string, 0, len(exports))
		for _, e := range exports {
			if l.objects != nil && e.ObjectPath != "" {
				if err := l.objects.Delete(ctx, e.ObjectPath); err != nil {
					// The object path embeds the export id: scrubbed here and again when the delivery fails.
					return nil, false, logger.ScrubErr(fmt.Errorf("identity: delete export object: %w", err), p.UserID)
				}
				st.objects++
			}
			ids = append(ids, e.ID)
		}
		if err := l.repo.DeleteExportDocs(ctx, ids); err != nil {
			return nil, false, logger.RedactErr(fmt.Errorf("identity: delete exports: %w", err), p.UserID)
		}
		st.docs += len(ids)
		if len(exports) == identityExportsPage {
			return nil, false, nil
		}
	}
	n, err := l.repo.DeletePrivate(ctx, p.UserID, identityPrivatePage)
	if err != nil {
		return nil, false, logger.RedactErr(fmt.Errorf("identity: delete private docs: %w", err), p.UserID)
	}
	st.docs += n
	if n == identityPrivatePage {
		return nil, false, nil
	}
	outcome, err := l.repo.DeleteHandleIfOwned(ctx, p.HandleLower, p.UserID)
	if err != nil {
		return nil, false, logger.RedactErr(fmt.Errorf("identity: delete handle: %w", err), p.UserID)
	}
	if outcome == HandleDeleted {
		st.docs++
	}
	if outcome == HandleOwnerMismatch {
		l.log.WarnContext(ctx, "handle_owner_mismatch", append([]any{"uid_hash", logger.HashUID(p.UserID)}, logger.TraceAttrs(ctx)...)...)
	}
	if err := l.repo.DeleteQuotas(ctx, p.UserID); err != nil {
		return nil, false, logger.RedactErr(fmt.Errorf("identity: delete quotas: %w", err), p.UserID)
	}
	st.docs++
	return nil, true, nil
}

// BackstopResult counts what one backstop run did.
type BackstopResult struct {
	DeletionsRepublished int64
	ExportsRepublished   int64
	ExportsFailed        int64
}

// Backstop is the daily-maintenance recovery (ADR-0011 D-A option D): it re-publishes deletion jobs with no
// progress for an hour (a DLQ'd job, a lost publish, a deploy that dropped a message) and exports still PENDING
// after an hour (including one whose lease expired in a crash), and gives up exports PENDING after 24 hours
// (FAILED, the user may request again). It never acts on a user directly: it only re-sends the message the job
// handler validates, deduped by seq.
//
// Both scans are ordered oldest-progress first and filtered by age in the query (L-6), so a page holds only stuck
// documents and fresh jobs never crowd them out. Each scan walks at most backstopMaxPages pages of backstopPage
// documents with a cursor. Cost: 1 read per scan when nothing is stuck (2 per run), otherwise 1 per stuck document,
// at most backstopMaxPages*backstopPage = 200 per scan (400 per run). Republishing does not move the progress
// timestamp, so a job that stays stuck stays at the head of the next run; more than 200 permanently failing jobs
// (each one a DLQ and Error Reporting alert) log backstop_page_full.
func (l *Lifecycle) Backstop(ctx context.Context) (BackstopResult, error) {
	var res BackstopResult
	now := l.now()
	var deletions, republished, failed atomic.Int64
	var g errgroup.Group
	g.SetLimit(backstopPublishers)

	var cursor BackstopCursor
	capped := false
	for page := 0; page < backstopMaxPages; page++ {
		deleting, err := l.repo.ListDeleting(ctx, now.Add(-stuckAfter), cursor, backstopPage)
		if err != nil {
			_ = g.Wait()
			return res, fmt.Errorf("identity: backstop list deleting: %w", err)
		}
		for _, p := range deleting {
			if p.DeletionJob == nil {
				continue // cannot happen for a progressAt match; defensive
			}
			g.Go(func() error {
				if err := l.publish(ctx, JobMessage{Kind: JobKindAccountDelete, UID: p.UserID, Seq: p.DeletionJob.Seq}); err != nil {
					return logger.RedactErr(fmt.Errorf("identity: backstop republish deletion: %w", err), p.UserID)
				}
				deletions.Add(1)
				return nil
			})
		}
		if len(deleting) < backstopPage {
			break
		}
		last := deleting[len(deleting)-1]
		if last.DeletionJob == nil {
			break
		}
		cursor = BackstopCursor{At: last.DeletionJob.ProgressAt, ID: last.UserID}
		capped = page == backstopMaxPages-1
	}
	if capped {
		l.log.WarnContext(ctx, "backstop_page_full", append([]any{"query", "deleting", "limit", backstopPage, "pages", backstopMaxPages, "cursor_at", cursor.At}, logger.TraceAttrs(ctx)...)...)
	}

	cursor, capped = BackstopCursor{}, false
	for page := 0; page < backstopMaxPages; page++ {
		pending, err := l.repo.ListPendingExports(ctx, now.Add(-stuckAfter), cursor, backstopPage)
		if err != nil {
			_ = g.Wait()
			return res, fmt.Errorf("identity: backstop list exports: %w", err)
		}
		for _, e := range pending {
			if now.Sub(e.CreatedAt) >= exportFailAfter {
				g.Go(func() error {
					// An export that sat PENDING may still have an object (the READY write failed after the Put).
					if l.objects != nil && e.ObjectPath != "" {
						if err := l.objects.Delete(ctx, e.ObjectPath); err != nil {
							return logger.ScrubErr(fmt.Errorf("identity: backstop delete export object: %w", err), e.UID)
						}
					}
					switch err := l.repo.SetExportStatus(ctx, e.ID, ExportFailed, e.UpdateTime); {
					case err == nil:
						failed.Add(1)
					case errors.Is(err, ErrJobConflict), isNotFound(err):
						// Someone moved it on (READY or gone): nothing to do.
					default:
						return fmt.Errorf("identity: backstop fail export: %w", err)
					}
					return nil
				})
				continue
			}
			g.Go(func() error {
				if err := l.publish(ctx, JobMessage{Kind: JobKindAccountExport, ExportID: e.ID}); err != nil {
					return fmt.Errorf("identity: backstop republish export: %w", err)
				}
				republished.Add(1)
				return nil
			})
		}
		if len(pending) < backstopPage {
			break
		}
		last := pending[len(pending)-1]
		cursor = BackstopCursor{At: last.CreatedAt, ID: last.ID}
		capped = page == backstopMaxPages-1
	}
	if capped {
		l.log.WarnContext(ctx, "backstop_page_full", append([]any{"query", "pending_exports", "limit", backstopPage, "pages", backstopMaxPages, "cursor_at", cursor.At}, logger.TraceAttrs(ctx)...)...)
	}
	err := g.Wait()
	res.DeletionsRepublished, res.ExportsRepublished, res.ExportsFailed = deletions.Load(), republished.Load(), failed.Load()
	return res, err
}

// CronHandler is the `/internal/cron/daily-maintenance` handler: it runs the backstop under a 25 s deadline and
// answers 204, or 500 so Cloud Scheduler's retry runs it again. Mount it behind the OIDC verifier.
func (l *Lifecycle) CronHandler() http.Handler {
	return l.recoverPanic("cron/daily-maintenance", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(logger.WithTrace(r.Context(), logger.TraceFromRequest(r, l.projectID)), 25*time.Second)
		defer cancel()
		ctx, counter := budget.WithCounter(ctx)
		res, err := l.Backstop(ctx)
		attrs := append([]any{
			"account_job", "backstop", "deletions_republished", res.DeletionsRepublished,
			"exports_republished", res.ExportsRepublished, "exports_failed", res.ExportsFailed,
			"fs_reads", counter.Reads(), "fs_writes", counter.Writes(), "fs_deletes", counter.Deletes(),
		}, logger.TraceAttrs(ctx)...)
		if err != nil {
			attrs = append(attrs, "outcome", "error")
			mw.ReportError(ctx, l.log.With(attrs...), "cron/daily-maintenance", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		l.log.InfoContext(ctx, "account_job", append(attrs, "outcome", "ok")...)
		w.WriteHeader(http.StatusNoContent)
	}))
}
