package identity

// Tester audit of the P8 acceptance criteria (docs/plans/account-deletion-export.md T5-T10, ADR-0011 C1 and Q1-Q9):
// the cases the original tickets' tests left open. Uses the fakes of lifecycle_fakes_test.go.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestJobs_ErrorPolicyBoundaries pins the 5-consecutive-errors policy (opsctl purgeLoop, moved into the
// orchestrator): four errors in a row are absorbed, a success resets the count, the count is per step, and the
// Auth steps follow the same policy.
func TestJobs_ErrorPolicyBoundaries(t *testing.T) {
	boom := errors.New("firestore unavailable")
	msg := JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}

	t.Run("four errors in a row are absorbed", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		step := &fakeStep{name: "posts", need: 1, log: h.log, errs: map[int]error{1: boom, 2: boom, 3: boom, 4: boom}}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		if code := h.deliver(msg, 1); code != http.StatusNoContent || step.calls != 5 {
			t.Fatalf("status %d after %d calls, want 204 after 5 (4 failures + 1 success)", code, step.calls)
		}
		if _, ok := h.repo.user("u1"); ok {
			t.Error("the deletion did not complete")
		}
	})

	t.Run("a success resets the count: 4 errors on each of two steps do not fail the delivery", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		errs := map[int]error{1: boom, 2: boom, 3: boom, 4: boom}
		a := &fakeStep{name: "posts", need: 1, log: h.log, errs: errs}
		b := &fakeStep{name: "graph", need: 1, log: h.log, errs: errs}
		_ = h.l.RegisterEraser(BeforeIdentity, a)
		_ = h.l.RegisterEraser(BeforeIdentity, b)
		if code := h.deliver(msg, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204 (8 errors in total, never 5 in a row on one step)", code)
		}
		if a.calls != 5 || b.calls != 5 {
			t.Errorf("calls posts=%d graph=%d, want 5 and 5", a.calls, b.calls)
		}
	})

	t.Run("the Auth disable step gets exactly 5 attempts, then the delivery fails with nothing erased", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		step := &fakeStep{name: "posts", need: 1, log: h.log}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		h.auth.err["UpdateUser"] = boom
		if code := h.deliver(msg, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if n := h.log.count("auth.UpdateUser"); n != maxStepErrors {
			t.Errorf("Auth disable attempts = %d, want %d", n, maxStepErrors)
		}
		if step.calls != 0 || h.repo.writes != 0 || h.repo.deletes != 0 {
			t.Errorf("an eraser ran behind a failing Auth disable: calls %d writes %d deletes %d", step.calls, h.repo.writes, h.repo.deletes)
		}
	})

	t.Run("a step error naming the uid, a counterpart uid and an export id is scrubbed on every attempt", func(t *testing.T) {
		const uid = "caller-uid-0123456789abcdef"
		const counterpart = "counterpart-uid-0123456789abc"
		exportID := strings.Repeat("ab12", 16)
		// The shape of a real Firestore failure: document paths and an edge id carry third-party uids.
		fsErr := fmt.Errorf("rpc error: code = Unavailable desc = commit documents/users/%s/x and follows/%s_%s; object %s.json", uid, uid, counterpart, exportID)
		for _, attempt := range []int{1, maxDeliveryAttempts} {
			h := newHarness(t)
			h.seedDeleting(uid, "Alice", time.Hour)
			step := &fakeStep{name: "posts", need: 1, log: h.log, errs: map[int]error{1: fsErr, 2: fsErr, 3: fsErr, 4: fsErr, 5: fsErr}}
			_ = h.l.RegisterEraser(BeforeIdentity, step)
			h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: uid, Seq: 0}, attempt)
			out := h.logs.String()
			for _, raw := range []string{uid, counterpart, exportID} {
				if strings.Contains(out, raw) {
					t.Errorf("attempt %d: the log carries %q:\n%s", attempt, raw, out)
				}
			}
			if attempt == maxDeliveryAttempts && !strings.Contains(out, "ReportedErrorEvent") {
				t.Errorf("the last attempt must reach Error Reporting:\n%s", out)
			}
			if attempt == 1 && len(h.logs.records("account_job")) != 1 {
				t.Errorf("want one account_job line:\n%s", out)
			}
		}
	})
}

