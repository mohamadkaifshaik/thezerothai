package identity

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

func handleNames(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("user%02d", i)
	}
	return out
}

func resolveWithBudget(t *testing.T, svc *service, in []string) (map[string]string, int64) {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	got, err := svc.ResolveHandles(ctx, in)
	if err != nil {
		t.Fatalf("ResolveHandles: %v", err)
	}
	if c.Writes() != 0 {
		t.Fatalf("ResolveHandles wrote %d docs", c.Writes())
	}
	return got, c.Reads()
}

// TestResolveHandles_TenHandlesSixCached is the T7 acceptance: 10 handles with 6 cached = 4 reads in one GetAll.
func TestResolveHandles_TenHandlesSixCached(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	names := handleNames(10)
	for i, h := range names {
		repo.handles[h] = fmt.Sprintf("uid-%d", i)
	}
	for i, h := range names[:6] {
		svc.cache.SetHandleUID(h, fmt.Sprintf("uid-%d", i))
	}

	got, reads := resolveWithBudget(t, svc, names)
	if reads != 4 || repo.resolveManyCalls != 1 {
		t.Fatalf("reads=%d GetAll calls=%d, want 4 and 1", reads, repo.resolveManyCalls)
	}
	if !reflect.DeepEqual(repo.resolveManyArgs[0], names[6:]) {
		t.Fatalf("fetched %v, want only the uncached %v", repo.resolveManyArgs[0], names[6:])
	}
	if len(got) != 10 || got["user00"] != "uid-0" || got["user09"] != "uid-9" {
		t.Fatalf("got %v", got)
	}

	// Everything is cached now.
	_, reads = resolveWithBudget(t, svc, names)
	if reads != 0 || repo.resolveManyCalls != 1 {
		t.Fatalf("repeat: reads=%d calls=%d, want 0 and 1", reads, repo.resolveManyCalls)
	}
}

func TestResolveHandles(t *testing.T) {
	tests := []struct {
		name      string
		in        []string
		stored    map[string]string
		wantMap   map[string]string
		wantCalls int
		wantReads int64
		wantFetch []string
	}{
		{"no handles", nil, nil, map[string]string{}, 0, 0, nil},
		{
			"unknown handle is absent and still one read",
			[]string{"ghost"}, map[string]string{}, map[string]string{}, 1, 1, []string{"ghost"},
		},
		{
			"known and unknown mixed",
			[]string{"alice", "ghost"}, map[string]string{"alice": "uid-a"}, map[string]string{"alice": "uid-a"}, 1, 2, []string{"alice", "ghost"},
		},
		{
			"input is lower-cased and deduplicated",
			[]string{"Alice", "ALICE", "alice"}, map[string]string{"alice": "uid-a"}, map[string]string{"alice": "uid-a"}, 1, 1, []string{"alice"},
		},
		{
			"malformed and reserved handles cost nothing",
			[]string{"ab", "admin", "has-dash", "abcdefghijklmnop", ""}, map[string]string{"admin": "uid-x"}, map[string]string{}, 0, 0, nil,
		},
		{
			"valid among skipped is the only read",
			[]string{"ab", "bob", "root"}, map[string]string{"bob": "uid-b"}, map[string]string{"bob": "uid-b"}, 1, 1, []string{"bob"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			for h, uid := range tc.stored {
				repo.handles[h] = uid
			}
			svc := newTestService(repo)
			got, reads := resolveWithBudget(t, svc, tc.in)
			if !reflect.DeepEqual(got, tc.wantMap) {
				t.Fatalf("map = %v, want %v", got, tc.wantMap)
			}
			if repo.resolveManyCalls != tc.wantCalls || reads != tc.wantReads {
				t.Fatalf("calls=%d reads=%d, want %d and %d", repo.resolveManyCalls, reads, tc.wantCalls, tc.wantReads)
			}
			if tc.wantFetch != nil {
				fetched := append([]string(nil), repo.resolveManyArgs[0]...)
				sort.Strings(fetched)
				if !reflect.DeepEqual(fetched, tc.wantFetch) {
					t.Fatalf("fetched %v, want %v", fetched, tc.wantFetch)
				}
			}
		})
	}
}

