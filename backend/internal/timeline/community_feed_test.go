package timeline

// GetCommunityTimeline. The fakes charge reads the way the real seams do. Unit budgets do not count the
// account-status interceptor's caller read, so a cold open is page + 4 here (community, member doc, posts, graph, userLikes) and
// page + 5 on the wire (25 at page 20, 55 at page 50); the apiserver chain test asserts the wire numbers.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	testCID      = "1000000000000000099"
	otherCID     = "1000000000000000098"
	testOwnerUID = "owner"
	testModUID   = "mod"
)

// commPosts adds ByCommunity to fakePosts with the real contract: members only, newest first by (createdAt, id), the window as
// positions (After exclusive, so a settle sentinel (W, zero id) includes everything from millisecond W), Limit clamped to 1..50, reads =
// max(rows, 1).
type commPosts struct {
	*fakePosts
	mu    sync.Mutex
	rows  map[string][]*posts.Post
	calls []commCall
	seq   int64
}

type commCall struct {
	cid    string
	w      posts.Window
	limit  int
	nReads int
}

func (c *commPosts) ByCommunity(ctx context.Context, cid string, w posts.Window, limit int) ([]*posts.Post, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	limit = min(max(limit, 1), posts.MaxLimit)
	var out []*posts.Post
	for _, p := range c.rows[cid] {
		if p.CommunityID == cid && inWin(p, w) {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return Compare(PositionOf(out[i]), PositionOf(out[j])) < 0 })
	if len(out) > limit {
		out = out[:limit]
	}
	n := max(len(out), 1)
	budget.FromContext(ctx).AddReads(int64(n))
	c.calls = append(c.calls, commCall{cid: cid, w: w, limit: limit, nReads: n})
	return out, nil
}

func (c *commPosts) callsSnapshot() []commCall {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Clone(c.calls)
}

// add stores a community post at ms (from the epoch); the id embeds ms so ids sort by time.
func (c *commPosts) add(cid, author string, ms int64) *posts.Post {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seq++
	id := pid(ms*1000 + c.seq%1000)
	p := &posts.Post{
		ID: id, AuthorID: author, Author: posts.AuthorSnapshot{UserID: author, Handle: "h_" + author},
		Kind: posts.KindPost, Text: "t" + id, ConversationID: id, Visibility: posts.VisibilityPublic,
		CreatedAt: time.UnixMilli(ms).UTC(), CommunityID: cid, ConversationCommunityID: cid,
	}
	c.rows[cid] = append(c.rows[cid], p)
	return p
}

// fakeCommunities is communities.Reader over one community: the first Get and the first Role of each uid are cold (1 read), the rest
// are cache hits (0), like the real 60 s caches.
type fakeCommunities struct {
	communities.Reader
	mu       sync.Mutex
	c        communities.Community
	missing  bool
	roles    map[string]communities.Role
	gotC     bool
	gotRole  map[string]bool
	gets     int
	roleGets int
	err      error
}

func (f *fakeCommunities) set(fn func(*communities.Community)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(&f.c)
}

func (f *fakeCommunities) cold() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gotC, f.gotRole = false, map[string]bool{}
}

func (f *fakeCommunities) Get(ctx context.Context, id string) (communities.Community, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	if f.err != nil {
		return communities.Community{}, f.err
	}
	if !f.gotC {
		f.gotC = true
		budget.FromContext(ctx).AddReads(1)
	}
	if f.missing || id != f.c.ID {
		return communities.Community{}, communities.ErrNotFound
	}
	return f.c, nil
}

func (f *fakeCommunities) Role(ctx context.Context, id, uid string) (communities.Role, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.roleGets++
	if f.missing || id != f.c.ID {
		return communities.RoleNone, communities.ErrNotFound
	}
	if r := f.c.RoleOf(uid); r != communities.RoleNone {
		return r, nil // owner and moderators come from the community document: no member doc read
	}
	if !f.gotRole[uid] {
		f.gotRole[uid] = true
		budget.FromContext(ctx).AddReads(1)
	}
	return f.roles[uid], nil
}

// lockedGraph makes fakeGraph safe for the parallel test.
type lockedGraph struct {
	mu    sync.Mutex
	inner *fakeGraph
}

