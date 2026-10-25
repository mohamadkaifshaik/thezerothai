package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// Unit tests of the per-item rules (ADR-0021 "Sweep" steps 3 to 5): the cheapest-first checks, the outcomes a committed
// transaction reports, the transient-attempts ladder, both panic recovery sites and the L-8 scrubbing of every error.

// A check that fails outside the transaction costs 0 reads (beyond the query) and exactly one precondition write; the
// publish transaction is never opened.
func TestSweepItem_ChecksBeforeTheTransaction(t *testing.T) {
	longText := strings.Repeat("a", 281)
	tests := []struct {
		name string
		mut  func(e *sweepEnv, p *ScheduledPost)
		want ScheduledFailure
	}{
		{"expired: later than SCHEDULED_MAX_LATENESS", func(e *sweepEnv, p *ScheduledPost) { p.PublishAt = e.now.Add(-6*time.Hour - time.Second) }, FailureExpired},
		{"expiry is decided before the schema version", func(e *sweepEnv, p *ScheduledPost) {
			p.PublishAt = e.now.Add(-7 * time.Hour)
			p.SchemaVersion = 2
		}, FailureExpired},
		{"expiry is decided before the draft is looked at", func(e *sweepEnv, p *ScheduledPost) {
			p.PublishAt = e.now.Add(-7 * time.Hour)
			p.Draft = nil
		}, FailureExpired},
		{"a higher schemaVersion is unsupported", func(_ *sweepEnv, p *ScheduledPost) { p.SchemaVersion = 2 }, FailureUnsupported},
		{"a PENDING item without a draft", func(_ *sweepEnv, p *ScheduledPost) { p.Draft = nil }, FailureInvalidContent},
		{"text with a control character no longer parses", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Text = "a\x00b" }, FailureInvalidContent},
		{"text over 280 characters", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Text = longText }, FailureInvalidContent},
		{"empty text without an image", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Text = "  " }, FailureInvalidContent},
		{"a reply policy this revision does not know", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.ReplyPolicy = "FOLLOWING_OF_FOLLOWING" }, FailureInvalidContent},
		{"a media id that is not a media id", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Media = []MediaRef{{ID: "m1"}} }, FailureInvalidContent},
		{"more than four images", func(_ *sweepEnv, p *ScheduledPost) {
			for i := 1; i <= 5; i++ {
				p.Draft.Media = append(p.Draft.Media, MediaRef{ID: sweepMediaID(i)})
			}
		}, FailureInvalidContent},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepEnv(t)
			it := e.dueItem("uid-alice", 1, func(p *ScheduledPost) { tc.mut(e, p) })
			queried := e.repo.doc("uid-alice", it.ID)

			res, c, err := e.sweep(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if res.Failed[tc.want] != 1 || res.Published != 0 || res.Transient != 0 {
				t.Fatalf("res = %+v, want one FAILED %s", res, tc.want)
			}
			if c.Reads() != 1 || c.Writes() != 1 {
				t.Errorf("cost = %d reads %d writes, want the query's 1 read and one write", c.Reads(), c.Writes())
			}
			if n := len(e.repo.callsOf("publish")); n != 0 {
				t.Errorf("the publish transaction ran %d times for a CPU-only failure", n)
			}
			tr := e.repo.callsOf("transition")
			if len(tr) != 1 || tr[0].t.To != ScheduledFailed || tr[0].t.Failure != tc.want || !tr[0].ref.UpdateTime.Equal(queried.UpdateTime) {
				t.Fatalf("transitions = %+v, want one FAILED %s conditional on the query's UpdateTime %v", tr, tc.want, queried.UpdateTime)
			}
			got := e.repo.doc("uid-alice", it.ID)
			if got.Status != ScheduledFailed || got.Failure != tc.want || got.Draft != nil || got.ExpireAt == nil || !got.ExpireAt.Equal(e.now.Add(168*time.Hour)) {
				t.Errorf("stored item = %+v, want FAILED %s, draft cleared, expireAt = now + 7d", got, tc.want)
			}
		})
	}
}

