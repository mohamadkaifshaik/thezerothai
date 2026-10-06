package handle

import (
	"strings"
	"testing"
)

func TestValidRun(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want bool
	}{
		{"len 2", "ab", false},
		{"len 3", "abc", true},
		{"len 15", strings.Repeat("a", 15), true},
		{"len 16", strings.Repeat("a", 16), false},
		{"underscore", "a_c", true},
		{"only underscores", "___", true},
		{"non-ascii letter", "abé", false},
		{"dash", "a-c", false},
		{"empty", "", false},
		{"newline suffix", "abc\n", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := ValidRun(tt.in); got != tt.want {
				t.Errorf("ValidRun(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}

func TestIsRuneAgreesWithValidRun(t *testing.T) {
	t.Parallel()
	for _, r := range []rune{'a', 'Z', '0', '_', '-', ' ', 'é', '@', '\n', 0x7f} {
		if got, want := IsRune(r), ValidRun(strings.Repeat(string(r), MinLen)); got != want {
			t.Errorf("rune %q: IsRune=%v but ValidRun(%d x rune)=%v", r, got, MinLen, want)
		}
	}
}
