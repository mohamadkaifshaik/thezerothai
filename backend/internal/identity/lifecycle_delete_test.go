package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const delKey = "0123456789abcdef" // a valid 16-char idempotency key

func TestStartGate(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name     string
		p        Profile
		wantWait time.Duration
		wantErr  bool
	}{
		{"just requested", Profile{Status: AccountStatusDeleting, DeletionRequestedAt: now}, 120 * time.Second, false},
		{"60 s in", Profile{Status: AccountStatusDeleting, DeletionRequestedAt: now.Add(-60 * time.Second)}, 60 * time.Second, false},
		{"exactly 120 s", Profile{Status: AccountStatusDeleting, DeletionRequestedAt: now.Add(-120 * time.Second)}, 0, false},
		{"long ago", Profile{Status: AccountStatusDeleting, DeletionRequestedAt: now.Add(-time.Hour)}, 0, false},
		{"checkpoint writes never move the clock: updatedAt is ignored when deletionRequestedAt is set",
			Profile{Status: AccountStatusDeleting, DeletionRequestedAt: now.Add(-time.Hour), UpdatedAt: now}, 0, false},
		{"set by hand: updatedAt is the fallback", Profile{Status: AccountStatusDeleting, UpdatedAt: now.Add(-30 * time.Second)}, 90 * time.Second, false},
		{"active", Profile{Status: AccountStatusActive, DeletionRequestedAt: now.Add(-time.Hour)}, 0, true},
		{"suspended", Profile{Status: AccountStatusSuspended}, 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			wait, err := StartGate(tt.p, now)
			if (err != nil) != tt.wantErr || wait != tt.wantWait {
				t.Errorf("StartGate = %v, %v; want %v, err=%v", wait, err, tt.wantWait, tt.wantErr)
			}
		})
	}
}

func TestDeleteAccount(t *testing.T) {
	t.Run("active user: DELETING, job state, one publish, cache updated, 1 write", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		h.cache.SetProfile(Profile{UserID: "u1", Status: AccountStatusActive})
		at, err := h.l.DeleteAccount(context.Background(), "u1", delKey)
		if err != nil {
			t.Fatalf("DeleteAccount: %v", err)
		}
		p, _ := h.repo.user("u1")
		if p.Status != AccountStatusDeleting || p.DeletionJob == nil || p.DeletionJob.Seq != 0 || !p.DeletionRequestedAt.Equal(at) || !at.Equal(h.clock.Now().UTC()) {
			t.Errorf("profile = %+v, requestedAt = %v", p, at)
		}
		if h.repo.writes != 1 || h.repo.reads != 1 {
			t.Errorf("reads/writes = %d/%d, want 1/1", h.repo.reads, h.repo.writes)
		}
		if h.pub.count() != 1 || h.pub.msgs[0] != (JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}) {
			t.Errorf("published = %+v", h.pub.msgs)
		}
		if c, ok := h.cache.GetProfile("u1"); !ok || c.Status != AccountStatusDeleting {
			t.Errorf("instance cache = %+v, %v; want DELETING (this instance must reject the uid at once)", c, ok)
		}
	})

	t.Run("deletion_requested_at has Firestore's microsecond precision, so a replay returns the same value", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		h.clock.Advance(123456789 * time.Nanosecond)
		at, err := h.l.DeleteAccount(context.Background(), "u1", delKey)
		if err != nil || !at.Equal(at.Truncate(time.Microsecond)) {
			t.Errorf("requestedAt = %v (%v), want microsecond precision", at, err)
		}
	})

	t.Run("suspended user may delete (Q3)", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		p.Status = AccountStatusSuspended
		h.repo.seed(p)
		if _, err := h.l.DeleteAccount(context.Background(), "u1", delKey); err != nil {
			t.Fatalf("DeleteAccount: %v", err)
		}
		if got, _ := h.repo.user("u1"); got.Status != AccountStatusDeleting {
			t.Errorf("status = %v, want DELETING", got.Status)
		}
	})

	t.Run("replay: same requestedAt, 0 writes, re-publishes the current seq", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		first, _ := h.l.DeleteAccount(context.Background(), "u1", delKey)
		h.clock.Advance(time.Minute)
		// Pretend the job already advanced to seq 3.
		h.repo.mu.Lock()
		h.repo.users["u1"].p.DeletionJob.Seq = 3
		h.repo.mu.Unlock()
		writes := h.repo.writes
		again, err := h.l.DeleteAccount(context.Background(), "u1", "another-key-0123456")
		if err != nil {
			t.Fatalf("replay: %v", err)
		}
		if !again.Equal(first) || h.repo.writes != writes {
			t.Errorf("replay requestedAt = %v (first %v), writes %d -> %d", again, first, writes, h.repo.writes)
		}
		last := h.pub.msgs[len(h.pub.msgs)-1]
		if last.Seq != 3 {
			t.Errorf("replay published seq %d, want the current seq 3", last.Seq)
		}
	})

	t.Run("publish failure still succeeds and logs an Error Reporting entry without the uid", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		h.pub.err = errors.New("pubsub down")
		if _, err := h.l.DeleteAccount(context.Background(), "u1", delKey); err != nil {
			t.Fatalf("DeleteAccount must succeed on a publish failure: %v", err)
		}
		out := h.logs.String()
		if !strings.Contains(out, "account_delete_enqueue_failed") || !strings.Contains(out, "ReportedErrorEvent") || strings.Contains(out, `"u1"`) {
			t.Errorf("log = %s", out)
		}
	})

	t.Run("validation and not found", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.l.DeleteAccount(context.Background(), "u1", "short"); err == nil {
			t.Error("bad idempotency key accepted")
		}
		_, err := h.l.DeleteAccount(context.Background(), "ghost", delKey)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound {
			t.Errorf("unknown profile: err = %v, want NOT_FOUND", err)
		}
		if h.pub.count() != 0 || h.repo.writes != 0 {
			t.Error("a rejected call published or wrote")
		}
	})

	t.Run("repo failure is internal and carries no raw uid", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("secret-uid-1", "Alice")
		h.repo.failOnce["BeginDeletion"] = errors.New("boom for secret-uid-1")
		_, err := h.l.DeleteAccount(context.Background(), "secret-uid-1", delKey)
		if err == nil || strings.Contains(err.Error(), "secret-uid-1") {
			t.Errorf("err = %v, want a redacted error", err)
		}
	})
}