func (g *lockedGraph) Snapshot(ctx context.Context, uid string) (graph.Snapshot, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.inner.Snapshot(ctx, uid)
}

// commViewer is the userLikes read: 1 read, no flags set.
type commViewer struct{}

func (commViewer) Viewer(ctx context.Context, _ string) posts.ViewerSet {
	budget.FromContext(ctx).AddReads(1)
	return posts.ViewerSet{}
}

type commRig struct {
	*rig
	cp *commPosts
	fc *fakeCommunities
}

func newCommRig(t *testing.T) *commRig {
	t.Helper()
	r := newRig(t)
	cp := &commPosts{fakePosts: r.posts, rows: map[string][]*posts.Post{}}
	r.srv.deps.Posts = cp
	r.srv.deps.Viewer = commViewer{}
	r.srv.deps.Graph = &lockedGraph{inner: r.graph}
	fc := &fakeCommunities{
		c: communities.Community{
			ID: testCID, Name: "Go", Status: communities.StatusActive, OwnerID: testOwnerUID, ModeratorIDs: []string{testModUID},
			MemberCount: 7, CreatedAt: r.clock.Now().Add(-time.Hour),
		},
		roles: map[string]communities.Role{"me": communities.RoleMember}, gotRole: map[string]bool{},
	}
	r.srv.SetCommunities(fc, 100)
	return &commRig{rig: r, cp: cp, fc: fc}
}

func (c *commRig) get(caller, cid, since, page string, size int32) (*timelinev1.GetCommunityTimelineResponse, *budget.Counter, error) {
	c.t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(caller))
	c.info = info
	ctx, counter := budget.WithCounter(ictx)
	resp, err := c.srv.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{CommunityId: cid, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, counter, err
	}
	return resp.Msg, counter, nil
}

func (c *commRig) must(since, page string, size int32) (*timelinev1.GetCommunityTimelineResponse, *budget.Counter) {
	c.t.Helper()
	resp, counter, err := c.get("me", testCID, since, page, size)
	if err != nil {
		c.t.Fatalf("unexpected error: %v", err)
	}
	return resp, counter
}

