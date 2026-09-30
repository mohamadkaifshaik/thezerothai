// Command api is the dzeroth modular monolith (ADR-0002): one Cloud Run service, one cold start, every
// module behind Connect-RPC. main() only wires dependencies — nothing heavy runs before ListenAndServe
// (cold-start budget: container start < 500ms, cold start incl. first request < 1.5s). The actual mux
// wiring lives in backend/internal/apiserver.Build so backend/e2e can boot the identical handler (a
// `package main` cannot be imported by another package, so that wiring can't live here).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "go.uber.org/automaxprocs" // right-sizes GOMAXPROCS for the container's cgroup CPU limit

	"github.com/dzeroth/dzeroth/backend/internal/apiserver"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		// No logger yet (config failed to load); this is a startup-only fatal path, never a request path.
		fmt.Fprintln(os.Stderr, "config: "+err.Error())
		os.Exit(1)
	}
	log := logger.New(cfg.ProjectID)
	slog.SetDefault(log)

	if err := run(ctx, cfg, log); err != nil {
		log.Error("fatal", "error", err.Error())
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	mux, fsClient, err := apiserver.Build(ctx, cfg, log)
	if err != nil {
		return err
	}
	defer fsClient.Close()

	// Cloud Run terminates TLS and speaks cleartext HTTP/2 (h2c) to the container; the stdlib has
	// supported that natively since Go 1.24, replacing the deprecated x/net/http2/h2c wrapper.
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           mux,
		Protocols:         protocols,
		ReadHeaderTimeout: 5 * time.Second,
		// ADR-0010 D5 A5: bound the header size (default 1 MiB) so a huge X-Forwarded-For cannot be pushed
		// through the IP-keyed structures.
		MaxHeaderBytes: 64 << 10,
		// IdleTimeout bounds how long a kept-alive connection with no in-flight request may sit open;
		// without it http.Server never times those out on its own (minor fix from the phase0 code review).
		IdleTimeout: 120 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "port", cfg.Port, "env", cfg.Env, "degraded_mode", string(cfg.Degraded))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	select {
	case <-ctx.Done():
		log.Info("shutdown signal received")
	case err := <-errCh:
		if err != nil {
			return fmt.Errorf("listen: %w", err)
		}
	}

	// Cloud Run sends SIGTERM and gives the process 10s before SIGKILL; leave headroom.
	shCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	return nil
}
