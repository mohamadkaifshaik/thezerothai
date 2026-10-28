package identity

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// setClock is a settable clock for the loader.
type setClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *setClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *setClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type fakeSetSource struct {
	reads atomic.Int64
	mu    sync.Mutex
	uids  []string
	err   error
}

func (s *fakeSetSource) LoadProtectedSet(context.Context) ([]string, error) {
	s.reads.Add(1)
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.uids, s.err
}

func (s *fakeSetSource) set(uids []string, err error) {
	s.mu.Lock()
	s.uids, s.err = uids, err
	s.mu.Unlock()
}

func newLoaderForTest(src *fakeSetSource) (*ProtectedSetLoader, *setClock, *bytes.Buffer) {
	clock := &setClock{t: time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	return NewProtectedSetLoader(src, time.Minute, 10*time.Minute, clock.now, log), clock, &buf
}

func TestProtectedSetCanSee(t *testing.T) {
	t.Parallel()
	set := newProtectedSet([]string{"p"})
	tests := []struct {
		name            string
		viewer, author  string
		following, want bool
	}{
		{"own protected", "p", "p", false, true},
		{"public author", "v", "q", false, true},
		{"protected, not following", "v", "p", false, false},
		{"protected, following", "v", "p", true, true},
	}
	for _, tt := range tests {
		if got := set.CanSee(tt.viewer, tt.author, tt.following); got != tt.want {
			t.Errorf("%s: CanSee = %v, want %v", tt.name, got, tt.want)
		}
	}
}

func TestProtectedSetLoader_LazyAndTTL(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{uids: []string{"p1", "p2"}}
	l, clock, _ := newLoaderForTest(src)
	if src.reads.Load() != 0 {
		t.Fatal("the loader read before anyone asked")
	}
	for i := 0; i < 5; i++ {
		s, err := l.Current(context.Background())
		if err != nil || !s.Has("p1") || s.Has("zz") {
			t.Fatalf("Current = %v, %v", s, err)
		}
	}
	if got := src.reads.Load(); got != 1 {
		t.Fatalf("5 calls inside the TTL read %d times, want 1", got)
	}
	clock.advance(59 * time.Second)
	_, _ = l.Current(context.Background())
	if got := src.reads.Load(); got != 1 {
		t.Fatalf("a call at 59 s read again (%d)", got)
	}
	clock.advance(2 * time.Second)
	src.set([]string{"p3"}, nil)
	s, err := l.Current(context.Background())
	if err != nil || !s.Has("p3") || s.Has("p1") || src.reads.Load() != 2 {
		t.Fatalf("after the TTL: has p3=%v has p1=%v reads=%d err=%v, want a fresh read", s.Has("p3"), s.Has("p1"), src.reads.Load(), err)
	}
}

func TestProtectedSetLoader_MissingDocIsEmptySet(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{} // nil uids, nil error: the doc does not exist
	l, _, _ := newLoaderForTest(src)
	s, err := l.Current(context.Background())
	if err != nil || s == nil || s.Has("anyone") {
		t.Fatalf("Current = %v, %v; want an empty set", s, err)
	}
}

func TestProtectedSetLoader_FiftyConcurrentCallsOneRead(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{uids: []string{"p"}}
	l, _, _ := newLoaderForTest(src)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if s, err := l.Current(context.Background()); err != nil || !s.Has("p") {
				t.Errorf("Current = %v, %v", s, err)
			}
		}()
	}
	close(start)
	wg.Wait()
	if got := src.reads.Load(); got != 1 {
		t.Fatalf("50 concurrent calls on an expired cache read %d times, want exactly 1", got)
	}
}

func TestProtectedSetLoader_StaleThenUnavailable(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{uids: []string{"p"}}
	l, clock, buf := newLoaderForTest(src)
	if _, err := l.Current(context.Background()); err != nil {
		t.Fatal(err)
	}
	src.set(nil, errors.New("firestore down"))

	// Failing for 9 minutes: the last good set is served, with a WARN.
	clock.advance(9 * time.Minute)
	s, err := l.Current(context.Background())
	if err != nil || !s.Has("p") {
		t.Fatalf("at 9 min: %v, %v; want the last good set", s, err)
	}
	if !strings.Contains(buf.String(), "protected_set_stale") {
		t.Errorf("no WARN protected_set_stale in %s", buf.String())
	}
	if strings.Contains(buf.String(), "protected_set_unavailable") {
		t.Error("ERROR logged while the stale set was still allowed")
	}

	// Failing for 11 minutes: fail closed, never an empty set.
	clock.advance(2 * time.Minute)
	s, err = l.Current(context.Background())
	if !errors.Is(err, ErrProtectedSetUnavailable) || s != nil {
		t.Fatalf("at 11 min: %v, %v; want ErrProtectedSetUnavailable and no set", s, err)
	}
	if !strings.Contains(buf.String(), "protected_set_unavailable") {
		t.Errorf("no ERROR protected_set_unavailable in %s", buf.String())
	}

	// Recovery.
	src.set([]string{"q"}, nil)
	clock.advance(10 * time.Second)
	if s, err = l.Current(context.Background()); err != nil || !s.Has("q") {
		t.Fatalf("after recovery: %v, %v", s, err)
	}
}

func TestProtectedSetLoader_NeverLoadedFailsClosed(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{err: errors.New("firestore down")}
	l, clock, _ := newLoaderForTest(src)
	for i := 0; i < 3; i++ {
		s, err := l.Current(context.Background())
		if !errors.Is(err, ErrProtectedSetUnavailable) || s != nil {
			t.Fatalf("call %d: %v, %v; want ErrProtectedSetUnavailable", i, s, err)
		}
	}
	// Failures back off: three requests in the same instant cost one attempt, not three.
	if got := src.reads.Load(); got != 1 {
		t.Errorf("3 calls during an outage read %d times, want 1 (retry backoff)", got)
	}
	clock.advance(protectedSetRetryBackoff + time.Second)
	_, _ = l.Current(context.Background())
	if got := src.reads.Load(); got != 2 {
		t.Errorf("reads after the backoff = %d, want 2", got)
	}
}

func TestProtectedSetLoader_InstallAndApply(t *testing.T) {
	t.Parallel()
	src := &fakeSetSource{uids: []string{"a"}}
	l, clock, _ := newLoaderForTest(src)

	// Apply on an instance that never loaded invents nothing.
	l.Apply("x", true)
	if l.set != nil {
		t.Fatal("Apply created a set on an instance that never loaded one")
	}

	// Install makes the committing instance see its own protect at once, without a read.
	l.Install([]string{"a", "x"}, clock.now())
	s, err := l.Current(context.Background())
	if err != nil || !s.Has("x") || src.reads.Load() != 0 {
		t.Fatalf("after Install: has x=%v reads=%d err=%v", s.Has("x"), src.reads.Load(), err)
	}
	// A set a consumer already holds is never mutated.
	l.Apply("x", false)
	if !s.Has("x") {
		t.Error("Apply mutated a published snapshot")
	}
	s2, _ := l.Current(context.Background())
	if s2.Has("x") || !s2.Has("a") {
		t.Errorf("after Apply(x, false): has x=%v has a=%v", s2.Has("x"), s2.Has("a"))
	}
}
