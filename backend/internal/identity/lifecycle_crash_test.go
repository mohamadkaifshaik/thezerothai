package identity

// Crash and failure injection for the deletion job (ADR-0011 handoff, tester T16: "crash after every step call",
// "users/{uid} existing until after Auth delete"). The fakes record every side effect in one ordered log; these tests
// kill the delivery after each of those effects in turn, redeliver the same message the way Pub/Sub does, and check
// the end state and the ordering invariants.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"
)

// trackedStep logs "step.<name> done" when the wrapped eraser reports completion, so the order of completed steps is
// part of the op log.
type trackedStep struct {
	*fakeStep
	log *opLog
}

func (s trackedStep) Run(ctx context.Context, uid string, cp []byte) ([]byte, bool, error) {
	next, done, err := s.fakeStep.Run(ctx, uid, cp)
	if err == nil && done {
		s.log.add("step." + s.name + " done")
	}
	return next, done, err
}

// flakyStep fails every call while fail is true, then behaves like fakeStep.
type flakyStep struct {
	*fakeStep
	fail bool
}

func (s *flakyStep) Run(ctx context.Context, uid string, cp []byte) ([]byte, bool, error) {
	if s.fail {
		s.log.add("step." + s.name + " failing")
		return nil, false, errors.New("eraser unavailable")
	}
	return s.fakeStep.Run(ctx, uid, cp)
}

