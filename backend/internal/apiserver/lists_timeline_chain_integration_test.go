//go:build integration

package apiserver

// W5-8 (ADR-0030 D5): GetListTimeline over the real Build chain on the emulators. The package tests in internal/timeline run
// the service below the interceptors, so the figures asserted here are the WHOLE-request figures of the proto doc comment
// (interceptor read included), read from the request line's fs_reads / fs_writes / fs_deletes of a FRESH Build over the same
// emulator project (cold caches) with budgettest, and the NOT_FOUND bytes are what a client receives.

import (
	"context"
	"fmt"
	"math/rand/v2"
	"net/http"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcGetListTimeline = "/dzeroth.timeline.v1.TimelineService/GetListTimeline"

// listsOn turns FEATURE_LISTS, graph and engagement on (the ADR's 6 fixed reads include userLikes) with the abuse limits
// relaxed. removed_ids is on so a refresh reads the removal log like production.
func listsOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.ListTimelinePerUserPerMinute = 1_000_000
	c.Quota.NewAccountWindow = time.Nanosecond
	c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.On}
	c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
}

type ltChain struct {
	*chainEnv
	lists listsv1connect.ListServiceClient
	graph graphv1connect.GraphServiceClient
}

func newLTChain(t *testing.T, mutate func(*config.Config)) *ltChain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		listsOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &ltChain{
		chainEnv: env,
		lists:    listsv1connect.NewListServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

type ltUser struct{ token, uid string }

func (e *ltChain) user(t *testing.T) ltUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	e.createProfile(t, tok)
	return ltUser{tok, uid}
}

// seedList writes lists/{id} (the shape lists.FirestoreRepo reads) with the given members and one root post per member,
// member i being i seconds older than member 0. It returns the list id and the post ids newest first.
func seedList(t *testing.T, fs *firestore.Client, owner string, private bool, members []string) (string, []string) {
	t.Helper()
	ctx := context.Background()
	id := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := fs.Collection("lists").Doc(id).Set(ctx, map[string]any{
		"ownerId": owner, "name": "Seeded", "description": "", "isPrivate": private, "memberIds": members, "createdAt": now, "updatedAt": now,
	}); err != nil {
		t.Fatalf("seed list: %v", err)
	}
	var postIDs []string
	for i, m := range members {
		pid := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
		if _, err := fs.Collection("posts").Doc(pid).Set(ctx, map[string]any{
			"authorId": m, "author": map[string]any{"userId": m, "handle": "h" + m},
			"kind": "POST", "isReply": false, "text": "listed", "conversationId": pid, "hashtags": []string{},
			"mentions": []map[string]any{}, "likeCount": int64(0), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
			"visibility": "PUBLIC", "createdAt": now.Add(-time.Duration(i+30) * time.Second), "hasMedia": false,
		}); err != nil {
			t.Fatalf("seed post: %v", err)
		}
		postIDs = append(postIDs, pid)
	}
	return id, postIDs
}

func memberNames(n int) []string {
	out := make([]string, n)
	prefix := fmt.Sprintf("lm%06d", rand.Int64N(999_999))
	for i := range out {
		out[i] = fmt.Sprintf("%sx%03d", prefix, i)
	}
	return out
}

