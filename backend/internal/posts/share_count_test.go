package posts

import (
	"testing"
	"time"
)

// share_count on the wire (shares design §3.1): the post's own counter, 0 on a REPOST row (the embed's original carries
// it), and gone from a withheld placeholder.
func TestShareCountOnTheWire(t *testing.T) {
	base := func(k Kind) *Post {
		return &Post{ID: "0000000000000000001", AuthorID: "a", Kind: k, ShareCount: 7, CreatedAt: time.Unix(1_700_000_000, 0)}
	}
	tests := []struct {
		name     string
		post     *Post
		withheld bool
		want     int64
	}{
		{"post", base(KindPost), false, 7},
		{"quote", base(KindQuote), false, 7},
		{"repost row", base(KindRepost), false, 0},
		{"withheld row", base(KindPost), true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := ToView(tt.post, ViewerSet{}, "viewer")
			if tt.withheld {
				ApplyWithheld(v)
			}
			if got := v.GetPost().GetShareCount(); got != tt.want {
				t.Fatalf("share_count = %d, want %d", got, tt.want)
			}
		})
	}
}

// The doc round trip keeps shareCount, and a negative stored value (a drifted counter) reads as 0.
func TestShareCountDocRoundTrip(t *testing.T) {
	p := &Post{ID: "0000000000000000002", AuthorID: "a", Kind: KindPost, ShareCount: 5}
	if got := toDoc(p).toPost(p.ID).ShareCount; got != 5 {
		t.Fatalf("round trip = %d, want 5", got)
	}
	d := toDoc(p)
	d.ShareCount = -2
	if got := d.toPost(p.ID).ShareCount; got != 0 {
		t.Fatalf("negative stored = %d, want 0", got)
	}
}

// AdjustShares moves the cached copy only (copy on write, clamped at 0) and leaves an uncached post alone.
func TestCacheAdjustShares(t *testing.T) {
	c := NewCache(time.Minute, 10, 10)
	orig := &Post{ID: "0000000000000000003", ShareCount: 1}
	c.SetPost(orig)
	c.AdjustShares(orig.ID, 1)
	got, _ := c.GetPost(orig.ID)
	if got.ShareCount != 2 || orig.ShareCount != 1 {
		t.Fatalf("cached=%d original=%d, want 2 and an untouched original 1", got.ShareCount, orig.ShareCount)
	}
	c.AdjustShares(orig.ID, -5)
	if got, _ = c.GetPost(orig.ID); got.ShareCount != 0 {
		t.Fatalf("clamped = %d, want 0", got.ShareCount)
	}
	c.AdjustShares("0000000000000000004", 1) // not cached: no entry appears
	if _, ok := c.GetPost("0000000000000000004"); ok {
		t.Fatal("AdjustShares created a cache entry")
	}
}
