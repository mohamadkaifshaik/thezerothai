package timeline

import (
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

type rig struct {
	t     *testing.T
	clock *fakeClock
	posts *fakePosts
	graph *fakeGraph
	dir   *fakeDirectory
	srv   *Server
	info  *logger.RequestInfo // request-log fields of the most recent home()/user() call
}

func newRig(t *testing.T) *rig {
	t.Helper()
	c := newClock()
	r := &rig{
		t: t, clock: c, posts: newFakePosts(c),
		graph: &fakeGraph{snaps: map[string]graph.Snapshot{}},
		dir:   &fakeDirectory{profiles: map[string]identity.Profile{}},
	}
	r.srv = NewServer(Deps{
		Flags: fakeFlags{on: true}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
		CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: c.Now,
	})
	return r
}

// follow makes caller follow n authors named f1..fn and gives each a profile.
func (r *rig) follow(caller string, n int) []string {
	snap := r.graph.snaps[caller]
	if snap.Following == nil {
		snap.Following = map[string]bool{}
	}
	var out []string
	for i := 1; i <= n; i++ {
		a := fmt.Sprintf("f%d", i)
		snap.Following[a] = true
		r.dir.profiles[a] = identity.Profile{UserID: a, Status: identity.AccountStatusActive}
		out = append(out, a)
	}
	r.graph.snaps[caller] = snap
	return out
}

func (r *rig) home(caller, since, page string, size int32) (*timelinev1.GetHomeTimelineResponse, *budget.Counter, error) {
	r.t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(caller))
	r.info = info
	ctx, counter := budget.WithCounter(ictx)
	resp, err := r.srv.GetHomeTimeline(ctx, connect.NewRequest(&timelinev1.GetHomeTimelineRequest{PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, counter, err
	}
	return resp.Msg, counter, nil
}

func (r *rig) user(caller, target string, replies bool, since, page string, size int32) (*timelinev1.GetUserTimelineResponse, *budget.Counter, error) {
	r.t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(caller))
	r.info = info
	ctx, counter := budget.WithCounter(ictx)
	resp, err := r.srv.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{
		UserId: target, IncludeReplies: replies, PageSize: size, SinceToken: since, PageToken: page,
	}))
	if err != nil {
		return nil, counter, err
	}
	return resp.Msg, counter, nil
}

func homeIDs(r *timelinev1.GetHomeTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func userIDs(r *timelinev1.GetUserTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func (r *rig) mustHome(since, page string, size int32) *timelinev1.GetHomeTimelineResponse {
	r.t.Helper()
	resp, _, err := r.home("me", since, page, size)
	if err != nil {
		r.t.Fatalf("unexpected error: %v", err)
	}
	return resp
}

func (r *rig) mustUser(caller, target string, replies bool, since, page string, size int32) *timelinev1.GetUserTimelineResponse {
	r.t.Helper()
	resp, _, err := r.user(caller, target, replies, since, page, size)
	if err != nil {
		r.t.Fatalf("unexpected error: %v", err)
	}
	return resp
}

// ms returns the clock's current time in ms plus d.
func (r *rig) ms(d time.Duration) int64 { return r.clock.Now().Add(d).UnixMilli() }

func TestHome_ColdBudgetAndChunking(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		following  int
		wantChunks int
		maxReads   int64 // excluding the interceptor read
	}{
		{"F=0 only self", 0, 1, 1 + 40},
		{"F=29 -> 30 authors, 1 chunk", 29, 1, 1 + 40},
		{"F=30 -> 31 authors, 2 chunks", 30, 2, 1 + 40 + 2},
		{"F=31 -> 32 authors, 2 chunks", 31, 2, 1 + 40 + 2},
		{"F=60 page 20: 2 + 3*14 = 44 with the interceptor", 60, 3, 43},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			authors := append(r.follow("me", tc.following), "me")
			for i, a := range authors {
				for j := 0; j < 30; j++ { // dense: every chunk fills k
					r.posts.add(a, r.ms(-time.Duration(1+i*30+j)*time.Millisecond*10))
				}
			}
			resp, counter, err := r.home("me", "", "", 20)
			if err != nil {
				t.Fatal(err)
			}
			if got := r.posts.queryCount("ByAuthors"); got != tc.wantChunks {
				t.Fatalf("chunk queries = %d, want %d", got, tc.wantChunks)
			}
			if counter.Reads() > tc.maxReads {
				t.Fatalf("reads = %d, want <= %d", counter.Reads(), tc.maxReads)
			}
			if len(resp.Posts) == 0 || resp.SinceToken == "" {
				t.Fatalf("cold open returned %d posts, since=%q", len(resp.Posts), resp.SinceToken)
			}
			if resp.NextPageToken == "" {
				t.Fatal("dense feed must return next_page_token")
			}
		})
	}
}