func (e *ltChain) listTimeline(u ltUser, listID string, size int32, since, page string) (*timelinev1.GetListTimelineResponse, error) {
	r, err := e.timeline.GetListTimeline(context.Background(), authed(u.token, &timelinev1.GetListTimelineRequest{ListId: listID, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// sortedByAge sorts post ids by the seeded age (index order = newest first), so a page can be compared to the seed.
func idsOf(r *timelinev1.GetListTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// TestListTimelineChain_Budgets asserts the ADR-0030 D5 table over the whole chain: a non-owner and the owner of a
// 150-member list at page 20 and 50 (cold, a fresh Build each), the owner's empty since refresh (3 + C), and a warm repeat.
func TestListTimelineChain_Budgets(t *testing.T) {
	setup := newLTChain(t, nil)
	owner, viewer := setup.user(t), setup.user(t)
	members := memberNames(150)
	list, _ := seedList(t, setup.fs, owner.uid, false, members)
	const C = 5 // ceil(150 / 30)

	cold := func(t *testing.T, name string, who ltUser, size int32, since string, b budgettest.Budget) (*timelinev1.GetListTimelineResponse, *ltChain) {
		t.Helper()
		c := newLTChain(t, nil)
		resp, err := c.listTimeline(who, list, size, since, "")
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		budgettest.Assert(t, name, c.lineBudget(t, rpcGetListTimeline), b)
		return resp, c
	}
	// Non-owner: 6 + C + 2*page (interceptor, list, caller graph, owner graph, owner profile, userLikes).
	r20, warm := cold(t, "non-owner page 20 cold", viewer, 20, "", budgettest.Budget{Reads: 6 + C + 40})
	if len(r20.GetPosts()) == 0 || r20.GetList().GetMemberCount() != 150 || r20.GetNextPageToken() == "" || r20.GetSinceToken() == "" {
		t.Fatalf("page 20: posts=%d header=%v", len(r20.GetPosts()), r20.GetList())
	}
	cold(t, "non-owner page 50 cold", viewer, 50, "", budgettest.Budget{Reads: 6 + C + 100})
	// The owner: 4 + C + 2*page (no owner profile or graph beyond the caller's own).
	cold(t, "owner page 20 cold", owner, 20, "", budgettest.Budget{Reads: 4 + C + 40})
	cold(t, "owner page 50 cold", owner, 50, "", budgettest.Budget{Reads: 4 + C + 100})

	// Warm: the same instance again. The fixed reads are cached (60 s), so only the C member queries remain (each at most
	// k = ceil(2*page / C) docs).
	if _, err := warm.listTimeline(viewer, list, 20, "", ""); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "non-owner page 20 warm", warm.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: C + 40})

	// An empty since refresh by the owner, cold: 3 + C (interceptor, list, owner graph, one empty query per chunk).
	first, _ := cold(t, "owner page 50 for the since token", owner, 50, "", budgettest.Budget{Reads: 4 + C + 100})
	_, refreshed := cold(t, "owner empty since refresh cold", owner, 50, first.GetSinceToken(), budgettest.Budget{Reads: 3 + C})
	_ = refreshed
}

// TestListTimelineChain_WarmFortyFiveMembersIsServedFromAuthorRecent: a list whose chunks come back unfilled fills the
// author-recent entries on the cold open, and the same instance then serves the page from them (shared with Home).
func TestListTimelineChain_WarmFortyFiveMembersIsServedFromAuthorRecent(t *testing.T) {
	c := newLTChain(t, nil)
	owner := c.user(t)
	list, ids := seedList(t, c.fs, owner.uid, true, memberNames(45))
	r, err := c.listTimeline(owner, list, 50, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(idsOf(r), ids) {
		t.Fatalf("posts = %v, want the 45 seeded in age order", idsOf(r))
	}
	budgettest.Assert(t, "owner 45 members cold", c.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 4 + 2 + 45})
	if _, err := c.listTimeline(owner, list, 50, "", ""); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "owner 45 members warm", c.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 0})
}

// TestListTimelineChain_NotFoundIsByteIdenticalToGetList: every cause a non-owner can hit answers the same bytes on both
// RPCs (code, message and the ErrorDetail), including a list id that never existed.
func TestListTimelineChain_NotFoundIsByteIdenticalToGetList(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer, blocker := c.user(t), c.user(t), c.user(t)
	priv, _ := seedList(t, c.fs, owner.uid, true, memberNames(2))
	pub, _ := seedList(t, c.fs, owner.uid, false, memberNames(2))
	hidden, _ := seedList(t, c.fs, owner.uid, false, memberNames(2))
	if _, err := c.fs.Collection("lists").Doc(hidden).Update(context.Background(), []firestore.Update{{Path: "hidden", Value: true}}); err != nil {
		t.Fatal(err)
	}
	blocked, _ := seedList(t, c.fs, blocker.uid, false, memberNames(2))
	if _, err := c.graph.Block(context.Background(), authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("lt-block"), UserId: viewer.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	missing := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)

	wire := func(err error) string {
		t.Helper()
		d := wireError(t, err, connect.CodeNotFound)
		var ce *connect.Error
		if !asConnectErr(err, &ce) {
			t.Fatal("not a connect error")
		}
		return fmt.Sprintf("%v|%s|%v|%s", ce.Code(), ce.Message(), d.GetReason(), marshalDet(t, d))
	}
	var want string
	for name, id := range map[string]string{"missing": missing, "private": priv, "hidden": hidden, "owner blocks caller": blocked} {
		_, gerr := c.lists.GetList(context.Background(), authed(viewer.token, &listsv1.GetListRequest{ListId: id}))
		_, terr := c.listTimeline(viewer, id, 20, "", "")
		got, tl := wire(gerr), wire(terr)
		if got != tl {
			t.Errorf("%s: GetList %q != GetListTimeline %q", name, got, tl)
		}
		if want == "" {
			want = got
		} else if got != want {
			t.Errorf("%s: %q differs from the other causes %q", name, got, want)
		}
	}
	// The public list is readable; the owner always sees theirs.
	if _, err := c.listTimeline(viewer, pub, 20, "", ""); err != nil {
		t.Fatalf("public list: %v", err)
	}
	if _, err := c.listTimeline(owner, priv, 20, "", ""); err != nil {
		t.Fatalf("owner's private list: %v", err)
	}
	// A list that becomes private between pages is NOT_FOUND for the next call.
	if _, err := c.fs.Collection("lists").Doc(pub).Update(context.Background(), []firestore.Update{{Path: "isPrivate", Value: true}}); err != nil {
		t.Fatal(err)
	}
	c2 := newLTChain(t, nil) // the first instance may serve the doc from its 60 s cache; production converges the same way
	if _, err := c2.listTimeline(viewer, pub, 20, "", ""); err == nil || wire(err) != want {
		t.Fatalf("a list made private: err=%v", err)
	}
}

// TestListTimelineChain_FlagModes: off, allowlist (in and out), percent (in and out) and on, for FEATURE_LISTS; FEATURE_POSTS
// off refuses too. A refusal reads only the interceptor's caller profile.
func TestListTimelineChain_FlagModes(t *testing.T) {
	setup := newLTChain(t, nil)
	owner := setup.user(t)
	list, _ := seedList(t, setup.fs, owner.uid, true, memberNames(3))
	pool := make([]ltUser, 16)
	for i := range pool {
		pool[i] = setup.user(t)
	}
	reg := flags.NewRegistry(flags.Spec{Name: "lists", Mode: flags.Percent, Percent: 50})
	var pIn, pOut ltUser
	for _, u := range pool {
		if reg.Enabled(u.uid, "lists") && pIn.uid == "" {
			pIn = u
		} else if !reg.Enabled(u.uid, "lists") && pOut.uid == "" {
			pOut = u
		}
	}
	if pIn.uid == "" || pOut.uid == "" {
		t.Fatal("setup: no uid on each side of the 50 percent bucket")
	}
	allow := func(uids ...string) map[string]struct{} {
		m := map[string]struct{}{}
		for _, u := range uids {
			m[u] = struct{}{}
		}
		return m
	}
	cases := []struct {
		name   string
		mutate func(*config.Config)
		who    ltUser
		on     bool
	}{
		{"off", func(c *config.Config) { c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Off} }, owner, false},
		{"allowlist in", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Allowlist, Allowlist: allow(owner.uid)}
		}, owner, true},
		{"allowlist out", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Allowlist, Allowlist: allow(pIn.uid)}
		}, owner, false},
		{"percent in", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Percent, Percent: 50, Allowlist: nil}
		}, pIn, false}, // pIn is in the bucket but cannot read the owner's private list: the flag passed, the answer is NOT_FOUND
		{"percent out", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Percent, Percent: 50}
		}, pOut, false},
		{"on", nil, owner, true},
		{"posts off", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.On}
			c.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.Off}
		}, owner, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newLTChain(t, tc.mutate)
			_, err := c.listTimeline(tc.who, list, 20, "", "")
			switch {
			case tc.on:
				if err != nil {
					t.Fatalf("err = %v, want success", err)
				}
			case tc.name == "percent in":
				wireError(t, err, connect.CodeNotFound)
			default:
				d := wireError(t, err, connect.CodeFailedPrecondition)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
					t.Fatalf("reason = %v", d.GetReason())
				}
				if tc.name != "posts off" && d.GetMetadata()["feature"] != "lists" {
					t.Fatalf("metadata = %v", d.GetMetadata())
				}
				budgettest.Assert(t, tc.name, c.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 1})
			}
		})
	}
}