// crashScenario is the reference account: an export with an object, a handle, a quota doc, private docs, and two
// registered erasers that each need several calls and take 10 s per call (so a 25 s slice runs 3 calls and the job
// spans several invocations). DeleteAccount has already run.
func crashScenario(t *testing.T) *harness {
	t.Helper()
	h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = 25 * time.Second })
	h.seedActive("u1", "Alice")
	h.repo.private["u1"] = 3
	h.repo.quotas["u1"] = 1
	h.repo.exports["e1"] = &ExportDoc{ID: "e1", UID: "u1", Status: ExportReady, ObjectPath: "e1.json", UpdateTime: utOf(1)}
	h.objs.objects["e1.json"] = []byte("{}")
	for _, s := range []*fakeStep{
		{name: "posts", need: 4, clock: h.clock, tick: 10 * time.Second, log: h.log},
		{name: "graph", need: 2, clock: h.clock, tick: 10 * time.Second, log: h.log},
	} {
		if err := h.l.RegisterEraser(BeforeIdentity, trackedStep{s, h.log}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.l.DeleteAccount(context.Background(), "u1", delKey); err != nil {
		t.Fatal(err)
	}
	return h
}

// deliverCrashy delivers msg and reports whether the instance "died" (the injected panic) instead of answering.
func (h *harness) deliverCrashy(msg JobMessage, attempt int) (code int, crashed bool) {
	h.t.Helper()
	defer func() {
		if r := recover(); r != nil {
			if r != errCrash {
				panic(r)
			}
			crashed = true
		}
	}()
	code = h.deliver(msg, attempt)
	// The handler recovers the injected panic into a 500 (and reports it); the log tells it apart from an error.
	h.log.mu.Lock()
	fired := h.log.fired
	h.log.fired = false
	h.log.mu.Unlock()
	return code, fired
}

// pump plays Pub/Sub: a message stays in flight until it is acked (204); a crash, a 429 (after the 60 s backoff) and
// a 500 redeliver it; published continuations queue behind it. It returns the number of crashes it saw.
func (h *harness) pump(maxSteps int) (crashes int) {
	h.t.Helper()
	var cur *JobMessage
	attempt := 1
	for range maxSteps {
		if cur == nil {
			m, ok := h.pub.pop()
			if !ok {
				return crashes
			}
			cur, attempt = &m, 1
		}
		code, crashed := h.deliverCrashy(*cur, attempt)
		switch {
		case crashed:
			crashes++
			attempt++
		case code == http.StatusTooManyRequests:
			h.clock.Advance(61 * time.Second)
			attempt++
		case code == http.StatusNoContent:
			cur = nil
		default:
			attempt++
		}
	}
	h.t.Fatalf("job still in flight after %d deliveries; last ops = %v", maxSteps, h.log.all())
	return crashes
}

// TestJobs_CrashAfterEverySideEffect kills the delivery after each recorded side effect of a complete deletion (the
// Auth disable, every step call, every object/doc delete, the state save, the continuation publish, the Auth delete,
// users/{uid}) and checks the redelivery converges to the same end state with the ADR-0011 Q1 order intact.
func TestJobs_CrashAfterEverySideEffect(t *testing.T) {
	// A clean run fixes the number of side effects to crash after.
	clean := crashScenario(t)
	base := len(clean.log.all())
	clean.pump(60)
	total := len(clean.log.all()) - base
	if total < 20 {
		t.Fatalf("a clean run recorded only %d side effects; the scenario is too small to mean anything", total)
	}

	for k := 1; k <= total; k++ {
		t.Run(fmt.Sprintf("crash after side effect %d", k), func(t *testing.T) {
			h := crashScenario(t)
			base := len(h.log.all())
			h.log.crashAt = base + k
			crashes := h.pump(120)
			if crashes != 1 {
				t.Fatalf("crashes = %d, want exactly 1", crashes)
			}
			ops := h.log.all()

			// End state: everything gone, Auth user deleted.
			if _, ok := h.repo.user("u1"); ok {
				t.Fatal("users/u1 survived")
			}
			if len(h.repo.exports) != 0 || len(h.objs.objects) != 0 || len(h.repo.handles) != 0 || len(h.repo.quotas) != 0 || h.repo.private["u1"] != 0 {
				t.Errorf("leftovers: exports=%v objects=%v handles=%v quotas=%v private=%d", h.repo.exports, h.objs.objects, h.repo.handles, h.repo.quotas, h.repo.private["u1"])
			}
			if h.pub.count() != 0 {
				t.Errorf("messages left in flight: %+v", h.pub.msgs)
			}

			first := func(op string) int { return slices.Index(ops, op) }
			for _, op := range []string{"auth.UpdateUser", "auth.RevokeRefreshTokens", "step.posts done", "step.graph done", "obj.Delete", "repo.DeleteQuotas", "repo.DeleteHandle", "auth.DeleteUser", "repo.DeleteUserDoc"} {
				if first(op) < 0 {
					t.Fatalf("%q never happened: %v", op, ops)
				}
			}
			// Q1 order, whatever the crash: disable, posts, graph, identity, Auth user, users/{uid} last.
			chain := []string{"auth.UpdateUser", "step.posts done", "step.graph done", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}
			for i := 1; i < len(chain); i++ {
				if first(chain[i-1]) > first(chain[i]) {
					t.Errorf("%q came after %q: %v", chain[i-1], chain[i], ops)
				}
			}
			if first("step.graph call=1") < first("step.posts done") {
				t.Errorf("graph started before posts finished: %v", ops)
			}
			if first("auth.UpdateUser") > first("step.posts call=1") {
				t.Errorf("an eraser ran before the Auth user was disabled: %v", ops)
			}
			// The DELETING marker is the last thing to go and nothing runs after it.
			if rest := ops[first("repo.DeleteUserDoc")+1:]; len(rest) != 0 {
				t.Errorf("operations after users/{uid} was deleted: %v", rest)
			}
		})
	}
}

// TestJobs_FailureNeverSkipsAhead: whichever step keeps failing, no later step runs. In particular the Firebase Auth
// user (which holds the email) and users/{uid} (the marker the backstop finds) survive until every earlier step is
// done, and once the fault clears the redelivery finishes the job.
func TestJobs_FailureNeverSkipsAhead(t *testing.T) {
	boom := errors.New("backend unavailable")
	tests := []struct {
		name string
		// inject makes the step fail persistently and returns the function that clears the fault.
		inject    func(h *harness, posts *flakyStep) (clear func())
		forbidden []string
	}{
		{"auth disable", func(h *harness, _ *flakyStep) func() {
			h.auth.err["UpdateUser"] = boom
			return func() { delete(h.auth.err, "UpdateUser") }
		}, []string{"step.posts call=", "step.posts failing", "obj.Delete", "repo.Delete", "auth.DeleteUser"}},
		{"an eraser", func(_ *harness, posts *flakyStep) func() {
			posts.fail = true
			return func() { posts.fail = false }
		}, []string{"obj.Delete", "repo.Delete", "auth.DeleteUser"}},
		{"export object delete", func(h *harness, _ *flakyStep) func() {
			h.objs.delErr = boom
			return func() { h.objs.delErr = nil }
		}, []string{"repo.DeleteExportDocs", "repo.DeleteHandle", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}},
		{"export doc delete", func(h *harness, _ *flakyStep) func() {
			h.repo.failOnce["DeleteExportDocs"], h.repo.failFor["DeleteExportDocs"] = boom, 1000
			return func() { delete(h.repo.failOnce, "DeleteExportDocs"); delete(h.repo.failFor, "DeleteExportDocs") }
		}, []string{"repo.DeleteHandle", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}},
		{"private docs delete", func(h *harness, _ *flakyStep) func() {
			h.repo.failOnce["DeletePrivate"], h.repo.failFor["DeletePrivate"] = boom, 1000
			return func() { delete(h.repo.failOnce, "DeletePrivate"); delete(h.repo.failFor, "DeletePrivate") }
		}, []string{"repo.DeleteHandle", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}},
		{"handle delete", func(h *harness, _ *flakyStep) func() {
			h.repo.failOnce["DeleteHandleIfOwned"], h.repo.failFor["DeleteHandleIfOwned"] = boom, 1000
			return func() { delete(h.repo.failOnce, "DeleteHandleIfOwned"); delete(h.repo.failFor, "DeleteHandleIfOwned") }
		}, []string{"repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}},
		{"quotas delete", func(h *harness, _ *flakyStep) func() {
			h.repo.failOnce["DeleteQuotas"], h.repo.failFor["DeleteQuotas"] = boom, 1000
			return func() { delete(h.repo.failOnce, "DeleteQuotas"); delete(h.repo.failFor, "DeleteQuotas") }
		}, []string{"auth.DeleteUser", "repo.DeleteUserDoc"}},
		{"auth user delete", func(h *harness, _ *flakyStep) func() {
			h.auth.err["DeleteUser"] = boom
			return func() { delete(h.auth.err, "DeleteUser") }
		}, []string{"repo.DeleteUserDoc"}},
		{"users doc delete", func(h *harness, _ *flakyStep) func() {
			h.repo.failOnce["DeleteUserDoc"], h.repo.failFor["DeleteUserDoc"] = boom, 1000
			return func() { delete(h.repo.failOnce, "DeleteUserDoc"); delete(h.repo.failFor, "DeleteUserDoc") }
		}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Hour })
			h.seedDeleting("u1", "Alice", time.Hour) // past the start gate
			h.repo.private["u1"] = 3
			h.repo.quotas["u1"] = 1
			h.repo.exports["e1"] = &ExportDoc{ID: "e1", UID: "u1", Status: ExportReady, ObjectPath: "e1.json", UpdateTime: utOf(1)}
			h.objs.objects["e1.json"] = []byte("{}")
			posts := &flakyStep{fakeStep: &fakeStep{name: "posts", need: 1, log: h.log}}
			if err := h.l.RegisterEraser(BeforeIdentity, posts); err != nil {
				t.Fatal(err)
			}
			clear := tt.inject(h, posts)
			msg := JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}

			if code := h.deliver(msg, 1); code != http.StatusInternalServerError {
				t.Fatalf("status with a persistent fault = %d, want 500 so Pub/Sub retries", code)
			}
			if _, ok := h.repo.user("u1"); !ok && tt.name != "users doc delete" {
				t.Fatal("users/u1 was deleted while an earlier step was failing")
			}
			for _, prefix := range tt.forbidden {
				if n := h.log.count(prefix); n != 0 {
					t.Errorf("%d x %q ran past the failing step: %v", n, prefix, h.log.all())
				}
			}
			if h.pub.count() != 0 {
				t.Errorf("a failed delivery published a continuation: %+v", h.pub.msgs)
			}

			clear()
			if code := h.deliver(msg, 2); code != http.StatusNoContent {
				t.Fatalf("redelivery after the fault cleared = %d, want 204", code)
			}
			if _, ok := h.repo.user("u1"); ok {
				t.Error("the redelivery did not finish the deletion")
			}
			if len(h.repo.exports) != 0 || len(h.objs.objects) != 0 || len(h.repo.quotas) != 0 {
				t.Errorf("leftovers after recovery: exports=%v objects=%v quotas=%v", h.repo.exports, h.objs.objects, h.repo.quotas)
			}
		})
	}
}