func TestHome_RefreshWithNothingNewCostsC(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 60) // 61 authors -> C = 3
	cold := r.mustHome("", "", 20)
	_ = cold
	// Drop every cache entry: "author-recent empty (or disabled)", graph warm.
	r.posts.recent = map[string]posts.Recent{}
	r.posts.queries = nil
	r.clock.Advance(5 * time.Minute)
	resp, counter, err := r.home("me", cold.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Posts) != 0 || resp.GapPageToken != "" || resp.NextPageToken != "" {
		t.Fatalf("expected an empty refresh, got %+v", resp)
	}
	// graph read (1) + C empty queries (3 x 1 read).
	if counter.Reads() != 1+3 {
		t.Fatalf("reads = %d, want 4 (graph + C=3)", counter.Reads())
	}
	if resp.SinceToken == "" {
		t.Fatal("an empty refresh still returns a since_token")
	}
}

// A cold open caches every author of an unfilled chunk (empty ones too), so the next refresh inside 60 s reads
// 0 posts (authors_from_cache) and runs no chunk query.
func TestHome_ColdOpenFillsAuthorRecentAndRefreshIsFree(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	authors := r.follow("me", 10)
	r.posts.add("f1", r.ms(-time.Minute))
	r.posts.add("me", r.ms(-30*time.Second))
	cold := r.mustHome("", "", 20)
	if len(cold.Posts) != 2 {
		t.Fatalf("cold posts = %d, want 2", len(cold.Posts))
	}
	for _, a := range append(authors, "me") {
		rec, ok := r.posts.AuthorRecent(a)
		if !ok || rec.Truncated {
			t.Fatalf("author %s: entry ok=%v truncated=%v, want a complete entry (empty ones too)", a, ok, rec.Truncated)
		}
	}
	r.posts.queries = nil
	r.clock.Advance(20 * time.Second)
	resp, counter, err := r.home("me", cold.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if n := r.posts.queryCount("By"); n != 0 {
		t.Fatalf("refresh ran %d queries, want 0 (all authors covered)", n)
	}
	if counter.Reads() != 1 { // the graph read only
		t.Fatalf("reads = %d, want 1", counter.Reads())
	}
	// Both posts are older than W, so the cold since is the newest post itself and nothing comes back.
	if len(resp.Posts) != 0 {
		t.Fatalf("refresh returned %d posts, want 0", len(resp.Posts))
	}
}

func TestHome_FiltersBlockedMutedBlockedByAndKeepsSelf(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 5)
	snap := r.graph.snaps["me"]
	snap.Muted = following("f2")
	snap.Blocked = following("f3")
	snap.BlockedBy = following("f4") // stale following still lists f4 (D6)
	r.graph.snaps["me"] = snap
	for _, a := range []string{"f1", "f2", "f3", "f4", "f5", "me"} {
		r.posts.add(a, r.ms(-time.Minute))
	}
	resp := r.mustHome("", "", 50)
	got := map[string]bool{}
	for _, v := range resp.Posts {
		got[v.Post.Author.UserId] = true
	}
	for _, a := range []string{"f1", "f5", "me"} {
		if !got[a] {
			t.Errorf("home is missing %s", a)
		}
	}
	for _, a := range []string{"f2", "f3", "f4"} {
		if got[a] {
			t.Errorf("home shows %s (muted/blocked/blocked-by)", a)
		}
	}
	// Suspended or deleting authors are not filtered (D10): the home never reads their status.
	if len(r.dir.profiles) != 5 || r.graph.calls[0] != "me" {
		t.Fatal("unexpected reads")
	}
}

