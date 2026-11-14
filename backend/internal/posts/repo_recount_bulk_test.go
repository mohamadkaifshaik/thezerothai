package posts

import "testing"

func TestChildParentOf(t *testing.T) {
	tests := []struct {
		name      string
		data      map[string]any
		want      ChildParent
		countable bool
	}{
		{"post with counters", map[string]any{"kind": "POST", "replyCount": int64(3), "quoteCount": int64(1)},
			ChildParent{ID: "x", Kind: KindPost, Replies: 3, Quotes: 1}, true},
		{"absent counters read 0", map[string]any{"kind": "QUOTE"}, ChildParent{ID: "x", Kind: KindQuote}, true},
		{"a non-integer counter reads 0 (a repair sets it)", map[string]any{"kind": "REPLY", "replyCount": "7"},
			ChildParent{ID: "x", Kind: KindReply}, true},
		{"a missing kind is scanned", map[string]any{"replyCount": int64(2)}, ChildParent{ID: "x", Replies: 2}, true},
		{"a repost is not countable", map[string]any{"kind": "REPOST"}, ChildParent{ID: "x", Kind: KindRepost}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := childParentOf("x", tt.data)
			if got != tt.want || got.Countable() != tt.countable {
				t.Fatalf("got %+v countable=%v, want %+v countable=%v", got, got.Countable(), tt.want, tt.countable)
			}
		})
	}
}

func TestAggReads(t *testing.T) {
	for n, want := range map[int64]int64{0: 1, 1: 1, 999: 1, 1000: 1, 1001: 2, 100_000: 100} {
		if got := aggReads(n); got != want {
			t.Errorf("aggReads(%d) = %d, want %d", n, got, want)
		}
	}
}

func TestChildRepairStale(t *testing.T) {
	tests := []struct {
		name            string
		replies, quotes ChildRecount
		stale           bool
	}{
		{"in step", childRecountOf(2, 2), childRecountOf(0, 0), false},
		{"reply count too high", childRecountOf(9, 4), childRecountOf(0, 0), true},
		{"quote count too low", childRecountOf(0, 0), childRecountOf(0, 1), true},
		{"a capped count is never stale (never written)", childRecountOf(150_000, planCountCap), childRecountOf(1, 1), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := ChildRepair{Replies: tt.replies, Quotes: tt.quotes}
			if c.Stale() != tt.stale || c.Wrote() {
				t.Fatalf("stale=%v wrote=%v, want stale=%v wrote=false", c.Stale(), c.Wrote(), tt.stale)
			}
		})
	}
	if !childRecountOf(0, planCountCap).Capped || childRecountOf(0, planCountCap-1).Capped {
		t.Fatal("the cap is planCountCap")
	}
}