func commIDs(r *timelinev1.GetCommunityTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// seed adds n posts, the newest `start` seconds before the clock, one second apart going back.
func (c *commRig) seed(n int, startSecAgo int) []*posts.Post {
	var out []*posts.Post
	for i := 0; i < n; i++ {
		out = append(out, c.cp.add(testCID, fmt.Sprintf("a%d", i%5), c.ms(-time.Duration(startSecAgo+i)*time.Second)))
	}
	return out
}

func TestCommunity_TwentyFivePostsPageTwentyThenFive(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(25, 100)
	resp, counter := c.must("", "", 20)
	if got := commIDs(resp); !slices.Equal(got, idsOf(ps[:20])) {
		t.Fatalf("page 1 = %v, want the 20 newest", got)
	}
	if resp.GetNextPageToken() == "" || resp.GetSinceToken() == "" {
		t.Fatalf("tokens: next=%q since=%q", resp.GetNextPageToken(), resp.GetSinceToken())
	}
	// community 1, member doc 1, posts 20, graph 1, userLikes 1 = 24; the interceptor makes it the wire's 25.
	if got := counter.Reads(); got != 24 {
		t.Fatalf("cold reads = %d, want 24", got)
	}
	if resp.GetCommunity().GetCommunityId() != testCID || resp.GetCommunity().GetViewerRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER || resp.GetCommunity().GetMemberCount() != 7 {
		t.Fatalf("header = %v", resp.GetCommunity())
	}
	resp2, counter2 := c.must("", resp.GetNextPageToken(), 20)
	if got := commIDs(resp2); !slices.Equal(got, idsOf(ps[20:])) {
		t.Fatalf("page 2 = %v, want the last 5", got)
	}
	if resp2.GetNextPageToken() != "" || resp2.GetSinceToken() != "" {
		t.Fatalf("page 2 tokens: next=%q since=%q, want none", resp2.GetNextPageToken(), resp2.GetSinceToken())
	}
	// community and member doc are warm; 5 posts + graph + userLikes.
	if got := counter2.Reads(); got != 7 {
		t.Fatalf("older page reads = %d, want 7", got)
	}
}

func TestCommunity_ColdBudgetAtPageFifty(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(60, 100)
	resp, counter := c.must("", "", 50)
	if len(resp.GetPosts()) != 50 || resp.GetNextPageToken() == "" {
		t.Fatalf("posts = %d next=%q", len(resp.GetPosts()), resp.GetNextPageToken())
	}
	if got := counter.Reads(); got != 54 {
		t.Fatalf("cold reads at page 50 = %d, want 54 (55 with the interceptor)", got)
	}
	// The fill reads at most the page size and the entry keeps 30.
	if calls := c.cp.callsSnapshot(); len(calls) != 1 || calls[0].limit != 50 {
		t.Fatalf("queries = %+v, want one of limit 50", calls)
	}
	// A warm page 50 reads the rows below the 30 the entry holds: 20, never more than the page.
	_, counter = c.must("", "", 50)
	calls := c.cp.callsSnapshot()
	if len(calls) != 2 || calls[1].limit != 20 || calls[1].w.Before == nil {
		t.Fatalf("queries = %+v, want a second of limit 20 below the entry", calls)
	}
	if got := counter.Reads(); got != 20+1+1 {
		t.Fatalf("warm page 50 reads = %d, want 22 (20 below the entry, graph, userLikes)", got)
	}
}

func TestCommunity_WarmEntryAndRefill(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(8, 100)
	first, _ := c.must("", "", 20)
	_, counter := c.must("", "", 20)
	// Warm: no query; only the graph and userLikes reads (community and member doc are cached).
	if got := counter.Reads(); got != 2 {
		t.Fatalf("warm reads = %d, want 2", got)
	}
	if n := len(c.cp.callsSnapshot()); n != 1 {
		t.Fatalf("queries = %d, want 1 (the second open is served from the entry)", n)
	}
	if got := idsOf(ps); !slices.Equal(commIDs(first), got) {
		t.Fatalf("ids = %v", commIDs(first))
	}

	// A post arrives; after 61 s the entry refills incrementally (After = its settle watermark) and keeps the old rows.
	c.clock.Advance(time.Second)
	np := c.cp.add(testCID, "a1", c.ms(0))
	c.clock.Advance(61 * time.Second)
	resp, counter := c.must("", "", 20)
	if got := commIDs(resp); len(got) != 9 || got[0] != np.ID {
		t.Fatalf("after refill = %v, want the new post first then the 8 old", got)
	}
	calls := c.cp.callsSnapshot()
	last := calls[len(calls)-1]
	if last.w.After == nil || last.w.After.ID != zeroID || last.w.Before != nil {
		t.Fatalf("refill window = %+v, want After = the settle sentinel", last.w)
	}
	if last.nReads != 1 {
		t.Fatalf("refill read %d rows, want 1", last.nReads)
	}
	if got := counter.Reads(); got != 1+2 {
		t.Fatalf("refill call reads = %d, want 3 (1 new post, graph, userLikes)", got)
	}
	if resp.GetNextPageToken() != "" {
		t.Fatalf("an exhausted community has no next token, got %q", resp.GetNextPageToken())
	}
}

func TestCommunity_RefillWithFullPageReplacesEntry(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(30, 400)
	c.must("", "", 20)
	c.clock.Advance(5 * time.Minute) // entry past the TTL but inside the LRU max age
	var fresh []*posts.Post          // newest first
	for i := 0; i < 25; i++ {
		fresh = append(fresh, c.cp.add(testCID, "a2", c.ms(-time.Duration(i)*time.Second)))
	}
	resp, counter := c.must("", "", 20)
	if got := commIDs(resp); !slices.Equal(got, idsOf(fresh[:20])) {
		t.Fatalf("page = %v, want the 20 newest", got)
	}
	calls := c.cp.callsSnapshot()
	if got := calls[len(calls)-1]; got.limit != 20 || got.nReads != 20 {
		t.Fatalf("refill = %+v, want one query of 20 rows (never more than the page)", got)
	}
	if got := counter.Reads(); got != 20+2 {
		t.Fatalf("reads = %d, want 22 (the full refill page, graph, userLikes; community and member doc warm)", got)
	}
	// 25 new posts exceed the page, so the rows in between are unknown: the entry now holds only the newest 20, not stale rows.
	_, counter = c.must("", "", 20)
	if got := counter.Reads(); got != 2 {
		t.Fatalf("warm reads after the replace = %d, want 2", got)
	}
}

func TestCommunity_RefreshReadsAndRemovals(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(3, 100)
	first, _ := c.must("", "", 20)
	since := first.GetSinceToken()

	// An empty refresh served by the warm entry reads nothing.
	resp, counter := c.must(since, "", 20)
	if len(resp.GetPosts()) != 0 || resp.GetSinceToken() == "" || counter.Reads() != 0 {
		t.Fatalf("empty refresh: posts=%d since=%q reads=%d, want 0 posts and 0 reads", len(resp.GetPosts()), resp.GetSinceToken(), counter.Reads())
	}

	// A moderator hides ps[1]: it is dropped everywhere and listed in removed_ids on the next refresh.
	hidden := ps[1].ID
	c.clock.Advance(10 * time.Second)
	c.fc.set(func(cm *communities.Community) {
		cm.RecentRemovals = []communities.Removal{{PostID: hidden, At: c.clock.Now()}}
	})
	// The entry still holds the post, and a refresh whose window reaches back over it drops it through keep.
	resp, _ = c.must(since, "", 20)
	if !slices.Equal(resp.GetRemovedIds(), []string{hidden}) {
		t.Fatalf("removed_ids = %v, want [%s]", resp.GetRemovedIds(), hidden)
	}
	if slices.Contains(commIDs(resp), hidden) {
		t.Fatal("the hidden post is still in the page")
	}
	if got, _ := c.info.Get(fieldCommunityRemove); fmt.Sprint(got) != "1" {
		t.Fatalf("log removed = %v, want 1", got)
	}
	// A cold open drops it too, with no removed_ids.
	resp, _ = c.must("", "", 20)
	if slices.Contains(commIDs(resp), hidden) || len(resp.GetRemovedIds()) != 0 || len(resp.GetPosts()) != 2 {
		t.Fatalf("cold open: ids=%v removed=%v", commIDs(resp), resp.GetRemovedIds())
	}
}

func TestCommunity_RefreshWithoutEntryQueriesTheWindowOnly(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(3, 100)
	first, _ := c.must("", "", 20)
	c.srv.ForgetCommunityFeed(testCID) // another instance, or an expired entry
	c.fc.cold()
	before := len(c.cp.callsSnapshot())
	resp, counter := c.must(first.GetSinceToken(), "", 20)
	calls := c.cp.callsSnapshot()
	if len(resp.GetPosts()) != 0 || len(calls) != before+1 || calls[before].nReads != 1 {
		t.Fatalf("posts=%d queries=%+v, want 0 posts and one 1-row query", len(resp.GetPosts()), calls[before:])
	}
	// community 1 + member doc 1 + the empty query 1 = 3 (4 with the interceptor): an empty refresh reads no graph and no userLikes.
	if got := counter.Reads(); got != 3 {
		t.Fatalf("empty refresh reads = %d, want 3", got)
	}
}

func TestCommunity_RefreshGapToken(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(2, 500)
	first, _ := c.must("", "", 20)
	c.clock.Advance(10 * time.Second)
	for i := 0; i < 25; i++ {
		c.cp.add(testCID, "a3", c.ms(-time.Duration(i)*time.Second)) // all after the entry loaded, inside its settle window
	}
	c.clock.Advance(2 * time.Minute)
	resp, _ := c.must(first.GetSinceToken(), "", 20)
	if len(resp.GetPosts()) != 20 || resp.GetGapPageToken() == "" || resp.GetNextPageToken() != "" {
		t.Fatalf("refresh: posts=%d gap=%q next=%q, want 20 posts and a gap token", len(resp.GetPosts()), resp.GetGapPageToken(), resp.GetNextPageToken())
	}
	gap, _ := c.must("", resp.GetGapPageToken(), 20)
	if len(gap.GetPosts()) != 5 || gap.GetGapPageToken() != "" || gap.GetNextPageToken() != "" {
		t.Fatalf("gap page: posts=%d gap=%q next=%q, want the remaining 5 and a closed gap", len(gap.GetPosts()), gap.GetGapPageToken(), gap.GetNextPageToken())
	}
}

func TestCommunity_RemovalsTruncationAndOverflow(t *testing.T) {
	t.Parallel()
	t.Run("a full array with no truncation is not rejected", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.seed(2, 100)
		first, _ := c.must("", "", 20)
		c.clock.Advance(time.Minute)
		var rs []communities.Removal
		for i := 0; i < 50; i++ {
			rs = append(rs, communities.Removal{PostID: pid(int64(9000 + i)), At: c.clock.Now().Add(-time.Duration(i) * time.Second)})
		}
		c.fc.set(func(cm *communities.Community) { cm.RecentRemovals = rs })
		resp, _ := c.must(first.GetSinceToken(), "", 20)
		if len(resp.GetRemovedIds()) != 50 || resp.GetRemovedIds()[0] != rs[0].PostID {
			t.Fatalf("removed_ids = %d, want all 50 newest first", len(resp.GetRemovedIds()))
		}
	})
	t.Run("a dropped removal newer than the token rejects it before any post is read", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.seed(2, 100)
		first, _ := c.must("", "", 20)
		c.clock.Advance(time.Minute)
		c.fc.set(func(cm *communities.Community) { cm.RemovalsTruncatedAt = c.clock.Now() })
		calls := len(c.cp.callsSnapshot())
		_, counter, err := c.get("me", testCID, first.GetSinceToken(), "", 20)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "since_token"})
		if len(c.cp.callsSnapshot()) != calls || counter.Reads() != 0 {
			t.Fatalf("posts were read for a rejected token (reads=%d)", counter.Reads())
		}
		// A cold open is not affected.
		if _, _, err := c.get("me", testCID, "", "", 20); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("a truncation older than the token is ignored", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.seed(2, 100)
		c.fc.set(func(cm *communities.Community) { cm.RemovalsTruncatedAt = c.clock.Now().Add(-time.Hour) })
		first, _ := c.must("", "", 20)
		if _, _, err := c.get("me", testCID, first.GetSinceToken(), "", 20); err != nil {
			t.Fatal(err)
		}
	})
}

