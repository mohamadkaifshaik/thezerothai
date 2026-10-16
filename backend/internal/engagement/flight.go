package engagement

import (
	"errors"
	"sync"
)

var errFlightPanic = errors.New("engagement: like flight panicked")

// flight collapses concurrent calls with one key into a single execution, like singleflight.Group.DoChan, with
// two additions the like path needs: every caller (leader included) waits on a channel so it can honour its own
// context, and onJoin (tests only) fires when a caller joins a flight already in progress, which gives the
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

// do returns a channel that yields exactly one result. fn runs in its own goroutine, once per concurrent key.
func (f *flight) do(key string, fn func() (any, error)) <-chan flightResult {
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
		return out
	}
	c := &flightCall{done: make(chan struct{})}
	f.calls[key] = c
	f.mu.Unlock()
	go func() {
		defer func() {
			// A panic in fn must not leave followers waiting forever (nor crash the instance from a goroutine
			// no HTTP recovery covers): every waiter gets an internal error.
			if r := recover(); r != nil {
				c.err = errFlightPanic
			}
			f.mu.Lock()
			delete(f.calls, key)
			f.mu.Unlock()
			close(c.done)
			out <- flightResult{val: c.val, err: c.err, led: true}
		}()
		c.val, c.err = fn()
	}()
	return out
}
