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

// scriptedClock returns the given times in order and then repeats the last one forever, so every spin loop in
// generateInt terminates on a finite script.
func scriptedClock(times ...time.Time) func() time.Time {
	i := 0
	return func() time.Time {
		t := times[i]
		if i < len(times)-1 {
			i++
		}
		return t
	}
}

// decode splits a generated id into its millisecond and sequence parts.
func decode(id int64) (ms, seq int64) {
	return id >> timeShift, id & maxSeq
}

// A11: once a backwards clock has been waited out and the clock is back on the last millisecond issued, the next id
// takes the same-millisecond path (sequence + 1, spin on overflow) instead of reusing sequence 0, which duplicated
// the first id of that millisecond.
func TestGenerate_ClockRollbackRecovery(t *testing.T) {
	base := Epoch.Add(96 * time.Hour)
	baseMs := base.UnixMilli() - epochMillis
	ms := func(d int) time.Time { return base.Add(time.Duration(d) * time.Millisecond) }

	tests := []struct {
		name string
		// prefill ids are generated at base before the rollback (1 = one id, maxSeq+1 = the sequence is exhausted).
		prefill int
		// after is what the clock reads on the calls of the next generateInt (the last value repeats).
		after   []time.Time
		wantMs  int64
		wantSeq int64
	}{
		{"T, T-1, T: same millisecond, next sequence", 1, []time.Time{ms(-1), ms(0)}, baseMs, 1},
		{"T, T-1, T+1: new millisecond, sequence 0", 1, []time.Time{ms(-1), ms(1)}, baseMs + 1, 0},
		{"T, T-1, T-2, T: long rollback, same millisecond", 1, []time.Time{ms(-1), ms(-2), ms(0)}, baseMs, 1},
		{"exhausted at T, T-1, T, T, T+1: spins to the next millisecond", maxSeq + 1, []time.Time{ms(-1), ms(0), ms(0), ms(1)}, baseMs + 1, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			n := &Node{node: 7, now: func() time.Time { return base }}
			seen := map[int64]bool{}
			var last int64
			for i := 0; i < tt.prefill; i++ {
				last = n.generateInt()
				seen[last] = true
			}
			n.now = scriptedClock(tt.after...)
			got := n.generateInt()
			if seen[got] {
				t.Fatalf("id %d after the clock recovered duplicates an earlier id", got)
			}
			if got <= last {
				t.Fatalf("id %d after the clock recovered is not above the previous id %d", got, last)
			}
			if gotMs, gotSeq := decode(got); gotMs != tt.wantMs || gotSeq != tt.wantSeq {
				t.Fatalf("decoded (ms, seq) = (%d, %d), want (%d, %d)", gotMs, gotSeq, tt.wantMs, tt.wantSeq)
			}
		})
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

func TestMinID(t *testing.T) {
	ms := time.Date(2026, 3, 4, 5, 6, 7, 89_000_000, time.UTC)
	min := MinID(ms)
	if len(min) != 19 {
		t.Fatalf("MinID = %q, want 19 digits", min)
	}
	if got, err := Time(min); err != nil || !got.Equal(ms) {
		t.Fatalf("Time(MinID) = %v, %v; want %v", got, err, ms)
	}
	// Every id of that millisecond is >= MinID, every id of the millisecond before is below it.
	n := &Node{node: maxNode, now: func() time.Time { return ms }}
	if id := n.Generate(); id < min {
		t.Fatalf("id %q of the millisecond is below MinID %q", id, min)
	}
	n = &Node{node: maxNode, now: func() time.Time { return ms.Add(-time.Millisecond) }}
	if id := n.Generate(); id >= min {
		t.Fatalf("id %q of the previous millisecond is not below MinID %q", id, min)
	}
	if got := MinID(Epoch.Add(-time.Hour)); got != "0000000000000000000" {
		t.Fatalf("MinID before the epoch = %q, want all zero", got)
	}
}
