package search

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// RefreshRunDeadline is the deadline of the standalone route (ADR-0028 D7).
const RefreshRunDeadline = 25 * time.Second

// NewRefreshHandler is the `/internal/cron/trends-refresh` route (ADR-0028 D7): POST only, a 25 s deadline, panic
// recovery, and 204 unless Refresh returns an error (the document read, the first page or the protected set failed;
// nothing was written), which is 500. The refresher owns the budget counter and writes the trends_refresh line and the
// Error Reporting entry. Mount it behind the OIDC verifier. It serves dev (a direct OIDC call; dev has no Scheduler
// jobs) and the hourly option (F1 A); prod runs the same step inside daily-maintenance (F1 B).
func NewRefreshHandler(r TrendsRefresher, log *slog.Logger, projectID string) http.Handler {
	return mw.RecoverHTTP(log, projectID, refreshOp, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(logger.WithTrace(req.Context(), logger.TraceFromRequest(req, projectID)), RefreshRunDeadline)
		defer cancel()
		if err := r.Refresh(ctx); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}
