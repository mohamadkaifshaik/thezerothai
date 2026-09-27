// Package budget counts Firestore reads/writes/deletes per request so the request log line carries
// fs_reads/fs_writes (observability skill) and integration tests can assert an RPC's documented
// worst-case budget (testing-strategy skill, ADR-0003).
package budget

import (
	"context"
	"sync/atomic"
)

// Counter is a request-scoped, concurrency-safe accumulator. Repos call Add* as they issue Firestore
// operations; the logging interceptor reads the totals after the handler returns.
type Counter struct {
	reads   int64
	writes  int64
	deletes int64
}

func (c *Counter) AddReads(n int64) {
	if c == nil || n == 0 {
		return
	}
	atomic.AddInt64(&c.reads, n)
}

func (c *Counter) AddWrites(n int64) {
	if c == nil || n == 0 {
		return
	}
	atomic.AddInt64(&c.writes, n)
}

func (c *Counter) AddDeletes(n int64) {
	if c == nil || n == 0 {
		return
	}
	atomic.AddInt64(&c.deletes, n)
}

func (c *Counter) Reads() int64 {
	if c == nil {
		return 0
	}
	return atomic.LoadInt64(&c.reads)
}

func (c *Counter) Writes() int64 {
	if c == nil {
		return 0
	}
	return atomic.LoadInt64(&c.writes)
}

func (c *Counter) Deletes() int64 {
	if c == nil {
		return 0
	}
	return atomic.LoadInt64(&c.deletes)
}

type ctxKey struct{}

// WithCounter attaches a fresh Counter to ctx, returning the new context and the counter so the caller
// (typically the logging interceptor) can read totals after the request completes.
func WithCounter(ctx context.Context) (context.Context, *Counter) {
	c := &Counter{}
	return context.WithValue(ctx, ctxKey{}, c), c
}

// FromContext returns the Counter attached by WithCounter, or nil if none (safe to call Add*/read on nil).
func FromContext(ctx context.Context) *Counter {
	c, _ := ctx.Value(ctxKey{}).(*Counter)
	return c
}
