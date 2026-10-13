package posts

import (
	"reflect"
	"testing"
	"time"
)

// TestPostDoc_RoundTrip: the domain Post and its stored shape convert losslessly, for a root post and a reply,
// and the stored shape matches ADR-0003 field names the indexes and queries rely on.
func TestPostDoc_RoundTrip(t *testing.T) {
	root := &Post{
		ID: "0000000000000000005", AuthorID: "a",
		Author:         AuthorSnapshot{UserID: "a", Handle: "alice", DisplayName: "Alice", AvatarURL: "u", Verified: true},
		Kind:           KindPost,
		Text:           "hi",
		ConversationID: "0000000000000000005",
		Hashtags:       []string{"go"},
		Mentions:       []Mention{{UserID: "b", Handle: "bob"}},
		LikeCount:      1, RepostCount: 2, ReplyCount: 3, QuoteCount: 4,
		Visibility: VisibilityPublic, SnapshotVersion: 9,
		CreatedAt: time.UnixMilli(5000).UTC(),
	}
	reply := &Post{
		ID: "0000000000000000006", AuthorID: "a", Kind: KindReply, IsReply: true, Text: "re",
		ReplyToID: "0000000000000000005", ReplyToHandle: "alice", ConversationID: "0000000000000000005",
		QuoteOfID: "q", RepostOfID: "r", Visibility: VisibilityPublic, CreatedAt: time.UnixMilli(6000).UTC(),
	}
	for _, p := range []*Post{root, reply} {
		got := toDoc(p).toPost(p.ID)
		// nil and empty slices are equivalent in the domain.
		if len(got.Hashtags) == 0 && len(p.Hashtags) == 0 {
			got.Hashtags = p.Hashtags
		}
		if !reflect.DeepEqual(got, p) {
			t.Fatalf("round trip differs:\n got %+v\nwant %+v", got, p)
		}
	}

	d := toDoc(root)
	if d.Hashtags == nil || d.Mentions == nil {
		t.Fatal("empty arrays must be stored as arrays, not omitted")
	}
	empty := toDoc(&Post{ID: "1", AuthorID: "a", CreatedAt: time.UnixMilli(1)})
	if empty.Hashtags == nil || empty.Mentions == nil || len(empty.Hashtags) != 0 || len(empty.Mentions) != 0 {
		t.Fatalf("nil slices should be stored as empty arrays: %+v", empty)
	}
}

func TestPostDoc_MediaRoundTrip(t *testing.T) {
	p := post("0000000000000000301", "uid-a")
	p.Media = []MediaRef{{ID: "0000000000000000201", URL: "https://m/1.webp", ThumbURL: "https://m/1_t.webp", Width: 4, Height: 3, Blurhash: "LEHV6n", AltText: "dog"}}
	got := toDoc(p).toPost(p.ID)
	if len(got.Media) != 1 || got.Media[0] != p.Media[0] {
		t.Fatalf("media = %+v", got.Media)
	}
	if len(toDoc(post("0000000000000000302", "uid-a")).Media) != 0 {
		t.Fatal("a post without images must store no media field")
	}
}