func TestCommunity_AuthorRules(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		snap graph.Snapshot
		mod  bool
		a    string
		want bool
	}{
		{"plain author", graph.Snapshot{}, false, "x", true},
		{"own post", graph.Snapshot{Blocked: map[string]bool{"me": true}, BlockedBy: map[string]bool{"me": true}}, false, "me", true},
		{"viewer blocks", graph.Snapshot{Blocked: map[string]bool{"x": true}}, false, "x", false},
		{"viewer mutes", graph.Snapshot{Muted: map[string]bool{"x": true}}, false, "x", false},
		{"author blocks viewer", graph.Snapshot{BlockedBy: map[string]bool{"x": true}}, false, "x", false},
		{"author blocks moderator: kept (F14)", graph.Snapshot{BlockedBy: map[string]bool{"x": true}}, true, "x", true},
		{"moderator's own block still drops", graph.Snapshot{Blocked: map[string]bool{"x": true}}, true, "x", false},
		{"moderator's own mute still drops", graph.Snapshot{Muted: map[string]bool{"x": true}}, true, "x", false},
		{"overflow, stranger dropped", graph.Snapshot{BlockedByOverflow: true}, false, "x", false},
		{"overflow, followed kept", graph.Snapshot{BlockedByOverflow: true, Following: map[string]bool{"x": true}}, false, "x", true},
		{"overflow, moderator keeps strangers", graph.Snapshot{BlockedByOverflow: true}, true, "x", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := communityAuthorAllowed("me", tt.snap, tt.mod, tt.a); got != tt.want {
				t.Fatalf("allowed = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCommunity_BlockedAuthorsDroppedPerViewer(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ok := c.cp.add(testCID, "friend", c.ms(-10*time.Second))
	c.cp.add(testCID, "blocked", c.ms(-20*time.Second))
	c.cp.add(testCID, "raider", c.ms(-30*time.Second)) // blocks the viewer
	mine := c.cp.add(testCID, "me", c.ms(-40*time.Second))
	c.graph.snaps["me"] = graph.Snapshot{Blocked: map[string]bool{"blocked": true}, BlockedBy: map[string]bool{"raider": true}}
	resp, _ := c.must("", "", 20)
	if got := commIDs(resp); !slices.Equal(got, []string{ok.ID, mine.ID}) {
		t.Fatalf("member sees %v, want only the friend and their own post", got)
	}
	// The entry is shared: a moderator reading it keeps the raider (F14) but still drops the author they block.
	c.graph.snaps[testModUID] = graph.Snapshot{Blocked: map[string]bool{"blocked": true}, BlockedBy: map[string]bool{"raider": true}}
	mresp, _, err := c.get(testModUID, testCID, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(mresp.GetPosts()); n != 3 {
		t.Fatalf("moderator sees %d posts, want 3 (raider kept, blocked dropped)", n)
	}
	if got := mresp.GetCommunity().GetViewerRole(); got != communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR {
		t.Fatalf("role = %v", got)
	}
	if got, _ := c.info.Get(fieldFiltered); fmt.Sprint(got) != "1" {
		t.Fatalf("items_filtered = %v, want 1", got)
	}
}

func TestCommunity_HiddenByModerationIsDropped(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	keep := c.cp.add(testCID, "a1", c.ms(-10*time.Second))
	gone := c.cp.add(testCID, "a1", c.ms(-20*time.Second))
	gone.Moderation = "TAKEN_DOWN"
	resp, _ := c.must("", "", 20)
	if got := commIDs(resp); !slices.Equal(got, []string{keep.ID}) {
		t.Fatalf("posts = %v, want only the visible one", got)
	}
}

func TestCommunity_TokenBinding(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(25, 100)
	first, _ := c.must("", "", 20)
	// A Home token and a List token are VALIDATION on a community, with 0 reads.
	for name, tc := range map[string]struct{ since, page, field string }{
		"home since":      {since: c.homeSince(), field: "since_token"},
		"home page":       {page: c.homePage(), field: "page_token"},
		"list since":      {since: c.srv.codec.encodeSince(listFeed("me", testListID), posts.Position{CreatedAt: c.clock.Now(), ID: pid(5)}), field: "since_token"},
		"list page":       {page: c.srv.codec.encodePage(listFeed("me", testListID), posts.Position{CreatedAt: c.clock.Now(), ID: pid(5)}, nil), field: "page_token"},
		"other community": {page: c.srv.codec.encodePage(communityFeed("me", otherCID), posts.Position{CreatedAt: c.clock.Now(), ID: pid(5)}, nil), field: "page_token"},
		"other caller":    {since: c.srv.codec.encodeSince(communityFeed("someone", testCID), posts.Position{CreatedAt: c.clock.Now(), ID: pid(5)}), field: "since_token"},
		"swapped kinds":   {page: first.GetSinceToken(), field: "page_token"},
		"both tokens":     {since: first.GetSinceToken(), page: first.GetNextPageToken(), field: "page_token"},
	} {
		_, counter, err := c.get("me", testCID, tc.since, tc.page, 20)
		if counter.Reads() != 0 {
			t.Errorf("%s: %d reads", name, counter.Reads())
		}
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tc.field})
	}
	// A community token on Home is refused too.
	if _, _, err := c.home("me", first.GetSinceToken(), "", 20); err == nil {
		t.Error("a community since_token opened on Home")
	}
	// Bad community ids.
	for _, id := range []string{"", "12", "abc", "10000000000000000990"} {
		_, counter, err := c.get("me", id, "", "", 20)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "community_id"})
		if counter.Reads() != 0 {
			t.Errorf("id %q: %d reads", id, counter.Reads())
		}
	}
}

