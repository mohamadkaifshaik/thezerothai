package logger

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTraceFromRequest_Traceparent(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
	got := TraceFromRequest(r, "my-project")
	want := "projects/my-project/traces/4bf92f3577b34da6a3ce929d0e0e4736"
	if got != want {
		t.Errorf("TraceFromRequest() = %q, want %q", got, want)
	}
}

func TestTraceFromRequest_CloudTraceContextFallback(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("X-Cloud-Trace-Context", "105445aa7843bc8bf206b120001000/1;o=1")
	got := TraceFromRequest(r, "my-project")
	want := "projects/my-project/traces/105445aa7843bc8bf206b120001000"
	if got != want {
		t.Errorf("TraceFromRequest() = %q, want %q", got, want)
	}
}

func TestTraceFromRequest_NoHeaders(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	if got := TraceFromRequest(r, "my-project"); got != "" {
		t.Errorf("TraceFromRequest() = %q, want empty", got)
	}
}

func TestTraceFromRequest_MalformedTraceparent(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("traceparent", "not-a-valid-traceparent")
	if got := TraceFromRequest(r, "my-project"); got != "" {
		t.Errorf("TraceFromRequest() = %q, want empty for malformed header", got)
	}
}

func TestHashUID_DeterministicAndNotPlaintext(t *testing.T) {
	h1 := HashUID("firebase-uid-123")
	h2 := HashUID("firebase-uid-123")
	if h1 != h2 {
		t.Fatal("HashUID should be deterministic")
	}
	if h1 == "firebase-uid-123" {
		t.Fatal("HashUID must not return the plaintext uid")
	}
	if HashUID("") != "" {
		t.Error("HashUID(\"\") should be empty")
	}
	if HashUID("other-uid") == h1 {
		t.Error("different uids should hash differently")
	}
}

func TestWithTrace_RoundTrip(t *testing.T) {
	ctx := WithTrace(context.Background(), "projects/p/traces/t")
	if got := TraceFromContext(ctx); got != "projects/p/traces/t" {
		t.Errorf("TraceFromContext() = %q", got)
	}
}

func TestWithTrace_EmptyIsNoop(t *testing.T) {
	ctx := WithTrace(context.Background(), "")
	if got := TraceFromContext(ctx); got != "" {
		t.Errorf("TraceFromContext() = %q, want empty", got)
	}
}

func TestWithLogger_FallbackWhenUnset(t *testing.T) {
	fallback := New("p")
	if got := L(context.Background(), fallback); got != fallback {
		t.Error("L() should return the fallback logger when none is attached")
	}
	custom := New("other")
	ctx := WithLogger(context.Background(), custom)
	if got := L(ctx, fallback); got != custom {
		t.Error("L() should return the attached logger")
	}
}

func TestReplaceAttr_SeverityNames(t *testing.T) {
	tests := []struct {
		name string
		in   slog.Attr
		want slog.Attr
	}{
		{"notice", slog.Any(slog.LevelKey, LevelNotice), slog.String("severity", "NOTICE")},
		{"info is untouched", slog.Any(slog.LevelKey, slog.LevelInfo), slog.Any("severity", slog.LevelInfo)},
		{"message key", slog.String(slog.MessageKey, "m"), slog.String("message", "m")},
		{"other keys", slog.String("k", "v"), slog.String("k", "v")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := replaceAttr(nil, tt.in)
			if got.Key != tt.want.Key || got.Value.String() != tt.want.Value.String() {
				t.Errorf("replaceAttr(%v) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
	if LevelNotice <= slog.LevelInfo || LevelNotice >= slog.LevelWarn {
		t.Errorf("LevelNotice %d must sit between INFO and WARN", LevelNotice)
	}
}

func TestTraceAttrs(t *testing.T) {
	if got := TraceAttrs(context.Background()); got != nil {
		t.Errorf("TraceAttrs(no trace) = %v, want nil", got)
	}
	got := TraceAttrs(WithTrace(context.Background(), "projects/p/traces/t"))
	if len(got) != 2 || got[0] != TraceKey || got[1] != "projects/p/traces/t" {
		t.Errorf("TraceAttrs = %v", got)
	}
}