// TestJobs_ReferenceChain runs a whole deletion through the push handler with the fakes: the gate nacks the first
// delivery, a slow step needs several 20 s slices with its checkpoint carried between them, and the order of
// every side effect is the ADR-0011 Q1 order with users/{uid} last.
func TestJobs_ReferenceChain(t *testing.T) {
	h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = 25 * time.Second })
	h.seedActive("u1", "Alice")
	h.repo.private["u1"] = 3
	h.repo.exports["e1"] = &ExportDoc{ID: "e1", UID: "u1", Status: ExportReady, ObjectPath: "e1.json", UpdateTime: utOf(1)}
	h.objs.objects["e1.json"] = []byte("{}")
	posts := &fakeStep{name: "posts", need: 7, clock: h.clock, tick: 10 * time.Second, log: h.log}
	graph := &fakeStep{name: "graph", need: 2, clock: h.clock, tick: 10 * time.Second, log: h.log}
	for _, s := range []StepEraser{posts, graph} {
		if err := h.l.RegisterEraser(BeforeIdentity, s); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.l.DeleteAccount(context.Background(), "u1", delKey); err != nil {
		t.Fatal(err)
	}

	gated := h.drain(40)

	if gated != 2 {
		t.Errorf("gated deliveries = %d, want 2 (60 s and 122 s: the 120 s gate passes on delivery 3, ADR-0011 \"1-2 nacks\")", gated)
	}
	if _, ok := h.repo.user("u1"); ok {
		t.Fatal("users/u1 still exists after the chain")
	}
	if len(h.repo.exports) != 0 || len(h.objs.objects) != 0 || len(h.repo.handles) != 0 || len(h.repo.quotas) != 0 || h.repo.private["u1"] != 0 {
		t.Errorf("leftovers: exports=%v objects=%v handles=%v quotas=%v private=%d", h.repo.exports, h.objs.objects, h.repo.handles, h.repo.quotas, h.repo.private["u1"])
	}
	if posts.calls != 7 || graph.calls != 2 {
		t.Errorf("step calls posts=%d graph=%d, want 7 and 2", posts.calls, graph.calls)
	}
	// The checkpoint of the slow step was carried across invocations: calls 2..7 saw "1".."6".
	for i, cp := range posts.cpSeen {
		want := ""
		if i > 0 {
			want = string(rune('0' + i))
		}
		if string(cp) != want {
			t.Errorf("posts call %d got checkpoint %q, want %q", i+1, cp, want)
		}
	}
	// Q1 order: Auth disable, posts, graph, identity (object before doc), Auth delete, users/{uid} last.
	order := []string{"auth.UpdateUser", "step.posts call=1", "step.posts call=7", "step.graph call=1", "step.graph call=2",
		"obj.Delete", "repo.DeleteExportDocs n=1", "repo.DeleteHandle", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}
	last := -1
	for _, op := range order {
		i := h.log.index(op)
		if i < 0 || i < last {
			t.Fatalf("op %q at %d (previous at %d); log = %v", op, i, last, h.log.all())
		}
		last = i
	}
	ops := h.log.all()
	if ops[len(ops)-1] != "repo.DeleteUserDoc" {
		t.Errorf("last op = %q, want users/{uid} delete (the backstop's marker stays until everything else is gone)", ops[len(ops)-1])
	}
	// Auth disable ran on the gated delivery before any eraser.
	if h.log.index("auth.UpdateUser") > h.log.index("step.posts call=1") {
		t.Error("the Auth user was not disabled before the first eraser")
	}
	// Four-ish invocations: gated + ceil(11 calls / 3 per slice); never one publish per call.
	if n := h.log.count("pub account_delete"); n < 4 || n > 6 {
		t.Errorf("publishes = %d, want about 4-6 (one per slice)", n)
	}
}

