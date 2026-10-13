package ids

import (
	"strings"
	"testing"
)

func TestValidUID(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want bool
	}{
		{"firebase style", "aB3dE6gH9jK2mN5pQ8sT1vW4xY7z", true},
		{"fixture with dash", "uid-alice", true},
		{"max length", strings.Repeat("a", 128), true},
		{"too long", strings.Repeat("a", 129), false},
		{"empty", "", false},
		{"underscore inside", "a_b", false},
		{"leading underscore", "_ab", false},
		{"reserved doc id shape", "__x__", false},
		{"slash", "a/b", false},
		{"space", "a b", false},
		{"unicode", "é", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := ValidUID(tt.in); got != tt.want {
				t.Errorf("ValidUID(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}

func TestValidPostID(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want bool
	}{
		{"19 digits", "1000000000000000001", true},
		{"zero padded", "0000000000000000001", true},
		{"18 digits", "100000000000000000", false},
		{"20 digits", "10000000000000000001", false},
		{"letters", "100000000000000000a", false},
		{"empty", "", false},
		{"sign", "-000000000000000001", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := ValidPostID(tt.in); got != tt.want {
				t.Errorf("ValidPostID(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}
