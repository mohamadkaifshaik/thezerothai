package posts

import (
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

func TestToProto_KindAndVisibility(t *testing.T) {
	t.Parallel()
	tests := []struct {
		kind Kind
		vis  Visibility
		wk   postsv1.PostKind
		wv   postsv1.Visibility
	}{
		{KindPost, VisibilityPublic, postsv1.PostKind_POST_KIND_POST, postsv1.Visibility_VISIBILITY_PUBLIC},
		{KindReply, VisibilityFollowers, postsv1.PostKind_POST_KIND_REPLY, postsv1.Visibility_VISIBILITY_FOLLOWERS},
		{KindQuote, "", postsv1.PostKind_POST_KIND_QUOTE, postsv1.Visibility_VISIBILITY_UNSPECIFIED},
		{KindRepost, "x", postsv1.PostKind_POST_KIND_REPOST, postsv1.Visibility_VISIBILITY_UNSPECIFIED},
		{"", VisibilityPublic, postsv1.PostKind_POST_KIND_UNSPECIFIED, postsv1.Visibility_VISIBILITY_PUBLIC},
	}
	for _, tt := range tests {
		got := ToProto(&Post{ID: "1", Kind: tt.kind, Visibility: tt.vis, CreatedAt: time.UnixMilli(5)})
		// The stored visibility never reaches the wire (ADR-0025 D2): always PUBLIC until ApplyWireVisibility.
		tt.wv = postsv1.Visibility_VISIBILITY_PUBLIC
		if got.GetKind() != tt.wk || got.GetVisibility() != tt.wv || got.GetCreatedAt().AsTime().UnixMilli() != 5 {
			t.Errorf("%v/%v -> %v/%v", tt.kind, tt.vis, got.GetKind(), got.GetVisibility())
		}
	}
}

// W3-28c: the frozen author copies never carry AuthorSnapshot.is_private (clients never infer "public" from false, and the
// field is filled only on live user-list rows).
func TestToProto_FrozenAuthorCopiesLeaveIsPrivateUnset(t *testing.T) {
	t.Parallel()
	author := AuthorSnapshot{UserID: "u1", Handle: "h", DisplayName: "D", AvatarURL: "a", Verified: true}
	p := &Post{ID: "1", Kind: KindQuote, Author: author, CreatedAt: time.UnixMilli(5),
		Embedded: &Embedded{PostID: "2", Author: author, Text: "t", CreatedAt: time.UnixMilli(4)}}
	got := ToProto(p)
	if got.GetAuthor().GetIsPrivate() || got.GetEmbedded().GetAuthor().GetIsPrivate() {
		t.Errorf("author=%v embedded author=%v, want is_private unset on both", got.GetAuthor(), got.GetEmbedded().GetAuthor())
	}
	if got.GetAuthor().GetUserId() != "u1" || got.GetEmbedded().GetAuthor().GetUserId() != "u1" {
		t.Errorf("authors not carried: %v / %v", got.GetAuthor(), got.GetEmbedded().GetAuthor())
	}
}
