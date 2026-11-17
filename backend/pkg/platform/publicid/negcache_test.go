package publicid

import (
	"context"
	"slices"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }
func newClock() *fakeClock                   { return &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)} }
func lastCall(f *fakeResolver) []string      { return f.calls[len(f.calls)-1] }
func callCount(f *fakeResolver) int          { return len(f.calls) }
func newNeg(t *testing.T, inner Resolver, size int, clk *fakeClock) *NegativeCache {
	t.Helper()
	c, err := NewNegativeCache(inner, size, 5*time.Minute, clk.now)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestNegativeCache_Validation(t *testing.T) {
	clk := newClock()
	inner := newFakeResolver(nil)
	for name, fn := range map[string]func() (*NegativeCache, error){
		"nil inner": func() (*NegativeCache, error) { return NewNegativeCache(nil, 1, time.Minute, clk.now) },
		"size 0":    func() (*NegativeCache, error) { return NewNegativeCache(inner, 0, time.Minute, clk.now) },
		"ttl 0":     func() (*NegativeCache, error) { return NewNegativeCache(inner, 1, 0, clk.now) },
		"nil clock": func() (*NegativeCache, error) { return NewNegativeCache(inner, 1, time.Minute, nil) },
	} {
		if _, err := fn(); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

// TestNegativeCache_HitSkipsInner: a uid with no public id is asked once; within the ttl it is answered "none" without
// a call, and a page mixing it with others asks inner only for the others. Found uids are never cached here.
func TestNegativeCache_HitSkipsInner(t *testing.T) {
	ctx := context.Background()
	clk := newClock()
	inner := newFakeResolver(map[string]string{uidN(1): pubN(1)})
	c := newNeg(t, inner, 10, clk)

	got, err := c.PublicIDsForUIDs(ctx, []string{uidN(1), uidN(9)})
	if err != nil || got[uidN(1)] != pubN(1) || len(got) != 1 {
		t.Fatalf("first = %v, %v", got, err)
	}
	clk.advance(4 * time.Minute)
	got, err = c.PublicIDsForUIDs(ctx, []string{uidN(9)})
	if err != nil || len(got) != 0 || callCount(inner) != 1 {
		t.Fatalf("all known: got %v, err %v, inner calls %d; want no call", got, err, callCount(inner))
	}
	for _, page := range [][]string{{uidN(9), uidN(1)}, {uidN(1), uidN(9)}, {uidN(9), uidN(1), uidN(9)}} {
		if _, err := c.PublicIDsForUIDs(ctx, page); err != nil {
			t.Fatal(err)
		}
		if got := lastCall(inner); !slices.Equal(got, []string{uidN(1)}) {
			t.Errorf("page %v asked inner for %v, want only uid1", page, got)
		}
	}
	if c.Len() != 1 {
		t.Errorf("entries = %d, want 1 (only the uid with none)", c.Len())
	}
}

// TestNegativeCache_ExpiryShowsMintedID: after the ttl the uid is asked again, so an id minted meanwhile appears.
func TestNegativeCache_ExpiryShowsMintedID(t *testing.T) {
	ctx := context.Background()
	clk := newClock()
	inner := newFakeResolver(nil)
	c := newNeg(t, inner, 10, clk)
	if _, err := c.PublicIDsForUIDs(ctx, []string{uidN(4)}); err != nil {
		t.Fatal(err)
	}
	inner.mu.Lock()
	inner.uidToPub[uidN(4)] = pubN(4) // minted (backfill or the account's GetMe)
	inner.mu.Unlock()
	clk.advance(5*time.Minute - time.Nanosecond)
	if got, _ := c.PublicIDsForUIDs(ctx, []string{uidN(4)}); len(got) != 0 || callCount(inner) != 1 {
		t.Fatalf("inside the ttl: %v, %d calls", got, callCount(inner))
	}
	clk.advance(time.Nanosecond)
	got, err := c.PublicIDsForUIDs(ctx, []string{uidN(4)})
	if err != nil || got[uidN(4)] != pubN(4) || callCount(inner) != 2 {
		t.Fatalf("at expiry: %v, %v, %d calls; want the minted id from a second call", got, err, callCount(inner))
	}
	if c.Len() != 0 {
		t.Errorf("entries = %d, want 0 once the id is found", c.Len())
	}
}

// TestNegativeCache_Bounded: the least recently used entry goes first when the bound is reached.
func TestNegativeCache_Bounded(t *testing.T) {
	ctx := context.Background()
	clk := newClock()
	inner := newFakeResolver(nil)
	c := newNeg(t, inner, 2, clk)
	for _, u := range []int{1, 2, 3} {
		if _, err := c.PublicIDsForUIDs(ctx, []string{uidN(u)}); err != nil {
			t.Fatal(err)
		}
	}
	if c.Len() != 2 {
		t.Fatalf("entries = %d, want the bound 2", c.Len())
	}
	if _, err := c.PublicIDsForUIDs(ctx, []string{uidN(1), uidN(2), uidN(3)}); err != nil {
		t.Fatal(err)
	}
	if got := lastCall(inner); !slices.Equal(got, []string{uidN(1)}) {
		t.Errorf("asked %v, want only the evicted uid1", got)
	}
}

// TestNegativeCache_ErrorRemembersNothing: a failed lookup caches no "none", and the reverse direction is not cached.
func TestNegativeCache_ErrorRemembersNothing(t *testing.T) {
	ctx := context.Background()
	clk := newClock()
	inner := newFakeResolver(map[string]string{uidN(1): pubN(1)})
	c := newNeg(t, inner, 10, clk)
	inner.err = errResolver
	if _, err := c.PublicIDsForUIDs(ctx, []string{uidN(9)}); err == nil {
		t.Fatal("want the inner error")
	}
	if c.Len() != 0 {
		t.Fatalf("entries = %d after an error", c.Len())
	}
	inner.err = nil
	for range 2 {
		got, err := c.UIDsForPublicIDs(ctx, []string{pubN(1), pubN(7)})
		if err != nil || got[pubN(1)] != uidN(1) {
			t.Fatalf("UIDsForPublicIDs = %v, %v", got, err)
		}
	}
	if callCount(inner) != 3 || c.Len() != 0 {
		t.Errorf("inner calls %d, entries %d; want every reverse lookup passed through", callCount(inner), c.Len())
	}
}
