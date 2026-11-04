package mw_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"golang.org/x/sync/errgroup"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

func panicsHere() error { panic("boom uid-secret") }

func TestRecoverGo_PanicBecomesTheGroupError(t *testing.T) {
	var logs bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&logs, nil))

	var g errgroup.Group
	g.Go(mw.RecoverGo(context.Background(), log, "test/worker", panicsHere))
	err := g.Wait()

	if err == nil || !strings.Contains(err.Error(), "panic of type string") {
		t.Fatalf("Wait = %v, want the panic as an error", err)
	}
	out := logs.String()
	for _, want := range []string{`"level":"ERROR"`, `"rpc":"test/worker"`, "ReportedErrorEvent", "panicsHere"} {
		if !strings.Contains(out, want) {
			t.Errorf("report misses %q: %s", want, out)
		}
	}
	if strings.Contains(out, "uid-secret") || strings.Contains(err.Error(), "uid-secret") {
		t.Errorf("the panic value escaped: err %v, log %s", err, out)
	}
}

func TestRecoverGo_PassesAnOrdinaryResultThrough(t *testing.T) {
	var logs bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&logs, nil))
	want := errors.New("plain")

	if err := mw.RecoverGo(context.Background(), log, "op", func() error { return nil })(); err != nil {
		t.Fatalf("nil result = %v", err)
	}
	if err := mw.RecoverGo(context.Background(), log, "op", func() error { return want })(); !errors.Is(err, want) {
		t.Fatalf("error result = %v", err)
	}
	if logs.Len() != 0 {
		t.Fatalf("a normal return reported: %s", logs.String())
	}
}
