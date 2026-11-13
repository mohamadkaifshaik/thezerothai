package apiserver

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type billingRecoveryProbe struct {
	calls           int
	providerHasTime bool
}

func (p *billingRecoveryProbe) Refresh(ctx context.Context) error {
	p.calls++
	deadline, ok := ctx.Deadline()
	// A normal provider request can take ten seconds. Leave time for storage.
	p.providerHasTime = ok && time.Until(deadline) > 10*time.Second
	return nil
}

func TestBillingRecoveryAllowsProviderRequestAndPreservesResponse(t *testing.T) {
	step := &billingRecoveryProbe{}
	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Sweep", "complete")
		w.WriteHeader(http.StatusAccepted)
	})
	h := withBillingRecovery(inner, step, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/internal/cron/publish-scheduled", nil))
	if step.calls != 1 || !step.providerHasTime {
		t.Fatal("recovery cancels before a healthy provider request can complete")
	}
	if w.Code != http.StatusAccepted || w.Header().Get("X-Sweep") != "complete" {
		t.Fatal("recovery changed the scheduled sweep response")
	}
}

func TestBillingRecoverySkipsWhenCronBudgetCannotFitProvider(t *testing.T) {
	step := &billingRecoveryProbe{}
	started := time.Now()
	clockCalls := 0
	now := func() time.Time {
		clockCalls++
		if clockCalls == 1 {
			return started
		}
		return started.Add(18 * time.Second) // ten seconds left in the cron budget
	}
	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	h := withBillingRecoveryClock(inner, step, slog.New(slog.NewTextHandler(io.Discard, nil)), now)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/internal/cron/publish-scheduled", nil))
	if step.calls != 0 || w.Code != http.StatusNoContent {
		t.Fatal("insufficient budget started doomed work or changed the sweep result")
	}
}

func TestBillingRecoveryDoesNotRunForGet(t *testing.T) {
	step := &billingRecoveryProbe{}
	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusMethodNotAllowed) })
	h := withBillingRecovery(inner, step, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/internal/cron/publish-scheduled", nil))
	if step.calls != 0 || w.Code != http.StatusMethodNotAllowed {
		t.Fatal("GET ran recovery")
	}
}