func TestJobs_Gate(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("u1", "Alice", 60*time.Second)
	step := &fakeStep{name: "posts", need: 1, log: h.log}
	_ = h.l.RegisterEraser(BeforeIdentity, step)

	code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1)
	if code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 inside the 120 s gate", code)
	}
	if step.calls != 0 || h.repo.writes != 0 || h.repo.deletes != 0 {
		t.Errorf("gated delivery erased: step calls %d, writes %d, deletes %d", step.calls, h.repo.writes, h.repo.deletes)
	}
	if h.log.count("auth.UpdateUser") != 1 || h.log.count("auth.RevokeRefreshTokens") != 1 {
		t.Errorf("gated delivery must disable the Auth user and revoke tokens once: %v", h.log.all())
	}
	if h.repo.reads != 1 {
		t.Errorf("reads = %d, want only the job-state read", h.repo.reads)
	}
	h.clock.Advance(61 * time.Second)
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 2); code != http.StatusNoContent {
		t.Fatalf("status after the gate = %d, want 204", code)
	}
	if step.calls != 1 {
		t.Errorf("step calls after the gate = %d, want 1", step.calls)
	}
}

// TestJobs_SeqDedupe covers every relation between the message seq and the saved seq.
func TestJobs_SeqDedupe(t *testing.T) {
	tests := []struct {
		name        string
		stateSeq    int64
		msgSeq      int64
		wantRepub   int64 // -1 = no publish
		wantStepRun bool
	}{
		{"current seq works", 4, 4, 5, true}, // 1 step call (need 5, not done) -> saves 5 and publishes it
		{"previous seq re-publishes the saved one", 4, 3, 4, false},
		{"older seq is dropped", 4, 2, -1, false},
		{"far older seq is dropped", 9, 0, -1, false},
		{"future seq is dropped", 4, 5, -1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
			p := h.seedDeleting("u1", "Alice", time.Hour)
			p.DeletionJob = &DeletionJob{Seq: tt.stateSeq, Step: "posts"}
			h.repo.seed(p)
			step := &fakeStep{name: "posts", need: 5, log: h.log, clock: h.clock, tick: time.Second}
			_ = h.l.RegisterEraser(BeforeIdentity, step)

			if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: tt.msgSeq}, 1); code != http.StatusNoContent {
				t.Fatalf("status = %d, want 204", code)
			}
			if (step.calls > 0) != tt.wantStepRun {
				t.Errorf("step ran = %v, want %v", step.calls > 0, tt.wantStepRun)
			}
			if tt.wantRepub < 0 {
				if h.pub.count() != 0 {
					t.Errorf("published %+v, want nothing", h.pub.msgs)
				}
				return
			}
			if h.pub.count() != 1 || h.pub.msgs[0].Seq != tt.wantRepub {
				t.Errorf("published %+v, want one message with seq %d", h.pub.msgs, tt.wantRepub)
			}
			if !tt.wantStepRun && h.repo.writes != 0 {
				t.Errorf("a duplicate wrote %d times", h.repo.writes)
			}
		})
	}
}