func TestSweepItem_BoundaryAndImageOnlyPublish(t *testing.T) {
	t.Run("exactly SCHEDULED_MAX_LATENESS late is not expired", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.PublishAt = e.now.Add(-6 * time.Hour) })
		res, _, _ := e.sweep(context.Background())
		if res.Published != 1 || res.Expired() != 0 {
			t.Errorf("res = %+v, want published", res)
		}
	})
	t.Run("an image-only post publishes (empty text with media is valid)", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.Draft = &ScheduledDraft{Media: []MediaRef{{ID: sweepMediaID(7)}}} })
		res, _, _ := e.sweep(context.Background())
		if res.Published != 1 {
			t.Errorf("res = %+v, want published", res)
		}
		if p := e.repo.params[0]; p.Draft.Text != "" || len(p.MediaIDs) != 1 {
			t.Errorf("params = %+v", p)
		}
	})
	t.Run("a text-only post sends no media to the transaction", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem("uid-alice", 1)
		_, _, _ = e.sweep(context.Background())
		if p := e.repo.params[0]; p.MediaIDs != nil || p.MediaAlts != nil || p.ResolveMentions != nil {
			t.Errorf("params = %+v, want no media and no mention resolver", p)
		}
	})
}

// A committed publish transaction already wrote its terminal state: the service writes nothing more for it.
func TestSweepItem_CommittedOutcomes(t *testing.T) {
	tests := []struct {
		name      string
		res       PublishResult
		published int
		cancelled int
		failed    ScheduledFailure
		noop      int
	}{
		{"cancelled: the author is deleting or gone", PublishResult{Outcome: PublishCancelled}, 0, 1, "", 0},
		{"failed: account restricted", PublishResult{Outcome: PublishFailed, Failure: FailureAccountRestricted}, 0, 0, FailureAccountRestricted, 0},
		{"failed: quota exceeded", PublishResult{Outcome: PublishFailed, Failure: FailureQuotaExceeded}, 0, 0, FailureQuotaExceeded, 0},
		{"failed: media unavailable", PublishResult{Outcome: PublishFailed, Failure: FailureMediaUnavailable}, 0, 0, FailureMediaUnavailable, 0},
		{"no-op: another run, a Cancel or the eraser won", PublishResult{Outcome: PublishNoop}, 0, 0, "", 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepEnv(t)
			e.dueItem("uid-alice", 1)
			e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) { return tc.res, nil }
			res, _, err := e.sweep(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if res.Published != tc.published || res.Cancelled != tc.cancelled || res.Noop != tc.noop || res.Transient != 0 {
				t.Errorf("res = %+v", res)
			}
			if tc.failed != "" && res.Failed[tc.failed] != 1 {
				t.Errorf("failed = %v, want %s once", res.Failed, tc.failed)
			}
			if n := len(e.repo.callsOf("transition")) + len(e.repo.callsOf("bump")); n != 0 {
				t.Errorf("the service wrote %d times after a committed transaction", n)
			}
			if len(e.events.created) != 0 || len(e.dir.forgotten) != 0 {
				t.Error("post-commit effects ran without a published post")
			}
		})
	}
}

