package pageresume

import "testing"

func TestIndex(t *testing.T) {
	t.Parallel()
	// newest last: d is newest (position 0), a is oldest (position 3)
	base := []string{"a", "b", "c", "d"}
	tests := []struct {
		name  string
		items []string
		a     Anchor
		want  int
	}{
		{"nothing changed", base, Anchor{Next: "b", Last: "c", NextIndex: 2}, 2},
		{"next removed lands on last+1", []string{"a", "c", "d"}, Anchor{Next: "b", Last: "c", NextIndex: 2}, 2},
		{"new newest entry shifts nothing", []string{"a", "b", "c", "d", "e"}, Anchor{Next: "b", Last: "c", NextIndex: 2}, 3},
		{"re-added next moves above last: not shown twice", []string{"a", "c", "d", "b"}, Anchor{Next: "b", Last: "c", NextIndex: 2}, 3},
		{"both anchors gone: recorded offset", []string{"a", "d"}, Anchor{Next: "b", Last: "c", NextIndex: 2}, 2},
		{"past the end", []string{"a"}, Anchor{Next: "b", Last: "c", NextIndex: 9}, 9},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := Index(tt.items, tt.a); got != tt.want {
				t.Fatalf("Index = %d, want %d", got, tt.want)
			}
		})
	}
}