// homeSince and homePage seal Home tokens for "me".
func (c *commRig) homeSince() string {
	return c.srv.codec.encodeSince(homeFeed("me"), posts.Position{CreatedAt: c.clock.Now().Add(-time.Hour), ID: pid(5)})
}

func (c *commRig) homePage() string {
	return c.srv.codec.encodePage(homeFeed("me"), posts.Position{CreatedAt: c.clock.Now().Add(-time.Hour), ID: pid(5)}, nil)
}

func TestCommunity_StatusRules(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		mutate   func(*fakeCommunities)
		notFound bool
	}{
		{"active", func(*fakeCommunities) {}, false},
		{"archived is readable", func(f *fakeCommunities) { f.c.Status = communities.StatusArchived }, false},
		{"suspended", func(f *fakeCommunities) { f.c.Status = communities.StatusSuspended }, true},
		{"suspended for the owner too", func(f *fakeCommunities) { f.c.Status = communities.StatusSuspended; f.c.OwnerID = "me" }, true},
		{"missing", func(f *fakeCommunities) { f.missing = true }, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newCommRig(t)
			c.seed(2, 100)
			tt.mutate(c.fc)
			resp, counter, err := c.get("me", testCID, "", "", 20)
			if !tt.notFound {
				if err != nil || len(resp.GetPosts()) != 2 {
					t.Fatalf("err=%v resp=%v", err, resp)
				}
				return
			}
			wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
			if counter.Reads() > 2 || len(c.cp.callsSnapshot()) != 0 {
				t.Fatalf("not found cost %d reads, %d queries", counter.Reads(), len(c.cp.callsSnapshot()))
			}
		})
	}
	t.Run("suspended and missing are byte-identical", func(t *testing.T) {
		t.Parallel()
		a, b := newCommRig(t), newCommRig(t)
		a.fc.c.Status = communities.StatusSuspended
		b.fc.missing = true
		_, _, ea := a.get("me", testCID, "", "", 20)
		_, _, eb := b.get("me", testCID, "", "", 20)
		if ea == nil || eb == nil || ea.Error() != eb.Error() {
			t.Fatalf("%v vs %v", ea, eb)
		}
	})
	t.Run("a reader failure is internal and keeps ids out of the error", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.fc.err = errors.New("boom")
		_, _, err := c.get("me", testCID, "", "", 20)
		if connect.CodeOf(err) != connect.CodeUnknown && connect.CodeOf(err) != connect.CodeInternal {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestCommunity_ReplyPermissionFromRole(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		role   communities.Role
		status communities.Status
		want   postsv1.ReplyPermission
	}{
		{"member", communities.RoleMember, communities.StatusActive, postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED},
		{"outsider", communities.RoleNone, communities.StatusActive, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED},
		{"banned", communities.RoleBanned, communities.StatusActive, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED},
		{"archived", communities.RoleMember, communities.StatusArchived, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newCommRig(t)
			c.cp.add(testCID, "a1", c.ms(-10*time.Second))
			c.fc.c.Status = tt.status
			c.fc.roles["me"] = tt.role
			resp, _ := c.must("", "", 20)
			if got := resp.GetPosts()[0].GetViewerReplyPermission(); got != tt.want {
				t.Fatalf("permission = %v, want %v", got, tt.want)
			}
			if got := resp.GetCommunity().GetViewerRole(); got == communitiesv1.CommunityRole_COMMUNITY_ROLE_UNSPECIFIED {
				t.Fatalf("role not set on the header")
			}
		})
	}
	t.Run("owner and moderator", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.cp.add(testCID, "a1", c.ms(-10*time.Second))
		for _, u := range []string{testOwnerUID, testModUID} {
			resp, _, err := c.get(u, testCID, "", "", 20)
			if err != nil || resp.GetPosts()[0].GetViewerReplyPermission() != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
				t.Fatalf("%s: err=%v perm=%v", u, err, resp.GetPosts()[0].GetViewerReplyPermission())
			}
		}
	})
}