// TestListTimelineChain_PerViewerAndTakedown: a member the viewer mutes drops out, the owner-level drop (a member who blocks
// the owner) is gone for everyone, a Home token is refused with 0 list reads, and a moderator takedown after the token is in
// removed_ids on the refresh.
func TestListTimelineChain_PerViewerAndTakedown(t *testing.T) {
	c := newLTChain(t, func(cfg *config.Config) { cfg.FeatureRemovedIDs = flags.Spec{Name: "removed_ids", Mode: flags.On} })
	owner, viewer, m1, m2 := c.user(t), c.user(t), c.user(t), c.user(t)
	list, ids := seedList(t, c.fs, owner.uid, false, []string{m1.uid, m2.uid, memberNames(1)[0]})
	m1Post, m2Post, otherPost := ids[0], ids[1], ids[2]

	r, err := c.listTimeline(viewer, list, 20, "", "")
	if err != nil || !slices.Equal(idsOf(r), []string{m1Post, m2Post, otherPost}) {
		t.Fatalf("baseline: err=%v posts=%v", err, idsOf(r))
	}
	home, err := c.timeline.GetHomeTimeline(context.Background(), authed(viewer.token, &timelinev1.GetHomeTimelineRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.listTimeline(viewer, list, 20, home.Msg.GetSinceToken(), "")
	wireError(t, err, connect.CodeInvalidArgument)
	if err == nil {
		t.Fatal("a Home token opened on a list")
	}
	budgettest.Assert(t, "home token on a list", c.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 1})

	// The takedown after the token.
	mod := posts.NewFirestoreRepo(c.fs)
	if _, err := mod.Takedown(context.Background(), m2Post, time.Now()); err != nil {
		t.Fatal(err)
	}
	fresh := newLTChain(t, func(cfg *config.Config) { cfg.FeatureRemovedIDs = flags.Spec{Name: "removed_ids", Mode: flags.On} })
	ref, err := fresh.listTimeline(viewer, list, 20, r.GetSinceToken(), "")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(ref.GetRemovedIds(), m2Post) {
		t.Fatalf("removed_ids = %v, want it to list %s", ref.GetRemovedIds(), m2Post)
	}
	if slices.Contains(idsOf(ref), m2Post) {
		t.Fatalf("the taken-down post is still served: %v", idsOf(ref))
	}

	// The viewer mutes m1: dropped for the viewer only.
	if _, err := c.graph.Mute(context.Background(), authed(viewer.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("lt-mute"), UserId: m1.uid})); err != nil {
		t.Fatalf("Mute: %v", err)
	}
	muted := newLTChain(t, nil)
	rm, err := muted.listTimeline(viewer, list, 20, "", "")
	if err != nil || slices.Contains(idsOf(rm), m1Post) || !slices.Contains(idsOf(rm), otherPost) {
		t.Fatalf("muted member: err=%v posts=%v", err, idsOf(rm))
	}
	ro, err := muted.listTimeline(owner, list, 20, "", "")
	if err != nil || !slices.Contains(idsOf(ro), m1Post) {
		t.Fatalf("the owner still sees m1: err=%v posts=%v", err, idsOf(ro))
	}

	// m2 blocks the owner: the owner-level drop removes m2 for every viewer (lists.Reader.Members).
	if _, err := c.graph.Block(context.Background(), authed(m2.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("lt-ob"), UserId: owner.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	dropped := newLTChain(t, nil)
	rd, err := dropped.listTimeline(viewer, list, 20, "", "")
	if err != nil || rd.GetList().GetMemberCount() != 2 {
		t.Fatalf("owner-level drop: err=%v count=%d", err, rd.GetList().GetMemberCount())
	}
}

// TestListTimelineChain_WindowQueryAtOneHundredFiftyMembers: with removed_ids on, a refresh whose since_token predates the
// instance's removal-log cache is answered by the ADR-0016 window query for all 150 authors (ADR-0030 D5: a list never has
// more than 180), not rejected as truncated, and stays inside the documented 218.
func TestListTimelineChain_WindowQueryAtOneHundredFiftyMembers(t *testing.T) {
	withLog := func(cfg *config.Config) { cfg.FeatureRemovedIDs = flags.Spec{Name: "removed_ids", Mode: flags.On} }
	setup := newLTChain(t, withLog)
	owner, viewer := setup.user(t), setup.user(t)
	members := memberNames(150)
	list, ids := seedList(t, setup.fs, owner.uid, false, members)
	first, err := setup.listTimeline(viewer, list, 50, "", "")
	if err != nil || first.GetSinceToken() == "" {
		t.Fatalf("cold open: err=%v", err)
	}
	// A takedown after the token, so the window query has something to list.
	if _, err := posts.NewFirestoreRepo(setup.fs).Takedown(context.Background(), ids[40], time.Now()); err != nil {
		t.Fatal(err)
	}
	// 55 removals by other authors, newer than the token: a cold cache loads only the newest 50, so its coverage starts after the
	// token and the refresh must be answered by the per-feed window query (ADR-0016 amendment (b)), the 107-read worst case.
	for i := 0; i < 55; i++ {
		id := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
		now := time.Now().UTC()
		if _, err := setup.fs.Collection("postRemovals").Doc(id).Set(context.Background(), map[string]any{
			"state": "REMOVED", "authorId": "zz" + memberNames(1)[0], "createdAt": now.Add(time.Duration(i) * time.Millisecond), "expireAt": now.Add(32 * 24 * time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
	}
	fresh := newLTChain(t, withLog) // a cold removal-log cache: the token is older than what it covers
	ref, err := fresh.listTimeline(viewer, list, 50, first.GetSinceToken(), "")
	if err != nil {
		t.Fatalf("refresh: %v (the window query must answer a 150-member list)", err)
	}
	if !slices.Contains(ref.GetRemovedIds(), ids[40]) {
		t.Fatalf("removed_ids = %v, want %s", ref.GetRemovedIds(), ids[40])
	}
	budgettest.Assert(t, "non-owner page 50 refresh with the window query", fresh.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 218})
}