func TestHome_RefreshGapFollowsToTheOldSinceAndEndsEmpty(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	// Old history, then a burst of new posts that exceeds one page.
	for i := 0; i < 10; i++ {
		r.posts.add("f1", r.ms(-time.Duration(2000-i)*time.Second))
	}
	cold := r.mustHome("", "", 5)
	r.posts.recent = map[string]posts.Recent{}
	oldSince, err := newCodec(r.clock).parse(homeFeed("me"), cold.SinceToken, "")
	if err != nil {
		t.Fatal(err)
	}
	r.clock.Advance(10 * time.Minute)
	var fresh []string
	for i := 0; i < 40; i++ {
		fresh = append(fresh, r.posts.add([]string{"f1", "f2", "f3", "me"}[i%4], r.ms(-time.Duration(300-i)*time.Second)).ID)
	}
	resp := r.mustHome(cold.SinceToken, "", 5)
	if resp.GapPageToken == "" || resp.NextPageToken != "" {
		t.Fatalf("gap=%q next=%q, want a gap token and no next page on a refresh", resp.GapPageToken, resp.NextPageToken)
	}
	seen := map[string]bool{}
	for _, id := range homeIDs(resp) {
		seen[id] = true
	}
	token, steps := resp.GapPageToken, 0
	for token != "" {
		steps++
		if steps > 50 {
			t.Fatal("gap never closed")
		}
		page := r.mustHome("", token, 5)
		if page.SinceToken != "" {
			t.Fatal("a page response must not carry a since_token")
		}
		for _, v := range page.Posts {
			if Compare(PositionOf(&posts.Post{ID: v.Post.PostId, CreatedAt: v.Post.CreatedAt.AsTime()}), *oldSince.Since) >= 0 {
				t.Fatalf("gap page returned %s at or below the old since", v.Post.PostId)
			}
			if seen[v.Post.PostId] {
				t.Fatalf("duplicate %s across gap pages", v.Post.PostId)
			}
			seen[v.Post.PostId] = true
		}
		token = page.NextPageToken
	}
	for _, id := range fresh {
		if !seen[id] {
			t.Fatalf("post %s newer than the old since was never delivered", id)
		}
	}
}

// D13 regression: a post committed late with createdAt older than an item an earlier refresh returned is
// delivered by the next refresh, because since trails by the settle window.
func TestHome_SettleWindowDeliversALateCommit(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 2)
	cold := r.mustHome("", "", 20)
	r.posts.recent = map[string]posts.Recent{}
	r.clock.Advance(time.Minute)

	p1 := r.posts.add("f1", r.ms(-time.Second)) // visible to refresh 1
	resp1 := r.mustHome(cold.SinceToken, "", 20)
	if got := homeIDs(resp1); len(got) != 1 || got[0] != p1.ID {
		t.Fatalf("refresh 1 = %v, want [p1]", got)
	}
	// p2 committed after refresh 1, with createdAt older than p1 (but inside the settle window).
	p2 := r.posts.add("f2", r.ms(-5*time.Second))
	r.clock.Advance(30 * time.Second)
	r.posts.recent = map[string]posts.Recent{}
	resp2 := r.mustHome(resp1.SinceToken, "", 20)
	got := map[string]bool{}
	for _, id := range homeIDs(resp2) {
		got[id] = true
	}
	if !got[p2.ID] {
		t.Fatalf("late commit %s was skipped by the since watermark", p2.ID)
	}
	if !got[p1.ID] {
		t.Fatal("p1 should come back (newer than W); the client dedupes by post_id")
	}
}

