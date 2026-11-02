package timeline

// W5-36 (Part B backend tests): the attack list of the W5-27 report, at the package level over the fakes of community_feed_test.go.
// Tests are named TestW536_* so one -run TestW536 selects them. The chain-level counterparts are in
// internal/apiserver/communities_w536_chain_integration_test.go.

import (
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// An entry between 60 s and 5 min old, and a removal the capped array has since dropped (the STALENESS BOUND of communityEntryMaxAge):
// the shared entry still holds the hidden post, recentRemovals no longer lists it, so a cold open shows it until the entry expires. The
// LRU's hard expiry runs on the real clock, so ForgetCommunityFeed stands for it (it is the same Delete the expiry performs). A since
// token older than the dropped removal is rejected, so the client cold-opens and lands on this bound (designed, ADR-0031 A3). Only a
// post that outlives the expiry would be a defect.
func TestW536_DroppedRemovalShowsOnlyUntilTheEntryExpires(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(3, 100)
	first, _ := c.must("", "", 20)
	if len(first.GetPosts()) != 3 {
		t.Fatalf("setup: %d posts", len(first.GetPosts()))
	}

	// Another instance hides ps[1]: the row leaves the query (communityId is deleted), the removal was listed and then fell off the
	// capped array, so only removalsTruncatedAt remembers it.
	hidden := ps[1]
	hidden.CommunityID = ""
	c.clock.Advance(time.Minute)
	c.fc.set(func(cm *communities.Community) { cm.RemovalsTruncatedAt = c.clock.Now() })

	// The old token cannot be answered honestly: it is rejected like an expired one (0 post reads).
	calls := len(c.cp.callsSnapshot())
	_, _, err := c.get("me", testCID, first.GetSinceToken(), "", 20)
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "since_token"})
	if len(c.cp.callsSnapshot()) != calls {
		t.Fatal("a rejected token read posts")
	}

	for _, age := range []time.Duration{2 * time.Second, 3 * time.Minute} { // 62 s and 3 min 2 s since the fill: past the TTL, inside the max age
		c.clock.Advance(age)
		resp, _ := c.must("", "", 20)
		if !slices.Contains(commIDs(resp), hidden.ID) || len(resp.GetPosts()) != 3 {
			t.Fatalf("entry age %v: ids = %v, want the stale entry's 3 rows (the documented bound)", age, commIDs(resp))
		}
	}

	// Expiry (5 min): the next call cold-fills and the hidden post is gone.
	c.srv.ForgetCommunityFeed(testCID)
	resp, _ := c.must("", "", 20)
	if slices.Contains(commIDs(resp), hidden.ID) || len(resp.GetPosts()) != 2 {
		t.Fatalf("after expiry: ids = %v, want the 2 listed rows", commIDs(resp))
	}
}

// The mirror image: a RESTORE puts a row back below the entry's range, which an incremental refill (After the settle watermark) cannot see.
// It comes back when the entry expires, within communityEntryMaxAge. Pinned as the bound.
func TestW536_RestoredPostReturnsWhenTheEntryExpires(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(3, 100)
	back := ps[1]
	back.CommunityID = "" // hidden before anyone opens the feed
	first, _ := c.must("", "", 20)
	if len(first.GetPosts()) != 2 {
		t.Fatalf("setup: %d posts", len(first.GetPosts()))
	}
	back.CommunityID = testCID // restored on another instance
	c.clock.Advance(61 * time.Second)
	resp, _ := c.must("", "", 20)
	if slices.Contains(commIDs(resp), back.ID) {
		t.Fatalf("a restored row below the entry showed before the entry expired: %v (the bound moved)", commIDs(resp))
	}
	c.srv.ForgetCommunityFeed(testCID)
	resp, _ = c.must("", "", 20)
	if !slices.Contains(commIDs(resp), back.ID) || len(resp.GetPosts()) != 3 {
		t.Fatalf("after expiry: %v, want all 3 rows", commIDs(resp))
	}
}

