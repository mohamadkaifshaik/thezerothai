package lists

import (
	"context"
	"errors"
	"testing"
)

// L-1 (W5-45): a missing id is remembered for the TTL, so a repeat probe is 0 reads; a write that creates the list on this
// instance (cache.put) makes it visible to its owner at once; other errors are never remembered.
func TestLoadList_NegativeCache(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	l := listN(9, testUID)

	t.Run("a missing id costs one read, then none", func(t *testing.T) {
		t.Parallel()
		s, fr := newTestService(&fakeRepo{}, nil, oldAccount())
		for i := range 3 {
			if _, err := s.loadList(ctx, l.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("call %d: err = %v, want ErrNotFound", i, err)
			}
		}
		if got := fr.readCalls(); got != 1 {
			t.Errorf("repo reads = %d, want 1", got)
		}
	})
	t.Run("a list created after a negative entry is visible at once", func(t *testing.T) {
		t.Parallel()
		s, fr := newTestService(&fakeRepo{}, nil, oldAccount())
		if _, err := s.loadList(ctx, l.ID); !errors.Is(err, ErrNotFound) {
			t.Fatalf("err = %v, want ErrNotFound", err)
		}
		fr.seed(l)
		s.cache.put(l) // what CreateList does with the written list
		got, err := s.loadList(ctx, l.ID)
		if err != nil || got.ID != l.ID {
			t.Fatalf("after create: %+v, %v", got, err)
		}
	})
	t.Run("an evicted list is read again", func(t *testing.T) {
		t.Parallel()
		s, fr := newTestService(&fakeRepo{}, nil, oldAccount())
		fr.seed(l)
		if _, err := s.loadList(ctx, l.ID); err != nil {
			t.Fatal(err)
		}
		s.cache.evict(l.ID)
		if _, err := s.loadList(ctx, l.ID); err != nil {
			t.Fatal(err)
		}
		if got := fr.readCalls(); got != 2 {
			t.Errorf("repo reads = %d, want 2", got)
		}
	})
	t.Run("a failed read is not remembered as missing", func(t *testing.T) {
		t.Parallel()
		fr := &fakeRepo{getErr: errors.New("unavailable")}
		s, _ := newTestService(fr, nil, oldAccount())
		for range 2 {
			if _, err := s.loadList(ctx, l.ID); err == nil || errors.Is(err, ErrNotFound) {
				t.Fatalf("err = %v, want the repository error", err)
			}
		}
		if got := fr.readCalls(); got != 2 {
			t.Errorf("repo reads = %d, want 2 (not cached)", got)
		}
	})
}
