package engagement

import (
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync"
)

var errFlightPanic = errors.New("engagement: like flight panicked")

// flight collapses concurrent calls with one key into a single execution, like singleflight.Group.DoChan, with
// two additions the like path needs: callers wait on a channel so a follower can honour its own context (the
// leader never abandons its own flight: the post-commit effects must run), and onJoin (tests only) fires when a caller joins a flight already in progress, which gives the
// concurrency tests a deterministic seam instead of scheduler yields.
type flight struct {
	mu     sync.Mutex
	calls  map[string]*flightCall
	onJoin func(key string)
}

type flightCall struct {
	done chan struct{}
	val  any
	err  error
}

// flightResult is what a caller receives; led is true for the caller that ran fn.
type flightResult struct {
	val any
	err error
	led bool
}

// do returns a channel that yields exactly one result, and whether this caller is the leader (ran fn). fn runs in
// its own goroutine, once per concurrent key.
func (f *flight) do(key string, fn func() (any, error)) (<-chan flightResult, bool) {
	out := make(chan flightResult, 1)
	f.mu.Lock()
	if f.calls == nil {
		f.calls = map[string]*flightCall{}
	}
	if c, ok := f.calls[key]; ok {
		hook := f.onJoin
		f.mu.Unlock()
		if hook != nil {
			hook(key)
		}
		go func() {
			<-c.done
			out <- flightResult{val: c.val, err: c.err}
		}()
		return out, false
	}
	c := &flightCall{done: make(chan struct{})}
	f.calls[key] = c
	f.mu.Unlock()
	go func() {
		defer func() {
			// A panic in fn must not leave followers waiting forever (nor crash the instance from a goroutine
			// no HTTP recovery covers): every waiter gets an internal error.
			if r := recover(); r != nil {
				slog.Error("engagement: like flight panicked", "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
				c.err = fmt.Errorf("%w: %v", errFlightPanic, r)
			}
			f.mu.Lock()
			delete(f.calls, key)
			f.mu.Unlock()
			close(c.done)
			out <- flightResult{val: c.val, err: c.err, led: true}
		}()
		c.val, c.err = fn()
	}()
	return out, true
}
