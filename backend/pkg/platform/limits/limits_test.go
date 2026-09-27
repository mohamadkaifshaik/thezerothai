package limits

import "testing"

func TestClampPageSize(t *testing.T) {
	tests := []struct {
		name string
		in   int32
		want int
	}{
		{"zero uses default", 0, DefaultPageSize},
		{"negative uses default", -5, DefaultPageSize},
		{"within range", 35, 35},
		{"exactly max", MaxPageSize, MaxPageSize},
		{"over max clamps", 500, MaxPageSize},
		{"exactly one", 1, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ClampPageSize(tt.in); got != tt.want {
				t.Errorf("ClampPageSize(%d) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}
