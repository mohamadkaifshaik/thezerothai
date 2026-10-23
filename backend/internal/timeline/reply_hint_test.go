package timeline

import (
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// mentionedOnly is the stored wire name of posts.ReplyPolicyMentionedOnly (an untyped constant, so timeline need not
// import the symbol: the import guard in server_test.go allows only the listed seams).
const mentionedOnly = "MENTIONED_ONLY"

// TestTimelines_PassTheViewerToTheReplyHint: toViews hands the caller to posts.ToView, so a MENTIONED_ONLY root
// the caller wrote is ALLOWED and another viewer's is NOT_ALLOWED (ADR-0021 D2); an unrestricted root stays ALLOWED.
func TestTimelines_PassTheViewerToTheReplyHint(t *testing.T) {
	t.Parallel()
	allowed, notAllowed := postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED
	t.Run("profile, own root", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		p := r.seedUser("me", 1)[0]
		p.ReplyPolicy = mentionedOnly
		resp := r.mustUser("me", "me", false, "", "", 20)
		if len(resp.GetPosts()) != 1 || resp.GetPosts()[0].GetViewerReplyPermission() != allowed {
			t.Fatalf("own root hint = %v, want ALLOWED", resp.GetPosts())
		}
	})
	t.Run("profile, another viewer's root", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		p := r.seedUser("bob", 1)[0]
		p.ReplyPolicy = mentionedOnly
		resp := r.mustUser("me", "bob", false, "", "", 20)
		if len(resp.GetPosts()) != 1 || resp.GetPosts()[0].GetViewerReplyPermission() != notAllowed {
			t.Fatalf("other's root hint = %v, want NOT_ALLOWED", resp.GetPosts())
		}
	})
	t.Run("home, a followed author's root", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		authors := r.follow("me", 1)
		r.posts.add(authors[0], r.ms(-2*time.Second)).ReplyPolicy = mentionedOnly
		resp := r.mustHome("", "", 20)
		if len(resp.GetPosts()) != 1 || resp.GetPosts()[0].GetViewerReplyPermission() != notAllowed {
			t.Fatalf("home hint = %v, want NOT_ALLOWED", resp.GetPosts())
		}
	})
}
