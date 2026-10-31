package identity

import (
	"strings"
	"testing"
)

func TestSingleLineText(t *testing.T) {
	tests := []struct {
		name     string
		in       string
		min, max int
		want     string
		ok       bool
	}{
		{"plain", "Cricket", 1, 25, "Cricket", true},
		{"trimmed", "  Cricket \u00a0", 1, 25, "Cricket", true},
		{"nfc", "e\u0301", 1, 25, "\u00e9", true},
		{"empty where min 1", "", 1, 25, "", false},
		{"blank where min 1", " \t ", 1, 25, "", false},
		{"empty where min 0", "", 0, 100, "", true},
		{"25 code points", strings.Repeat("a", 25), 1, 25, strings.Repeat("a", 25), true},
		{"26 code points", strings.Repeat("a", 26), 1, 25, "", false},
		{"counts code points not bytes", strings.Repeat("\u0928", 25), 1, 25, strings.Repeat("\u0928", 25), true},
		{"newline", "a\nb", 1, 25, "", false},
		{"tab inside", "a\tb", 1, 25, "", false},
		{"line separator", "a\u2028b", 1, 25, "", false},
		{"bidi override", "a\u202eb", 1, 25, "", false},
		{"bidi isolate", "a\u2066b", 1, 25, "", false},
		{"invalid utf-8", "a\xffb", 1, 25, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := SingleLineText(tt.in, tt.min, tt.max)
			if ok != tt.ok || got != tt.want {
				t.Errorf("SingleLineText(%q, %d, %d) = %q, %v; want %q, %v", tt.in, tt.min, tt.max, got, ok, tt.want, tt.ok)
			}
		})
	}
}

// The display name rule and SingleLineText(1, 50) agree on every sample, so the two cannot drift apart.
func TestSingleLineText_MatchesDisplayName(t *testing.T) {
	for _, s := range []string{"Ana", " Ana ", "", "a\nb", "a\u202eb", strings.Repeat("x", 51), strings.Repeat("x", 50), "e\u0301"} {
		_, ok := SingleLineText(s, 1, 50)
		if ok == displayNameIssue(s) {
			t.Errorf("%q: SingleLineText ok=%v but displayNameIssue=%v", s, ok, displayNameIssue(s))
		}
	}
}
