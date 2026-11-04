package identity

import (
	"net/http"
	"testing"
)

// The daily_maintenance_success log metric in infra/terraform/modules/monitoring matches this exact pair of fields, and the
// heartbeat alert fires when the metric goes quiet. Renaming either one needs the same change in that filter.
func TestCronHandler_SuccessLineFeedsTheHeartbeatMetric(t *testing.T) {
	h := newHarness(t)
	rec := newRecorder()
	h.l.CronHandler().ServeHTTP(rec, newRequest(http.MethodPost))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	lines := h.logs.records("account_job")
	if len(lines) != 1 {
		t.Fatalf("account_job lines = %d, want 1: %s", len(lines), h.logs.String())
	}
	if lines[0]["account_job"] != "backstop" || lines[0]["outcome"] != "ok" {
		t.Fatalf("line = %v, want account_job=backstop outcome=ok", lines[0])
	}
}