// TestJobs_ConcurrentSameSeq: two deliveries of the same message race; both may work (the erasers are
// precondition-safe) but exactly one advances the state and publishes the continuation.
func TestJobs_ConcurrentSameSeq(t *testing.T) {
	h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
	h.seedDeleting("u1", "Alice", time.Hour)
	var arrived sync.WaitGroup
	arrived.Add(2)
	release := make(chan struct{})
	step := &fakeStep{name: "posts", need: 10, log: h.log, clock: h.clock, tick: time.Second, gate: func() {
		arrived.Done()
		<-release
	}}
	_ = h.l.RegisterEraser(BeforeIdentity, step)

	// The first step is auth_disable, so move the saved step to the slow one to make both run it.
	p, _ := h.repo.user("u1")
	p.DeletionJob = &DeletionJob{Seq: 0, Step: "posts"}
	h.repo.seed(p)

	var wg sync.WaitGroup
	codes := make([]int, 2)
	for i := range codes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i] = h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1)
		}()
	}
	arrived.Wait()
	close(release)
	wg.Wait()

	for i, c := range codes {
		if c != http.StatusNoContent {
			t.Errorf("delivery %d = %d, want 204", i, c)
		}
	}
	if h.pub.count() != 1 || h.pub.msgs[0].Seq != 1 {
		t.Errorf("published %+v, want exactly one continuation with seq 1", h.pub.msgs)
	}
	if got, _ := h.repo.user("u1"); got.DeletionJob.Seq != 1 {
		t.Errorf("saved seq = %d, want 1", got.DeletionJob.Seq)
	}
}

// TestJobs_SaveSurvivesAnUnrelatedWrite: another account's purge decrementing this user's counters changes the
// document between the read and the save; the job must not stall (that would strand the deletion).
func TestJobs_SaveSurvivesAnUnrelatedWrite(t *testing.T) {
	h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
	h.seedDeleting("u1", "Alice", time.Hour)
	step := &fakeStep{name: "posts", need: 10, log: h.log, clock: h.clock, tick: time.Second, gate: func() { h.repo.touch("u1") }}
	_ = h.l.RegisterEraser(BeforeIdentity, step)
	p, _ := h.repo.user("u1")
	p.DeletionJob = &DeletionJob{Seq: 0, Step: "posts"}
	h.repo.seed(p)

	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	if h.pub.count() != 1 || h.pub.msgs[0].Seq != 1 {
		t.Errorf("published %+v, want the continuation despite the unrelated write", h.pub.msgs)
	}
}

func TestJobs_SaveConflict(t *testing.T) {
	newCase := func(t *testing.T) *harness {
		h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
		h.seedDeleting("u1", "Alice", time.Hour)
		_ = h.l.RegisterEraser(BeforeIdentity, &fakeStep{name: "posts", need: 10, log: h.log, clock: h.clock, tick: time.Second})
		p, _ := h.repo.user("u1")
		p.DeletionJob = &DeletionJob{Seq: 0, Step: "posts"}
		h.repo.seed(p)
		return h
	}
	t.Run("one lost precondition is retried after a re-read", func(t *testing.T) {
		h := newCase(t)
		h.repo.failOnce["SaveJobState"] = ErrJobConflict
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", code)
		}
		if h.pub.count() != 1 || h.pub.msgs[0].Seq != 1 {
			t.Errorf("published %+v, want seq 1", h.pub.msgs)
		}
	})
	t.Run("endless conflicts give up and retry the delivery", func(t *testing.T) {
		h := newCase(t)
		h.repo.failOnce["SaveJobState"] = ErrJobConflict
		h.repo.failFor["SaveJobState"] = 100
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if h.repo.calls["SaveJobState"] != saveRetries || h.pub.count() != 0 {
			t.Errorf("save attempts %d, publishes %d", h.repo.calls["SaveJobState"], h.pub.count())
		}
	})
	t.Run("the user erased by a concurrent delivery shows as a lost precondition, then a duplicate", func(t *testing.T) {
		h := newCase(t)
		h.l.erasers[0].(*fakeStep).gate = func() {
			h.repo.mu.Lock()
			delete(h.repo.users, "u1")
			h.repo.mu.Unlock()
		}
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent || h.pub.count() != 0 {
			t.Errorf("status %d publishes %d", code, h.pub.count())
		}
	})
	t.Run("the user vanishing mid-save is a duplicate", func(t *testing.T) {
		h := newCase(t)
		h.repo.failOnce["SaveJobState"] = ErrNotFound
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent || h.pub.count() != 0 {
			t.Errorf("status %d publishes %d", code, h.pub.count())
		}
	})
}