// TestResolveHandles_NegativeCache: an unknown handle is remembered as free for the 10 s negative TTL, so a
// repeat costs 0 reads; CreateProfile claiming it clears the entry.
func TestResolveHandles_NegativeCache(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)

	if _, reads := resolveWithBudget(t, svc, []string{"newbie"}); reads != 1 {
		t.Fatalf("first reads = %d, want 1", reads)
	}
	got, reads := resolveWithBudget(t, svc, []string{"newbie"})
	if len(got) != 0 || reads != 0 || repo.resolveManyCalls != 1 {
		t.Fatalf("repeat: got=%v reads=%d calls=%d, want empty, 0, 1", got, reads, repo.resolveManyCalls)
	}
	// The negative cache is shared with CheckHandleAvailability (no second cache).
	if ok, _, err := svc.CheckHandleAvailability(context.Background(), "newbie"); err != nil || !ok || repo.resolveCalls != 0 {
		t.Fatalf("CheckHandleAvailability: ok=%v err=%v ResolveHandle calls=%d, want a cache answer", ok, err, repo.resolveCalls)
	}

	// Claiming the handle (SetProfile) clears the negative entry, so the next resolve sees it.
	repo.handles["newbie"] = "uid-n"
	svc.cache.SetProfile(Profile{UserID: "uid-n", Handle: "newbie", HandleLower: "newbie"})
	got, _ = resolveWithBudget(t, svc, []string{"newbie"})
	if got["newbie"] != "uid-n" {
		t.Fatalf("got %v, want newbie -> uid-n", got)
	}
}

// TestResolveHandles_SharesTheHandleCache: a resolved handle is a CheckHandleAvailability cache hit.
func TestResolveHandles_SharesTheHandleCache(t *testing.T) {
	repo := newFakeRepo()
	repo.handles["taken"] = "uid-t"
	svc := newTestService(repo)
	resolveWithBudget(t, svc, []string{"taken"})
	ok, _, err := svc.CheckHandleAvailability(context.Background(), "taken")
	if err != nil || ok || repo.resolveCalls != 0 {
		t.Fatalf("ok=%v err=%v resolveCalls=%d, want taken from the cache", ok, err, repo.resolveCalls)
	}
}

func TestResolveHandles_Errors(t *testing.T) {
	t.Run("more than ten distinct handles is rejected before any read", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestService(repo)
		if _, err := svc.ResolveHandles(context.Background(), handleNames(MaxResolveHandles+1)); err == nil || repo.resolveManyCalls != 0 {
			t.Fatalf("err=%v calls=%d, want an error and no read", err, repo.resolveManyCalls)
		}
		// Ten distinct plus duplicates is fine.
		in := append(handleNames(MaxResolveHandles), handleNames(MaxResolveHandles)...)
		if _, err := svc.ResolveHandles(context.Background(), in); err != nil {
			t.Fatalf("10 distinct handles with duplicates rejected: %v", err)
		}
	})
	t.Run("a repo failure is returned, wrapped, and nothing is cached", func(t *testing.T) {
		repo := newFakeRepo()
		boom := errors.New("boom")
		repo.resolveManyErr = boom
		svc := newTestService(repo)
		if _, err := svc.ResolveHandles(context.Background(), []string{"alice"}); !errors.Is(err, boom) {
			t.Fatalf("err = %v, want it to wrap the repo error", err)
		}
		repo.resolveManyErr = nil
		repo.handles["alice"] = "uid-a"
		got, _ := resolveWithBudget(t, svc, []string{"alice"})
		if got["alice"] != "uid-a" {
			t.Fatalf("a failed lookup poisoned the cache: %v", got)
		}
	})
}
