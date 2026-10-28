package timeline

// ADR-0025 D4 (W3-30): GetUserTimeline answers author_protected for a protected account's unapproved viewers before any
// cache or page is read, and the feeds drop a REPOST of such an author and strip a QUOTE of one through posts.Audience.

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func codeOf(err error) connect.Code {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.Code
	}
	return connect.CodeUnknown
}

// fakeProtected is a mutable identity.ProtectedAuthors.
type fakeProtected struct {
	mu   sync.Mutex
	uids map[string]bool
	err  error
}

// fakeSet restates the D3 expression only because a fake cannot reach identity's unexported set type.
type fakeSet map[string]bool

func (s fakeSet) Has(uid string) bool { return s[uid] }
func (s fakeSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s[author] || following
}

func (f *fakeProtected) Current(context.Context) (identity.ProtectedSet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	out := fakeSet{}
	for u := range f.uids {
		out[u] = true
	}
	return out, nil
}

func (f *fakeProtected) protect(uids ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, u := range uids {
		f.uids[u] = true
	}
}

// protectedRig is newRig with the protected-set loader wired the way apiserver wires it.
func protectedRig(t *testing.T) (*rig, *fakeProtected) {
	t.Helper()
	r := newRig(t)
	fp := &fakeProtected{uids: map[string]bool{}}
	r.srv = NewServer(Deps{
		Flags: fakeFlags{on: true}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
		CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
	}, WithProtectedAuthors(fp))
	r.dir.profiles["P"] = identity.Profile{UserID: "P", Status: identity.AccountStatusActive}
	return r, fp
}

func pPost(r *rig, sec int) *posts.Post {
	return r.posts.add("P", r.ms(-time.Duration(sec)*time.Second))
}

// copyOfP makes p a copy (kind) of a post by the protected author P.
func copyOfP(p *posts.Post, kind posts.Kind) {
	makeCopy(p, kind)
	p.EmbeddedAuthorID, p.Embedded.Author.UserID = "P", "P"
}

var allTabs = []timelinev1.UserTimelineTab{pbPosts, pbReplies, pbMedia, pbReposts}

func TestProtected_UserTimelineMatrix(t *testing.T) {
	t.Parallel()
	for _, tab := range allTabs {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r, fp := protectedRig(t)
			p := pPost(r, 5)
			p.HasMedia = true
			rp := pPost(r, 6)
			makeCopy(rp, posts.KindRepost) // an unprotected original: only P's own tab is under test
			fp.protect("P")

			// An unapproved viewer: author_protected, nothing else, 2 reads here (users + graph; 3 with the
			// interceptor), no query.
			resp, counter, err := r.tabPage("stranger", "P", tab, 20, "", "")
			if err != nil {
				t.Fatal(err)
			}
			if !resp.GetAuthorProtected() || len(resp.GetPosts()) != 0 || resp.GetSinceToken() != "" || resp.GetNextPageToken() != "" ||
				resp.GetGapPageToken() != "" || len(resp.GetRemovedIds()) != 0 {
				t.Fatalf("response = %v, want only author_protected", resp)
			}
			if counter.Reads() != 2 || len(r.posts.queries) != 0 {
				t.Fatalf("reads = %d, queries = %v, want 2 and none", counter.Reads(), r.posts.queries)
			}
			if v, _ := r.info.Get(fieldAuthorProtected); v != true {
				t.Fatalf("request log author_protected = %v", v)
			}

			// A follower, and P itself: unchanged.
			r.graph.snaps["fan"] = graph.Snapshot{Following: following("P")}
			if resp, _, err := r.tabPage("fan", "P", tab, 20, "", ""); err != nil || resp.GetAuthorProtected() || len(resp.GetPosts()) == 0 {
				t.Fatalf("follower: err=%v protected=%v rows=%d", err, resp.GetAuthorProtected(), len(resp.GetPosts()))
			}
			if resp, _, err := r.tabPage("P", "P", tab, 20, "", ""); err != nil || resp.GetAuthorProtected() || len(resp.GetPosts()) == 0 {
				t.Fatalf("author: err=%v protected=%v rows=%d", err, resp.GetAuthorProtected(), len(resp.GetPosts()))
			}
		})
	}
}