func TestHome_TokenRejectionsCostNothing(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	cold := r.mustHome("", "", 20)
	r.posts.queries, r.graph.calls = nil, nil

	tests := []struct {
		name        string
		since, page string
		caller      string
		field       string
	}{
		{"both tokens", cold.SinceToken, cold.SinceToken, "me", fieldPage},
		{"garbage since", "xx", "", "me", fieldSince},
		{"garbage page", "", "xx", "me", fieldPage},
		{"since token as page token", "", cold.SinceToken, "me", fieldPage},
		{"another caller's since token", cold.SinceToken, "", "mallory", fieldSince},
		{"user-feed token on home", userTok(r), "", "me", fieldSince},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, counter, err := r.home(tc.caller, tc.since, tc.page, 20)
			wantField(t, err, tc.field)
			if counter.Reads() != 0 || len(r.graph.calls) != 0 || len(r.posts.queries) != 0 {
				t.Fatalf("a rejected token read %d docs, graph %v, queries %v", counter.Reads(), r.graph.calls, r.posts.queries)
			}
		})
	}
}

func userTok(r *rig) string {
	return newCodec(r.clock).encodeSince(userFeed("me", "f1", false), pos(1000, 1))
}

func TestHome_TokensOlderThan24hAreAcceptedUntilTheTTL(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 2)
	r.posts.add("f1", r.ms(-time.Hour))
	cold := r.mustHome("", "", 1)
	r.clock.Advance(25 * time.Hour)
	if _, _, err := r.home("me", cold.SinceToken, "", 20); err != nil {
		t.Fatalf("since token of 25 h: %v", err)
	}
	r.clock.Advance(720 * time.Hour)
	_, counter, err := r.home("me", cold.SinceToken, "", 20)
	wantField(t, err, fieldSince)
	if counter.Reads() != 0 {
		t.Fatal("expired token must cost 0 reads")
	}
}

func TestHome_ClosedGapReturnsEmptyWithZeroReads(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 2)
	f := homeFeed("me")
	tok := newCodec(r.clock).encodePage(f, pos(1000, 1), ptr(pos(5000, 5))) // Lower newer than Upper
	resp, counter, err := r.home("me", "", tok, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Posts) != 0 || resp.NextPageToken != "" || counter.Reads() != 0 || len(r.graph.calls) != 0 {
		t.Fatalf("closed gap: %+v reads=%d", resp, counter.Reads())
	}
}

func TestHome_WorstCaseAtTheFollowingCapAndBoundedConcurrency(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 5000)
	for i := 1; i <= 5000; i += 3 {
		r.posts.add(fmt.Sprintf("f%d", i), r.ms(-time.Duration(i)*time.Second))
	}
	// Rendezvous instead of a sleep: the first two queries wait until both are in flight (bounded, so a serial
	// implementation fails the max-in-flight assertion below instead of hanging).
	var arrived atomic.Int32
	r.posts.hook = func() {
		if arrived.Add(1) > 2 {
			return
		}
		deadline := time.Now().Add(2 * time.Second)
		for arrived.Load() < 2 && time.Now().Before(deadline) {
			runtime.Gosched()
		}
	}
	start := time.Now()
	resp, counter, err := r.home("me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	// 2 + C + 2p = 269 with the interceptor read, so 268 here.
	if counter.Reads() > 268 {
		t.Fatalf("reads = %d, want <= 268", counter.Reads())
	}
	if got := r.posts.queryCount("ByAuthors"); got != 167 {
		t.Fatalf("chunks = %d, want C=167", got)
	}
	if r.posts.maxInFlight > chunkConcurrency || r.posts.maxInFlight < 2 {
		t.Fatalf("max in flight = %d, want 2..%d", r.posts.maxInFlight, chunkConcurrency)
	}
	if len(resp.Posts) == 0 {
		t.Fatal("no posts")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("worst case took %v", time.Since(start))
	}
}

