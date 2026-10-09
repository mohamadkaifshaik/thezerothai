package identity

// Tests for the two security-review findings on the job side of the account lifecycle:
//   - L-4: an export is composed by exactly one delivery at a time (a PENDING lease claimed with an UpdateTime
//     precondition), and a replay inside 2 minutes does not publish again.
//   - L-6: the daily backstop scans are ordered oldest-progress first with a cursor, so fresh jobs cannot hide
//     stuck ones and a run makes progress through every candidate (up to backstopMaxPages pages).

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

// TestExportJob_ConcurrentDeliveriesComposeOnce (L-4): while one delivery is composing, a second delivery of the
// same export neither composes nor writes; it is nacked with 429 for Pub/Sub to redeliver after its backoff.
func TestExportJob_ConcurrentDeliveriesComposeOnce(t *testing.T) {
	h := newHarness(t)
	h.seedActive("u1", "Alice")
	var composed atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: "[]", hook: func() {
		if composed.Add(1) == 1 {
			close(started)
			<-release // the first delivery is mid-compose
		}
	}})
	doc := newPendingExport(h, "u1")
	msg := JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}

	firstCode := make(chan int, 1)
	go func() { firstCode <- h.deliver(msg, 1) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("the first delivery never started composing")
	}

	readsBefore, writesBefore := h.repo.reads, h.repo.writes
	for range 3 { // a replay storm and Pub/Sub redeliveries land while the first run is live
		if code := h.deliver(msg, 1); code != http.StatusTooManyRequests {
			t.Fatalf("concurrent delivery = HTTP %d, want 429 (leased)", code)
		}
	}
	if got := h.repo.writes - writesBefore; got != 0 {
		t.Errorf("leased deliveries wrote %d times, want 0", got)
	}
	if got := h.repo.reads - readsBefore; got != 3 {
		t.Errorf("leased deliveries read %d times, want 1 each (the exports doc)", got)
	}
	if h.log.count("auth.") != 1 {
		t.Errorf("Firebase Auth calls = %d, want 1 (only the claimant composes)", h.log.count("auth."))
	}

	close(release)
	select {
	case code := <-firstCode:
		if code != http.StatusNoContent {
			t.Fatalf("first delivery = HTTP %d, want 204", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the first delivery never finished")
	}
	if composed.Load() != 1 || h.log.count("obj.Put") != 1 {
		t.Errorf("composed %d times, %d objects written; want exactly once", composed.Load(), h.log.count("obj.Put"))
	}
	if h.repo.exports[doc.ID].Status != ExportReady {
		t.Errorf("status = %s, want READY", h.repo.exports[doc.ID].Status)
	}
	// A late redelivery after READY is the usual 1-read duplicate.
	if code := h.deliver(msg, 2); code != http.StatusNoContent || composed.Load() != 1 {
		t.Errorf("redelivery after READY = HTTP %d, composed %d", code, composed.Load())
	}
}

// TestExportJob_LostClaimDoesNotCompose: two deliveries read the same document; the one that loses the conditional
// claim composes nothing and writes nothing.
func TestExportJob_LostClaimDoesNotCompose(t *testing.T) {
	h := newHarness(t)
	h.seedActive("u1", "Alice")
	var composed atomic.Int32
	_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: "[]", hook: func() { composed.Add(1) }})
	doc := newPendingExport(h, "u1")
	h.repo.failOnce["ClaimExport"] = ErrJobConflict // the concurrent delivery's claim landed first

	if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusTooManyRequests {
		t.Fatalf("HTTP %d, want 429", code)
	}
	if composed.Load() != 0 || h.log.count("obj.") != 0 || h.repo.writes != 0 {
		t.Errorf("the losing delivery composed %d, objects %d, writes %d", composed.Load(), h.log.count("obj."), h.repo.writes)
	}
	recs := h.logs.records("account_job")
	if len(recs) != 1 || recs[0]["outcome"] != "leased" {
		t.Errorf("log lines = %v, want one with outcome leased", recs)
	}
}

