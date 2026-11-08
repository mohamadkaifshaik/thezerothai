// outbox_wiring.go composes the durable outbox (pkg/platform/outbox): the one process-wide Outbox, its handler registry
// (post_delete today; a later kind registers in newOutbox), its sweep and its account-deletion step.
//
// The sweep has no Cloud Scheduler job of its own (the free tier holds 3 per billing account and prod keeps the third as
// headroom). It rides the publish-scheduled cron (every 5 min in prod) as a step AFTER the publish sweep, under the
// daily-maintenance status rule: the route's status is the publish sweep's alone, and the outbox step's outcome is for the
// logs. It runs whatever the scheduled-posts kill switch says (it is not a scheduled-posts feature) and is skipped under
// DEGRADED_MODE=readonly (it writes). /internal/cron/outbox-sweep runs it alone, for dev (no Scheduler jobs) and operators.
package apiserver

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// Time budget of the outbox step inside the publish-scheduled request: the request is cut off at outboxCutoff after it
// started (Cloud Run's request timeout is 30 s); the step gets min(outboxStepMax, what is left) and is skipped below
// outboxStepMin. The standalone route runs it under outboxRouteDeadline.
const (
	outboxCutoff        = 28 * time.Second
	outboxStepMax       = 10 * time.Second
	outboxStepMin       = 3 * time.Second
	outboxRouteDeadline = 25 * time.Second
	outboxSweepOp       = "cron/outbox-sweep"
)

// newOutbox builds the process's outbox over client and registers every kind's handler. now nil means time.Now (tests
// pass a clock).
func newOutbox(client *firestore.Client, postDeleteJobs posts.PostDeleteJobs, log *slog.Logger, now func() time.Time) (*outbox.Outbox, error) {
	ob := outbox.New(client, outbox.Config{Now: now})
	if err := ob.Handle(posts.PostDeleteOutboxKind, postDeleteOutboxHandler(postDeleteJobs, log)); err != nil {
		return nil, fmt.Errorf("outbox: %w", err)
	}
	return ob, nil
}

// postDeleteOutboxHandler republishes a deleted post's post_delete job through the same PostDeleted DeletePost calls. The
// job's media, engagement and pin steps all re-check that the post is gone and are idempotent, so a republish of an item
// whose inline publish did go through (a lost Done) is a harmless duplicate.
func postDeleteOutboxHandler(jobs posts.PostDeleteJobs, log *slog.Logger) outbox.Handler {
	return func(ctx context.Context, it outbox.Item) error {
		w, err := posts.DecodePostDeleteWork(it.Payload)
		if err != nil {
			log.WarnContext(ctx, "outbox_item_dropped", append([]any{"kind", it.Kind, "reason", "malformed_payload", "uid_hash", logger.HashUID(it.UID)}, logger.TraceAttrs(ctx)...)...)
			return nil
		}
		if err := jobs.PostDeleted(ctx, w.UID, w.PostID, w.MediaIDs); err != nil {
			return logger.RedactErr(fmt.Errorf("post_delete republish: %w", err), w.UID)
		}
		return nil
	}
}

// outboxSweeper is the one method of *outbox.Outbox the step needs.
type outboxSweeper interface {
	Sweep(ctx context.Context) (outbox.Result, error)
}

// outboxSweepStep runs one sweep and writes its one `outbox_sweep` line (counts only), one `outbox_item_stuck` ERROR per
// item that reached the attempt threshold (kind and hashed uid only), and an Error Reporting entry for a failed due query,
// a stuck item or a panic. Its error is the due query's (or the panic's).
type outboxSweepStep struct {
	sweeper  outboxSweeper
	readOnly bool
	log      *slog.Logger
}

func (s outboxSweepStep) run(ctx context.Context) (err error) {
	if s.readOnly {
		s.log.InfoContext(ctx, "outbox_sweep", append([]any{"outcome", "skipped_readonly"}, logger.TraceAttrs(ctx)...)...)
		return nil
	}
	reporter := s.log.With(logger.TraceAttrs(ctx)...)
	defer func() {
		if v := recover(); v != nil {
			err = panicError{v}
			mw.ReportError(ctx, reporter, outboxSweepOp, err)
		}
	}()
	started := time.Now()
	res, err := s.sweeper.Sweep(ctx)
	for _, st := range res.StuckItems {
		s.log.ErrorContext(ctx, "outbox_item_stuck", append([]any{"kind", st.Kind, "uid_hash", st.UIDHash}, logger.TraceAttrs(ctx)...)...)
	}
	if res.Stuck > 0 {
		mw.ReportError(ctx, reporter, outboxSweepOp, fmt.Errorf("outbox: %d item(s) reached the attempt threshold", res.Stuck))
	}
	attrs := append(res.LogAttrs(), "latency_ms", time.Since(started).Milliseconds())
	if err != nil {
		s.log.WarnContext(ctx, "outbox_sweep", append(append(attrs, "outcome", "error"), logger.TraceAttrs(ctx)...)...)
		mw.ReportError(ctx, reporter, outboxSweepOp, logger.ScrubErr(err))
		return err
	}
	s.log.InfoContext(ctx, "outbox_sweep", append(append(attrs, "outcome", "ok"), logger.TraceAttrs(ctx)...)...)
	return nil
}

// withOutboxSweep runs inner (the publish-scheduled sweep) through a status-capturing writer, then the outbox step with
// min(outboxStepMax, outboxCutoff - elapsed), then writes inner's captured response. A non-POST goes to inner alone.
func withOutboxSweep(inner http.Handler, step outboxSweepStep, projectID string, now func() time.Time) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			inner.ServeHTTP(w, r)
			return
		}
		started := now()
		rec := &statusRecorder{header: http.Header{}}
		inner.ServeHTTP(rec, r)

		ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, projectID))
		if left := outboxCutoff - now().Sub(started); left < outboxStepMin {
			step.log.InfoContext(ctx, "outbox_sweep", append([]any{"outcome", "skipped_deadline", "left_ms", left.Milliseconds()}, logger.TraceAttrs(ctx)...)...)
		} else {
			sctx, cancel := context.WithTimeout(ctx, min(outboxStepMax, left))
			_ = step.run(sctx) // logged and reported by run; never the route's status
			cancel()
		}
		rec.replay(w)
	})
}

// outboxSweepHandler is /internal/cron/outbox-sweep: POST only, a 25 s deadline, 204, or 500 when the due query failed
// (nothing was processed, so a retry is harmless).
func outboxSweepHandler(step outboxSweepStep, log *slog.Logger, projectID string) http.Handler {
	return mw.RecoverHTTP(log, projectID, outboxSweepOp, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(logger.WithTrace(r.Context(), logger.TraceFromRequest(r, projectID)), outboxRouteDeadline)
		defer cancel()
		if err := step.run(ctx); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}

// outboxEraserStep is the outbox step (step "outbox"): the user's pending work items (uid ==). Appended BeforeIdentity
// after beacons; dropping them is safe because the same deletion removes what they would have cleaned up.
func outboxEraserStep(ob *outbox.Outbox) identity.StepEraser {
	return eraserStep[outbox.Checkpoint]{name: "outbox", purge: ob.PurgeUser}
}

// registerOutboxLifecycle registers the outbox step. There is no export section: an item is an operational pointer
// (kind, the post id, the uid, attempts), not user content. Call it after registerBeaconsLifecycle.
func registerOutboxLifecycle(l *identity.Lifecycle, ob *outbox.Outbox) error {
	return l.RegisterEraser(identity.BeforeIdentity, outboxEraserStep(ob))
}
