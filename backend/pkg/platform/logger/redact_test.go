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

// ScrubPairErr hashes the subject with HashUID and every other person with HashTarget (a different domain, so the line
// cannot be joined to the other person's own request lines), after the same pattern pass as ScrubErr.
func TestScrubPairErr(t *testing.T) {
	const (
		uid   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		third = "cccccccccccccccccccccccccccc"
	)
	tests := []struct {
		name    string
		err     error
		targets []string
		want    []string
		wantNot []string
	}{
		{"bare ids", fmt.Errorf("export %s: decode profile %s: %w", uid, other, errSentinel), []string{other},
			[]string{HashUID(uid), HashTarget(other)}, []string{uid, other, HashUID(other)}},
		{"path and edge id", fmt.Errorf("get projects/p/databases/(default)/documents/users/%s and %s_%s: %w", third, uid, other, errSentinel), []string{other},
			[]string{"<redacted>"}, []string{uid, other, third, "documents/"}},
		{"the subject among the targets keeps its uid hash", fmt.Errorf("read %s and %s: %w", uid, other, errSentinel), []string{uid, other, ""},
			[]string{HashUID(uid), HashTarget(other)}, []string{uid, other, HashTarget(uid)}},
		{"no subject", fmt.Errorf("decode profile %s: %w", other, errSentinel), []string{other},
			[]string{HashTarget(other)}, []string{other}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			subject := uid
			if tt.name == "no subject" {
				subject = ""
			}
			got := ScrubPairErr(tt.err, subject, tt.targets...)
			for _, w := range tt.want {
				if !strings.Contains(got.Error(), w) {
					t.Errorf("%q lacks %q", got.Error(), w)
				}
			}
			for _, w := range tt.wantNot {
				if strings.Contains(got.Error(), w) {
					t.Errorf("%q still contains %q", got.Error(), w)
				}
			}
			if !errors.Is(got, errSentinel) {
				t.Error("errors.Is must still reach the original cause")
			}
			if errors.Unwrap(got) != nil {
				t.Error("a scrubbed error must not unwrap to the raw cause (mw logs the whole chain)")
			}
		})
	}
	if ScrubPairErr(nil, uid, other) != nil {
		t.Error("nil must stay nil")
	}
}