func TestCommunity_ProtectedAuthorDroppedEvenForModerators(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.srv.aud = posts.NewSnapshotAudience(&fakeProtected{uids: map[string]bool{"prot": true}})
	c.cp.add(testCID, "prot", c.ms(-10*time.Second))
	vis := c.cp.add(testCID, "a1", c.ms(-20*time.Second))
	for _, u := range []string{"me", testModUID} {
		resp, _, err := c.get(u, testCID, "", "", 20)
		if err != nil {
			t.Fatal(err)
		}
		if got := commIDs(resp); !slices.Equal(got, []string{vis.ID}) {
			t.Fatalf("%s sees %v, want the protected author's post dropped", u, got)
		}
	}
	// The caller's own protected post stays; a followed protected author stays.
	c.graph.snaps["me"] = graph.Snapshot{Following: map[string]bool{"prot": true}}
	resp, _ := c.must("", "", 20)
	if len(resp.GetPosts()) != 2 {
		t.Fatalf("a follower sees %d posts, want 2", len(resp.GetPosts()))
	}
}

func TestCommunity_LogFieldsAndCacheHit(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(3, 100)
	c.must("", "", 20)
	for k, want := range map[string]any{fieldOp: opCommunity, fieldCacheHit: false, fieldReturned: 3, fieldMode: string(modeCold)} {
		if got, _ := c.info.Get(k); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("log field %s = %v, want %v", k, got, want)
		}
	}
	c.must("", "", 20)
	if got, _ := c.info.Get(fieldCacheHit); got != true {
		t.Fatalf("warm cache_hit = %v", got)
	}
}