// TestExportJob_CrashedLeaseIsRecovered: a run that dies mid-compose leaves a PENDING export with a lease. Until it
// lapses deliveries back off; afterwards the redelivery (Pub/Sub's 60 s backoff) composes it, and so does the daily
// backstop if every delivery was lost.
func TestExportJob_CrashedLeaseIsRecovered(t *testing.T) {
	crash := func(h *harness) (ExportDoc, *atomic.Int32) {
		h.seedActive("u1", "Alice")
		var composed atomic.Int32
		_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: "[]", hook: func() {
			if composed.Add(1) == 1 {
				panic(errCrash) // the instance dies mid-compose
			}
		}})
		doc := newPendingExport(h, "u1")
		// The handler's panic recovery turns the dying delivery into a 500 (Pub/Sub redelivers it).
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusInternalServerError {
			t.Fatalf("crashed delivery = HTTP %d, want 500", code)
		}
		stored := h.repo.exports[doc.ID]
		if stored.Status != ExportPending || !stored.LeaseUntil.After(h.clock.Now()) {
			t.Fatalf("after the crash: status %s, lease %v; want PENDING with a live lease", stored.Status, stored.LeaseUntil)
		}
		return *stored, &composed
	}

	t.Run("redelivery after the lease lapses", func(t *testing.T) {
		h := newHarness(t)
		doc, composed := crash(h)
		msg := JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}
		if code := h.deliver(msg, 2); code != http.StatusTooManyRequests || composed.Load() != 1 {
			t.Fatalf("redelivery inside the lease = HTTP %d, composed %d; want 429 and no compose", code, composed.Load())
		}
		h.clock.Advance(61 * time.Second)
		if code := h.deliver(msg, 3); code != http.StatusNoContent {
			t.Fatalf("redelivery after the lease = HTTP %d, want 204", code)
		}
		if h.repo.exports[doc.ID].Status != ExportReady || composed.Load() != 2 {
			t.Errorf("status %s, composed %d; want READY after exactly one retry", h.repo.exports[doc.ID].Status, composed.Load())
		}
		if _, ok := h.objs.get(doc.ObjectPath); !ok {
			t.Error("no object after the recovered run")
		}
	})

	t.Run("backstop picks up a crashed PENDING export once it is an hour old", func(t *testing.T) {
		h := newHarness(t)
		doc, composed := crash(h)
		h.clock.Advance(stuckAfter + time.Minute)
		res, err := h.l.Backstop(context.Background())
		if err != nil || res.ExportsRepublished != 1 {
			t.Fatalf("Backstop = %+v, %v; want the expired-lease export republished", res, err)
		}
		h.drain(3)
		if h.repo.exports[doc.ID].Status != ExportReady || composed.Load() != 2 {
			t.Errorf("status %s, composed %d", h.repo.exports[doc.ID].Status, composed.Load())
		}
	})
}

// TestGetAccountExport_LeasedIsPendingAndNotFoundIsUnchanged: the lease is invisible to clients (still PENDING) and
// the byte-identical NOT_FOUND of Q6 is untouched.
func TestGetAccountExport_LeasedIsPendingAndNotFoundIsUnchanged(t *testing.T) {
	h := newHarness(t)
	h.seedActive("u1", "Alice")
	doc := newPendingExport(h, "u1")
	h.repo.exports[doc.ID].LeaseUntil = h.clock.Now().Add(time.Minute)

	v, err := h.l.GetAccountExport(context.Background(), "u1", doc.ID)
	if err != nil || v.Status != ExportPending || v.DownloadURL != "" {
		t.Fatalf("leased export view = %+v, %v; want PENDING", v, err)
	}
	_, other := h.l.GetAccountExport(context.Background(), "u2", doc.ID)
	_, missing := h.l.GetAccountExport(context.Background(), "u1", expID("u1", expKey2))
	if other == nil || missing == nil || other.Error() != missing.Error() {
		t.Errorf("NOT_FOUND differs: foreign %v, unknown %v", other, missing)
	}
}

// deletingWithProgress seeds a DELETING account whose last saved progress was `ago` ago.
func (h *harness) deletingWithProgress(uid string, ago time.Duration) {
	h.t.Helper()
	p := h.seedDeleting(uid, "H"+uid, 48*time.Hour)
	p.DeletionJob = &DeletionJob{Seq: 4, ProgressAt: h.clock.Now().Add(-ago)}
	h.repo.seed(p)
}

func (h *harness) published(kind string) map[string]bool {
	h.t.Helper()
	out := map[string]bool{}
	for _, m := range h.pub.msgs {
		if m.Kind != kind {
			continue
		}
		if kind == JobKindAccountDelete {
			out[m.UID] = true
		} else {
			out[m.ExportID] = true
		}
	}
	return out
}

// TestBackstop_FreshJobsCannotHideAStuckOne (L-6): 60 fresh DELETING accounts (more than a page) no longer starve the
// one stuck account, no page_full warning is needed, and the fresh ones cost no read.
func TestBackstop_FreshJobsCannotHideAStuckOne(t *testing.T) {
	h := newHarness(t)
	for i := range 60 {
		h.deletingWithProgress(fmt.Sprintf("fresh-%03d", i), time.Minute)
	}
	h.deletingWithProgress("stuck", 3*time.Hour)

	res, err := h.l.Backstop(context.Background())
	if err != nil || res != (BackstopResult{DeletionsRepublished: 1}) {
		t.Fatalf("Backstop = %+v, %v; want only the stuck account republished", res, err)
	}
	if got := h.published(JobKindAccountDelete); len(got) != 1 || !got["stuck"] {
		t.Errorf("published %v", got)
	}
	// 1 read for the stuck account + 1 for the (empty) exports scan: fresh jobs are filtered in the query.
	if h.repo.reads != 2 {
		t.Errorf("reads = %d, want 2", h.repo.reads)
	}
	if n := len(h.logs.records("backstop_page_full")); n != 0 {
		t.Errorf("%d backstop_page_full lines for a single stuck job", n)
	}
}

