package timeline

// F-03 on the feeds: Home, list and community rows whose author is not ACTIVE (SUSPENDED, DELETING, no users doc) are
// dropped per row, a REPOST of such an author's post is dropped and a QUOTE of one keeps its own text with the embed
// tombstoned, with one batched Directory read per page (two past 50 distinct uids), cursor progress on the raw window and
// a Directory failure failing the page. GetUserTimeline applies the same rule to the authors its copies embed.

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// statusOrigID is the id of the post the copies below embed.
const statusOrigID = "0000000000000000777"

// asCopy turns p into a REPOST or QUOTE of statusOrigID by orig.
func asCopy(p *posts.Post, kind posts.Kind, orig string) *posts.Post {
	p.Kind = kind
	p.EmbeddedAuthorID = orig
	p.Embedded = &posts.Embedded{PostID: statusOrigID, Author: posts.AuthorSnapshot{UserID: orig, Handle: "h_" + orig}, Text: "the original"}
	if kind == posts.KindRepost {
		p.RepostOfID = statusOrigID
	} else {
		p.QuoteOfID = statusOrigID
	}
	return p
}

// statusFeed is one of the three feeds under test, over a rig whose Directory knows every author it was told about.
type statusFeed struct {
	r      *rig
	viewer string
	// author makes a an author whose rows this feed reads (a followee, a list member, anyone for a community), ACTIVE.
	author func(a string)
	// add stores a root post by a at ms.
	add func(a string, ms int64) *posts.Post
	// page reads one page as "me".
	page func(token string, size int32) ([]*postsv1.PostView, string, error)
}

func homeStatusFeed(t *testing.T) statusFeed {
	r := newRig(t)
	return statusFeed{
		r: r, viewer: "me",
		author: func(a string) {
			snap := r.graph.snaps["me"]
			if snap.Following == nil {
				snap.Following = map[string]bool{}
			}
			snap.Following[a] = true
			r.graph.snaps["me"] = snap
			r.dir.profiles[a] = identity.Profile{UserID: a, Status: identity.AccountStatusActive}
		},
		add: r.posts.add,
		page: func(token string, size int32) ([]*postsv1.PostView, string, error) {
			resp, err := r.home("me", "", token, size)
			return resp.GetPosts(), resp.GetNextPageToken(), err
		},
	}
}

func listStatusFeed(t *testing.T) statusFeed {
	r, fl := listRig(t)
	return statusFeed{
		r: r, viewer: "me",
		author: func(a string) {
			fl.members = append(fl.members, a)
			r.dir.profiles[a] = identity.Profile{UserID: a, Status: identity.AccountStatusActive}
		},
		add: r.posts.add,
		page: func(token string, size int32) ([]*postsv1.PostView, string, error) {
			resp, err := r.list("me", testListID, "", token, size)
			return resp.GetPosts(), resp.GetNextPageToken(), err
		},
	}
}

func communityStatusFeed(viewer string) func(t *testing.T) statusFeed {
	return func(t *testing.T) statusFeed {
		c := newCommRig(t)
		c.dir.profiles["me"] = identity.Profile{UserID: "me", Status: identity.AccountStatusActive} // an author for the moderator
		return statusFeed{
			r: c.rig, viewer: viewer,
			author: func(a string) {
				c.dir.profiles[a] = identity.Profile{UserID: a, Status: identity.AccountStatusActive}
			},
			add: func(a string, ms int64) *posts.Post { return c.cp.add(testCID, a, ms) },
			page: func(token string, size int32) ([]*postsv1.PostView, string, error) {
				resp, err := c.get(viewer, testCID, "", token, size)
				return resp.GetPosts(), resp.GetNextPageToken(), err
			},
		}
	}
}

var statusFeeds = []struct {
	name string
	new  func(t *testing.T) statusFeed
}{
	{"home", homeStatusFeed},
	{"list", listStatusFeed},
	{"community member", communityStatusFeed("me")},
	// Suspension is not F14: a moderator, who keeps rows by authors who block them, still loses a suspended author's rows.
	{"community moderator", communityStatusFeed(testModUID)},
}