// The shared author-recent entry filled for a follower must not answer a stranger, and a token issued while P was
// public gets the same answer once P protects.
func TestProtected_DecidedBeforeCacheAndTokens(t *testing.T) {
	t.Parallel()
	r, fp := protectedRig(t)
	pPost(r, 5)
	r.graph.snaps["fan"] = graph.Snapshot{Following: following("P")}
	if resp, _, err := r.user("fan", "P", false, "", "", 20); err != nil || len(resp.GetPosts()) != 1 {
		t.Fatalf("follower fill: %v %v", resp, err)
	}
	if _, ok := r.posts.AuthorRecent("P"); !ok {
		t.Fatal("the author-recent entry was not filled; the test proves nothing")
	}
	since := r.mustTab("stranger", "P", pbPosts, 20, "", "").GetSinceToken()
	if since == "" {
		t.Fatal("no since token while P was public")
	}
	fp.protect("P")
	resp, counter, err := r.user("stranger", "P", false, "", "", 20)
	if err != nil || !resp.GetAuthorProtected() || len(resp.GetPosts()) != 0 || counter.Reads() != 2 {
		t.Fatalf("stranger after cache fill: %v err=%v reads=%d", resp, err, counter.Reads())
	}
	resp, _, err = r.tabPage("stranger", "P", pbPosts, 20, since, "")
	if err != nil || !resp.GetAuthorProtected() || resp.GetSinceToken() != "" {
		t.Fatalf("token issued before P protected: %v err=%v", resp, err)
	}
}

// NOT_FOUND rules come first: a blocking author and a missing user get the profile NOT_FOUND, not author_protected.
func TestProtected_NotFoundRulesFirst(t *testing.T) {
	t.Parallel()
	r, fp := protectedRig(t)
	fp.protect("P", "ghost")
	r.graph.snaps["blocked"] = graph.Snapshot{BlockedBy: following("P")}
	if _, _, err := r.user("blocked", "P", false, "", "", 20); err == nil || codeOf(err) != connect.CodeNotFound {
		t.Fatalf("blocked caller err = %v, want NOT_FOUND", err)
	}
	if _, _, err := r.user("stranger", "ghost", false, "", "", 20); err == nil || codeOf(err) != connect.CodeNotFound {
		t.Fatalf("missing user err = %v, want NOT_FOUND", err)
	}
}

// An unknown set is never read as "everyone is public": UNAVAILABLE for an unapproved read, nothing leaked.
func TestProtected_SetUnavailableFailsClosed(t *testing.T) {
	t.Parallel()
	r, fp := protectedRig(t)
	pPost(r, 5)
	fp.err = errors.New("set unavailable")
	if resp, _, err := r.user("stranger", "P", false, "", "", 20); err == nil || codeOf(err) != connect.CodeUnavailable {
		t.Fatalf("user timeline: resp=%v err=%v, want UNAVAILABLE", resp, err)
	}
	// A follower and the author never ask the set.
	r.graph.snaps["fan"] = graph.Snapshot{Following: following("P")}
	if resp, _, err := r.user("fan", "P", false, "", "", 20); err != nil || len(resp.GetPosts()) != 1 {
		t.Fatalf("follower with the set down: %v %v", resp, err)
	}
	// Home: a quote of P's post by a followee needs the set.
	r.follow("me", 1)
	cp := r.posts.add("f1", r.ms(-2*time.Second))
	copyOfP(cp, posts.KindQuote)
	if resp, _, err := r.home("me", "", "", 20); err == nil || codeOf(err) != connect.CodeUnavailable {
		t.Fatalf("home: resp=%v err=%v, want UNAVAILABLE", resp, err)
	}
}