func TestHome_OlderPagesWalkTheWholeFeedOnce(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 70) // 71 authors: 3 chunks
	var want int
	for i := 1; i <= 70; i++ {
		for j := 0; j < 3; j++ {
			r.posts.add(fmt.Sprintf("f%d", i), r.ms(-time.Duration(i*10+j)*time.Second))
			want++
		}
	}
	resp := r.mustHome("", "", 20)
	seen := map[string]bool{}
	for _, id := range homeIDs(resp) {
		seen[id] = true
	}
	tok, pages := resp.NextPageToken, 1
	for tok != "" {
		pages++
		page := r.mustHome("", tok, 20)
		for _, id := range homeIDs(page) {
			if seen[id] {
				t.Fatalf("duplicate %s", id)
			}
			seen[id] = true
		}
		tok = page.NextPageToken
		if pages > 100 {
			t.Fatal("did not terminate")
		}
	}
	if len(seen) != want {
		t.Fatalf("walked %d posts, want %d", len(seen), want)
	}
}

// ---- GetUserTimeline ----

func (r *rig) seedUser(target string, n int) []*posts.Post {
	r.dir.profiles[target] = identity.Profile{UserID: target, Status: identity.AccountStatusActive}
	var out []*posts.Post
	for i := 0; i < n; i++ {
		out = append(out, r.posts.add(target, r.ms(-time.Duration(1000-i)*time.Second)))
	}
	return out
}

func TestUser_PagesCoverAllPostsExactlyOnce(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		total int
		pages int // calls until next_page_token == ""
	}{
		{"45 posts", 45, 3},
		{"exactly 40 posts: the third call is empty", 40, 3},
		{"0 posts", 0, 1},
		{"1 post", 1, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.seedUser("bob", tc.total)
			seen := map[string]bool{}
			tok, calls := "", 0
			for {
				calls++
				resp, counter, err := r.user("me", "bob", false, "", tok, 20)
				if err != nil {
					t.Fatal(err)
				}
				for _, id := range userIDs(resp) {
					if seen[id] {
						t.Fatalf("duplicate %s", id)
					}
					seen[id] = true
				}
				if tc.total == 40 && calls == 3 {
					if len(resp.Posts) != 0 || resp.NextPageToken != "" || counter.Reads() != 3 {
						t.Fatalf("empty final call: %d posts next=%q reads=%d, want 0/\"\"/3 (target + graph + 1 empty query)", len(resp.Posts), resp.NextPageToken, counter.Reads())
					}
				}
				if tok = resp.NextPageToken; tok == "" {
					break
				}
				if calls > 10 {
					t.Fatal("did not terminate")
				}
			}
			if len(seen) != tc.total || calls != tc.pages {
				t.Fatalf("covered %d of %d posts in %d calls, want %d calls", len(seen), tc.total, calls, tc.pages)
			}
		})
	}
}