func TestCommunity_FlagModes(t *testing.T) {
	t.Parallel()
	mk := func(spec flags.Spec) posts.FlagChecker {
		return flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, spec)
	}
	allow := map[string]struct{}{"me": {}}
	tests := []struct {
		name    string
		reg     posts.FlagChecker
		wantOff bool
	}{
		{"off", mk(flags.Spec{Name: communities.FlagName, Mode: flags.Off}), true},
		{"allowlist, listed", mk(flags.Spec{Name: communities.FlagName, Mode: flags.Allowlist, Allowlist: allow}), false},
		{"allowlist, unlisted", mk(flags.Spec{Name: communities.FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{"x": {}}}), true},
		{"percent 0", mk(flags.Spec{Name: communities.FlagName, Mode: flags.Percent, Percent: 0}), true},
		{"percent 100", mk(flags.Spec{Name: communities.FlagName, Mode: flags.Percent, Percent: 100}), false},
		{"on", mk(flags.Spec{Name: communities.FlagName, Mode: flags.On}), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newCommRig(t)
			c.srv.deps.Flags = tt.reg
			c.seed(1, 100)
			_, counter, err := c.get("me", testCID, "", "", 20)
			if tt.wantOff {
				wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "communities"})
				if counter.Reads() != 0 || c.fc.gets != 0 {
					t.Fatalf("a refused call read %d docs", counter.Reads())
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
		})
	}
	t.Run("posts off", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.srv.deps.Flags = flags.NewRegistry(flags.Spec{Name: communities.FlagName, Mode: flags.On})
		_, counter, err := c.get("me", testCID, "", "", 20)
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, nil)
		if counter.Reads() != 0 {
			t.Fatalf("reads = %d", counter.Reads())
		}
	})
}

