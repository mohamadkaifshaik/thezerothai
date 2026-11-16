package identity

import (
	"testing"
	"time"
)

// Cache is a thin wrapper over cache.LRU (already covered by pkg/platform/cache's own tests); these tests
// just confirm identity wires Get/Set/Invalidate through correctly, including the two Invalidate* methods
// that no caller uses yet (dead code today — flagged to backend-developer; see tester handback report).

func TestCache_ProfileRoundTrip(t *testing.T) {
	c := NewCache(time.Minute)
	if _, ok := c.GetProfile("uid-1"); ok {
		t.Fatal("expected a miss before SetProfile")
	}
	p := Profile{UserID: "uid-1", Handle: "Alice", HandleLower: "alice"}
	c.SetProfile(p)

	got, ok := c.GetProfile("uid-1")
	if !ok || got != p {
		t.Fatalf("GetProfile() = %+v, %v; want %+v, true", got, ok, p)
	}
	if uid, ok := c.GetHandleUID("alice"); !ok || uid != "uid-1" {
		t.Fatalf("GetHandleUID(alice) = %q, %v; want uid-1, true", uid, ok)
	}

	c.InvalidateProfile("uid-1")
	if _, ok := c.GetProfile("uid-1"); ok {
		t.Fatal("expected a miss after InvalidateProfile")
	}
}

func TestCache_SetProfile_SkipsHandleMappingWhenHandleLowerEmpty(t *testing.T) {
	c := NewCache(time.Minute)
	c.SetProfile(Profile{UserID: "uid-1"})
	if _, ok := c.GetHandleUID(""); ok {
		t.Fatal("expected no handle mapping for an empty HandleLower")
	}
}

func TestCache_InvalidateHandle(t *testing.T) {
	c := NewCache(time.Minute)
	c.SetProfile(Profile{UserID: "uid-1", Handle: "Alice", HandleLower: "alice"})
	c.InvalidateHandle("alice")
	if _, ok := c.GetHandleUID("alice"); ok {
		t.Fatal("expected a miss after InvalidateHandle")
	}
}

func TestCache_UnreadCountRoundTrip(t *testing.T) {
	c := NewCache(time.Minute)
	if _, ok := c.GetUnreadCount("uid-1"); ok {
		t.Fatal("expected a miss before SetUnreadCount")
	}
	c.SetUnreadCount("uid-1", 5)
	if n, ok := c.GetUnreadCount("uid-1"); !ok || n != 5 {
		t.Fatalf("GetUnreadCount() = %d, %v; want 5, true", n, ok)
	}
	c.InvalidateUnreadCount("uid-1")
	if _, ok := c.GetUnreadCount("uid-1"); ok {
		t.Fatal("expected a miss after InvalidateUnreadCount")
	}
}

// A new notification row (InvalidateUnreadBelowCap) keeps an unread count at the cap and evicts any lower one; the
// pending count is evicted either way, and InvalidateUnreadCount always evicts both (audit L1).
func TestCache_InvalidateUnreadBelowCap(t *testing.T) {
	tests := []struct {
		name       string
		cached     int64 // -1 = nothing cached
		belowCap   bool  // InvalidateUnreadBelowCap, else InvalidateUnreadCount
		wantUnread bool
	}{
		{"at cap: kept", UnreadBadgeCap, true, true},
		{"below cap: evicted", UnreadBadgeCap - 1, true, false},
		{"zero: evicted", 0, true, false},
		{"nothing cached: still nothing", -1, true, false},
		{"full invalidation at cap: evicted", UnreadBadgeCap, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := NewCache(time.Minute)
			if tt.cached >= 0 {
				c.SetUnreadCount("uid-1", tt.cached)
			}
			c.SetPendingCount("uid-1", 3)
			if tt.belowCap {
				c.InvalidateUnreadBelowCap("uid-1")
			} else {
				c.InvalidateUnreadCount("uid-1")
			}
			n, ok := c.GetUnreadCount("uid-1")
			if ok != tt.wantUnread || (ok && n != tt.cached) {
				t.Errorf("unread = %d, %v; want cached=%v (%d)", n, ok, tt.wantUnread, tt.cached)
			}
			if _, ok := c.GetPendingCount("uid-1"); ok {
				t.Error("pending count must always be evicted")
			}
		})
	}
}
