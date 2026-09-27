package budget

import (
	"context"
	"sync"
	"testing"
)

func TestCounter_AddAndRead(t *testing.T) {
	ctx, c := WithCounter(context.Background())
	c.AddReads(2)
	c.AddWrites(1)
	c.AddDeletes(3)

	if got := FromContext(ctx); got.Reads() != 2 || got.Writes() != 1 || got.Deletes() != 3 {
		t.Fatalf("counter = reads:%d writes:%d deletes:%d", got.Reads(), got.Writes(), got.Deletes())
	}
}

func TestFromContext_NoCounterIsNilSafe(t *testing.T) {
	c := FromContext(context.Background())
	// Must not panic, and must report zero.
	c.AddReads(5)
	c.AddWrites(5)
	c.AddDeletes(5)
	if c.Reads() != 0 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Fatalf("nil counter should report zero: reads=%d writes=%d deletes=%d", c.Reads(), c.Writes(), c.Deletes())
	}
}

func TestCounter_AddZeroIsNoop(t *testing.T) {
	_, c := WithCounter(context.Background())
	c.AddReads(0)
	c.AddWrites(0)
	c.AddDeletes(0)
	if c.Reads() != 0 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Fatal("adding zero should not change the counter")
	}
}

func TestCounter_ConcurrentAdds(t *testing.T) {
	_, c := WithCounter(context.Background())
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.AddReads(1)
		}()
	}
	wg.Wait()
	if c.Reads() != 100 {
		t.Fatalf("Reads() = %d, want 100", c.Reads())
	}
}