func TestCommunity_ParallelColdOpens(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(40, 100)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, _ := budget.WithCounter(ctxFor("me"))
			resp, err := c.srv.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{CommunityId: testCID, PageSize: 20}))
			if err != nil || len(resp.Msg.GetPosts()) != 20 {
				t.Errorf("err=%v", err)
			}
		}()
	}
	wg.Wait()
}

func TestCommunity_Helpers(t *testing.T) {
	t.Parallel()
	t.Run("mergeNewestFirst dedupes and orders", func(t *testing.T) {
		t.Parallel()
		mk := func(ms int64) *posts.Post {
			return &posts.Post{ID: pid(ms), CreatedAt: time.UnixMilli(ms)}
		}
		got := mergeNewestFirst([]*posts.Post{mk(9), mk(5)}, []*posts.Post{mk(5), mk(3), mk(12)})
		if want := []string{pid(12), pid(9), pid(5), pid(3)}; !slices.Equal(idsOf(got), want) {
			t.Fatalf("merged = %v", idsOf(got))
		}
	})
	t.Run("ForgetCommunityFeed on an unwired server is safe", func(t *testing.T) {
		t.Parallel()
		NewServer(Deps{}).ForgetCommunityFeed(testCID)
	})
	t.Run("SetCommunities(nil) leaves it unwired", func(t *testing.T) {
		t.Parallel()
		s := NewServer(Deps{})
		s.SetCommunities(nil, 10)
		if s.community != nil {
			t.Fatal("wired with a nil reader")
		}
	})
}
