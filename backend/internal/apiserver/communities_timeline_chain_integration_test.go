//go:build integration

package apiserver

// GetCommunityTimeline and the COMMUNITY kind of SetHomeTabs over the real Build chain on the emulators. The package
// tests in internal/timeline run below the interceptors; these run the whole request on a FRESH Build over the same emulator
// project (cold caches).

import (
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func communitiesOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.CommunityTimelinePerUserPerMinute = 1_000_000
	c.RateLimit.ListsWritePerUserPerMinute = 1_000_000
	c.Quota.NewAccountWindow = time.Nanosecond
	c.FeatureCommunities = flags.Spec{Name: "communities", Mode: flags.On}
	c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
}

type cmChain struct{ *chainEnv }

func newCMChain(t *testing.T) *cmChain {
	t.Helper()
	return &cmChain{newChain(t, communitiesOn)}
}

func (e *cmChain) user(t *testing.T) ltUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	e.createProfile(t, tok)
	return ltUser{tok, uid}
}

// seedCommunity writes communities/{cid} and, when member is not empty, that user's JOINED member doc. status is "ACTIVE" or "SUSPENDED".
func seedCommunity(t *testing.T, fs *firestore.Client, owner, member, status string) string {
	t.Helper()
	ctx := context.Background()
	cid := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := fs.Collection("communities").Doc(cid).Set(ctx, map[string]any{
		"name": "Seeded", "description": "about", "rules": []any{}, "ownerId": owner, "moderatorIds": []string{}, "memberCount": int64(3),
		"status": status, "visibility": "PUBLIC", "recentRemovals": []any{}, "modlog": []any{}, "modlogSeq": int64(0), "createdAt": now, "updatedAt": now,
	}); err != nil {
		t.Fatalf("seed community: %v", err)
	}
	if member != "" {
		if _, err := fs.Collection("communities").Doc(cid).Collection("communityMembers").Doc(member).Set(ctx, map[string]any{"uid": member, "state": "JOINED", "joinedAt": now}); err != nil {
			t.Fatalf("seed member: %v", err)
		}
	}
	return cid
}

// seedCommunityPosts writes n root posts listed in cid, authored by author, with ids that fall as createdAt falls, the
// newest 30 s old. It returns the ids newest first.
func seedCommunityPosts(t *testing.T, fs *firestore.Client, cid, author string, n int) []string {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	base := time.Now().UnixMilli()*1000 + 500_000
	var out []string
	for i := 0; i < n; i++ {
		pid := fmt.Sprintf("%019d", base-int64(i)*10)
		if _, err := fs.Collection("posts").Doc(pid).Set(ctx, map[string]any{
			"authorId": author, "author": map[string]any{"userId": author, "handle": "h" + author},
			"kind": "POST", "isReply": false, "text": "in a community", "conversationId": pid, "hashtags": []string{},
			"mentions": []map[string]any{}, "likeCount": int64(0), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
			"visibility": "PUBLIC", "createdAt": now.Add(-time.Duration(i+30) * time.Second), "hasMedia": false,
			"communityId": cid, "conversationCommunityId": cid, "community": map[string]any{"id": cid, "name": "Seeded"},
		}); err != nil {
			t.Fatalf("seed post: %v", err)
		}
		out = append(out, pid)
	}
	return out
}