// removalsTruncatedAt == the token cutoff (issued - posts.RemovalLag). A removal dropped at exactly the cutoff is not newer than it: the
// token is accepted (After is strict, the same strictness that decides which listed removals are returned). One nanosecond later it is
// rejected; one earlier is accepted. The boundary of the listing is the same: At == cutoff is not listed, cutoff+1ns is.
func TestW536_TruncationAtTheTokenCutoff(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(2, 100)
	first, _ := c.must("", "", 20)
	tok, err := c.srv.codec.parse(communityFeed("me", testCID), first.GetSinceToken(), "")
	if err != nil || tok.SinceIssued.IsZero() {
		t.Fatalf("parse: %v issued=%v", err, tok.SinceIssued)
	}
	cutoff := tok.SinceIssued.Add(-removalLag)

	for _, tt := range []struct {
		name      string
		truncated time.Time
		rejected  bool
	}{
		{"never truncated", time.Time{}, false},
		{"one nanosecond before the cutoff", cutoff.Add(-time.Nanosecond), false},
		{"exactly the cutoff", cutoff, false},
		{"one nanosecond after the cutoff", cutoff.Add(time.Nanosecond), true},
	} {
		c.fc.set(func(cm *communities.Community) { cm.RemovalsTruncatedAt = tt.truncated })
		_, _, err := c.get("me", testCID, first.GetSinceToken(), "", 20)
		if tt.rejected {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "since_token"})
			if got, _ := c.info.Get(fieldRemovedReset); got != true {
				t.Errorf("%s: removed_reset = %v, want true", tt.name, got)
			}
		} else if err != nil {
			t.Errorf("%s: %v", tt.name, err)
		}
	}

	c.fc.set(func(cm *communities.Community) {
		cm.RemovalsTruncatedAt = time.Time{}
		cm.RecentRemovals = []communities.Removal{{PostID: pid(7001), At: cutoff}, {PostID: pid(7002), At: cutoff.Add(time.Nanosecond)}, {PostID: pid(7003), At: cutoff.Add(-time.Nanosecond)}}
	})
	resp, _ := c.must(first.GetSinceToken(), "", 20)
	if got := resp.GetRemovedIds(); !slices.Equal(got, []string{pid(7002)}) {
		t.Errorf("removed_ids = %v, want only the entry newer than the cutoff", got)
	}
}

// A since token issued by one instance is answered by another (same cursor key): the second has no entry, so the refresh is the window
// query alone (1 row read), it lists the removals from the community document it reads, and its own token is accepted by the first. A
// token sealed with another key is VALIDATION with 0 reads.
func TestW536_SinceTokenAcrossInstances(t *testing.T) {
	t.Parallel()
	a := newCommRig(t)
	a.seed(3, 100)
	first, _ := a.must("", "", 20)

	deps := a.srv.deps
	b := NewServer(deps)
	fb := &fakeCommunities{c: a.fc.c, roles: a.fc.roles, gotRole: map[string]bool{}}
	b.SetCommunities(fb, 100)
	callOn := func(srv *Server, since string) (*timelinev1.GetCommunityTimelineResponse, *budget.Counter, error) {
		ctx, counter := budget.WithCounter(ctxFor("me"))
		resp, err := srv.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{CommunityId: testCID, PageSize: 20, SinceToken: since}))
		if err != nil {
			return nil, counter, err
		}
		return resp.Msg, counter, nil
	}

	// A post lands after the token; a removal is recorded on the community document.
	a.clock.Advance(20 * time.Second)
	np := a.cp.add(testCID, "a1", a.ms(0))
	a.clock.Advance(time.Second)
	gone := pid(8001)
	fb.set(func(cm *communities.Community) {
		cm.RecentRemovals = []communities.Removal{{PostID: gone, At: a.clock.Now()}}
	})
	resp, counter, err := callOn(b, first.GetSinceToken())
	if err != nil {
		t.Fatalf("the second instance refused the first's token: %v", err)
	}
	if got := commIDs(resp); !slices.Equal(got, []string{np.ID}) {
		t.Fatalf("refresh = %v, want the one new post", got)
	}
	if !slices.Equal(resp.GetRemovedIds(), []string{gone}) {
		t.Fatalf("removed_ids = %v", resp.GetRemovedIds())
	}
	// community 1 + member doc 1 + the window query (1 new row) + graph 1 + userLikes 1.
	if got := counter.Reads(); got != 5 {
		t.Errorf("cross-instance refresh reads = %d, want 5", got)
	}
	if _, _, err := callOn(a.srv, resp.GetSinceToken()); err != nil {
		t.Errorf("the first instance refused the second's token: %v", err)
	}

	other := NewServer(Deps{Flags: deps.Flags, Posts: deps.Posts, Graph: deps.Graph, Directory: deps.Directory, Viewer: deps.Viewer,
		CursorKey: []byte("another-key-another-key-another!"), TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: a.clock.Now})
	other.SetCommunities(&fakeCommunities{c: a.fc.c, roles: a.fc.roles, gotRole: map[string]bool{}}, 100)
	_, counter, err = callOn(other, first.GetSinceToken())
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "since_token"})
	if counter.Reads() != 0 {
		t.Errorf("a foreign token cost %d reads", counter.Reads())
	}
}

