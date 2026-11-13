package apiserver

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/billing"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

func registerBillingLifecycle(l *identity.Lifecycle, bindings *billing.FirestoreBindings) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, bindings); err != nil {
		return err
	}
	return l.RegisterExportSection(bindings)
}

// Share the existing five-minute cron, preserving its response and 30 s limit.
// No production Scheduler/IAM change is required to recover accepted work.
func withBillingRecovery(inner http.Handler, step trendsStep, log *slog.Logger) http.Handler {
	return withBillingRecoveryClock(inner, step, log, time.Now)
}

func withBillingRecoveryClock(inner http.Handler, step trendsStep, log *slog.Logger, now func() time.Time) http.Handler {
	if step == nil {
		return inner
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := now()
		rec := &statusRecorder{header: http.Header{}}
		inner.ServeHTTP(rec, r)
		if r.Method == http.MethodPost {
			left := 28*time.Second - now().Sub(started)
			if left >= billing.RecoveryAttemptBudget {
				ctx, cancel := context.WithTimeout(r.Context(), min(left, 15*time.Second))
				runBillingRecovery(ctx, step, log)
				cancel()
			} else {
				log.WarnContext(r.Context(), "billing_webhook_recovery", "outcome", "skipped_deadline")
			}
		}
		rec.replay(w)
	})
}
func runBillingRecovery(ctx context.Context, step trendsStep, log *slog.Logger) {
	defer func() {
		if recover() != nil {
			log.ErrorContext(ctx, "billing_webhook_recovery", "outcome", "panic")
		}
	}()
	if err := step.Refresh(ctx); err != nil {
		log.WarnContext(ctx, "billing_webhook_recovery", "outcome", "retry_pending")
	} else {
		log.InfoContext(ctx, "billing_webhook_recovery", "outcome", "complete")
	}
}
func billingRecoveryHandler(step trendsStep, log *slog.Logger, projectID string) http.Handler {
	return mw.RecoverHTTP(log, projectID, "billing_webhook_recovery", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		if err := step.Refresh(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}
