package mw

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// RecoverGo wraps fn for a goroutine of its own, for example errgroup's Go. Recover and RecoverHTTP cover only the goroutine
// that runs the handler, and a panic on any other goroutine ends the process with every request on it. Here it becomes fn's
// error and an Error Reporting entry that has the stack of the panic. Only the panic's type is reported: its value could
// carry a uid or document text. op names the work in the entry's rpc field.
func RecoverGo(ctx context.Context, log *slog.Logger, op string, fn func() error) func() error {
	return func() (err error) {
		defer func() {
			if v := recover(); v != nil {
				err = fmt.Errorf("%s: panic of type %T", op, v)
				ReportError(ctx, log.With(logger.TraceAttrs(ctx)...), op, logger.ScrubErr(err))
			}
		}()
		return fn()
	}
}