// TestJobs_Refusal is IAM control C1: a job message never makes a user deletable. Whatever the message says, a
// uid whose own document is not DELETING-by-DeleteAccount gets no Auth call and no erasure, and the refusal is an
// ERROR line that carries no raw uid.
func TestJobs_Refusal(t *testing.T) {
	deletingNoJob := Profile{UserID: "victim-uid", Status: AccountStatusDeleting}
	tests := []struct {
		name string
		p    Profile
	}{
		{"active", Profile{UserID: "victim-uid", Status: AccountStatusActive}},
		{"suspended", Profile{UserID: "victim-uid", Status: AccountStatusSuspended}},
		{"DELETING set by hand without a request", deletingNoJob},
		{"DELETING with a request but no job state", Profile{UserID: "victim-uid", Status: AccountStatusDeleting, DeletionRequestedAt: time.Now()}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			h.repo.seed(tt.p)
			step := &fakeStep{name: "posts", need: 1, log: h.log}
			_ = h.l.RegisterEraser(BeforeIdentity, step)

			code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "victim-uid", Seq: 0}, 1)

			if code != http.StatusNoContent {
				t.Errorf("status = %d, want 204 (ack: a refused job must not retry)", code)
			}
			if n := h.log.count("auth."); n != 0 {
				t.Errorf("%d Auth calls for a refused job", n)
			}
			if step.calls != 0 || h.repo.writes != 0 || h.repo.deletes != 0 || h.pub.count() != 0 {
				t.Errorf("a refused job acted: steps %d writes %d deletes %d publishes %d", step.calls, h.repo.writes, h.repo.deletes, h.pub.count())
			}
			if _, ok := h.repo.user("victim-uid"); !ok {
				t.Error("the user document was deleted")
			}
			out := h.logs.String()
			if !strings.Contains(out, `"level":"ERROR"`) || !strings.Contains(out, "auth_admin_refused") {
				t.Errorf("no ERROR auth_admin_refused line: %s", out)
			}
			if strings.Contains(out, "victim-uid") {
				t.Errorf("the refusal logged a raw uid: %s", out)
			}
		})
	}
}

func TestJobs_MissingUserAcksQuietly(t *testing.T) {
	h := newHarness(t)
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "gone", Seq: 3}, 1); code != http.StatusNoContent {
		t.Fatalf("status = %d", code)
	}
	if strings.Contains(h.logs.String(), `"level":"ERROR"`) || h.log.count("auth.") != 0 || h.repo.reads != 1 {
		t.Errorf("a finished deletion's redelivery must cost one read and make no noise: reads=%d log=%s", h.repo.reads, h.logs.String())
	}
}

// TestJobs_StepErrors: transient errors are retried inside the delivery; five in a row fail it (500) without
// saving anything, and the next delivery resumes.
func TestJobs_StepErrors(t *testing.T) {
	boom := errors.New("firestore unavailable")
	t.Run("two errors then success in one delivery", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		step := &fakeStep{name: "posts", need: 1, log: h.log, errs: map[int]error{1: boom, 2: boom}}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", code)
		}
		if step.calls != 3 {
			t.Errorf("step calls = %d, want 3 (2 failures + 1 success)", step.calls)
		}
		if _, ok := h.repo.user("u1"); ok {
			t.Error("the deletion did not complete")
		}
	})
	t.Run("five errors fail the delivery without saving", func(t *testing.T) {
		h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
		h.seedDeleting("u1", "Alice", time.Hour)
		step := &fakeStep{name: "posts", need: 1, log: h.log, errs: map[int]error{1: boom, 2: boom, 3: boom, 4: boom, 5: boom}}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		p, _ := h.repo.user("u1")
		p.DeletionJob = &DeletionJob{Seq: 0, Step: "posts"}
		h.repo.seed(p)

		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500 so Pub/Sub retries with backoff", code)
		}
		if step.calls != 5 || h.repo.writes != 0 || h.pub.count() != 0 {
			t.Errorf("calls %d writes %d publishes %d; want 5, 0, 0", step.calls, h.repo.writes, h.pub.count())
		}
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 2); code != http.StatusNoContent {
			t.Fatalf("redelivery status = %d, want 204", code)
		}
		if _, ok := h.repo.user("u1"); ok {
			t.Error("the redelivery did not finish the deletion")
		}
	})
	t.Run("an error on the last attempt is reported, earlier ones only warn", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Hour)
		h.repo.failOnce["GetJobState"] = boom
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 3); code != http.StatusInternalServerError {
			t.Fatalf("status = %d", code)
		}
		if strings.Contains(h.logs.String(), "ReportedErrorEvent") {
			t.Error("attempt 3 reported an error to Error Reporting")
		}
		h.repo.failOnce["GetJobState"] = boom
		h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, maxDeliveryAttempts)
		if !strings.Contains(h.logs.String(), "ReportedErrorEvent") {
			t.Error("the last attempt did not reach Error Reporting")
		}
	})
	t.Run("a publish failure of the continuation retries and the redelivery re-publishes it", func(t *testing.T) {
		h := newHarness(t, func(d *LifecycleDeps) { d.WorkBudget = time.Millisecond })
		h.seedDeleting("u1", "Alice", time.Hour)
		step := &fakeStep{name: "posts", need: 10, log: h.log, clock: h.clock, tick: time.Second}
		_ = h.l.RegisterEraser(BeforeIdentity, step)
		p, _ := h.repo.user("u1")
		p.DeletionJob = &DeletionJob{Seq: 0, Step: "posts"}
		h.repo.seed(p)
		h.pub.err = errors.New("pubsub down")
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if got, _ := h.repo.user("u1"); got.DeletionJob.Seq != 1 {
			t.Fatalf("state was not saved before the publish: seq %d", got.DeletionJob.Seq)
		}
		h.pub.err = nil
		callsBefore := step.calls
		if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 2); code != http.StatusNoContent {
			t.Fatalf("redelivery = %d", code)
		}
		if h.pub.count() != 1 || h.pub.msgs[0].Seq != 1 || step.calls != callsBefore {
			t.Errorf("redelivery published %+v with %d extra step calls; want just seq 1", h.pub.msgs, step.calls-callsBefore)
		}
	})
}