func TestSweepItem_TransientErrorsCountAttemptsThenRetire(t *testing.T) {
	tests := []struct {
		name         string
		attempts     int
		maxAttempts  int
		wantRetired  bool
		wantErrorLog bool
	}{
		{"first failure: attempts++", 0, 3, false, false},
		{"second failure: attempts++", 1, 3, false, false},
		{"third failure: FAILED INTERNAL and reported", 2, 3, true, true},
		{"already beyond the limit (config lowered): retired", 5, 3, true, true},
		{"SCHEDULED_MAX_ATTEMPTS=1 retires on the first", 0, 1, true, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.MaxAttempts = tc.maxAttempts })
			it := e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.Attempts = tc.attempts })
			queried := e.repo.doc("uid-alice", it.ID)
			e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) {
				return PublishResult{}, errors.New("rpc error: code = Unavailable desc = the service is currently unavailable")
			}

			res, c, err := e.sweep(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if res.Transient != 1 || res.Published != 0 {
				t.Fatalf("res = %+v, want one transient", res)
			}
			doc := e.repo.doc("uid-alice", it.ID)
			if tc.wantRetired {
				if doc.Status != ScheduledFailed || doc.Failure != FailureInternal || res.Failed[FailureInternal] != 1 || len(e.repo.callsOf("bump")) != 0 {
					t.Errorf("item = %+v res = %+v, want FAILED INTERNAL and no attempts++", doc, res)
				}
			} else {
				bumps := e.repo.callsOf("bump")
				if doc.Status != ScheduledPending || doc.Attempts != tc.attempts+1 || len(bumps) != 1 || !bumps[0].ref.UpdateTime.Equal(queried.UpdateTime) || len(e.repo.callsOf("transition")) != 0 {
					t.Errorf("item = %+v bumps = %+v, want attempts %d under the query's precondition", doc, bumps, tc.attempts+1)
				}
			}
			if c.Writes() != 1 {
				t.Errorf("writes = %d, want the one bookkeeping write", c.Writes())
			}
			reported := len(e.logs.lines("ReportedErrorEvent")) > 0
			if reported != tc.wantErrorLog {
				t.Errorf("Error Reporting entry = %v, want %v\n%s", reported, tc.wantErrorLog, e.logs.String())
			}
		})
	}
}

// A panic inside the transaction callback comes back as errPublishPanic (the callback's recover already rolled the
// transaction back). It retires the item FAILED INTERNAL in this run and never takes the attempts++ branch (review M-2).
func TestSweepItem_PanicInsideTheCallbackIsNotTransient(t *testing.T) {
	e := newSweepEnv(t)
	it := e.dueItem("uid-alice", 1) // attempts 0 of 3: a transient error would only count an attempt
	e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) {
		return PublishResult{}, fmt.Errorf("wrapped: %w", &publishPanicError{typ: "*errors.errorString"})
	}
	res, _, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Failed[FailureInternal] != 1 || res.Transient != 0 || len(e.repo.callsOf("bump")) != 0 {
		t.Errorf("res = %+v bumps = %d, want FAILED INTERNAL, not transient", res, len(e.repo.callsOf("bump")))
	}
	if doc := e.repo.doc("uid-alice", it.ID); doc.Status != ScheduledFailed || doc.Failure != FailureInternal || doc.Attempts != 0 {
		t.Errorf("item = %+v", doc)
	}
	reports := e.logs.lines("ReportedErrorEvent")
	if len(reports) != 1 || !strings.Contains(reports[0], "panic of type *errors.errorString") {
		t.Errorf("Error Reporting entries = %v, want one naming the panic type", reports)
	}
}

// The second recover site: around each item in its worker. The panicking item is retired, the author's NEXT item and
// every other worker carry on, and the process survives.
func TestSweepItem_PanicInTheWorkerIsRecoveredAndOthersPublish(t *testing.T) {
	e := newSweepEnv(t)
	bad := e.dueItem("uid-a", 1)
	good := e.dueItem("uid-a", 2)
	other := e.dueItem("uid-b", 3)
	e.repo.publish = func(ctx context.Context, p PublishParams) (PublishResult, error) {
		if p.ID == bad.ID {
			panic("poison item: secret text of uid-a")
		}
		return e.repo.publishDefault(ctx, p)
	}

	res, _, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Published != 2 || res.Failed[FailureInternal] != 1 {
		t.Fatalf("res = %+v, want 2 published and 1 FAILED INTERNAL", res)
	}
	if got := e.repo.doc("uid-a", bad.ID); got.Status != ScheduledFailed || got.Failure != FailureInternal {
		t.Errorf("poison item = %+v", got)
	}
	for _, it := range []*ScheduledPost{good, other} {
		if got := e.repo.doc(it.UID, it.ID); got.Status != ScheduledPublished {
			t.Errorf("%s item status = %v, want PUBLISHED", it.UID, got.Status)
		}
	}
	out := e.logs.String()
	if !strings.Contains(out, "panic of type string") || strings.Contains(out, "poison item") || strings.Contains(out, "secret text") {
		t.Errorf("only the panic type may be logged: %s", out)
	}
}