// TestJobs_RefusalHoldsOnEveryBranch is IAM control C1 beyond the seq == state.seq path: the fresh DELETING check
// comes before the dedupe, so a message that would only re-publish (seq == state.seq-1) or that is stale still gets
// no Auth call and no publish for a user who is not DELETING-by-DeleteAccount, even if the document carries stale
// deletion fields.
func TestJobs_RefusalHoldsOnEveryBranch(t *testing.T) {
	requested := time.Date(2026, 10, 7, 11, 0, 0, 0, time.UTC)
	job := &DeletionJob{Seq: 5, Step: "posts"}
	tests := []struct {
		name string
		p    Profile
	}{
		{"ACTIVE with stale deletion fields", Profile{UserID: "u1", Status: AccountStatusActive, DeletionRequestedAt: requested, DeletionJob: job}},
		{"SUSPENDED with stale deletion fields", Profile{UserID: "u1", Status: AccountStatusSuspended, DeletionRequestedAt: requested, DeletionJob: job}},
		{"DELETING with a job but no request time", Profile{UserID: "u1", Status: AccountStatusDeleting, DeletionJob: job}},
		{"DELETING with a request time but no job", Profile{UserID: "u1", Status: AccountStatusDeleting, DeletionRequestedAt: requested}},
		{"zero status", Profile{UserID: "u1", DeletionRequestedAt: requested, DeletionJob: job}},
	}
	for _, tt := range tests {
		for _, seq := range []int64{0, 4, 5, 6, 1 << 40} { // stale, seq-1 (re-publish), current, future, huge
			t.Run(fmt.Sprintf("%s, seq %d", tt.name, seq), func(t *testing.T) {
				h := newHarness(t)
				step := &fakeStep{name: "posts", need: 1, log: h.log}
				_ = h.l.RegisterEraser(BeforeIdentity, step)
				h.repo.seed(tt.p)
				if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: seq}, 1); code != http.StatusNoContent {
					t.Fatalf("status = %d, want 204", code)
				}
				if h.log.count("auth.") != 0 || step.calls != 0 || h.pub.count() != 0 || h.repo.writes != 0 || h.repo.deletes != 0 {
					t.Errorf("a refused message acted: %v (publishes %d)", h.log.all(), h.pub.count())
				}
				if _, ok := h.repo.user("u1"); !ok {
					t.Error("the user document was deleted")
				}
			})
		}
	}
}

// TestJobs_RefusalReadsFreshState: C1 is evaluated against the document read in this very delivery, never a cached
// or earlier view. A user who was DELETING at the gated delivery but is no longer DELETING at the next one (a
// restore by hand, a replaced document) is refused: the second delivery makes no Auth call.
func TestJobs_RefusalReadsFreshState(t *testing.T) {
	h := newHarness(t)
	p := h.seedDeleting("u1", "Alice", 10*time.Second)
	step := &fakeStep{name: "posts", need: 1, log: h.log}
	_ = h.l.RegisterEraser(BeforeIdentity, step)
	msg := JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}

	if code := h.deliver(msg, 1); code != http.StatusTooManyRequests {
		t.Fatalf("first delivery = %d, want 429", code)
	}
	authCalls := h.log.count("auth.")

	p.Status = AccountStatusActive
	h.repo.seed(p)
	h.clock.Advance(5 * time.Minute)
	if code := h.deliver(msg, 2); code != http.StatusNoContent {
		t.Fatalf("second delivery = %d, want 204", code)
	}
	if h.log.count("auth.") != authCalls || step.calls != 0 || h.repo.deletes != 0 {
		t.Errorf("the second delivery acted on a user who is no longer DELETING: %v", h.log.all())
	}
	if _, ok := h.repo.user("u1"); !ok {
		t.Error("the user document was deleted")
	}
}

// TestJobs_GateClock: the 120 s start gate is measured from deletionRequestedAt. Checkpoint writes and counter
// increments move updatedAt and must not move the gate (ADR-0011 D-A "The start-gate clock").
func TestJobs_GateClock(t *testing.T) {
	msg := JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}
	t.Run("recent updatedAt does not re-close the gate", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedDeleting("u1", "Alice", 10*time.Minute)
		p.UpdatedAt = h.clock.Now().Add(-time.Second) // a counter decrement by another account's purge
		h.repo.seed(p)
		if code := h.deliver(msg, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", code)
		}
		if _, ok := h.repo.user("u1"); ok {
			t.Error("the deletion did not run")
		}
	})
	t.Run("old updatedAt does not open the gate early", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedDeleting("u1", "Alice", 60*time.Second)
		p.UpdatedAt = h.clock.Now().Add(-24 * time.Hour)
		h.repo.seed(p)
		if code := h.deliver(msg, 1); code != http.StatusTooManyRequests {
			t.Fatalf("status = %d, want 429", code)
		}
	})
	t.Run("exactly 119.999 s is gated, exactly 120 s is not", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", 120*time.Second-time.Millisecond)
		if code := h.deliver(msg, 1); code != http.StatusTooManyRequests {
			t.Fatalf("119.999 s: status = %d, want 429", code)
		}
		h.clock.Advance(time.Millisecond)
		if code := h.deliver(msg, 2); code != http.StatusNoContent {
			t.Fatalf("120 s: status = %d, want 204", code)
		}
	})
}

