package timeline

import (
	"fmt"
	"testing"
	"time"

	tv "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

const pbArticles = tv.UserTimelineTab_USER_TIMELINE_TAB_ARTICLES

func TestArticlesTabPagesOriginalPublications(t *testing.T) {
	for _, total := range []int{0, 1, 40, 45} {
		t.Run(fmt.Sprint(total), func(t *testing.T) {
			r := newRig(t)
			r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
			for i := 0; i < total; i++ {
				p := r.posts.add("bob", r.ms(-time.Duration(2000-i)*time.Second))
				p.Article = &posts.ArticlePreview{ArticleID: fmt.Sprint(i), Title: "Article"}
			}
			for _, kind := range []posts.Kind{posts.KindPost, posts.KindReply, posts.KindQuote, posts.KindRepost} {
				p := r.posts.add("bob", r.ms(-time.Second))
				p.Kind = kind
				p.IsReply = kind == posts.KindReply
				if kind != posts.KindPost {
					p.Article = &posts.ArticlePreview{ArticleID: "decoy"}
				}
			}
			other := r.posts.add("someone-else", r.ms(-time.Second))
			other.Article = &posts.ArticlePreview{ArticleID: "other"}
			seen := map[string]bool{}
			page := ""
			calls := 0
			for {
				calls++
				res, err := r.tabPage("me", "bob", pbArticles, 20, "", page)
				if err != nil {
					t.Fatal(err)
				}
				for _, p := range res.Posts {
					if seen[p.Post.PostId] {
						t.Fatal("duplicate article")
					}
					seen[p.Post.PostId] = true
				}
				page = res.NextPageToken
				if page == "" {
					break
				}
				if calls > 4 {
					t.Fatal("pagination did not terminate")
				}
			}
			wantCalls := 1
			if total >= 40 {
				wantCalls = 3
			}
			if len(seen) != total || calls != wantCalls {
				t.Fatalf("got %d articles/%d calls want %d/%d", len(seen), calls, total, wantCalls)
			}
			for _, q := range r.posts.queries {
				if q != "ByAuthorArticles" {
					t.Fatalf("article tab used %s", q)
				}
			}
		})
	}
}

func TestArticlesTabUsesCanonicalModerationAndProtectedVisibility(t *testing.T) {
	r, protected := protectedRig(t)
	r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
	visible := r.posts.add("bob", r.ms(-30*time.Second))
	visible.Article = &posts.ArticlePreview{ArticleID: "visible"}
	hidden := r.posts.add("bob", r.ms(-20*time.Second))
	hidden.Article = &posts.ArticlePreview{ArticleID: "hidden"}
	hidden.Moderation = posts.ModerationTakenDown
	res, err := r.tabPage("me", "bob", pbArticles, 20, "", "")
	if err != nil || len(res.Posts) != 1 || res.Posts[0].Post.PostId != visible.ID {
		t.Fatalf("moderation leaked: %#v %v", res, err)
	}
	protected.protect("bob")
	r.posts.queries = nil
	res, err = r.tabPage("me", "bob", pbArticles, 20, "", "")
	if err != nil || !res.AuthorProtected || len(res.Posts) != 0 || len(r.posts.queries) != 0 {
		t.Fatalf("protected article leaked: %#v %v", res, err)
	}
}

func TestArticlesEffectiveTabIndependentOfProfileTabs(t *testing.T) {
	tab, ok := effectiveTab(pbArticles, true)
	if !ok || tab != tabArticles || tab.gated() {
		t.Fatalf("articles inherited extra capability gate: %s %t", tab, ok)
	}
}
