package logger

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

var errSentinel = errors.New("sentinel")

type causeOnly struct{ cause error }

func (c *causeOnly) Error() string { return "client safe" }
func (c *causeOnly) Unwrap() error { return c.cause }

func TestRedactErr(t *testing.T) {
	tests := []struct {
		name string
		err  error
		ids  []string
	}{
		{"wrapped message", fmt.Errorf("graph: block uid-a -> uid-b: %w", errSentinel), []string{"uid-a", "uid-b"}},
		{"cause hidden from Error()", &causeOnly{fmt.Errorf("doc graph/uid-b: %w", errSentinel)}, []string{"uid-b"}},
		{"empty ids ignored", fmt.Errorf("x uid-a: %w", errSentinel), []string{"", "uid-a"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := RedactErr(tt.err, tt.ids...)
			full := got.Error()
			for cause := errors.Unwrap(got); cause != nil; cause = errors.Unwrap(cause) {
				full += cause.Error()
			}
			for _, id := range tt.ids {
				if id != "" && strings.Contains(full, id) {
					t.Errorf("%q still contains %q", full, id)
				}
			}
			if !errors.Is(got, errSentinel) {
				t.Error("errors.Is must still reach the original cause")
			}
			if !strings.Contains(full, HashUID("uid-a")) && !strings.Contains(full, HashUID("uid-b")) {
				t.Errorf("%q carries no hash to correlate on", full)
			}
		})
	}
	if RedactErr(nil, "uid-a") != nil {
		t.Error("nil must stay nil")
	}
}

func TestRedactErr_As(t *testing.T) {
	var target *causeOnly
	if !errors.As(RedactErr(&causeOnly{errSentinel}, "u"), &target) {
		t.Error("errors.As must reach the original type")
	}
}

func TestScrubErr(t *testing.T) {
	uid := "aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	export := strings.Repeat("ab", 32)
	err := fmt.Errorf("rpc error: document documents/users/%s/x failed; edge %s_%s; object %s.json: %w", other, uid, other, export, errSentinel)
	got := ScrubErr(err, uid)
	full := got.Error()
	for _, raw := range []string{uid, other, export} {
		if strings.Contains(full, raw) {
			t.Errorf("%q still contains %q", full, raw)
		}
	}
	if !errors.Is(got, errSentinel) {
		t.Error("errors.Is must still reach the original cause")
	}
	if ScrubErr(nil, uid) != nil {
		t.Error("nil must stay nil")
	}
}