func TestProtected_HomeDropsRepostStripsQuote(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name       string
		followsP   bool
		wantRepost bool
		wantEmbed  postsv1.EmbedViewerState
	}{
		{"unapproved", false, false, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED},
		{"follows P", true, true, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r, fp := protectedRig(t)
			fp.protect("P")
			r.follow("me", 1) // f1 = X
			if tc.followsP {
				s := r.graph.snaps["me"]
				s.Following["P"] = true
				r.graph.snaps["me"] = s
			}
			plain := r.posts.add("f1", r.ms(-5*time.Second))
			rep := r.posts.add("f1", r.ms(-4*time.Second))
			copyOfP(rep, posts.KindRepost)
			qt := r.posts.add("f1", r.ms(-3*time.Second))
			copyOfP(qt, posts.KindQuote)
			var own *posts.Post
			if tc.followsP {
				own = r.posts.add("P", r.ms(-2*time.Second))
			}

			resp, counter, err := r.home("me", "", "", 20)
			if err != nil {
				t.Fatal(err)
			}
			byID := map[string]*postsv1.PostView{}
			for _, v := range resp.GetPosts() {
				byID[v.GetPost().GetPostId()] = v
			}
			if byID[plain.ID] == nil {
				t.Fatal("the plain post disappeared")
			}
			if (byID[rep.ID] != nil) != tc.wantRepost {
				t.Fatalf("repost present = %v, want %v", byID[rep.ID] != nil, tc.wantRepost)
			}
			q := byID[qt.ID]
			if q == nil {
				t.Fatal("the quote was dropped, it must be stripped instead")
			}
			if q.GetEmbedViewerState() != tc.wantEmbed {
				t.Fatalf("embed state = %v, want %v", q.GetEmbedViewerState(), tc.wantEmbed)
			}
			e := q.GetPost().GetEmbedded()
			stripped := e.GetText() == "" && len(e.GetMedia()) == 0 && e.GetCreatedAt() == nil
			if stripped != (tc.wantEmbed == postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED) {
				t.Fatalf("embedded stripped = %v for state %v: %v", stripped, tc.wantEmbed, e)
			}
			if e.GetPostId() == "" || e.GetAuthor().GetHandle() == "" {
				t.Fatalf("a stripped embed keeps post_id and the author snapshot: %v", e)
			}
			// The predicate adds no read: caller graph + the chunk query rows.
			if counter.Reads() > 8 {
				t.Fatalf("reads = %d", counter.Reads())
			}
			if v, ok := r.info.Get(fieldAudienceDropped); !ok || (fmt.Sprint(v) == "1") == tc.wantRepost {
				t.Fatalf("audience_dropped = %v", v)
			}
			if own != nil {
				if v := byID[own.ID]; v == nil || v.GetPost().GetVisibility() != postsv1.Visibility_VISIBILITY_FOLLOWERS {
					t.Fatalf("a followed protected author's post must carry the FOLLOWERS wire visibility: %v", v)
				}
			}
		})
	}
}

// Another user's profile tabs and the caller's own profile apply the same rule.
func TestProtected_ProfileFeedsDropCopiesOfProtectedAuthors(t *testing.T) {
	t.Parallel()
	r, fp := protectedRig(t)
	fp.protect("P")
	type rows struct{ rep, qt, ctl *posts.Post }
	seeded := map[string]rows{}
	for _, who := range []string{"bob", "me"} {
		r.dir.profiles[who] = identity.Profile{UserID: who, Status: identity.AccountStatusActive}
		rep := r.posts.add(who, r.ms(-4*time.Second))
		copyOfP(rep, posts.KindRepost)
		qt := r.posts.add(who, r.ms(-3*time.Second))
		copyOfP(qt, posts.KindQuote)
		seeded[who] = rows{rep, qt, r.posts.add(who, r.ms(-2*time.Second))}
	}
	for who, s := range seeded {
		resp, _, err := r.tabPage("me", who, pbReplies, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]*postsv1.PostView{}
		for _, v := range resp.GetPosts() {
			got[v.GetPost().GetPostId()] = v
		}
		// W3-36 L-2: the owner's own REPOST stays as an undoable PROTECTED row; another user's profile still drops it.
		own := who == "me"
		if (got[s.rep.ID] != nil) != own || got[s.ctl.ID] == nil || got[s.qt.ID] == nil ||
			got[s.qt.ID].GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
			t.Fatalf("%s: repost kept=%v control=%v quote=%v", who, got[s.rep.ID] != nil, got[s.ctl.ID] != nil, got[s.qt.ID])
		}
		if rv := got[s.rep.ID]; own {
			emb := rv.GetPost().GetEmbedded()
			if rv.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || !rv.GetRepostedByViewer() ||
				emb.GetPostId() == "" || emb.GetText() != "" || len(emb.GetMedia()) != 0 || emb.GetCreatedAt() != nil {
				t.Fatalf("own repost placeholder: %v", rv)
			}
		}
	}
	// A viewer who follows P keeps all three of bob's rows.
	r.graph.snaps["me"] = graph.Snapshot{Following: following("P")}
	resp, _, err := r.tabPage("me", "bob", pbReplies, 20, "", "")
	if err != nil || len(resp.GetPosts()) != 3 {
		t.Fatalf("approved viewer: %d rows err=%v", len(resp.GetPosts()), err)
	}
}

