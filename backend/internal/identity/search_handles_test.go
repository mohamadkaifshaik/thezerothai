package identity

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

func TestPrefixSucc(t *testing.T) {
	t.Parallel()
	tests := []struct {
		in, want string
		ok       bool
	}{
		{"ab", "ac", true},
		{"z", "{", true},
		{"az", "a{", true},
		{"ab_", "ab`", true},
		{"a9", "a:", true},
		{"", "", false},
		{"a\xff", "", false},
	}
	for _, tc := range tests {
		got, ok := prefixSucc(tc.in)
		if got != tc.want || ok != tc.ok {
			t.Errorf("prefixSucc(%q) = %q, %v; want %q, %v", tc.in, got, ok, tc.want, tc.ok)
		}
	}
}

func TestSearchHandles_Service(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	for _, h := range []string{"abd", "ab", "abc", "ab_c", "zz", "b"} {
		repo.profiles["uid-"+h] = Profile{UserID: "uid-" + h, HandleLower: h, Status: AccountStatusActive}
	}
	repo.profiles["uid-sus"] = Profile{UserID: "uid-sus", HandleLower: "abx", Status: AccountStatusSuspended}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour).(*service)

	tests := []struct {
		name      string
		prefix    string
		limit     int
		want      []string
		wantLimit int // limit passed to the repo; 0 = repo not called
		wantReads int64
	}{
		{"order and exact first, status kept", "AB", 20, []string{"ab", "ab_c", "abc", "abd", "abx"}, 20, 5},
		{"limit clamped to 20", "ab", 50, []string{"ab", "ab_c", "abc", "abd", "abx"}, 20, 5},
		{"limit below 1 clamped to 1", "ab", 0, []string{"ab"}, 1, 1},
		{"limit respected", "ab", 2, []string{"ab", "ab_c"}, 2, 2},
		{"no match bills 1", "q", 5, nil, 5, 1},
		{"empty prefix: nothing, 0 reads", "", 5, nil, 0, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			before := repo.searchCalls
			ctx, counter := budget.WithCounter(context.Background())
			got, err := svc.SearchHandles(ctx, tc.prefix, tc.limit)
			if err != nil {
				t.Fatal(err)
			}
			var handles []string
			for _, p := range got {
				handles = append(handles, p.HandleLower)
			}
			if len(handles) != len(tc.want) {
				t.Fatalf("handles = %v, want %v", handles, tc.want)
			}
			for i := range handles {
				if handles[i] != tc.want[i] {
					t.Fatalf("handles = %v, want %v", handles, tc.want)
				}
			}
			if tc.wantLimit == 0 {
				if repo.searchCalls != before {
					t.Fatal("repo called for an empty prefix")
				}
			} else if last := repo.searchArgs[len(repo.searchArgs)-1]; last.limit != tc.wantLimit {
				t.Fatalf("repo limit = %d, want %d", last.limit, tc.wantLimit)
			}
			if counter.Reads() != tc.wantReads {
				t.Fatalf("reads = %d, want %d", counter.Reads(), tc.wantReads)
			}
		})
	}
	// The suspended account is returned raw, with its status.
	got, _ := svc.SearchHandles(context.Background(), "abx", 5)
	if len(got) != 1 || got[0].Status != AccountStatusSuspended {
		t.Fatalf("suspended profile not returned raw: %+v", got)
	}
}
