package apiserver

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// recordJobs records PostDeleted calls (the media job publisher).
type recordJobs struct {
	calls []posts.PostDeleteWork
	err   error
}

func (r *recordJobs) PostDeleted(_ context.Context, uid, postID string, mediaIDs []string) error {
	r.calls = append(r.calls, posts.PostDeleteWork{UID: uid, PostID: postID, MediaIDs: mediaIDs})
	return r.err
}

func TestPostDeleteOutboxHandler(t *testing.T) {
	ctx := context.Background()
	e, err := posts.PostDeleteEntry("uid-alice", "0000000000000000101", []string{"0000000000000000201"})
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&logs, nil))

	jobs := &recordJobs{}
	h := postDeleteOutboxHandler(jobs, log)
	if err := h(ctx, outbox.Item{Entry: e}); err != nil {
		t.Fatal(err)
	}
	if len(jobs.calls) != 1 || jobs.calls[0].PostID != "0000000000000000101" || jobs.calls[0].UID != "uid-alice" || len(jobs.calls[0].MediaIDs) != 1 {
		t.Fatalf("calls = %+v: the sweep must republish through the same PostDeleted", jobs.calls)
	}

	jobs.err = errors.New("pubsub down for uid-alice")
	err = h(ctx, outbox.Item{Entry: e})
	if err == nil {
		t.Fatal("a publish failure must keep the item")
	}
	if strings.Contains(err.Error(), "uid-alice") {
		t.Fatalf("error %q carries the raw uid", err)
	}

	// A payload no retry can fix is logged and dropped (nil), never retried until its TTL.
	jobs.calls = nil
	if err := h(ctx, outbox.Item{Entry: outbox.Entry{Kind: posts.PostDeleteOutboxKind, Key: "1", UID: "u", Payload: []byte("{")}}); err != nil {
		t.Fatalf("malformed payload = %v, want dropped", err)
	}
	if len(jobs.calls) != 0 || !strings.Contains(logs.String(), "outbox_item_dropped") {
		t.Fatalf("calls %v logs %s", jobs.calls, logs.String())
	}
}

// fakeOutboxSweeper is an outboxSweeper.
type fakeOutboxSweeper struct {
	res      outbox.Result
	err      error
	calls    int
	deadline time.Duration // time left on the ctx when Sweep ran
	panicky  bool
}

func (f *fakeOutboxSweeper) Sweep(ctx context.Context) (outbox.Result, error) {
	f.calls++
	if d, ok := ctx.Deadline(); ok {
		f.deadline = time.Until(d)
	}
	if f.panicky {
		panic("boom")
	}
	return f.res, f.err
}

func TestOutboxSweepStep(t *testing.T) {
	ctx := context.Background()
	tests := []struct {
		name     string
		sw       *fakeOutboxSweeper
		readOnly bool
		wantErr  bool
		wantLog  []string
		wantRuns int
	}{
		{"ok", &fakeOutboxSweeper{res: outbox.Result{Due: 2, Done: 2}}, false, false, []string{`"msg":"outbox_sweep"`, `"done":2`, `"outcome":"ok"`}, 1},
		{"readonly skips", &fakeOutboxSweeper{}, true, false, []string{`"outcome":"skipped_readonly"`}, 0},
		{"due query failure", &fakeOutboxSweeper{err: errors.New("unavailable")}, false, true, []string{`"outcome":"error"`, `"rpc":"` + outboxSweepOp}, 1},
		{"item errors logged at WARN with their scrubbed cause", &fakeOutboxSweeper{res: outbox.Result{Due: 3, Failed: 3, Errors: []outbox.ItemError{{Kind: "post_delete", Outcome: "failed", Cause: "pubsub down", Count: 3}}}}, false, false,
			[]string{`"level":"WARN","msg":"outbox_item_error"`, `"kind":"post_delete"`, `"outcome":"failed"`, `"count":3`, `"cause":"pubsub down"`}, 1},
		{"panic is contained", &fakeOutboxSweeper{panicky: true}, false, true, []string{`"rpc":"` + outboxSweepOp}, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var logs bytes.Buffer
			s := outboxSweepStep{sweeper: tt.sw, readOnly: tt.readOnly, log: slog.New(slog.NewJSONHandler(&logs, nil))}
			err := s.run(ctx)
			if (err != nil) != tt.wantErr || tt.sw.calls != tt.wantRuns {
				t.Fatalf("err %v calls %d", err, tt.sw.calls)
			}
			for _, w := range tt.wantLog {
				if !strings.Contains(logs.String(), w) {
					t.Errorf("logs lack %s:\n%s", w, logs.String())
				}
			}
		})
	}
}

// fixedStatus is an inner cron handler answering a fixed status after advancing the clock by took.
type fixedStatus struct {
	status int
	clock  *outboxClock
	took   time.Duration
	calls  int
}

