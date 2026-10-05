package identity

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TestResolveHandles_StalePositiveEntry is ADR-0010 D21 G5: bob renames to bob2 and carol claims "bob" while this
// instance still holds bob -> bob2's uid. A positive entry is a hit for at most notFoundTTL (10 s); a cached
// profile that contradicts it also turns it into a miss.
func TestResolveHandles_StalePositiveEntry(t *testing.T) {
	const bob2UID, carolUID = "uid-bob2", "uid-carol"
	tests := []struct {
		name         string
		age          time.Duration
		cachedHandle string // HandleLower of bob2's profile in the instance cache; "" = not cached
		wantUID      string
		wantReads    int64
	}{
		{"11 s old: miss, carol wins", 11 * time.Second, "", carolUID, 1},
		{"9 s old, profile shows the rename: miss, carol wins", 9 * time.Second, "bob2", carolUID, 1},
		{"9 s old, profile still shows bob: hit", 9 * time.Second, "bob", bob2UID, 0},
		// The accepted residual: nothing local contradicts the entry, so the stale mapping is served.
		{"9 s old, no cached profile: stale mapping is the accepted residual", 9 * time.Second, "", bob2UID, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.handles["bob"] = carolUID // carol claimed it
			svc := newTestService(repo)
			clock := time.Unix(1_000_000, 0)
			svc.cache.now = func() time.Time { return clock }
			svc.cache.SetHandleUID("bob", bob2UID) // learned before the rename
			if tt.cachedHandle != "" {
				svc.cache.SetProfile(Profile{UserID: bob2UID, HandleLower: tt.cachedHandle, Status: AccountStatusActive})
				svc.cache.SetHandleUID("bob", bob2UID) // SetProfile of "bob2" must not hide the stale entry's age
			}
			clock = clock.Add(tt.age)

			ctx, c := budget.WithCounter(context.Background())
			got, err := svc.ResolveHandles(ctx, []string{"bob"})
			if err != nil {
				t.Fatal(err)
			}
			if got["bob"] != tt.wantUID || c.Reads() != tt.wantReads {
				t.Fatalf("uid=%q reads=%d, want %q and %d", got["bob"], c.Reads(), tt.wantUID, tt.wantReads)
			}
		})
	}
}

// TestCache_GetHandleUIDKeepsFullTTL: only ResolveHandles tightens the bound.
func TestCache_GetHandleUIDKeepsFullTTL(t *testing.T) {
	c := NewCache(time.Minute)
	clock := time.Unix(1_000_000, 0)
	c.now = func() time.Time { return clock }
	c.SetHandleUID("bob", "uid-1")
	clock = clock.Add(30 * time.Second)
	if uid, ok := c.GetHandleUID("bob"); !ok || uid != "uid-1" {
		t.Fatalf("GetHandleUID = %q, %v", uid, ok)
	}
	if _, ok := c.GetHandleUIDFresh("bob", notFoundTTL); ok {
		t.Fatal("30 s old entry must not be fresh within 10 s")
	}
}
