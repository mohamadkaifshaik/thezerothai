package timeline

import (
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TestTimelines_ExistingQuotesDisplayWithQuotesFlagOff: FEATURE_QUOTES gates quote CREATION only. With every flag
// on except quotes (engagement on), a stored QUOTE with its embedded snapshot still appears, embedded intact, on
// the home and the profile timeline.
func TestTimelines_ExistingQuotesDisplayWithQuotesFlagOff(t *testing.T) {
	t.Parallel()
	// "quotes" is the wire name of FEATURE_QUOTES; timeline must not import posts.QuotesFlagName.
	mk := func() *rig {
		r := newRig(t)
		r.srv = NewServer(Deps{
			Flags: offFor{"quotes"}, Viewer: &stubViewer{}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
			CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
		})
		return r
	}
	t.Run("home", func(t *testing.T) {
		t.Parallel()
		r := mk()
		authors := r.follow("me", 1)
		cp := r.posts.add(authors[0], r.ms(-2*time.Second))
		makeCopy(cp, posts.KindQuote)
		resp := r.mustHome("", "", 20)
		var found bool
		for _, v := range resp.GetPosts() {
			if v.GetPost().GetPostId() == cp.ID {
				found = v.GetPost().GetEmbedded().GetPostId() == "9" && v.GetPost().GetEmbedded().GetText() == "secret"
			}
		}
		if !found {
			t.Fatalf("quote missing or embed lost with quotes off: %v", homeIDs(resp))
		}
	})
	t.Run("profile", func(t *testing.T) {
		t.Parallel()
		r := mk()
		r.seedUser("bob", 1)
		cp := r.posts.add("bob", r.ms(-2*time.Second))
		makeCopy(cp, posts.KindQuote)
		resp := r.mustUser("me", "bob", false, "", "", 20)
		var found bool
		for _, v := range resp.GetPosts() {
			if v.GetPost().GetPostId() == cp.ID {
				found = v.GetPost().GetEmbedded().GetPostId() == "9"
			}
		}
		if !found {
			t.Fatalf("quote missing or embed lost with quotes off: %v", userIDs(resp))
		}
	})
}