func (f *fixedStatus) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	f.calls++
	f.clock.t = f.clock.t.Add(f.took)
	w.Header().Set("X-Inner", "1")
	w.WriteHeader(f.status)
}

type outboxClock struct{ t time.Time }

func (c *outboxClock) now() time.Time { return c.t }

func TestWithOutboxSweep(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		inner      int
		took       time.Duration
		sweepErr   error
		wantStatus int
		wantRuns   int
		wantMaxDl  time.Duration
	}{
		{"runs after the publish sweep, inner status kept", http.MethodPost, http.StatusNoContent, time.Second, nil, http.StatusNoContent, 1, outboxStepMax},
		{"a sweep failure never changes the inner status", http.MethodPost, http.StatusNoContent, 0, errors.New("x"), http.StatusNoContent, 1, outboxStepMax},
		{"inner 500 is kept, the outbox still runs", http.MethodPost, http.StatusInternalServerError, 0, nil, http.StatusInternalServerError, 1, outboxStepMax},
		{"budget shrinks to what is left of the cutoff", http.MethodPost, http.StatusNoContent, 22 * time.Second, nil, http.StatusNoContent, 1, 6 * time.Second},
		{"skipped below the minimum budget", http.MethodPost, http.StatusNoContent, 26 * time.Second, nil, http.StatusNoContent, 0, 0},
		{"non-POST goes to the inner handler alone", http.MethodGet, http.StatusMethodNotAllowed, 0, nil, http.StatusMethodNotAllowed, 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clock := &outboxClock{t: time.Unix(1_800_000_000, 0)}
			inner := &fixedStatus{status: tt.inner, clock: clock, took: tt.took}
			sw := &fakeOutboxSweeper{err: tt.sweepErr}
			step := outboxSweepStep{sweeper: sw, log: slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))}
			h := withOutboxSweep(inner, step, "demo", clock.now)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, httptest.NewRequest(tt.method, "/internal/cron/publish-scheduled", nil))
			if rr.Code != tt.wantStatus || inner.calls != 1 || sw.calls != tt.wantRuns || rr.Header().Get("X-Inner") != "1" {
				t.Fatalf("status %d inner %d sweeps %d header %q", rr.Code, inner.calls, sw.calls, rr.Header().Get("X-Inner"))
			}
			if tt.wantRuns == 1 && (sw.deadline <= 0 || sw.deadline > tt.wantMaxDl) {
				t.Fatalf("sweep deadline %v, want in (0, %v]", sw.deadline, tt.wantMaxDl)
			}
		})
	}
}

func TestOutboxSweepHandler(t *testing.T) {
	tests := []struct {
		name   string
		method string
		err    error
		want   int
	}{
		{"ok", http.MethodPost, nil, http.StatusNoContent},
		{"due query failed: 500 so Scheduler retries", http.MethodPost, errors.New("unavailable"), http.StatusInternalServerError},
		{"GET", http.MethodGet, nil, http.StatusMethodNotAllowed},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sw := &fakeOutboxSweeper{err: tt.err}
			log := slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))
			h := outboxSweepHandler(outboxSweepStep{sweeper: sw, log: log}, log, "demo")
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, httptest.NewRequest(tt.method, "/internal/cron/outbox-sweep", nil))
			if rr.Code != tt.want {
				t.Fatalf("status %d, want %d", rr.Code, tt.want)
			}
		})
	}
}

func TestNewOutbox_RegistersPostDelete(t *testing.T) {
	ob, err := newOutbox(nil, &recordJobs{}, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)), nil)
	if err != nil {
		t.Fatal(err)
	}
	// The kind is taken: a second registration fails.
	if err := ob.Handle(posts.PostDeleteOutboxKind, func(context.Context, outbox.Item) error { return nil }); err == nil {
		t.Fatal("post_delete has no handler registered")
	}
}

func TestOutboxEraserStep(t *testing.T) {
	if got := outboxEraserStep(outbox.New(nil, outbox.Config{})).Name(); got != "outbox" {
		t.Fatalf("step name = %q", got)
	}
}

func TestStuckReporter(t *testing.T) {
	var logs bytes.Buffer
	r := stuckReporter(slog.New(slog.NewJSONHandler(&logs, nil)))
	r(context.Background(), outbox.StuckItem{Kind: "post_delete", UIDHash: "abcd", Cause: "pubsub down"})
	for _, w := range []string{`"msg":"outbox_item_stuck"`, `"kind":"post_delete"`, `"uid_hash":"abcd"`, `"cause":"pubsub down"`, `"rpc":"` + outboxSweepOp} {
		if !strings.Contains(logs.String(), w) {
			t.Errorf("logs lack %s:\n%s", w, logs.String())
		}
	}
}