// Without a wired loader (the pre-W3-26a state) nobody is protected and nothing is dropped.
func TestProtected_NoLoaderChangesNothing(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.dir.profiles["P"] = identity.Profile{UserID: "P", Status: identity.AccountStatusActive}
	pPost(r, 5)
	if resp, _, err := r.user("stranger", "P", false, "", "", 20); err != nil || resp.GetAuthorProtected() || len(resp.GetPosts()) != 1 {
		t.Fatalf("%v %v", resp, err)
	}
}

// cachedProtected is a fakeProtected with the loader's optional Cached face; it counts Current calls.
type cachedProtected struct {
	*fakeProtected
	fresh   bool
	current int
}

func (c *cachedProtected) Current(ctx context.Context) (identity.ProtectedSet, error) {
	c.current++
	return c.fakeProtected.Current(ctx)
}

func (c *cachedProtected) Cached() (identity.ProtectedSet, bool) {
	s, _ := c.fakeProtected.Current(context.Background())
	return s, c.fresh
}

// TestProtected_WireVisibilityHintSkipsSetForFollowedAndOwn is W3-40b L-4: a Home page of followed authors, one of them
// protected, makes 0 Current calls while a fresh copy is held and still marks the protected author's row FOLLOWERS;
// without a fresh copy the same page asks Current and the wire values are identical.
func TestProtected_WireVisibilityHintSkipsSetForFollowedAndOwn(t *testing.T) {
	t.Parallel()
	for _, fresh := range []bool{true, false} {
		t.Run(fmt.Sprintf("fresh=%v", fresh), func(t *testing.T) {
			t.Parallel()
			r, fp := protectedRig(t)
			cp := &cachedProtected{fakeProtected: fp, fresh: fresh}
			r.srv = NewServer(Deps{
				Flags: fakeFlags{on: true}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
				CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
			}, WithProtectedAuthors(cp))
			fp.protect("P")
			r.follow("me", 1) // f1 = X, public
			s := r.graph.snaps["me"]
			s.Following["P"] = true
			r.graph.snaps["me"] = s
			plain := r.posts.add("f1", r.ms(-5*time.Second))
			own := r.posts.add("P", r.ms(-2*time.Second))

			resp, _, err := r.home("me", "", "", 20)
			if err != nil {
				t.Fatal(err)
			}
			byID := map[string]*postsv1.PostView{}
			for _, v := range resp.GetPosts() {
				byID[v.GetPost().GetPostId()] = v
			}
			if byID[own.ID].GetPost().GetVisibility() != postsv1.Visibility_VISIBILITY_FOLLOWERS {
				t.Fatalf("followed protected author's row = %v, want FOLLOWERS", byID[own.ID].GetPost().GetVisibility())
			}
			if byID[plain.ID].GetPost().GetVisibility() == postsv1.Visibility_VISIBILITY_FOLLOWERS {
				t.Fatal("a public author's row must not be FOLLOWERS")
			}
			if fresh && cp.current != 0 {
				t.Fatalf("Current calls = %d, want 0 for a page of followed authors", cp.current)
			}
			if !fresh && cp.current == 0 {
				t.Fatal("without a fresh copy the hint must ask Current")
			}
		})
	}
}