// TestBackstop_ResumesFromTheCheckpoint (T8 acceptance: "a job that has used up retries (DLQ), when the backstop
// runs, then the job resumes from its checkpoint"): the republished message carries the stored seq, and the
// delivery continues the saved step with the saved checkpoint instead of starting over.
func TestBackstop_ResumesFromTheCheckpoint(t *testing.T) {
	h := newHarness(t)
	now := h.clock.Now()
	p := h.seedDeleting("u1", "Alice", 3*time.Hour)
	p.DeletionJob = &DeletionJob{Seq: 3, Step: "posts", Checkpoint: []byte("2"), ProgressAt: now.Add(-2 * time.Hour)}
	h.repo.seed(p)
	posts := &fakeStep{name: "posts", need: 4, log: h.log}
	graph := &fakeStep{name: "graph", need: 1, log: h.log}
	_ = h.l.RegisterEraser(BeforeIdentity, posts)
	_ = h.l.RegisterEraser(BeforeIdentity, graph)

	res, err := h.l.Backstop(context.Background())
	if err != nil || res.DeletionsRepublished != 1 {
		t.Fatalf("Backstop = %+v, %v", res, err)
	}
	h.drain(10)

	if _, ok := h.repo.user("u1"); ok {
		t.Fatal("the republished job did not finish the deletion")
	}
	if len(posts.cpSeen) == 0 || string(posts.cpSeen[0]) != "2" || posts.calls != 2 {
		t.Errorf("posts saw checkpoints %q over %d calls; want to resume from \"2\" in 2 calls", posts.cpSeen, posts.calls)
	}
	if n := h.log.count("auth.UpdateUser"); n != 0 {
		// Resuming at "posts" skips the Auth disable step that already ran before the checkpoint was saved.
		t.Errorf("Auth disable ran %d times on a resume past it, want 0", n)
	}
}

// TestBackstop_Boundaries: the no-progress age is inclusive at 1 h, the export give-up age inclusive at 24 h, a job
// that never saved state counts from the request, and a READY/FAILED export is left alone.
func TestBackstop_Boundaries(t *testing.T) {
	h := newHarness(t)
	now := h.clock.Now()
	neverSaved := h.seedDeleting("never", "Never", 90*time.Minute) // ProgressAt == requested
	_ = neverSaved
	at59 := h.seedDeleting("at59", "At59", 5*time.Hour)
	at59.DeletionJob = &DeletionJob{Seq: 1, ProgressAt: now.Add(-stuckAfter + time.Second)}
	h.repo.seed(at59)
	at60 := h.seedDeleting("at60", "At60", 5*time.Hour)
	at60.DeletionJob = &DeletionJob{Seq: 2, ProgressAt: now.Add(-stuckAfter)}
	h.repo.seed(at60)
	h.repo.exports["e59"] = &ExportDoc{ID: "e59", UID: "a", Status: ExportPending, CreatedAt: now.Add(-stuckAfter + time.Second), UpdateTime: utOf(1)}
	h.repo.exports["e60"] = &ExportDoc{ID: "e60", UID: "a", Status: ExportPending, CreatedAt: now.Add(-stuckAfter), UpdateTime: utOf(1)}
	h.repo.exports["e24"] = &ExportDoc{ID: "e24", UID: "a", Status: ExportPending, CreatedAt: now.Add(-exportFailAfter), UpdateTime: utOf(1)}
	h.repo.exports["ef"] = &ExportDoc{ID: "ef", UID: "a", Status: ExportFailed, CreatedAt: now.Add(-48 * time.Hour), UpdateTime: utOf(1)}

	res, err := h.l.Backstop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res != (BackstopResult{DeletionsRepublished: 2, ExportsRepublished: 1, ExportsFailed: 1}) {
		t.Errorf("result = %+v", res)
	}
	got := map[JobMessage]bool{}
	for _, m := range h.pub.msgs {
		got[m] = true
	}
	for _, want := range []JobMessage{
		{Kind: JobKindAccountDelete, UID: "never", Seq: 0},
		{Kind: JobKindAccountDelete, UID: "at60", Seq: 2},
		{Kind: JobKindAccountExport, ExportID: "e60"},
	} {
		if !got[want] {
			t.Errorf("missing %+v in %+v", want, h.pub.msgs)
		}
	}
	if len(got) != 3 || h.repo.exports["e24"].Status != ExportFailed || h.repo.exports["ef"].Status != ExportFailed || h.repo.exports["e59"].Status != ExportPending {
		t.Errorf("published %+v; e24=%s e59=%s", h.pub.msgs, h.repo.exports["e24"].Status, h.repo.exports["e59"].Status)
	}
	if h.log.count("auth.") != 0 {
		t.Error("the backstop called Firebase Auth")
	}
}