func TestUser_ColdBudgetWarmFirstPageAndCacheHit(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("bob", 30)
	resp, counter, err := r.user("me", "bob", false, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	// The fakes charge target users + caller graph + Limit(20) = 2 + 20; the account-status interceptor (not in
	// this rig) adds the 3rd fixed read, giving the documented 3 + p = 23 at p = 20.
	if counter.Reads() != 2+20 {
		t.Fatalf("cold reads = %d, want 22 (+1 interceptor = 3 + p)", counter.Reads())
	}
	if len(resp.Posts) != 20 || resp.NextPageToken == "" {
		t.Fatalf("first page: %d posts next=%q", len(resp.Posts), resp.NextPageToken)
	}
	wantCacheHit(t, r, false) // the cold open queried
	r.posts.queries = nil
	resp2, counter2, err := r.user("me", "bob", false, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.posts.queries) != 0 || counter2.Reads() != 2 { // users + graph are always charged by the fakes
		t.Fatalf("warm first page ran queries %v reads %d, want 0 queries", r.posts.queries, counter2.Reads())
	}
	wantCacheHit(t, r, true) // T12 AC: the warm first page is served from the author-recent entry
	if fmt.Sprint(userIDs(resp2)) != fmt.Sprint(userIDs(resp)) {
		t.Fatal("cache-served page differs from the queried page")
	}
	// A smaller page is also served from the entry and still returns a next token.
	small := r.mustUser("me", "bob", false, "", "", 5)
	if len(small.Posts) != 5 || small.NextPageToken == "" || len(r.posts.queries) != 0 {
		t.Fatalf("page 5: %d posts next=%q queries=%v", len(small.Posts), small.NextPageToken, r.posts.queries)
	}
	// Page 50 queries directly: 3 + p.
	_, c50, err := r.user("me", "bob", false, "", "", 50)
	if err != nil || c50.Reads() != 2+30 {
		t.Fatalf("page 50 reads = %d err=%v, want 32 (30 posts)", c50.Reads(), err)
	}
	// Deep paging never touches the entry.
	r.posts.queries = nil
	_ = r.mustUser("me", "bob", false, "", resp.NextPageToken, 20)
	if len(r.posts.queries) != 1 {
		t.Fatalf("page 2 ran %d queries, want 1", len(r.posts.queries))
	}
}

func TestUser_SinceRefresh(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("bob", 5)
	cold := r.mustUser("me", "bob", false, "", "", 20)
	r.clock.Advance(2 * time.Minute) // entry expired
	r.posts.queries = nil
	resp, counter, err := r.user("me", "bob", false, cold.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	// target + graph + 1 empty query = 3 (+1 interceptor = 4 cold).
	if len(resp.Posts) != 0 || counter.Reads() != 3 {
		t.Fatalf("refresh: %d posts reads=%d, want 0 posts and 3 reads", len(resp.Posts), counter.Reads())
	}
	// Now the entry is stale; fill it with a cold open and refresh again: served from the entry, 0 queries.
	cold2 := r.mustUser("me", "bob", false, "", "", 20)
	r.posts.queries = nil
	r.clock.Advance(20 * time.Second)
	resp2 := r.mustUser("me", "bob", false, cold2.SinceToken, "", 20)
	if len(r.posts.queries) != 0 {
		t.Fatalf("warm refresh ran queries %v", r.posts.queries)
	}
	if resp2.SinceToken == "" {
		t.Fatal("no since_token")
	}
}

func TestUser_RefreshGapAndRepliesTab(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("bob", 0)
	cold := r.mustUser("me", "bob", false, "", "", 5)
	r.clock.Advance(time.Minute)
	for i := 0; i < 12; i++ {
		r.posts.add("bob", r.ms(-time.Duration(30-i)*time.Second))
	}
	reply := r.posts.add("bob", r.ms(-time.Second))
	reply.IsReply = true
	// Replies tab: no isReply filter.
	rep := r.mustUser("me", "bob", true, "", "", 50)
	if len(rep.Posts) != 13 {
		t.Fatalf("replies tab = %d posts, want 13", len(rep.Posts))
	}
	r.posts.recent = map[string]posts.Recent{}
	resp := r.mustUser("me", "bob", false, cold.SinceToken, "", 5)
	if len(resp.Posts) != 5 || resp.GapPageToken == "" || resp.NextPageToken != "" {
		t.Fatalf("refresh: %d posts gap=%q next=%q", len(resp.Posts), resp.GapPageToken, resp.NextPageToken)
	}
	for _, p := range resp.Posts {
		if p.Post.PostId == reply.ID {
			t.Fatal("Posts tab returned a reply")
		}
	}
	// The Posts-tab gap token does not open on the Replies tab.
	_, _, err := r.user("me", "bob", true, "", resp.GapPageToken, 5)
	wantField(t, err, fieldPage)
	total := len(resp.Posts)
	tok := resp.GapPageToken
	for tok != "" {
		page := r.mustUser("me", "bob", false, "", tok, 5)
		total += len(page.Posts)
		tok = page.NextPageToken
	}
	if total != 12 {
		t.Fatalf("refresh + gap pages = %d posts, want 12", total)
	}
}

func notFound(t *testing.T, err error) []byte {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound || ae.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED || ae.Message != "profile not found" {
		t.Fatalf("err = %#v, want NOT_FOUND / UNSPECIFIED / profile not found", err)
	}
	return []byte(fmt.Sprintf("%d|%d|%s|%v", ae.Code, ae.Reason, ae.Message, ae.Metadata))
}

func TestUser_VisibilityMatrix(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		setup     func(r *rig)
		wantFound bool
		maxReads  int64 // excluding the interceptor
	}{
		{"stranger", func(r *rig) {}, true, 2 + 3},
		{"missing user", func(r *rig) { delete(r.dir.profiles, "bob") }, false, 1},
		{"suspended (Directory drops it)", func(r *rig) { delete(r.dir.profiles, "bob") }, false, 1},
		{"B blocks A", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{BlockedBy: following("bob")} }, false, 2},
		{"both block each other", func(r *rig) {
			r.graph.snaps["me"] = graph.Snapshot{BlockedBy: following("bob"), Blocked: following("bob")}
		}, false, 2},
		{"A blocks B: posts returned", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{Blocked: following("bob")} }, true, 5},
		{"A mutes B: posts returned", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{Muted: following("bob")} }, true, 5},
		{"overflow, B blocks A (target graph)", func(r *rig) {
			r.graph.snaps["me"] = graph.Snapshot{BlockedByOverflow: true}
			r.graph.snaps["bob"] = graph.Snapshot{Blocked: following("me")}
		}, false, 3},
		{"overflow, no block: +1 read", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{BlockedByOverflow: true} }, true, 6},
	}
	var wire []byte
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)
			r.seedUser("bob", 3)
			tc.setup(r)
			resp, counter, err := r.user("me", "bob", false, "", "", 3)
			if tc.wantFound {
				if err != nil || len(resp.Posts) != 3 {
					t.Fatalf("err=%v posts=%d, want 3 posts", err, len(resp.GetPosts()))
				}
			} else {
				b := notFound(t, err)
				if wire == nil {
					wire = b
				} else if string(wire) != string(b) {
					t.Fatalf("NOT_FOUND bytes differ: %s vs %s", wire, b)
				}
			}
			if counter.Reads() > tc.maxReads {
				t.Fatalf("reads = %d, want <= %d", counter.Reads(), tc.maxReads)
			}
		})
	}
}