// TestBackstop_CursorWalksEveryCandidate (L-6): with more stuck jobs than one page, including a page boundary inside a
// run of identical timestamps, one run republishes every one of them exactly once.
func TestBackstop_CursorWalksEveryCandidate(t *testing.T) {
	h := newHarness(t)
	const n = 3*backstopPage - 10 // 140: three pages, the last partial
	for i := range n {
		// 70 distinct timestamps, each shared by two accounts, so a page boundary can fall between twins.
		h.deletingWithProgress(fmt.Sprintf("u%03d", i), 2*time.Hour+time.Duration(i/2)*time.Second)
	}
	res, err := h.l.Backstop(context.Background())
	if err != nil || res.DeletionsRepublished != n {
		t.Fatalf("Backstop = %+v, %v; want %d republished", res, err, n)
	}
	if got := h.published(JobKindAccountDelete); len(got) != n || len(h.pub.msgs) != n {
		t.Errorf("%d distinct uids over %d messages, want %d each", len(got), len(h.pub.msgs), n)
	}
	// Reads = the documents returned (n) + 1 for the empty exports scan; no page re-reads a document.
	if h.repo.reads != n+1 {
		t.Errorf("reads = %d, want %d", h.repo.reads, n+1)
	}
	if len(h.logs.records("backstop_page_full")) != 0 {
		t.Error("page_full logged although the walk reached the end")
	}
}

// TestBackstop_PageCapIsBoundedOldestFirst (L-6): beyond backstopMaxPages pages a run stops, takes the oldest
// candidates first and says so with a WARN, so the read cost per run stays bounded.
func TestBackstop_PageCapIsBoundedOldestFirst(t *testing.T) {
	h := newHarness(t)
	const total = backstopMaxPages*backstopPage + 30
	for i := range total {
		h.deletingWithProgress(fmt.Sprintf("u%03d", i), 2*time.Hour+time.Duration(total-i)*time.Second) // u000 is the oldest
	}
	res, err := h.l.Backstop(context.Background())
	capN := backstopMaxPages * backstopPage
	if err != nil || res.DeletionsRepublished != int64(capN) {
		t.Fatalf("Backstop = %+v, %v; want %d republished", res, err, capN)
	}
	got := h.published(JobKindAccountDelete)
	for i := range total {
		uid := fmt.Sprintf("u%03d", i)
		wantIn := i < capN // the capN oldest are the lowest indexes
		if got[uid] != wantIn {
			t.Fatalf("%s republished = %v, want %v (oldest progress first)", uid, got[uid], wantIn)
		}
	}
	if h.repo.reads > capN+1 {
		t.Errorf("reads = %d, want at most %d", h.repo.reads, capN+1)
	}
	recs := h.logs.records("backstop_page_full")
	if len(recs) != 1 || recs[0]["query"] != "deleting" || recs[0]["level"] != "WARN" {
		t.Errorf("backstop_page_full lines = %v", recs)
	}
}

// TestBackstop_ExportsCursorAndOrder (L-6): the PENDING-export scan is ordered by createdAt with the age filter in the
// query. Old exports are failed or republished past one page, fresh ones are never read.
func TestBackstop_ExportsCursorAndOrder(t *testing.T) {
	h := newHarness(t)
	now := h.clock.Now()
	for i := range 60 {
		h.repo.exports[fmt.Sprintf("fresh-%02d", i)] = &ExportDoc{ID: fmt.Sprintf("fresh-%02d", i), UID: "a", Status: ExportPending, CreatedAt: now.Add(-time.Minute), UpdateTime: utOf(1)}
	}
	for i := range 55 {
		id := fmt.Sprintf("mid-%02d", i)
		h.repo.exports[id] = &ExportDoc{ID: id, UID: "a", Status: ExportPending, CreatedAt: now.Add(-2*time.Hour - time.Duration(i)*time.Second), UpdateTime: utOf(1)}
	}
	h.repo.exports["old"] = &ExportDoc{ID: "old", UID: "a", Status: ExportPending, CreatedAt: now.Add(-30 * time.Hour), UpdateTime: utOf(1)}

	res, err := h.l.Backstop(context.Background())
	if err != nil || res != (BackstopResult{ExportsRepublished: 55, ExportsFailed: 1}) {
		t.Fatalf("Backstop = %+v, %v", res, err)
	}
	if got := h.published(JobKindAccountExport); len(got) != 55 || got["old"] || got["fresh-00"] {
		t.Errorf("republished %d exports (old=%v fresh=%v)", len(got), got["old"], got["fresh-00"])
	}
	if h.repo.exports["old"].Status != ExportFailed {
		t.Error("the 30 h old export was not given up")
	}
	// 56 stuck docs returned (a full page of 50, then 6) + 1 read for the empty deletion scan.
	if h.repo.reads != 56+1 {
		t.Errorf("reads = %d, want 57", h.repo.reads)
	}
}

// TestBackstop_ListErrorsStopTheRun: a failing scan aborts with a wrapped error after the in-flight publishes finish.
func TestBackstop_ListErrorsStopTheRun(t *testing.T) {
	for _, method := range []string{"ListDeleting", "ListPendingExports"} {
		t.Run(method, func(t *testing.T) {
			h := newHarness(t)
			h.repo.failOnce[method] = errors.New("firestore down")
			if _, err := h.l.Backstop(context.Background()); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}