// TestJobs_FlagAndDegradedModeDoNotGate (Q8, Q9): the handler has no flag or degraded-mode input at all, so a
// DELETING account finishes with the account_lifecycle flag off. The harness builds the Lifecycle with neither.
func TestJobs_NeverGated(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("u1", "Alice", time.Hour)
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusNoContent {
		t.Fatalf("status = %d", code)
	}
	if _, ok := h.repo.user("u1"); ok {
		t.Error("in-flight deletion did not complete")
	}
}

func TestJobs_UnknownSavedStep(t *testing.T) {
	h := newHarness(t)
	p := h.seedDeleting("u1", "Alice", time.Hour)
	p.DeletionJob = &DeletionJob{Seq: 0, Step: "a_step_that_was_removed"}
	h.repo.seed(p)
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 (an unknown saved step must not silently restart)", code)
	}
}

func TestJobs_HandlerEdgeCases(t *testing.T) {
	tests := []struct {
		name string
		body string
		want int
	}{
		{"not an envelope", "nope", http.StatusNoContent},
		{"not a job message", envelope("just a string", 1), http.StatusNoContent},
		{"unknown kind", envelope(map[string]any{"kind": "p2_refresh", "uid": "u1"}, 1), http.StatusNoContent},
		{"delete with an invalid uid", envelope(JobMessage{Kind: JobKindAccountDelete, UID: "bad_uid/../x", Seq: 0}, 1), http.StatusNoContent},
		{"delete with a negative seq", envelope(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: -1}, 1), http.StatusNoContent},
		{"export with a bad id", envelope(JobMessage{Kind: JobKindAccountExport, ExportID: "nope"}, 1), http.StatusNoContent},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			if got := h.deliverRaw(tt.body); got != tt.want {
				t.Errorf("status = %d, want %d", got, tt.want)
			}
			if h.repo.reads != 0 || h.repo.writes != 0 || h.log.count("auth.") != 0 {
				t.Error("an invalid message touched Firestore or Auth")
			}
		})
	}
	t.Run("GET is rejected", func(t *testing.T) {
		h := newHarness(t)
		rec := newRecorder()
		h.l.JobsHandler().ServeHTTP(rec, newRequest(http.MethodGet))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("status = %d", rec.Code)
		}
	})
}

