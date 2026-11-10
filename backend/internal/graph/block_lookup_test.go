package graph

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
)

func TestBlockersAmong(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		viewer     Snapshot
		others     map[string]Snapshot
		cached     []string // candidates already in the instance cache before the call
		candidates []string
		want       string
		wantBatch  []string // uids of the one batched read; nil means no batched read
	}{
		{
			name:       "no overflow: the viewer's blockedBy answers, no batched read",
			viewer:     Snapshot{BlockedBy: map[string]bool{"uid-b": true}},
			others:     map[string]Snapshot{"uid-c": {Blocked: map[string]bool{"uid-a": true}}},
			candidates: []string{"uid-b", "uid-c"},
			want:       "uid-b",
		},
		{
			name:       "overflow: the misses' own blocked lists are read in one batch",
			viewer:     Snapshot{BlockedBy: map[string]bool{"uid-b": true}, BlockedByOverflow: true},
			others:     map[string]Snapshot{"uid-c": {Blocked: map[string]bool{"uid-a": true}}, "uid-d": {}},
			candidates: []string{"uid-b", "uid-c", "uid-d", "uid-c"},
			want:       "uid-b,uid-c",
			wantBatch:  []string{"uid-c", "uid-d"},
		},
		{
			name:       "overflow: a cached candidate is not read again",
			viewer:     Snapshot{BlockedByOverflow: true},
			others:     map[string]Snapshot{"uid-c": {Blocked: map[string]bool{"uid-a": true}}, "uid-d": {Blocked: map[string]bool{"uid-a": true}}},
			cached:     []string{"uid-c"},
			candidates: []string{"uid-c", "uid-d"},
			want:       "uid-c,uid-d",
			wantBatch:  []string{"uid-d"},
		},
		{
			name:       "overflow: everything cached, no batched read",
			viewer:     Snapshot{BlockedByOverflow: true},
			others:     map[string]Snapshot{"uid-c": {}},
			cached:     []string{"uid-c"},
			candidates: []string{"uid-c"},
			want:       "",
		},
		{
			name:       "no candidates",
			viewer:     Snapshot{BlockedByOverflow: true},
			candidates: nil,
			want:       "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			repo.snapshots["uid-a"] = tc.viewer
			for uid, s := range tc.others {
				repo.snapshots[uid] = s
			}
			svc := newTestServiceWithRepo(repo, true)
			for _, uid := range tc.cached {
				svc.cache.Set(uid, repo.snapshots[uid])
			}
			got, err := svc.BlockersAmong(context.Background(), "uid-a", tc.candidates)
			if err != nil {
				t.Fatalf("BlockersAmong: %v", err)
			}
			var ids []string
			for id, ok := range got {
				if ok {
					ids = append(ids, id)
				}
			}
			sort.Strings(ids)
			if strings.Join(ids, ",") != tc.want {
				t.Errorf("blockers = %v, want %q", ids, tc.want)
			}
			if tc.wantBatch == nil {
				if repo.batchCalls != 0 {
					t.Errorf("batched reads = %d, want 0", repo.batchCalls)
				}
				return
			}
			if repo.batchCalls != 1 {
				t.Fatalf("batched reads = %d, want 1", repo.batchCalls)
			}
			batch := append([]string(nil), repo.batchUIDs[0]...)
			sort.Strings(batch)
			if strings.Join(batch, ",") != strings.Join(tc.wantBatch, ",") {
				t.Errorf("batch = %v, want %v", batch, tc.wantBatch)
			}
			// What the batch read is cached: a second call reads nothing more.
			if _, err := svc.BlockersAmong(context.Background(), "uid-a", tc.candidates); err != nil {
				t.Fatal(err)
			}
			if repo.batchCalls != 1 {
				t.Errorf("batched reads after a repeat = %d, want 1 (cached)", repo.batchCalls)
			}
		})
	}
}

