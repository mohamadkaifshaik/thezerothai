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

func TestBioText(t *testing.T) {
	tests := []struct {
		name string
		in   string
		max  int
		want string
		ok   bool
	}{
		{"plain", "A place for cricket.", 160, "A place for cricket.", true},
		{"empty", "", 160, "", true},
		{"trimmed", "  hi \n", 160, "hi", true},
		{"newline kept", "a\nb", 160, "a\nb", true},
		{"nfc", "e\u0301", 160, "\u00e9", true},
		{"at the bound", strings.Repeat("a", 300), 300, strings.Repeat("a", 300), true},
		{"over the bound", strings.Repeat("a", 301), 300, "", false},
		{"counts code points", strings.Repeat("\u0928", 160), 160, strings.Repeat("\u0928", 160), true},
		{"carriage return", "a\r\nb", 160, "", false},
		{"tab", "a\tb", 160, "", false},
		{"line separator", "a\u2028b", 160, "", false},
		{"bidi override", "a\u202eb", 160, "", false},
		{"invalid utf-8", "a\xffb", 160, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := BioText(tt.in, tt.max)
			if ok != tt.ok || got != tt.want {
				t.Errorf("BioText(%q, %d) = %q, %v; want %q, %v", tt.in, tt.max, got, ok, tt.want, tt.ok)
			}
		})
	}
}

// The bio rule and BioText(160) agree on every sample, so the two cannot drift apart.
func TestBioText_MatchesBio(t *testing.T) {
	for _, s := range []string{"hello", " hi ", "", "a\nb", "a\r\nb", "a\u202eb", strings.Repeat("x", 161), strings.Repeat("x", 160), "e\u0301", "a\tb"} {
		_, ok := BioText(s, 160)
		if ok == bioIssue(s) {
			t.Errorf("%q: BioText ok=%v but bioIssue=%v", s, ok, bioIssue(s))
		}
	}
}