func TestRegistry(t *testing.T) {
	h := newHarness(t)
	step := func(n string) StepEraser { return &fakeStep{name: n, need: 1, log: h.log} }
	tests := []struct {
		name    string
		pos     Position
		step    StepEraser
		wantErr string
	}{
		{"ok", BeforeIdentity, step("media"), ""},
		{"after identity is a startup error", AfterIdentity, step("late"), "BeforeIdentity"},
		{"zero position", 0, step("zero"), "BeforeIdentity"},
		{"duplicate", BeforeIdentity, step("media"), "twice"},
		{"reserved identity", BeforeIdentity, step("identity"), "reserved"},
		{"reserved auth_delete", BeforeIdentity, step("auth_delete"), "reserved"},
		{"reserved users_doc", BeforeIdentity, step("users_doc"), "reserved"},
		{"empty", BeforeIdentity, step(""), "reserved"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := h.l.RegisterEraser(tt.pos, tt.step)
			if tt.wantErr == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("err = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
	t.Run("registration after the first job is refused", func(t *testing.T) {
		h := newHarness(t)
		h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "nobody", Seq: 0}, 1) // seals on dispatch
		h.seedDeleting("u1", "Alice", time.Hour)
		h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1)
		if err := h.l.RegisterEraser(BeforeIdentity, step("late")); err == nil {
			t.Error("a step registered after the first running job was accepted")
		}
		if err := h.l.RegisterExportSection(fakeSection{name: "late", json: "1"}); err == nil {
			t.Error("a section registered after the first running job was accepted")
		}
	})
	t.Run("section names", func(t *testing.T) {
		h := newHarness(t)
		for _, n := range []string{"", "account", "profile", "exportVersion", "generatedAt"} {
			if err := h.l.RegisterExportSection(fakeSection{name: n}); err == nil {
				t.Errorf("section %q accepted", n)
			}
		}
		if err := h.l.RegisterExportSection(fakeSection{name: "posts"}); err != nil {
			t.Fatal(err)
		}
		if err := h.l.RegisterExportSection(fakeSection{name: "posts"}); err == nil {
			t.Error("duplicate section accepted")
		}
	})
}

func TestNewLifecycle_Validation(t *testing.T) {
	h := newHarness(t)
	good := LifecycleDeps{Repo: h.repo, Cache: h.cache, Publisher: h.pub, Auth: h.auth, ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute}
	if _, err := NewLifecycle(good); err != nil {
		t.Fatalf("valid deps: %v", err)
	}
	for name, mutate := range map[string]func(*LifecycleDeps){
		"no repo":      func(d *LifecycleDeps) { d.Repo = nil },
		"no cache":     func(d *LifecycleDeps) { d.Cache = nil },
		"no publisher": func(d *LifecycleDeps) { d.Publisher = nil },
		"no auth":      func(d *LifecycleDeps) { d.Auth = nil },
		"no retention": func(d *LifecycleDeps) { d.ExportRetention = 0 },
		"no url ttl":   func(d *LifecycleDeps) { d.ExportURLTTL = 0 },
		"no quota":     func(d *LifecycleDeps) { d.ExportsPerDay = 0 },
	} {
		d := good
		mutate(&d)
		if _, err := NewLifecycle(d); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

// TestIdentityStep: exports go object-first, a handle owned by someone else is left alone with a WARN, and full
// pages ask for another call.
func TestIdentityStep(t *testing.T) {
	t.Run("handle owned by another uid is left alone", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		h.repo.handles[p.HandleLower] = "someone-else"
		if _, done, err := h.l.identityStep(context.Background(), p, &jobStats{}); err != nil || !done {
			t.Fatalf("identityStep = %v, %v", done, err)
		}
		if h.repo.handles[p.HandleLower] != "someone-else" {
			t.Error("another user's handle was deleted")
		}
		if len(h.logs.records("handle_owner_mismatch")) != 1 {
			t.Errorf("no WARN handle_owner_mismatch: %s", h.logs.String())
		}
	})
	t.Run("a full page of exports asks for another call", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		for i := range identityExportsPage + 1 {
			id := string(rune('a'+i%26)) + string(rune('a'+i/26))
			h.repo.exports[id] = &ExportDoc{ID: id, UID: "u1", ObjectPath: id + ".json"}
		}
		_, done, err := h.l.identityStep(context.Background(), p, &jobStats{})
		if err != nil || done {
			t.Fatalf("first call: done=%v err=%v, want not done", done, err)
		}
		if _, done, err = h.l.identityStep(context.Background(), p, &jobStats{}); err != nil || !done {
			t.Fatalf("second call: done=%v err=%v, want done", done, err)
		}
		if len(h.repo.exports) != 0 {
			t.Errorf("%d exports left", len(h.repo.exports))
		}
	})
	t.Run("a full page of private docs asks for another call", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		h.repo.private["u1"] = identityPrivatePage + 1
		if _, done, _ := h.l.identityStep(context.Background(), p, &jobStats{}); done {
			t.Fatal("done with private docs left")
		}
		if _, done, _ := h.l.identityStep(context.Background(), p, &jobStats{}); !done || h.repo.private["u1"] != 0 {
			t.Fatalf("done=%v private=%d", done, h.repo.private["u1"])
		}
	})
	t.Run("object delete failure stops before the doc is deleted", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		h.repo.exports["e1"] = &ExportDoc{ID: "e1", UID: "u1", ObjectPath: "e1.json"}
		h.objs.delErr = errors.New("gcs down")
		if _, _, err := h.l.identityStep(context.Background(), p, &jobStats{}); err == nil {
			t.Fatal("want error")
		}
		if len(h.repo.exports) != 1 {
			t.Error("the export doc was deleted while its object still exists: a crash would orphan the object")
		}
	})
}