// TestExportJob_NoObjectLeftBehind (T10: "a DELETING user -> FAILED and no object", "a crash mid-write -> exactly
// one complete object"): every FAILED outcome also removes whatever object an earlier crashed attempt may have
// left under the deterministic path, and a failure to remove it keeps the job retrying instead of reporting FAILED.
func TestExportJob_NoObjectLeftBehind(t *testing.T) {
	stale := []byte(`{"exportVersion":1,"partial`)
	deliver := func(h *harness, doc ExportDoc) int {
		return h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1)
	}

	t.Run("DELETING user with a stale object from an earlier attempt", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Minute)
		doc := newPendingExport(h, "u1")
		h.objs.objects[doc.ObjectPath] = stale
		if code := deliver(h, doc); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("status %s, stale object present = %v", h.repo.exports[doc.ID].Status, ok)
		}
	})
	t.Run("vanished user with a stale object", func(t *testing.T) {
		h := newHarness(t)
		doc := newPendingExport(h, "ghost")
		h.objs.objects[doc.ObjectPath] = stale
		deliver(h, doc)
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("status %s, stale object present = %v", h.repo.exports[doc.ID].Status, ok)
		}
	})
	t.Run("expired export with a stale object", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.objs.objects[doc.ObjectPath] = stale
		h.clock.Advance(8 * 24 * time.Hour)
		deliver(h, doc)
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("status %s, stale object present = %v", h.repo.exports[doc.ID].Status, ok)
		}
	})
	t.Run("permanent section error: FAILED, partial object removed", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		_ = h.l.RegisterExportSection(fakeSection{name: "posts", err: fmt.Errorf("%w: unencodable value", errPermanent)})
		doc := newPendingExport(h, "u1")
		h.objs.objects[doc.ObjectPath] = stale
		if code := deliver(h, doc); code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204 (a permanent failure is not retried)", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("status %s, object present = %v", h.repo.exports[doc.ID].Status, ok)
		}
	})
	t.Run("object delete failure while failing the export retries and stays PENDING", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Minute)
		doc := newPendingExport(h, "u1")
		h.objs.delErr = errors.New("gcs down")
		if code := deliver(h, doc); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if h.repo.exports[doc.ID].Status != ExportPending {
			t.Errorf("status = %s, want PENDING (so the redelivery or backstop retries)", h.repo.exports[doc.ID].Status)
		}
		h.objs.delErr = nil
		if code := deliver(h, doc); code != http.StatusNoContent || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("retry: status %d, export %s", code, h.repo.exports[doc.ID].Status)
		}
	})
}

// TestExportJob_RefusesAnExportWithoutAUser: C1 for the export's Auth read. A PENDING export doc with no uid never
// reaches Firebase Auth or the bucket.
func TestExportJob_RefusesAnExportWithoutAUser(t *testing.T) {
	h := newHarness(t)
	doc := newPendingExport(h, "")
	if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	if h.log.count("auth.") != 0 || h.log.count("obj.") != 0 || h.repo.writes != 0 {
		t.Errorf("a uid-less export acted: %v", h.log.all())
	}
	if out := h.logs.String(); !strings.Contains(out, "auth_admin_refused") {
		t.Errorf("no auth_admin_refused line: %s", out)
	}
}