// A panic after the commit (the cache update or PostEvents.Created) finds the doc already PUBLISHED: the FAILED write's
// precondition fails, which is correct, and nothing is "fixed" with an unconditional write.
func TestSweepItem_PanicAfterTheCommitLeavesItPublished(t *testing.T) {
	e := newSweepEnv(t)
	it := e.dueItem("uid-alice", 1)
	e.events.panicOn = func(*Post) bool { return true }

	res, _, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := e.repo.doc("uid-alice", it.ID); got.Status != ScheduledPublished || got.Failure != "" {
		t.Errorf("item = %+v, want it to stay PUBLISHED", got)
	}
	tr := e.repo.callsOf("transition")
	if len(tr) != 1 || tr[0].t.Failure != FailureInternal {
		t.Fatalf("transitions = %+v, want the one FAILED INTERNAL attempt", tr)
	}
	if res.Published != 1 || res.Failed[FailureInternal] != 0 || res.Noop != 1 {
		t.Errorf("res = %+v, want 1 published and the failed write counted as a no-op", res)
	}
	if len(e.logs.lines("ReportedErrorEvent")) != 1 {
		t.Errorf("the panic was not reported once: %s", e.logs.String())
	}
}

// A bookkeeping write whose precondition fails means someone else moved the item on: quiet no-op, no retry, no fix-up.
func TestSweepItem_LostPreconditionIsAQuietNoop(t *testing.T) {
	e := newSweepEnv(t)
	it := e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.SchemaVersion = 9 })
	e.repo.afterDue = func() { // the user cancels between the query and the sweep's write
		e.repo.mu.Lock()
		defer e.repo.mu.Unlock()
		d := e.repo.docs["uid-alice/"+it.ID]
		(ScheduledTransition{To: ScheduledCancelled}).apply(d, e.now, time.Hour)
		e.repo.touch(d)
	}
	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Noop != 1 || len(res.Failed) != 0 || c.Writes() != 0 {
		t.Errorf("res = %+v writes = %d, want a no-op with 0 writes", res, c.Writes())
	}
	if got := e.repo.doc("uid-alice", it.ID); got.Status != ScheduledCancelled || got.Failure != "" {
		t.Errorf("item = %+v, want the user's CANCELLED untouched", got)
	}
	if n := len(e.repo.callsOf("transition")); n != 1 {
		t.Errorf("write attempts = %d, want exactly one (no retry, no unconditional fix-up)", n)
	}
}

func TestSweepItem_ABookkeepingWriteThatErrorsIsCountedAndLogged(t *testing.T) {
	e := newSweepEnv(t)
	e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.SchemaVersion = 9 })
	e.repo.transitionErr = errors.New("unavailable")
	res, _, err := e.sweep(context.Background())
	if err != nil || res.WriteFailed != 1 || len(res.Failed) != 0 {
		t.Fatalf("res = %+v err = %v, want one failed write", res, err)
	}
	if len(e.logs.lines("scheduled_item_bookkeeping_failed")) != 1 {
		t.Error("a failed state write left no log line")
	}
}