// TestBackstop: it only re-sends messages the handler validates; it recovers stuck work and gives up old exports.
func TestBackstop(t *testing.T) {
	h := newHarness(t)
	now := h.clock.Now()
	stuck := h.seedDeleting("stuck", "Stuck", 3*time.Hour)
	stuck.DeletionJob = &DeletionJob{Seq: 7, ProgressAt: now.Add(-2 * time.Hour)}
	h.repo.seed(stuck)
	fresh := h.seedDeleting("fresh", "Fresh", 10*time.Minute)
	fresh.DeletionJob = &DeletionJob{Seq: 2, ProgressAt: now.Add(-time.Minute)}
	h.repo.seed(fresh)
	h.repo.seed(Profile{UserID: "byhand", HandleLower: "byhand", Status: AccountStatusDeleting}) // no job state
	h.seedActive("active", "Active")
	h.repo.exports["pend-old"] = &ExportDoc{ID: "pend-old", UID: "a", Status: ExportPending, CreatedAt: now.Add(-25 * time.Hour), UpdateTime: utOf(1)}
	h.repo.exports["pend-mid"] = &ExportDoc{ID: "pend-mid", UID: "a", Status: ExportPending, CreatedAt: now.Add(-2 * time.Hour), UpdateTime: utOf(1)}
	h.repo.exports["pend-new"] = &ExportDoc{ID: "pend-new", UID: "a", Status: ExportPending, CreatedAt: now.Add(-time.Minute), UpdateTime: utOf(1)}
	h.repo.exports["ready"] = &ExportDoc{ID: "ready", UID: "a", Status: ExportReady, CreatedAt: now.Add(-48 * time.Hour), UpdateTime: utOf(1)}

	res, err := h.l.Backstop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res != (BackstopResult{DeletionsRepublished: 1, ExportsRepublished: 1, ExportsFailed: 1}) {
		t.Errorf("result = %+v", res)
	}
	got := map[JobMessage]bool{}
	for _, m := range h.pub.msgs {
		got[m] = true
	}
	if !got[JobMessage{Kind: JobKindAccountDelete, UID: "stuck", Seq: 7}] || !got[JobMessage{Kind: JobKindAccountExport, ExportID: "pend-mid"}] || len(got) != 2 {
		t.Errorf("published %+v", h.pub.msgs)
	}
	if h.repo.exports["pend-old"].Status != ExportFailed || h.repo.exports["pend-new"].Status != ExportPending {
		t.Error("export states wrong")
	}
	if h.log.count("auth.") != 0 {
		t.Error("the backstop must never call Firebase Auth")
	}
}

func TestBackstop_Errors(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("stuck", "Stuck", 3*time.Hour)
	p, _ := h.repo.user("stuck")
	p.DeletionJob = &DeletionJob{Seq: 1, ProgressAt: h.clock.Now().Add(-2 * time.Hour)}
	h.repo.seed(p)
	h.pub.err = errors.New("down")
	if _, err := h.l.Backstop(context.Background()); err == nil || strings.Contains(err.Error(), "stuck") && strings.Contains(err.Error(), "uid=") {
		t.Errorf("err = %v, want a publish error", err)
	}
}

func TestCronHandler(t *testing.T) {
	h := newHarness(t)
	rec := newRecorder()
	h.l.CronHandler().ServeHTTP(rec, newRequest(http.MethodPost))
	if rec.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", rec.Code)
	}
	if len(h.logs.records("account_job")) != 1 {
		t.Errorf("want one account_job line: %s", h.logs.String())
	}
	rec = newRecorder()
	h.l.CronHandler().ServeHTTP(rec, newRequest(http.MethodGet))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET status = %d", rec.Code)
	}
	h.pub.err = errors.New("down")
	h.seedDeleting("stuck", "Stuck", 3*time.Hour)
	p, _ := h.repo.user("stuck")
	p.DeletionJob = &DeletionJob{Seq: 1, ProgressAt: h.clock.Now().Add(-2 * time.Hour)}
	h.repo.seed(p)
	rec = newRecorder()
	h.l.CronHandler().ServeHTTP(rec, newRequest(http.MethodPost))
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("failing backstop status = %d, want 500 (Scheduler retries)", rec.Code)
	}
}
