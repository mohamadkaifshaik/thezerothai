package identity

import (
	"context"
	"strings"
	"testing"
	"time"
)

// The backstop republishes on errgroup goroutines. A panic there is that run's error, so the cron route answers 500 and
// Cloud Scheduler retries, instead of the instance ending.
func TestBackstop_PanicOnPublisherIsTheRunsError(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("stuck", "Stuck", 3*time.Hour)
	p, _ := h.repo.user("stuck")
	p.DeletionJob = &DeletionJob{Seq: 1, ProgressAt: h.clock.Now().Add(-2 * time.Hour)}
	h.repo.seed(p)
	h.pub.hook = func() { panic("boom") }
	if _, err := h.l.Backstop(context.Background()); err == nil || !strings.Contains(err.Error(), "panic of type string") {
		t.Fatalf("err = %v, want the panic as the run's error", err)
	}
}
