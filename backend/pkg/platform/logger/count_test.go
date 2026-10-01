package logger

import (
	"context"
	"testing"
)

func TestAddRequestCount_SumsAcrossCalls(t *testing.T) {
	ctx, info := WithRequestInfo(context.Background())
	AddRequestCount(ctx, "posts_cache_hit", 3)
	AddRequestCount(ctx, "posts_cache_hit", 0)
	AddRequestCount(ctx, "posts_cache_hit", 4)
	AddRequestCount(ctx, "other", 1)
	if v, ok := info.Get("posts_cache_hit"); !ok || v != int64(7) {
		t.Fatalf("posts_cache_hit = %v (%T), %v; want int64 7", v, v, ok)
	}
	if v, _ := info.Get("other"); v != int64(1) {
		t.Fatalf("other = %v, want 1", v)
	}
	if n := len(info.Fields()); n != 2 {
		t.Fatalf("fields = %d, want 2 (a counter is one field, not one per call)", n)
	}
}

func TestAddRequestCount_ReplacesANonCounterValue(t *testing.T) {
	ctx, info := WithRequestInfo(context.Background())
	SetRequestField(ctx, "k", true)
	AddRequestCount(ctx, "k", 2)
	if v, _ := info.Get("k"); v != int64(2) {
		t.Fatalf("k = %v, want 2", v)
	}
}

func TestAddRequestCount_NoRequestInfoIsANoop(t *testing.T) {
	AddRequestCount(context.Background(), "k", 1) // must not panic
}