func TestUser_ValidationAndTokensOlderThan24h(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("bob", 3)
	for _, bad := range []string{"", "a_b", "x/y"} {
		_, counter, err := r.user("me", bad, false, "", "", 20)
		wantField(t, err, "user_id")
		if counter.Reads() != 0 {
			t.Fatal("validation read docs")
		}
	}
	cold := r.mustUser("me", "bob", false, "", "", 20)
	_, counter, err := r.user("me", "bob", false, cold.SinceToken, cold.SinceToken, 20)
	wantField(t, err, fieldPage)
	if counter.Reads() != 0 {
		t.Fatal("both tokens must read nothing")
	}
	r.clock.Advance(25 * time.Hour)
	if _, _, err := r.user("me", "bob", false, cold.SinceToken, "", 20); err != nil {
		t.Fatalf("25 h old since: %v", err)
	}
	r.clock.Advance(721 * time.Hour)
	_, _, err = r.user("me", "bob", false, cold.SinceToken, "", 20)
	wantField(t, err, fieldSince)
	// Another caller's token and another target's token.
	_, _, err = r.user("mallory", "bob", false, cold.SinceToken, "", 20)
	wantField(t, err, fieldSince)
	_, _, err = r.user("me", "carol", false, cold.SinceToken, "", 20)
	wantField(t, err, fieldSince)
}

func TestUser_OwnTimelineSkipsTheGraphRead(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("me", 2)
	resp, counter, err := r.user("me", "me", false, "", "", 20)
	if err != nil || len(resp.Posts) != 2 {
		t.Fatalf("err=%v posts=%d", err, len(resp.GetPosts()))
	}
	if len(r.graph.calls) != 0 || counter.Reads() != 1+2 {
		t.Fatalf("graph calls %v reads %d, want 0 graph reads, 3 total", r.graph.calls, counter.Reads())
	}
}