func (e *cmChain) feed(u ltUser, cid string, size int32, since, page string) (*timelinev1.GetCommunityTimelineResponse, error) {
	r, err := e.timeline.GetCommunityTimeline(context.Background(), authed(u.token, &timelinev1.GetCommunityTimelineRequest{CommunityId: cid, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func feedIDs(r *timelinev1.GetCommunityTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// TestCommunityTimelineChain_Budgets asserts the read budgets over the whole chain: a cold open at page 20 and 50 (page + 5: the
// interceptor, the community, the member doc, the posts, the caller graph, userLikes), the older page, a warm repeat, and an empty since
// refresh (4 cold), each from a fresh Build so no cache is warm.
func TestCommunityTimelineChain_Budgets(t *testing.T) {
	setup := newCMChain(t)
	owner, viewer := setup.user(t), setup.user(t)
	cid := seedCommunity(t, setup.fs, owner.uid, viewer.uid, "ACTIVE")
	ids := seedCommunityPosts(t, setup.fs, cid, owner.uid, 60)

	cold := func(t *testing.T, name string, size int32, since, page string) (*timelinev1.GetCommunityTimelineResponse, *cmChain) {
		t.Helper()
		c := newCMChain(t)
		resp, err := c.feed(viewer, cid, size, since, page)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return resp, c
	}
	r20, warm := cold(t, "page 20 cold", 20, "", "")
	if !slices.Equal(feedIDs(r20), ids[:20]) || r20.GetNextPageToken() == "" || r20.GetSinceToken() == "" {
		t.Fatalf("page 20: ids=%v next=%q since=%q", feedIDs(r20), r20.GetNextPageToken(), r20.GetSinceToken())
	}
	if r20.GetCommunity().GetCommunityId() != cid || r20.GetCommunity().GetViewerRole().String() != "COMMUNITY_ROLE_MEMBER" {
		t.Fatalf("header = %v", r20.GetCommunity())
	}
	cold(t, "page 50 cold", 50, "", "")

	// Warm: the same instance again. The community, the member doc, the graph and userLikes are cached, and the entry answers the page.
	if _, err := warm.feed(viewer, cid, 20, "", ""); err != nil {
		t.Fatal(err)
	}

	// An older page (the second of 20 + 20 + 20): one query of at most 20 rows plus the fixed reads.
	_, _ = cold(t, "older page cold", 20, "", r20.GetNextPageToken())

	// An empty since refresh on an instance with no entry: the interceptor, the community, the member doc and the one empty query. It
	// reads no graph and no userLikes.
	first, _ := cold(t, "page 50 for the since token", 50, "", "")
	newest := first.GetSinceToken()
	// The seeded posts are 30 s old, so the settle watermark (15 s) is newer than every one of them: nothing is newer than the token.
	resp, _ := cold(t, "empty since refresh cold", 20, newest, "")
	if len(resp.GetPosts()) != 0 || len(resp.GetRemovedIds()) != 0 {
		t.Fatalf("refresh: posts=%d removed=%v", len(resp.GetPosts()), resp.GetRemovedIds())
	}
}

// TestCommunityTimelineChain_StatusAndTokens: a SUSPENDED and a missing community answer the same NOT_FOUND within 2 reads; a token of
// another feed is VALIDATION with only the interceptor's read.
func TestCommunityTimelineChain_StatusAndTokens(t *testing.T) {
	c := newCMChain(t)
	owner, viewer := c.user(t), c.user(t)
	suspended := seedCommunity(t, c.fs, owner.uid, "", "SUSPENDED")
	active := seedCommunity(t, c.fs, owner.uid, "", "ACTIVE")
	seedCommunityPosts(t, c.fs, active, owner.uid, 3)
	missing := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)

	var want string
	for name, id := range map[string]string{"suspended": suspended, "missing": missing} {
		_, err := c.feed(viewer, id, 20, "", "")
		d := wireError(t, err, connect.CodeNotFound)
		got := fmt.Sprintf("%s|%s", marshalDet(t, d), err.Error())
		if want == "" {
			want = got
		} else if got != want {
			t.Errorf("%s answers %q, want %q", name, got, want)
		}
	}
	// The suspended community is not readable by its owner either.
	if _, err := c.feed(owner, suspended, 20, "", ""); connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatalf("owner of a suspended community: %v", err)
	}
	// A Home token on a community is VALIDATION with 0 reads beyond the interceptor.
	home, err := c.timeline.GetHomeTimeline(context.Background(), authed(viewer.token, &timelinev1.GetHomeTimelineRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.feed(viewer, active, 20, home.Msg.GetSinceToken(), "")
	wireError(t, err, connect.CodeInvalidArgument)
}

// TestCommunityTimelineChain_HomeTab: SetHomeTabs accepts a community the caller has not joined, at +1 read, and GetMe returns the tab
// with an empty title while communities is on.
func TestCommunityTimelineChain_HomeTab(t *testing.T) {
	c := newCMChain(t)
	owner, viewer := c.user(t), c.user(t)
	cid := seedCommunity(t, c.fs, owner.uid, "", "ACTIVE")
	req := &timelinev1.SetHomeTabsRequest{
		IdempotencyKey: "w527-tab-0123456789ab",
		Tabs:           []*commonv1.HomeTab{{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY, Id: cid}},
	}
	resp, err := c.timeline.SetHomeTabs(context.Background(), authed(viewer.token, req))
	if err != nil {
		t.Fatalf("SetHomeTabs: %v", err)
	}
	if len(resp.Msg.GetTabs()) != 1 || resp.Msg.GetTabs()[0].GetKind() != commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY || resp.Msg.GetTabs()[0].GetTitle() != "" {
		t.Fatalf("tabs = %v", resp.Msg.GetTabs())
	}
	me, err := c.identity.GetMe(context.Background(), authed(viewer.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	if got := me.Msg.GetHomeTabs(); len(got) != 1 || got[0].GetId() != cid {
		t.Fatalf("GetMe home_tabs = %v", got)
	}
}
