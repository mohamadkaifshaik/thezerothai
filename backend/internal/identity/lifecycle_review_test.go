package identity

// Tests for the code-reviewer findings on the P8 backend (m3, m4, m6, m7, m8, m9): context-aware step retries,
// observability fields, the backstop page limit, handler panics and the conditional final delete.

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ctxStep fails on every call, after running hook.
type ctxStep struct {
	name  string
	calls int
	hook  func()
}

func (s *ctxStep) Name() string { return s.name }

func (s *ctxStep) Run(context.Context, string, []byte) ([]byte, bool, error) {
	s.calls++
	if s.hook != nil {
		s.hook()
	}
	return nil, false, errors.New("step failed")
}

func workInputs(h *harness, uid string, step string, cp []byte) (Profile, deletionTarget, DeletionJob) {
	p := h.seedDeleting(uid, "Alice", time.Hour)
	return p, deletionTarget{uid: uid, seq: 4}, DeletionJob{Seq: 4, Step: step, Checkpoint: cp}
}

// TestWork_ContextEndedSavesTheCheckpoint (m3): a step that fails because the work context ran out is not a failing
// step. work stops, keeps the last good checkpoint and returns the next state to save, with no error and no retries
// burned; the same holds when the context ends during the pause between retries.
func TestWork_ContextEndedSavesTheCheckpoint(t *testing.T) {
	t.Run("cancelled while the step runs", func(t *testing.T) {
		h := newHarness(t)
		ctx, cancel := context.WithCancel(context.Background())
		step := &ctxStep{name: "posts", hook: cancel}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		p, tg, job := workInputs(h, "u1", "posts", []byte("2"))
		var st jobStats
		next, done, err := h.l.work(ctx, p, tg, job, &st)
		if err != nil || done || step.calls != 1 || st.calls != 1 {
			t.Fatalf("work = %+v done=%v err=%v after %d calls, want a clean stop after 1", next, done, err, step.calls)
		}
		if next.Seq != 5 || next.Step != "posts" || string(next.Checkpoint) != "2" {
			t.Errorf("next state = %+v, want seq 5 at posts with checkpoint 2", next)
		}
	})
	t.Run("cancelled during the backoff between retries", func(t *testing.T) {
		h := newHarness(t, func(d *LifecycleDeps) { d.RetryBackoff = time.Hour })
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		time.AfterFunc(20*time.Millisecond, cancel)
		step := &ctxStep{name: "posts"}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		p, tg, job := workInputs(h, "u1", "posts", nil)
		next, done, err := h.l.work(ctx, p, tg, job, &jobStats{})
		if err != nil || done || next.Step != "posts" || next.Seq != 5 {
			t.Fatalf("work = %+v done=%v err=%v, want a clean stop at posts", next, done, err)
		}
		if step.calls >= maxStepErrors {
			t.Errorf("%d calls: the retry loop did not respect the context", step.calls)
		}
	})
	t.Run("a failing step still fails after maxStepErrors tries", func(t *testing.T) {
		h := newHarness(t)
		step := &ctxStep{name: "posts"}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		p, tg, job := workInputs(h, "u1", "posts", nil)
		if _, _, err := h.l.work(context.Background(), p, tg, job, &jobStats{}); err == nil || step.calls != maxStepErrors {
			t.Errorf("err = %v after %d calls, want an error after %d", err, step.calls, maxStepErrors)
		}
	})
}

