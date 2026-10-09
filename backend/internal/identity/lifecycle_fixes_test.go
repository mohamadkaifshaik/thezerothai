package identity

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// blockingSection never finishes: it waits for its context, as a section reading an account too large to export in
// time would.
type blockingSection struct{ name string }

func (s blockingSection) Name() string { return s.name }

func (s blockingSection) WriteSection(ctx context.Context, _ string, _ io.Writer) error {
	<-ctx.Done()
	return ctx.Err()
}

// TestExportComposeTimeout is M1: an export that cannot finish inside the compose budget is FAILED (too_large) and
// acked with an ERROR entry, never nacked for Pub/Sub to retry up to 10 times.
func TestExportComposeTimeout(t *testing.T) {
	h := newHarness(t, func(d *LifecycleDeps) { d.ExportBudget = 30 * time.Millisecond })
	h.seedActive("u1", "Alice")
	if err := h.l.RegisterExportSection(blockingSection{name: "posts"}); err != nil {
		t.Fatal(err)
	}
	doc := newPendingExport(h, "u1")

	code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1)
	if code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204: a timed-out export must be acked, not retried", code)
	}
	if got := h.repo.exports[doc.ID].Status; got != ExportFailed {
		t.Errorf("status = %s, want FAILED", got)
	}
	if _, ok := h.objs.get(doc.ObjectPath); ok {
		t.Error("a timed-out export left an object")
	}
	out := h.logs.String()
	for _, want := range []string{"ReportedErrorEvent", "account_export_too_large", "failed:too_large"} {
		if !strings.Contains(out, want) {
			t.Errorf("log lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, doc.ID) || strings.Contains(out, `"u1"`) {
		t.Errorf("log leaks an export id or uid:\n%s", out)
	}
	if n := h.repo.writes; n != 2 {
		t.Errorf("writes = %d, want 2 (claim, FAILED)", n)
	}
}

// TestBackstopFailedExportDeletesObject is Nit 2: giving up on a PENDING export removes an object a failed READY write
// may have left behind.
func TestBackstopFailedExportDeletesObject(t *testing.T) {
	h := newHarness(t)
	h.seedActive("u1", "Alice")
	doc := newPendingExport(h, "u1")
	h.objs.objects[doc.ObjectPath] = []byte("{}")
	h.clock.Advance(exportFailAfter + time.Minute)

	res, err := h.l.Backstop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.ExportsFailed != 1 || h.repo.exports[doc.ID].Status != ExportFailed {
		t.Fatalf("result %+v, status %s", res, h.repo.exports[doc.ID].Status)
	}
	if _, ok := h.objs.get(doc.ObjectPath); ok {
		t.Error("the FAILED export kept its object")
	}
}