func TestSweepItem_ItemStartLineBeforeTheTransaction(t *testing.T) {
	e := newSweepEnv(t)
	it := e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.Draft.Text = "my private draft text" })
	var logged bool
	e.repo.publish = func(ctx context.Context, p PublishParams) (PublishResult, error) {
		logged = len(e.logs.lines(`"scheduled_item_start"`)) == 1 // already written when the transaction starts
		return e.repo.publishDefault(ctx, p)
	}
	if _, _, err := e.sweep(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !logged {
		t.Fatal("scheduled_item_start was not logged before the transaction")
	}
	line := e.logs.lines(`"scheduled_item_start"`)[0]
	if !strings.Contains(line, it.ID) || !strings.Contains(line, `"uid_hash":"`) || strings.Contains(line, "uid-alice") {
		t.Errorf("line = %s, want the scheduled id and the uid hash only", line)
	}
	if strings.Contains(e.logs.String(), "my private draft text") {
		t.Errorf("draft text reached the log: %s", e.logs.String())
	}
}

// Every error that is logged, reported or returned goes through logger.ScrubErr (review L-8): the sweep touches many
// users, and Firestore error text carries documents/users/<uid>/scheduled/<id>. The proof is end to end, over the real
// log output of every path that logs an error, with TWO uids in each error.
func TestSweep_ErrorsNeverLeakUIDs(t *testing.T) {
	const (
		uidA = "uidAAAAAAAAAAAAAAAAAAAAAAAA1"
		uidB = "uidBBBBBBBBBBBBBBBBBBBBBBBB2"
		idA  = "11111111111111111111111111111111"
		idB  = "22222222222222222222222222222222"
	)
	leaky := func() error {
		return fmt.Errorf("rpc error: code = Unavailable desc = contended on documents/users/%s/scheduled/%s and on documents/users/%s/scheduled/%s: %s_%s",
			uidA, idA, uidB, idB, uidA, uidB)
	}
	assertClean := func(t *testing.T, e *sweepEnv, returned error) {
		t.Helper()
		all := e.logs.String()
		if returned != nil {
			all += "\n" + returned.Error()
		}
		for _, secret := range []string{uidA, uidB, idA, idB, "documents/users"} {
			if strings.Contains(all, secret) {
				t.Errorf("%q survived in the output:\n%s", secret, all)
			}
		}
	}

	t.Run("transient, attempts++ path", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem(uidA, 1)
		e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) { return PublishResult{}, leaky() }
		if _, _, err := e.sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(e.logs.lines("scheduled_item_transient")) != 1 {
			t.Fatal("the transient path logged nothing to scan")
		}
		assertClean(t, e, nil)
	})
	t.Run("last attempt, reported to Error Reporting", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem(uidA, 1, func(p *ScheduledPost) { p.Attempts = 2 })
		e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) { return PublishResult{}, leaky() }
		if _, _, err := e.sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(e.logs.lines("ReportedErrorEvent")) != 1 {
			t.Fatal("nothing was reported")
		}
		assertClean(t, e, nil)
	})
	t.Run("bookkeeping write fails", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem(uidA, 1, func(p *ScheduledPost) { p.SchemaVersion = 9 })
		e.dueItem(uidB, 2)
		e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) { return PublishResult{}, leaky() }
		e.repo.transitionErr, e.repo.bumpErr = leaky(), leaky()
		if _, _, err := e.sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(e.logs.lines("scheduled_item_bookkeeping_failed")) != 2 {
			t.Fatalf("expected two failed-write lines: %s", e.logs.String())
		}
		assertClean(t, e, nil)
	})
	t.Run("the due query fails and the error is returned", func(t *testing.T) {
		e := newSweepEnv(t)
		e.repo.dueErr, e.repo.dueErrAt = leaky(), 1
		_, _, err := e.sweep(context.Background())
		if err == nil {
			t.Fatal("want the query error")
		}
		assertClean(t, e, err)
	})
	t.Run("a mention-resolution error from the transaction", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem(uidA, 1, func(p *ScheduledPost) { p.Draft.Text = "hello @bob" })
		e.repo.publish = func(ctx context.Context, p PublishParams) (PublishResult, error) {
			return PublishResult{}, fmt.Errorf("posts: resolve mentions: %w", leaky())
		}
		if _, _, err := e.sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		assertClean(t, e, nil)
	})
}