// TestJobs_LogsStepCountsAndExportSizes (m9, m4): the delete line carries step_calls, deleted_docs and
// deleted_objects; the export line carries sections and bytes.
func TestJobs_LogsStepCountsAndExportSizes(t *testing.T) {
	t.Run("delete", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		h.repo.private["u1"] = 3
		doc := newPendingExport(h, "u1")
		h.objs.objects[doc.ObjectPath] = []byte("{}")
		_ = h.l.RegisterEraser(BeforeIdentity, &fakeStep{name: "posts", need: 1, log: h.log})
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		recs := h.logs.records("account_job")
		if len(recs) != 1 {
			t.Fatalf("%d account_job lines", len(recs))
		}
		r := recs[0]
		// auth_disable, posts, identity, auth_delete, users_doc.
		if r["step_calls"] != float64(5) || r["deleted_objects"] != float64(1) {
			t.Errorf("step_calls=%v deleted_objects=%v in %v", r["step_calls"], r["deleted_objects"], r)
		}
		// 1 export doc + 3 private docs + the handle + quotas + users doc.
		if r["deleted_docs"] != float64(7) {
			t.Errorf("deleted_docs = %v, want 7", r["deleted_docs"])
		}
	})
	t.Run("export", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: "[]"})
		doc := newPendingExport(h, "u1")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		raw, _ := h.objs.get(doc.ObjectPath)
		recs := h.logs.records("account_job")
		if len(recs) != 1 || recs[0]["sections"] != float64(3) || recs[0]["bytes"] != float64(len(raw)) {
			t.Errorf("want sections 3 and bytes %d, got %v", len(raw), recs)
		}
	})
	t.Run("a DELETING flag set by hand (no job state) is not scanned and not republished", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		p.Status = AccountStatusDeleting // set by hand: no job state, so the ordered scan cannot match it
		h.repo.seed(p)
		res, err := h.l.Backstop(logger.WithTrace(context.Background(), "projects/p/traces/abc"))
		if err != nil || res != (BackstopResult{}) || h.pub.count() != 0 {
			t.Errorf("Backstop = %+v, %v, published %d", res, err, h.pub.count())
		}
	})
}

type panicRepo struct{ *fakeLCRepo }

func (panicRepo) ListDeleting(context.Context, time.Time, BackstopCursor, int) ([]Profile, error) {
	panic("boom for user caller-uid-0123456789abcdef")
}

// TestJobHandlers_RecoverPanics (m7): a panic in either handler becomes a 500 and an Error Reporting entry that
// carries neither the panic value nor a uid.
func TestJobHandlers_RecoverPanics(t *testing.T) {
	t.Run("jobs", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("caller-uid-0123456789abcdef", "Alice", time.Hour)
		_ = h.l.RegisterEraser(BeforeIdentity, &fakeStep{name: "posts", need: 1, log: h.log, gate: func() { panic("boom for user caller-uid-0123456789abcdef") }})
		code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "caller-uid-0123456789abcdef", Seq: 0}, 1)
		assertRecovered(t, h, code)
	})
	t.Run("cron", func(t *testing.T) {
		h := newHarness(t)
		h.l.repo = panicRepo{h.repo}
		rec := newRecorder()
		h.l.CronHandler().ServeHTTP(rec, newRequest(http.MethodPost))
		assertRecovered(t, h, rec.Code)
	})
}

func assertRecovered(t *testing.T, h *harness, code int) {
	t.Helper()
	out := h.logs.String()
	if code != http.StatusInternalServerError || !strings.Contains(out, "ReportedErrorEvent") || !strings.Contains(out, "panic of type") {
		t.Errorf("status %d, log:\n%s", code, out)
	}
	if strings.Contains(out, "caller-uid-0123456789abcdef") || strings.Contains(out, "boom for user") {
		t.Errorf("the panic value reached the log:\n%s", out)
	}
}

// TestJobs_FinalDeleteIsConditional (m8): if the account stopped being DELETING at this seq while the steps ran (a
// restore by hand, another delivery), the final delete leaves users/{uid} alone and the delivery acks as a duplicate.
func TestJobs_FinalDeleteIsConditional(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("u1", "Alice", time.Hour)
	restore := func() {
		p, _ := h.repo.user("u1")
		p.Status, p.DeletionJob, p.DeletionRequestedAt = AccountStatusActive, nil, time.Time{}
		h.repo.seed(p)
	}
	_ = h.l.RegisterEraser(BeforeIdentity, &fakeStep{name: "posts", need: 1, log: h.log, gate: restore})
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	if p, ok := h.repo.user("u1"); !ok || p.Status != AccountStatusActive {
		t.Errorf("the restored account was deleted: %+v, %v", p, ok)
	}
	if recs := h.logs.records("account_job"); len(recs) != 1 || recs[0]["outcome"] != "duplicate" {
		t.Errorf("log = %v", recs)
	}
}