func wantCacheHit(t *testing.T, r *rig, want bool) {
	t.Helper()
	got, ok := r.info.Get(fieldCacheHit)
	if !ok || got != want {
		t.Fatalf("%s = %v (set=%v), want %v", fieldCacheHit, got, ok, want)
	}
}

func wantClamped(t *testing.T, r *rig, want bool) {
	t.Helper()
	got, ok := r.info.Get(fieldClamped)
	if !ok || got != want {
		t.Fatalf("%s = %v (set=%v), want %v", fieldClamped, got, ok, want)
	}
}

// TestSinceClampedIsLogged (T13 AC): since_clamped is true exactly when the newest returned post is inside the
// settle window (so it will come back on the next refresh), for both feeds.
func TestSinceClampedIsLogged(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		age   time.Duration // age of the one new post
		clamp bool
	}{
		{"post inside the settle window", time.Second, true},
		{"post older than the settle window", time.Minute, false},
	}
	for _, tt := range tests {
		t.Run("home/"+tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.follow("me", 1)
			cold := r.mustHome("", "", 20)
			r.posts.recent = map[string]posts.Recent{}
			r.clock.Advance(2 * time.Minute)
			r.posts.add("f1", r.ms(-tt.age))
			r.mustHome(cold.SinceToken, "", 20)
			wantClamped(t, r, tt.clamp)
		})
		t.Run("user/"+tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.seedUser("bob", 0)
			cold := r.mustUser("me", "bob", false, "", "", 20)
			r.clock.Advance(2 * time.Minute)
			r.posts.add("bob", r.ms(-tt.age))
			r.mustUser("me", "bob", false, cold.SinceToken, "", 20)
			wantClamped(t, r, tt.clamp)
		})
	}
}

// TestTimeline_ErrorsNeverCarryRawUids: a graph/directory failure whose text embeds a uid (graph's repo wraps
// "graph: get <uid>: ...") must reach mw.ErrorMapping redacted (security review L4).
func TestTimeline_ErrorsNeverCarryRawUids(t *testing.T) {
	t.Parallel()
	const callerUID, targetUID = "caller-uid-secret", "target-uid-secret"
	leak := func(uid string) error { return fmt.Errorf("graph: get %s: rpc error: unavailable", uid) }
	tests := []struct {
		name  string
		setup func(r *rig)
		call  func(r *rig) error
	}{
		{"home caller graph", func(r *rig) { r.graph.errs[callerUID] = leak(callerUID) },
			func(r *rig) error { _, _, err := r.home(callerUID, "", "", 20); return err }},
		{"user target profile", func(r *rig) { r.dir.err = leak(targetUID) },
			func(r *rig) error { _, _, err := r.user(callerUID, targetUID, false, "", "", 20); return err }},
		{"user caller graph", func(r *rig) { r.seedUser(targetUID, 1); r.graph.errs[callerUID] = leak(callerUID) },
			func(r *rig) error { _, _, err := r.user(callerUID, targetUID, false, "", "", 20); return err }},
		{"user target graph", func(r *rig) {
			r.seedUser(targetUID, 1)
			r.graph.snaps[callerUID] = graph.Snapshot{BlockedByOverflow: true}
			r.graph.errs[targetUID] = leak(targetUID)
		}, func(r *rig) error { _, _, err := r.user(callerUID, targetUID, false, "", "", 20); return err }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.graph.errs = map[string]error{}
			tt.setup(r)
			err := tt.call(r)
			if err == nil {
				t.Fatal("want an error")
			}
			if msg := logger.CauseChain(err); strings.Contains(msg, callerUID) || strings.Contains(msg, targetUID) || strings.Contains(err.Error(), "-uid-secret") {
				t.Fatalf("raw uid in error: %q / %q", err.Error(), msg)
			}
		})
	}
}