// TestGetAccountExport_BudgetOfEveryPath (Q6): every path, NOT_FOUND ones included, costs the one fresh read and no
// write, only a READY export of the owner is signed, and a malformed id costs no read at all.
func TestGetAccountExport_BudgetOfEveryPath(t *testing.T) {
	h := newHarness(t)
	id := expID("u1", expKey1)
	h.repo.exports[id] = &ExportDoc{ID: id, UID: "u1", Status: ExportReady, ObjectPath: id + ".json", ExpireAt: h.clock.Now().Add(time.Hour)}
	tests := []struct {
		name      string
		uid, id   string
		wantReads int
		wantSign  int
		wantErr   bool
	}{
		{"owner, READY: 1 read, 1 signature", "u1", id, 1, 1, false},
		{"another user: 1 read, no signature", "u2", id, 1, 0, true},
		{"unknown id: 1 read", "u1", strings.Repeat("e", 64), 1, 0, true},
		{"malformed id: 0 reads", "u1", "../x", 0, 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			readsBefore, signedBefore := h.repo.reads, len(h.objs.signed)
			_, err := h.l.GetAccountExport(context.Background(), tt.uid, tt.id)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v", err)
			}
			if got := h.repo.reads - readsBefore; got != tt.wantReads {
				t.Errorf("reads = %d, want %d", got, tt.wantReads)
			}
			if got := len(h.objs.signed) - signedBefore; got != tt.wantSign {
				t.Errorf("signatures = %d, want %d", got, tt.wantSign)
			}
			if h.repo.writes != 0 {
				t.Errorf("writes = %d, want 0", h.repo.writes)
			}
		})
	}
}

// TestRequestAccountExport_KeyBoundaries: the idempotency key convention (16-64 chars of [A-Za-z0-9_-]) at its edges,
// including multi-byte characters that a byte-length check would let through.
func TestRequestAccountExport_KeyBoundaries(t *testing.T) {
	tests := []struct {
		name string
		key  string
		ok   bool
	}{
		{"15 chars", strings.Repeat("a", 15), false},
		{"16 chars", strings.Repeat("a", 16), true},
		{"64 chars", strings.Repeat("a", 64), true},
		{"65 chars", strings.Repeat("a", 65), false},
		{"underscore and dash", "key_with-dash_0123", true},
		{"space", "key with space 0123", false},
		{"slash (path injection)", "../../etc/passwd-0123", false},
		{"emoji (16 runes, 19 bytes)", strings.Repeat("a", 15) + "😀", false},
		{"RTL text", "مفتاح-مفتاح-مفتاح-مفتاح", false},
		{"empty", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			h.seedActive("u1", "Alice")
			_, errExport := h.l.RequestAccountExport(context.Background(), "u1", tt.key)
			_, errDelete := h.l.DeleteAccount(context.Background(), "u1", tt.key)
			if (errExport == nil) != tt.ok || (errDelete == nil) != tt.ok {
				t.Errorf("export err = %v, delete err = %v, want ok=%v", errExport, errDelete, tt.ok)
			}
		})
	}
}

// TestExportJob_AuthRecord: the export's `account` section needs Firebase Auth. An Auth outage retries the job
// without leaving an object; a user whose Auth record is already gone still gets a complete file with an empty
// account section instead of a FAILED export.
func TestExportJob_AuthRecord(t *testing.T) {
	t.Run("Auth outage retries and leaves nothing", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.auth.err["GetUser"] = errors.New("identity toolkit unavailable")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportPending || h.repo.writes != 1 {
			t.Errorf("object present = %v, status %s, writes %d (want only the lease claim)", ok, h.repo.exports[doc.ID].Status, h.repo.writes)
		}
		delete(h.auth.err, "GetUser")
		h.clock.Advance(61 * time.Second) // Pub/Sub's minimum backoff: the 35 s lease has expired
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 2); code != http.StatusNoContent || h.repo.exports[doc.ID].Status != ExportReady {
			t.Errorf("retry: status %d, export %s", code, h.repo.exports[doc.ID].Status)
		}
	})
	t.Run("a missing Auth record still exports", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.auth.missing = true
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		raw, ok := h.objs.get(doc.ObjectPath)
		if !ok || h.repo.exports[doc.ID].Status != ExportReady {
			t.Fatalf("object present = %v, status %s", ok, h.repo.exports[doc.ID].Status)
		}
		if e := parseExport(t, raw); e.Account["providers"] == nil || e.Account["email"] != nil {
			t.Errorf("account = %v, want an empty record with providers []", e.Account)
		}
	})
}
