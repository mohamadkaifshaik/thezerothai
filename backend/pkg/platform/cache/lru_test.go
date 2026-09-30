package cache

import (
	"sync"
	"testing"
	"time"
)

func TestLRU_SetGet(t *testing.T) {
	c := New[string, int](10, time.Minute)
	c.Set("a", 1)
	v, ok := c.Get("a")
	if !ok || v != 1 {
		t.Fatalf("Get(a) = %v, %v; want 1, true", v, ok)
	}
	if _, ok := c.Get("missing"); ok {
		t.Fatal("Get(missing) should miss")
	}
}

func TestLRU_TTLExpiry(t *testing.T) {
	now := time.Now()
	c := New[string, int](10, time.Second)
	c.now = func() time.Time { return now }
	c.Set("a", 1)

	c.now = func() time.Time { return now.Add(2 * time.Second) }
	if _, ok := c.Get("a"); ok {
		t.Fatal("expected entry to have expired")
	}
}

func TestLRU_CapacityEviction(t *testing.T) {
	c := New[string, int](2, time.Minute)
	c.Set("a", 1)
	c.Set("b", 2)
	c.Set("c", 3) // evicts "a" (least recently used)

	if _, ok := c.Get("a"); ok {
		t.Fatal("expected a to be evicted")
	}
	if v, ok := c.Get("b"); !ok || v != 2 {
		t.Fatalf("Get(b) = %v, %v", v, ok)
	}
	if v, ok := c.Get("c"); !ok || v != 3 {
		t.Fatalf("Get(c) = %v, %v", v, ok)
	}
}

func TestLRU_RecentlyUsedSurvives(t *testing.T) {
	c := New[string, int](2, time.Minute)
	c.Set("a", 1)
	c.Set("b", 2)
	c.Get("a") // touch a, making b the LRU
	c.Set("c", 3)

	if _, ok := c.Get("b"); ok {
		t.Fatal("expected b to be evicted, a should have survived")
	}
	if _, ok := c.Get("a"); !ok {
		t.Fatal("expected a to survive (recently used)")
	}
}

func TestLRU_Delete(t *testing.T) {
	c := New[string, int](10, time.Minute)
	c.Set("a", 1)
	c.Delete("a")
	if _, ok := c.Get("a"); ok {
		t.Fatal("expected a to be deleted")
	}
	if c.Len() != 0 {
		t.Fatalf("Len() = %d, want 0", c.Len())
	}
}

func TestLRU_SetOverwritesAndRefreshesTTL(t *testing.T) {
	now := time.Now()
	c := New[string, int](10, time.Second)
	c.now = func() time.Time { return now }
	c.Set("a", 1)

	c.now = func() time.Time { return now.Add(500 * time.Millisecond) }
	c.Set("a", 2) // refresh TTL

	c.now = func() time.Time { return now.Add(1200 * time.Millisecond) }
	v, ok := c.Get("a")
	if !ok || v != 2 {
		t.Fatalf("Get(a) = %v, %v; want 2, true (TTL should have refreshed)", v, ok)
	}
}

func TestLRU_UnboundedCapacity(t *testing.T) {
	c := New[int, int](0, time.Minute)
	for i := 0; i < 1000; i++ {
		c.Set(i, i*i)
	}
	if c.Len() != 1000 {
		t.Fatalf("Len() = %d, want 1000 (capacity <= 0 means unbounded)", c.Len())
	}
}

func TestLRU_GetOrSet(t *testing.T) {
	c := New[string, *int](10, 0)
	made := 0
	mk := func() *int { made++; v := made; return &v }
	a := c.GetOrSet("k", mk)
	b := c.GetOrSet("k", mk)
	if a != b || made != 1 {
		t.Fatalf("second GetOrSet must return the first value without calling mk (made=%d)", made)
	}
	if got, ok := c.Get("k"); !ok || got != a {
		t.Fatal("GetOrSet value must be visible to Get")
	}
}

func TestLRU_GetOrSet_ConcurrentFirstAccessSharesOneValue(t *testing.T) {
	c := New[string, *int](10, 0)
	var wg sync.WaitGroup
	out := make([]*int, 64)
	for i := range out {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out[i] = c.GetOrSet("k", func() *int { return new(int) })
		}()
	}
	wg.Wait()
	for i, v := range out {
		if v != out[0] {
			t.Fatalf("goroutine %d got a different value: first-access race", i)
		}
	}
}
