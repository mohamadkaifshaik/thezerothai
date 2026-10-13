package text

import "testing"

func TestParseOptional(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    string
		wantErr bool
	}{
		{"empty is an image-only post", "", "", false},
		{"whitespace only", " \n\t ", "", false},
		{"invisible only", "\U0000200B\U00002060\U0000200B", "", false},
		{"text is parsed as usual", "  hello #Go ", "hello #Go", false},
		{"control character still rejected", "\x00", "", true},
		{"invalid utf-8 still rejected", "\xff", "", true},
		{"bidi control with text still rejected", "hi \U0000202E", "", true},
		{"too long still rejected", repeat("a", 281), "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseOptional(tt.raw)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && got.Text != tt.want {
				t.Fatalf("text = %q, want %q", got.Text, tt.want)
			}
		})
	}
}

func repeat(s string, n int) string {
	out := make([]byte, 0, len(s)*n)
	for i := 0; i < n; i++ {
		out = append(out, s...)
	}
	return string(out)
}
