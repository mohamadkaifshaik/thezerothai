package lists

import "testing"

// The cache stores copies: a caller changing the member slice it was given, or the one it got back, never changes the entry.
func TestDocCache_CopiesAndEvicts(t *testing.T) {
	t.Parallel()
	c := newDocCache(10)
	members := []string{"a", "b"}
	c.put(List{ID: "1", Name: "n", MemberIDs: members})
	members[0] = "changed"
	got, ok := c.get("1")
	if !ok || got.MemberIDs[0] != "a" {
		t.Fatalf("get = %+v, %v, want the stored copy", got, ok)
	}
	got.MemberIDs[1] = "changed"
	if again, _ := c.get("1"); again.MemberIDs[1] != "b" {
		t.Errorf("a returned slice aliases the cached one: %v", again.MemberIDs)
	}
	c.evict("1")
	if _, ok := c.get("1"); ok {
		t.Error("evict left the entry")
	}
	if _, ok := c.get("never"); ok {
		t.Error("a missing id was found")
	}
}

// The entry count is bounded by CACHE_LISTS_ENTRIES, and a zero config still yields a working one-entry cache.
func TestDocCache_Bounded(t *testing.T) {
	t.Parallel()
	c := newDocCache(2)
	c.put(List{ID: "1"})
	c.put(List{ID: "2"})
	c.put(List{ID: "3"})
	if n := c.lru.Len(); n != 2 {
		t.Errorf("entries = %d, want 2", n)
	}
	one := newDocCache(0)
	one.put(List{ID: "1"})
	if _, ok := one.get("1"); !ok {
		t.Error("a zero size must still give a working cache")
	}
}