// Concurrent cold fills (several requests find no entry at once, as on a fresh instance under a burst). Whatever the interleaving, every
// request answers the same 20 newest rows, no query reads more than the page, every request stays inside the cold ceiling of page + 4,
// and the entry the last writer leaves is consistent: the next call is a warm hit with no query. Run under -race.
func TestW536_ConcurrentColdFills(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	ps := c.seed(40, 100)
	want := idsOf(ps[:20])
	const n = 12
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		reads   []int64
		results [][]string
	)
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, counter := budget.WithCounter(ctxFor("me"))
			resp, err := c.srv.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{CommunityId: testCID, PageSize: 20}))
			if err != nil {
				t.Errorf("err = %v", err)
				return
			}
			mu.Lock()
			reads, results = append(reads, counter.Reads()), append(results, commIDs(resp.Msg))
			mu.Unlock()
		}()
	}
	wg.Wait()
	for i, ids := range results {
		if !slices.Equal(ids, want) {
			t.Errorf("request %d answered %v", i, ids)
		}
		if reads[i] > 24 { // community 1 + member doc 1 + posts 20 + graph 1 + userLikes 1
			t.Errorf("request %d read %d, over the cold ceiling of 24", i, reads[i])
		}
	}
	fills := c.cp.callsSnapshot()
	for _, q := range fills {
		if q.limit > 20 || q.nReads > 20 {
			t.Errorf("a fill read beyond the page: %+v", q)
		}
	}
	t.Logf("%d concurrent cold opens ran %d fill queries (there is no single-flight: each racing request that misses pays its own fill, bounded by its page)", n, len(fills))
	before := len(fills)
	if _, counter := c.must("", "", 20); counter.Reads() != 2 || len(c.cp.callsSnapshot()) != before {
		t.Errorf("after the burst the entry is not a clean warm hit: reads=%d queries=%d->%d", counter.Reads(), before, len(c.cp.callsSnapshot()))
	}
}

// A refresh with 25 new posts after a warm entry expired: the refill is one query of at most the page (20), the first 20 come back with a
// gap token, and the gap page holds the other 5 with the gap closed. (RefreshGapToken in community_feed_test.go has an entry-less
// refresh; this is the entry-holding path.)
func TestW536_RefreshWithTwentyFiveNewPostsOnAWarmEntry(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(3, 600)
	first, _ := c.must("", "", 20)
	c.clock.Advance(20 * time.Second)
	var fresh []*posts.Post
	for i := range 25 {
		fresh = append(fresh, c.cp.add(testCID, "a4", c.ms(-time.Duration(i)*100*time.Millisecond)))
	}
	c.clock.Advance(2 * time.Minute) // the entry is past its TTL
	resp, counter := c.must(first.GetSinceToken(), "", 20)
	if len(resp.GetPosts()) != 20 || resp.GetGapPageToken() == "" || resp.GetNextPageToken() != "" {
		t.Fatalf("refresh: posts=%d gap=%q next=%q", len(resp.GetPosts()), resp.GetGapPageToken(), resp.GetNextPageToken())
	}
	if !slices.Equal(commIDs(resp), idsOf(fresh[:20])) {
		t.Errorf("the refresh is not the 20 newest")
	}
	for _, q := range c.cp.callsSnapshot() {
		if q.nReads > 20 {
			t.Errorf("a query read %d rows, over the page", q.nReads)
		}
	}
	if counter.Reads() > 24 {
		t.Errorf("reads = %d, over page + 4", counter.Reads())
	}
	gap, _ := c.must("", resp.GetGapPageToken(), 20)
	if !slices.Equal(commIDs(gap), idsOf(fresh[20:])) || gap.GetGapPageToken() != "" {
		t.Errorf("gap page = %v gap=%q, want the remaining 5 and a closed gap", commIDs(gap), gap.GetGapPageToken())
	}
}

