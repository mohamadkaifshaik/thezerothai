package engagement

import (
	"errors"
	"sync"
	"testing"
)

func TestFlight_PanicReachesLeaderAndFollowerAndClearsKey(t *testing.T) {
	var f flight
	joined := make(chan struct{})
	f.onJoin = func(string) { close(joined) }
	release := make(chan struct{})
	started := make(chan struct{})
	lead, isLeader := f.do("k", func() (any, error) {
		close(started)
		<-release
		panic("boom")
	})
	if !isLeader {
		t.Fatal("first caller must lead")
	}
	<-started
	follow, isLeader2 := f.do("k", func() (any, error) { return nil, nil })
	if isLeader2 {
		t.Fatal("second caller must join")
	}
	<-joined
	close(release)
	for name, ch := range map[string]<-chan flightResult{"leader": lead, "follower": follow} {
		if r := <-ch; !errors.Is(r.err, errFlightPanic) {
			t.Errorf("%s err = %v, want errFlightPanic", name, r.err)
		}
	}
	f.mu.Lock()
	n := len(f.calls)
	f.mu.Unlock()
	if n != 0 {
		t.Fatalf("flight keys left = %d, want 0", n)
	}
	var mu sync.Mutex
	ran := 0
	ch, led := f.do("k", func() (any, error) { mu.Lock(); ran++; mu.Unlock(); return 7, nil })
	if r := <-ch; !led || r.err != nil || r.val != 7 {
		t.Fatalf("next do: %+v led=%v", r, led)
	}
	mu.Lock()
	defer mu.Unlock()
	if ran != 1 {
		t.Fatalf("fn ran %d times, want 1", ran)
	}
}
