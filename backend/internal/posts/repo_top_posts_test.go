package posts

import "testing"

// TestTopPostsOf: REPOSTs, hidden posts and posts without views are left out; order is kept; at most limit.
func TestTopPostsOf(t *testing.T) {
	ps := []*Post{
		{ID: "a", ViewCount: 50},
		{ID: "r", Kind: KindRepost, ViewCount: 40},
		{ID: "h", ViewCount: 30, Moderation: ModerationTakenDown},
		{ID: "b", ViewCount: 20},
		{ID: "c", ViewCount: 10},
		{ID: "z", ViewCount: 0},
	}
	got := topPostsOf(ps, 2)
	if len(got) != 2 || got[0].ID != "a" || got[1].ID != "b" {
		t.Fatalf("limit 2 = %v", postIDs(got))
	}
	if got := topPostsOf(ps, 5); len(got) != 3 || got[2].ID != "c" {
		t.Fatalf("limit 5 = %v", postIDs(got))
	}
}