// Page 50 against an entry of 30 rows. A community of 29 or 30 posts is answered by the entry alone (exhaustive); at 31, 45 and 60 the
// entry is not exhaustive, so the warm page 50 reads exactly the rows below it (1, 15, 20) and never more than the page.
func TestW536_PageFiftyAgainstTheThirtyRowEntry(t *testing.T) {
	t.Parallel()
	tests := []struct {
		posts       int
		warmQueries int
		warmRows    int
		wantPosts   int
		wantNext    bool
	}{
		{29, 0, 0, 29, false},
		{30, 0, 0, 30, false},
		{31, 1, 1, 31, false},
		{45, 1, 15, 45, false},
		{60, 1, 20, 50, true},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("%d posts", tt.posts), func(t *testing.T) {
			t.Parallel()
			c := newCommRig(t)
			c.seed(tt.posts, 100)
			cold, _ := c.must("", "", 50)
			if len(cold.GetPosts()) != min(tt.posts, 50) {
				t.Fatalf("cold page = %d posts", len(cold.GetPosts()))
			}
			before := len(c.cp.callsSnapshot())
			warm, counter := c.must("", "", 50)
			calls := c.cp.callsSnapshot()[before:]
			if len(calls) != tt.warmQueries {
				t.Fatalf("warm queries = %+v, want %d", calls, tt.warmQueries)
			}
			if tt.warmQueries == 1 && (calls[0].limit != 50-communityEntryMax || calls[0].nReads != tt.warmRows) {
				t.Errorf("warm query = %+v, want limit 20 reading %d rows", calls[0], tt.warmRows)
			}
			if len(warm.GetPosts()) != tt.wantPosts || (warm.GetNextPageToken() != "") != tt.wantNext {
				t.Errorf("warm page: posts=%d next=%q, want %d next=%v", len(warm.GetPosts()), warm.GetNextPageToken(), tt.wantPosts, tt.wantNext)
			}
			if got := counter.Reads(); got != int64(tt.warmRows)+2 {
				t.Errorf("warm reads = %d, want rows %d + graph + userLikes", got, tt.warmRows)
			}
			if !slices.Equal(commIDs(cold), commIDs(warm)) {
				t.Errorf("cold and warm pages differ")
			}
		})
	}
}

// F14 reply-hint edge, pinned as intended: a moderator keeps the row of an author who blocks them and sees viewer_reply_permission
// ALLOWED, although CreatePost would answer NOT_FOUND for that reply (a block). NOT_ALLOWED would tell the moderator that the author
// blocks them (a block oracle), so the hint follows the role alone. A plain member never sees the row at all.
// The chain-level counterpart (the reply really is NOT_FOUND) is TestW536_F14ReplyHintOnTheWire in internal/apiserver.
func TestW536_ModeratorSeesAllowedOnARaiderRow(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	raid := c.cp.add(testCID, "raider", c.ms(-10*time.Second))
	c.graph.snaps[testModUID] = graph.Snapshot{BlockedBy: map[string]bool{"raider": true}}
	c.graph.snaps["me"] = graph.Snapshot{BlockedBy: map[string]bool{"raider": true}}

	resp, _, err := c.get(testModUID, testCID, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := commIDs(resp); !slices.Equal(got, []string{raid.ID}) {
		t.Fatalf("moderator sees %v, want the raider's row (F14)", got)
	}
	if got := resp.GetPosts()[0].GetViewerReplyPermission(); got != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
		t.Fatalf("moderator's hint = %v, want ALLOWED (no block oracle)", got)
	}
	member, _ := c.must("", "", 20)
	if len(member.GetPosts()) != 0 {
		t.Fatalf("a plain member sees the raider's row: %v", commIDs(member))
	}
}

// The request-line fields of a rejected-by-reset call and of a plain refresh carry counts and enums only.
func TestW536_LogFieldsNameNoIDs(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	c.seed(2, 100)
	ictx, info := logger.WithRequestInfo(ctxFor("me"))
	ctx, _ := budget.WithCounter(ictx)
	if _, err := c.srv.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{CommunityId: testCID})); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{fieldOp, fieldMode, fieldViewerRole, fieldCommunityRemove, fieldCacheHit, fieldReturned} {
		v, ok := info.Get(k)
		if !ok {
			t.Errorf("log field %s missing", k)
			continue
		}
		if s := fmt.Sprint(v); s == testCID || s == "me" {
			t.Errorf("log field %s carries an id: %v", k, v)
		}
	}
}