// A full lookup is read in chunks, each cached as soon as it lands: when a later chunk fails, the call fails (the
// caller fails closed) but the earlier chunks stay cached, so the retry reads only what is still missing.
func TestBlockersAmong_ChunkedReadKeepsEarlierChunksOnFailure(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.snapshots["uid-a"] = Snapshot{BlockedByOverflow: true}
	candidates := make([]string, MaxBlockLookup)
	for i := range candidates {
		candidates[i] = fmt.Sprintf("uid-%03d", i)
	}
	repo.snapshots["uid-099"] = Snapshot{Blocked: map[string]bool{"uid-a": true}}
	repo.batchErr, repo.batchErrOnCall = errors.New("deadline exceeded"), 2
	svc := newTestServiceWithRepo(repo, true)

	if _, err := svc.BlockersAmong(context.Background(), "uid-a", candidates); err == nil {
		t.Fatal("a failed chunk must fail the lookup")
	}
	if repo.batchCalls != 2 {
		t.Fatalf("batched reads = %d, want 2 (stop at the failed chunk)", repo.batchCalls)
	}
	for i, uids := range repo.batchUIDs {
		if len(uids) > blockLookupChunk {
			t.Errorf("batch %d read %d docs, want at most %d", i, len(uids), blockLookupChunk)
		}
	}
	first := repo.batchUIDs[0]

	repo.batchErr = nil
	got, err := svc.BlockersAmong(context.Background(), "uid-a", candidates)
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	if len(got) != 1 || !got["uid-099"] {
		t.Errorf("blockers = %v, want only uid-099", got)
	}
	reread := 0
	for _, uids := range repo.batchUIDs[2:] {
		for _, u := range uids {
			for _, f := range first {
				if u == f {
					reread++
				}
			}
		}
	}
	if reread != 0 {
		t.Errorf("the retry re-read %d docs of the first chunk, want 0 (cached)", reread)
	}
	if total := len(repo.batchUIDs[2:]); total == 0 {
		t.Error("the retry read nothing: the failed chunks were not cached and must be read")
	}
}

func TestBlockersAmong_Errors(t *testing.T) {
	t.Parallel()
	t.Run("batched read fails: the cause is wrapped", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.snapshots["uid-a"] = Snapshot{BlockedByOverflow: true}
		repo.batchErr = errors.New("rpc error: graph/uid-secret not readable")
		svc := newTestServiceWithRepo(repo, true)
		_, err := svc.BlockersAmong(context.Background(), "uid-a", []string{"uid-secret"})
		if err == nil {
			t.Fatal("want an error")
		}
		if !errors.Is(err, repo.batchErr) {
			t.Errorf("error does not wrap the cause: %v", err)
		}
	})
	t.Run("viewer graph fails", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.err = errors.New("boom")
		svc := newTestServiceWithRepo(repo, true)
		if _, err := svc.BlockersAmong(context.Background(), "uid-a", []string{"uid-b"}); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("over the cap: nothing read", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.snapshots["uid-a"] = Snapshot{BlockedByOverflow: true}
		svc := newTestServiceWithRepo(repo, true)
		many := make([]string, MaxBlockLookup+1)
		for i := range many {
			many[i] = fmt.Sprintf("uid-%03d", i)
		}
		if _, err := svc.BlockersAmong(context.Background(), "uid-a", many); err == nil {
			t.Fatal("want an error over the cap")
		}
		if repo.calls != 0 || repo.batchCalls != 0 {
			t.Errorf("reads = %d + %d batched, want none", repo.calls, repo.batchCalls)
		}
		// Duplicates do not count against the cap.
		dup := make([]string, MaxBlockLookup+1)
		for i := range dup {
			dup[i] = "uid-b"
		}
		if _, err := svc.BlockersAmong(context.Background(), "uid-a", dup); err != nil {
			t.Errorf("duplicates over the cap: %v", err)
		}
	})
}
