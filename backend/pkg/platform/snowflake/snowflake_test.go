package snowflake

import (
	"strings"
	"sync"
	"testing"
	"time"
)

func TestGenerate_Format(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	id := n.Generate()
	if len(id) != 19 {
		t.Fatalf("len(id) = %d, want 19: %q", len(id), id)
	}
	for _, r := range id {
		if r < '0' || r > '9' {
			t.Fatalf("id contains non-digit: %q", id)
		}
	}
}

func TestGenerate_MonotonicAndUnique(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	seen := make(map[string]bool)
	prev := ""
	for i := 0; i < 10_000; i++ {
		id := n.Generate()
		if id <= prev {
			t.Fatalf("id not strictly increasing: prev=%q id=%q at i=%d", prev, id, i)
		}
		if seen[id] {
			t.Fatalf("duplicate id: %q", id)
		}
		seen[id] = true
		prev = id
	}
}

func TestGenerate_ConcurrentUnique(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	const goroutines = 20
	const perGoroutine = 500
	ids := make(chan string, goroutines*perGoroutine)
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				ids <- n.Generate()
			}
		}()
	}
	wg.Wait()
	close(ids)

	seen := make(map[string]bool, goroutines*perGoroutine)
	for id := range ids {
		if seen[id] {
			t.Fatalf("duplicate id under concurrency: %q", id)
		}
		seen[id] = true
	}
}

func TestGenerate_TimeOrderMatchesLexicographicOrder(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	t0 := Epoch.Add(24 * time.Hour)
	n.now = func() time.Time { return t0 }
	first := n.Generate()

	n.now = func() time.Time { return t0.Add(5 * time.Second) }
	second := n.Generate()

	if strings.Compare(first, second) >= 0 {
		t.Fatalf("expected first < second lexicographically: %q, %q", first, second)
	}
}

func TestGenerate_SequenceOverflowRollsToNextMillisecond(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	tick := Epoch.Add(48 * time.Hour)
	callCount := 0
	n.now = func() time.Time {
		callCount++
		// First maxSeq+2 calls report the same millisecond, then time advances.
		if callCount > maxSeq+2 {
			return tick.Add(time.Millisecond)
		}
		return tick
	}

	var last int64
	for i := 0; i <= maxSeq+1; i++ {
		id := n.generateInt()
		if id <= last {
			t.Fatalf("expected strictly increasing ids through sequence overflow, got %d after %d", id, last)
		}
		last = id
	}
}

func TestGenerate_ClockRollbackWaits(t *testing.T) {
	n, err := NewNode()
	if err != nil {
		t.Fatalf("NewNode() error = %v", err)
	}
	base := Epoch.Add(72 * time.Hour)
	n.now = func() time.Time { return base }
	first := n.generateInt()

	// Simulate a clock that rolled back one millisecond, then recovers on the next call.
	rolledBack := true
	n.now = func() time.Time {
		if rolledBack {
			rolledBack = false
			return base.Add(-time.Millisecond)
		}
		return base.Add(time.Millisecond)
	}
	second := n.generateInt()

	if second <= first {
		t.Fatalf("expected id after clock rollback to still be strictly increasing: first=%d second=%d", first, second)
	}
}

func TestTime(t *testing.T) {
	n := &Node{node: 5, now: func() time.Time { return Epoch.Add(1234 * time.Millisecond) }}
	got, err := Time(n.Generate())
	if err != nil || !got.Equal(Epoch.Add(1234*time.Millisecond)) {
		t.Fatalf("Time = %v, %v", got, err)
	}
	for _, bad := range []string{"", "abc", "-1"} {
		if _, err := Time(bad); err == nil {
			t.Errorf("Time(%q) must fail", bad)
		}
	}
}
