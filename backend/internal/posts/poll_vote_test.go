package posts

import (
	"testing"
	"time"
)

// Voted and Cache.AdjustPoll build a NEW Post and Poll: the shared cached copies are never changed in place (W6-7).
func TestPostVoted_CopyOnWrite(t *testing.T) {
	orig := &Post{ID: "1", Poll: &Poll{Options: []string{"a", "b"}, Counts: []int64{3, 1}, Total: 4, ClosesAt: time.Now()}}
	got := orig.Voted(1)
	if got == orig || got.Poll == orig.Poll || &got.Poll.Counts[0] == &orig.Poll.Counts[0] {
		t.Fatal("Voted shares memory with the original")
	}
	if got.Poll.Counts[1] != 2 || got.Poll.Total != 5 || orig.Poll.Counts[1] != 1 || orig.Poll.Total != 4 {
		t.Fatalf("got %+v orig %+v", got.Poll, orig.Poll)
	}
	if orig.Voted(5) != orig || (&Post{}).Voted(0) == nil {
		t.Error("an out-of-range choice or a post without a poll must be returned as is")
	}
}

func TestCacheAdjustPoll(t *testing.T) {
	c := NewCache(time.Minute, 10, 10)
	if c.AdjustPoll("1", 0) != nil {
		t.Fatal("an uncached post must return nil")
	}
	p := &Post{ID: "1", Poll: &Poll{Options: []string{"a", "b"}, Counts: []int64{0, 0}}}
	c.SetPost(p)
	c.AdjustPoll("1", 0)
	last := c.AdjustPoll("1", 0)
	if last.Poll.Total != 2 || last.Poll.Counts[0] != 2 || p.Poll.Total != 0 {
		t.Fatalf("cached %+v original %+v", last.Poll, p.Poll)
	}
}