func viewIDs(vs []*postsv1.PostView) []string {
	out := []string{}
	for _, v := range vs {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func TestFeeds_AuthorStatus_RowsAndCopies(t *testing.T) {
	t.Parallel()
	suspend := func(f statusFeed, a string) {
		f.r.dir.profiles[a] = identity.Profile{UserID: a, Status: nonActive}
	}
	deleting := func(f statusFeed, a string) {
		f.r.dir.profiles[a] = identity.Profile{UserID: a, Status: nonActive + 1}
	}
	missing := func(f statusFeed, a string) {
		delete(f.r.dir.profiles, a)
		f.r.dir.missing = map[string]bool{a: true} // the community rig answers ACTIVE for authors it holds no entry for
	}
	states := []struct {
		name string
		set  func(f statusFeed, a string)
	}{{"SUSPENDED", suspend}, {"DELETING", deleting}, {"no users doc", missing}}

	for _, feed := range statusFeeds {
		for _, st := range states {
			t.Run(feed.name+"/"+st.name, func(t *testing.T) {
				t.Parallel()
				f := feed.new(t)
				for _, a := range []string{"good", "bad", "copier"} {
					f.author(a)
				}
				good := f.add("good", f.r.ms(-1*time.Second))
				bad := f.add("bad", f.r.ms(-2*time.Second))
				repost := asCopy(f.add("copier", f.r.ms(-3*time.Second)), posts.KindRepost, "bad")
				quote := asCopy(f.add("copier", f.r.ms(-4*time.Second)), posts.KindQuote, "bad")
				goodRepost := asCopy(f.add("copier", f.r.ms(-5*time.Second)), posts.KindRepost, "good")
				mine := f.add("me", f.r.ms(-6*time.Second))
				if feed.name == "list" {
					mine = nil // the caller is not a member of the list
				}

				// Before: every row shows.
				vs, _, err := f.page("", 50)
				if err != nil {
					t.Fatal(err)
				}
				if got := len(vs); got < 5 {
					t.Fatalf("before: %d rows %v, want every row", got, viewIDs(vs))
				}

				st.set(f, "bad")
				vs, _, err = f.page("", 50)
				if err != nil {
					t.Fatal(err)
				}
				want := []string{good.ID, quote.ID, goodRepost.ID}
				if mine != nil {
					want = append(want, mine.ID)
				}
				if got := viewIDs(vs); !slices.Equal(got, want) {
					t.Fatalf("rows = %v, want %v (bad %s and its REPOST %s dropped)", got, want, bad.ID, repost.ID)
				}
				for _, v := range vs {
					e := v.GetPost().GetEmbedded()
					switch v.GetPost().GetPostId() {
					case quote.ID:
						if !e.GetUnavailable() || e.GetPostId() != statusOrigID || e.GetText() != "" || e.GetAuthor() != nil {
							t.Fatalf("QUOTE embed = %v, want the tombstone of %s", e, statusOrigID)
						}
						if v.GetPost().GetText() != quote.Text {
							t.Fatalf("QUOTE text = %q, want its own %q", v.GetPost().GetText(), quote.Text)
						}
					case goodRepost.ID:
						if e.GetUnavailable() || e.GetText() != "the original" {
							t.Fatalf("REPOST of an ACTIVE author: embed = %v, want the snapshot", e)
						}
					}
				}
				// The shared rows were never changed: the next instance sees the untouched snapshot.
				if quote.Embedded.Unavailable || quote.QuoteOfID != statusOrigID || quote.EmbeddedAuthorID != "bad" {
					t.Fatalf("the stored QUOTE was mutated: %+v", quote)
				}
				// One batch for the page, the caller never in it.
				calls := f.r.dir.calls()
				last := calls[len(calls)-1]
				if slices.Contains(last, f.viewer) {
					t.Fatalf("batch %v asks for the caller", last)
				}
				if f.r.info != nil {
					if got, ok := f.r.info.Get(fieldDroppedInactive); !ok || fmt.Sprint(got) != "2" {
						t.Fatalf("%s = %v (%v), want 2", fieldDroppedInactive, got, ok)
					}
				}
			})
		}
	}
}

// A page whose rows are all by an inactive author is empty but still advances: the token stands on the raw window, so
// paging reaches the older visible rows, each once and in order.
func TestFeeds_AuthorStatus_FullyFilteredPageAdvances(t *testing.T) {
	t.Parallel()
	for _, feed := range statusFeeds {
		t.Run(feed.name, func(t *testing.T) {
			t.Parallel()
			f := feed.new(t)
			f.author("bad")
			f.author("good")
			for i := range 4 {
				f.add("bad", f.r.ms(-time.Duration(i+1)*time.Second))
			}
			var want []string
			for i := range 3 {
				want = append(want, f.add("good", f.r.ms(-time.Duration(i+10)*time.Second)).ID)
			}
			f.r.dir.profiles["bad"] = identity.Profile{UserID: "bad", Status: nonActive}

			vs, next, err := f.page("", 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(vs) != 0 || next == "" {
				t.Fatalf("first page = %v next=%q, want empty with a next token", viewIDs(vs), next)
			}
			var got []string
			for pages := 0; next != "" && pages < 10; pages++ {
				vs, next, err = f.page(next, 2)
				if err != nil {
					t.Fatal(err)
				}
				got = append(got, viewIDs(vs)...)
			}
			if !slices.Equal(got, want) {
				t.Fatalf("paged rows = %v, want %v", got, want)
			}
		})
	}
}

// A Directory failure fails the page: author status is never assumed. The error carries no raw uid.
func TestFeeds_AuthorStatus_DirectoryErrorFailsClosed(t *testing.T) {
	t.Parallel()
	for _, feed := range statusFeeds {
		t.Run(feed.name, func(t *testing.T) {
			t.Parallel()
			f := feed.new(t)
			f.author("uid-secret-author")
			f.add("uid-secret-author", f.r.ms(-time.Second))
			f.r.dir.err = errors.New("identity: decode profile uid-secret-author: boom")
			vs, _, err := f.page("", 20)
			if err == nil {
				t.Fatalf("err = nil with rows %v, want a failure", viewIDs(vs))
			}
			for _, msg := range []string{err.Error(), logger.CauseChain(err)} {
				if strings.Contains(msg, "uid-secret-author") {
					t.Fatalf("error %q leaks the author uid", msg)
				}
			}
		})
	}
}

// Cost: one Directory call for a page of up to 50 distinct uids, two (each at most 50) for a page of 50 rows by 50
// authors copying 50 other authors.
func TestFeeds_AuthorStatus_BatchCost(t *testing.T) {
	t.Parallel()
	for _, feed := range statusFeeds {
		t.Run(feed.name, func(t *testing.T) {
			t.Parallel()
			f := feed.new(t)
			for i := range 50 {
				a, o := fmt.Sprintf("a%02d", i), fmt.Sprintf("o%02d", i)
				f.author(a)
				f.r.dir.profiles[o] = identity.Profile{UserID: o, Status: identity.AccountStatusActive}
				asCopy(f.add(a, f.r.ms(-time.Duration(i+1)*time.Second)), posts.KindQuote, o)
			}
			before := len(f.r.dir.calls())
			vs, _, err := f.page("", 50)
			if err != nil {
				t.Fatal(err)
			}
			if len(vs) != 50 {
				t.Fatalf("rows = %d, want 50", len(vs))
			}
			calls := f.r.dir.calls()[before:]
			asked := map[string]bool{}
			for _, b := range calls {
				if len(b) > 50 {
					t.Fatalf("a batch of %d uids, want at most 50 (posts.AuthorStatusBatch)", len(b))
				}
				for _, u := range b {
					asked[u] = true
				}
			}
			if len(calls) != 2 || len(asked) != 100 {
				t.Fatalf("%d calls asking %d uids, want 2 covering 100", len(calls), len(asked))
			}
		})
	}
}

// GetUserTimeline already answers NOT_FOUND for a non-ACTIVE target (checkVisible); its copies of an inactive author's
// post get the same rule as the feeds. A page with no copy of another author asks the Directory nothing more.
func TestUser_AuthorStatus_EmbeddedAuthors(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.dir.profiles["t"] = identity.Profile{UserID: "t", Status: identity.AccountStatusActive}
	plain := r.posts.add("t", r.ms(-1*time.Second))
	before := len(r.dir.calls())
	resp := r.mustUser("me", "t", false, "", "", 20)
	if got := userIDs(resp); !slices.Equal(got, []string{plain.ID}) {
		t.Fatalf("rows = %v", got)
	}
	if n := len(r.dir.calls()) - before; n != 1 {
		t.Fatalf("Directory calls = %d, want 1 (the target check only)", n)
	}

	repost := asCopy(r.posts.add("t", r.ms(-2*time.Second)), posts.KindRepost, "gone")
	quote := asCopy(r.posts.add("t", r.ms(-3*time.Second)), posts.KindQuote, "gone")
	r.dir.profiles["gone"] = identity.Profile{UserID: "gone", Status: nonActive}
	delete(r.posts.recent, "t") // the author-recent entry of the first call would serve the old page for 60 s
	resp = r.mustUser("me", "t", false, "", "", 20)
	if got, want := userIDs(resp), []string{plain.ID, quote.ID}; !slices.Equal(got, want) {
		t.Fatalf("rows = %v, want %v (the REPOST %s of a suspended author dropped)", got, want, repost.ID)
	}
	if e := resp.GetPosts()[1].GetPost().GetEmbedded(); !e.GetUnavailable() || e.GetText() != "" {
		t.Fatalf("QUOTE embed = %v, want the tombstone", e)
	}
	// The owner's own profile follows the same rule.
	resp = r.mustUser("t", "t", false, "", "", 20)
	if got, want := userIDs(resp), []string{plain.ID, quote.ID}; !slices.Equal(got, want) {
		t.Fatalf("own profile rows = %v, want %v", got, want)
	}
	r.dir.err = errors.New("down")
	if _, err := r.user("me", "t", false, "", "", 20); err == nil {
		t.Fatal("a Directory failure must fail the page")
	}
}
