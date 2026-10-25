package mw

import (
	"fmt"
	"log/slog"
	"net/http"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// RecoverHTTP wraps an /internal/* HTTP handler (a Pub/Sub push or a Scheduler cron route, which have no Connect
// interceptor chain) so a panic on the handler's own goroutine becomes a 500 and an Error Reporting entry instead of
// a crashed request path. Pub/Sub and Cloud Scheduler retry a 500. Only the panic TYPE is reported: its value could
// carry a uid or document text. op names the route in the entry's rpc field (for example "cron/publish-scheduled").
//
// It covers only the goroutine ServeHTTP runs on: a handler that starts goroutines must recover inside them (the
// publish sweep does, per item).
func RecoverHTTP(log *slog.Logger, projectID, op string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, projectID))
				ReportError(ctx, log.With(logger.TraceAttrs(ctx)...), op, logger.ScrubErr(fmt.Errorf("panic of type %T", v)))
				w.WriteHeader(http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}
