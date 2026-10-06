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
		if got.GetKind() != tt.wk || got.GetVisibility() != tt.wv || got.GetCreatedAt().AsTime().UnixMilli() != 5 {
			t.Errorf("%v/%v -> %v/%v", tt.kind, tt.vis, got.GetKind(), got.GetVisibility())
		}
	}
}
