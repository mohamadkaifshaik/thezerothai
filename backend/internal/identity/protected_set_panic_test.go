package identity

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type panicSetSource struct{ reads atomic.Int64 }

func (s *panicSetSource) LoadProtectedSet(context.Context) ([]string, error) {
	s.reads.Add(1)
	panic("boom")
}

// The refresh runs on singleflight's DoChan goroutine, where a panic is re-raised on a fresh goroutine that nothing can
// recover: it would end the instance. It must act like any failed read: fail closed, hold the retry backoff, and leave no
// refresh marked in flight.
func TestProtectedSetLoader_PanicInLoadIsAFailedRead(t *testing.T) {
	var logs bytes.Buffer
	clock := &setClock{t: time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	src := &panicSetSource{}
	l := NewProtectedSetLoader(src, time.Minute, 10*time.Minute, clock.now, slog.New(slog.NewJSONHandler(&logs, nil)))

	for i := range 3 {
		if s, err := l.Current(context.Background()); !errors.Is(err, ErrProtectedSetUnavailable) || s != nil {
			t.Fatalf("call %d: %v, %v; want ErrProtectedSetUnavailable", i, s, err)
		}
	}
	if got := src.reads.Load(); got != 1 {
		t.Errorf("3 calls read %d times, want 1 (the retry backoff holds after a panic)", got)
	}
	if !strings.Contains(logs.String(), protectedSetLoadOp) {
		t.Errorf("the panic was not reported: %s", logs.String())
	}
	l.mu.Lock()
	inflight := l.inflight
	l.mu.Unlock()
	if inflight {
		t.Error("the refresh is still marked in flight")
	}
}
