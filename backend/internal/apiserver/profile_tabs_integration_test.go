//go:build integration

package apiserver

// GetUserTimeline tabs MEDIA and REPOSTS (ADR-0024 D5, ticket W3-9) over the real Build chain on the emulators: the rows
// and their order, the documented cold budget (24 reads at page 20, 54 at page 50: account-status interceptor 1, target
// users 1, caller graph 1, one Limit(page) query, the caller's userLikes 1), the 20-read warm figure (no instance cache
// for these tabs), tab-bound tokens, the profile_tabs flag modes and the drop and visibility rules, asserted with
// budgettest on the logged fs_reads / fs_writes / fs_deletes of the request line.
//
// The data is written through one chain (the "writer") and read through a freshly booted chain (the "reader") on the
// same emulator project, so the reader's instance caches (posts, graph, userLikes, users) are cold: the worst case the
// documented budget describes. The emulator does not enforce composite indexes, so these tests prove the query shape and
// the budget; Firestore itself needs the two W3-2 indexes READY and the W3-8 backfill run before profile_tabs leaves off
// (docs/runbooks/posts.md section 13).

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcGetUserTimeline = timelinev1connect.TimelineServiceGetUserTimelineProcedure

const (
	tabMediaPB   = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_MEDIA
	tabRepostsPB = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPOSTS
	tabPostsPB   = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_POSTS
)

// profileTabsOn turns FEATURE_PROFILE_TABS and FEATURE_ENGAGEMENT on (the userLikes read of the documented budget) with the
// abuse limits relaxed for loopback seeding.
func profileTabsOn(c *config.Config) {
	engagementOn(c)
	c.RateLimit.UserTimelinePerMinute = 1_000_000
	c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.On}
}

// newTabChain boots a chain with profileTabsOn then mutate. It is a bmChain so the budget-from-log helper is shared.
func newTabChain(t *testing.T, mutate func(*config.Config)) *bmChain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		profileTabsOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &bmChain{
		chainEnv: env,
		eng:      engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

// tabCall is one GetUserTimeline call as u.
func (e *bmChain) tabCall(u bmUser, target string, tab timelinev1.UserTimelineTab, size int32, since, page string) (*timelinev1.GetUserTimelineResponse, error) {
	r, err := e.timeline.GetUserTimeline(context.Background(), authed(u.token, &timelinev1.GetUserTimelineRequest{
		UserId: target, Tab: tab, PageSize: size, SinceToken: since, PageToken: page,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func tabPostIDs(r *timelinev1.GetUserTimelineResponse) []string {
	out := make([]string, 0, len(r.GetPosts()))
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// tabWorld is the data of the budget tests: an author with media posts, plain posts and reposts of another user's posts,
// and a viewer who follows nobody.
type tabWorld struct {
	author, viewer, other bmUser
	media, plain, reposts []string // oldest first
}

// seedTabWorld writes nMedia posts with hasMedia true (CreatePost then the field the W3-7 media path writes: the chain
// has no image upload), nPlain text posts, and nRepost REPOSTs of nRepost posts by `other`, through the real RepostPost.
func seedTabWorld(t *testing.T, w *bmChain, nMedia, nPlain, nRepost int) tabWorld {
	t.Helper()
	ctx := context.Background()
	tw := tabWorld{author: w.user(t), viewer: w.user(t), other: w.user(t)}
	for i := 0; i < nMedia; i++ {
		id := w.post(t, tw.author, fmt.Sprint("media ", i))
		if _, err := w.fs.Doc("posts/"+id).Update(ctx, []firestore.Update{{Path: "hasMedia", Value: true}}); err != nil {
			t.Fatalf("mark hasMedia: %v", err)
		}
		tw.media = append(tw.media, id)
	}
	for i := 0; i < nPlain; i++ {
		tw.plain = append(tw.plain, w.post(t, tw.author, fmt.Sprint("plain ", i)))
	}
	tw.reposts = w.repostOthers(t, tw.author, tw.other, nRepost)
	return tw
}

// repostOthers has `other` write n posts and `by` repost each; it returns the REPOST ids, oldest first.
func (e *bmChain) repostOthers(t *testing.T, by, other bmUser, n int) []string {
	t.Helper()
	var out []string
	for i := 0; i < n; i++ {
		orig := e.post(t, other, fmt.Sprint("original ", i))
		rp, err := e.eng.RepostPost(context.Background(), authed(by.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("tab-repost"), PostId: orig}))
		if err != nil {
			t.Fatalf("RepostPost: %v", err)
		}
		out = append(out, rp.Msg.GetRepostPostId())
	}
	return out
}

// Cold budget: page 20 costs at most 24 reads and page 50 at most 54, writes 0, on a freshly booted reader whose every
// cache is cold; rows are the tab's rows newest first. The same figures hold for the Reposts tab, whose rows trigger the
// embed filter (it must cost 0 reads: the caller's graph was just read by the visibility check and is cached).
func TestProfileTabsChain_ColdBudgetAndRows(t *testing.T) {
	w := newTabChain(t, nil)
	tw := seedTabWorld(t, w, 55, 5, 55)
	for _, tc := range []struct {
		name string
		tab  timelinev1.UserTimelineTab
		want []string // newest first
	}{
		{"media", tabMediaPB, reversed(tw.media)},
		{"reposts", tabRepostsPB, reversed(tw.reposts)},
	} {
		for _, page := range []int32{20, 50} {
			t.Run(fmt.Sprintf("%s page %d", tc.name, page), func(t *testing.T) {
				r := newTabChain(t, nil) // a cold reader per call
				resp, err := r.tabCall(tw.viewer, tw.author.uid, tc.tab, page, "", "")
				if err != nil {
					t.Fatalf("GetUserTimeline: %v", err)
				}
				if got := tabPostIDs(resp); !slices.Equal(got, tc.want[:page]) {
					t.Fatalf("rows = %v, want the newest %d %v", got, page, tc.want[:page])
				}
				if resp.GetNextPageToken() == "" || resp.GetSinceToken() == "" {
					t.Fatalf("tokens next=%q since=%q, want both", resp.GetNextPageToken(), resp.GetSinceToken())
				}
				budgettest.Assert(t, fmt.Sprintf("GetUserTimeline %s page %d cold", tc.name, page), r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 4 + int64(page)})
				if got, _ := r.line(t, rpcGetUserTimeline)["tab"].(string); got != tc.name {
					t.Errorf("request line tab = %q, want %q", got, tc.name)
				}
			})
		}
	}
}

// Warm: users, graph and userLikes are cached, and a tab has no instance cache, so a repeat open costs exactly the
// Limit(page) query: 20 at page 20. Walking the tab by next_page_token covers every row once.
func TestProfileTabsChain_WarmReadsAndPaging(t *testing.T) {
	w := newTabChain(t, nil)
	tw := seedTabWorld(t, w, 45, 3, 0)
	r := newTabChain(t, nil)
	first, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, "", ""); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetUserTimeline media page 20 warm", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 20})

	seen := tabPostIDs(first)
	for tok, pages := first.GetNextPageToken(), 1; tok != ""; pages++ {
		resp, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, "", tok)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, tabPostIDs(resp)...)
		if tok = resp.GetNextPageToken(); pages > 5 {
			t.Fatal("did not terminate")
		}
	}
	if !slices.Equal(seen, reversed(tw.media)) {
		t.Fatalf("paged rows = %d ids, want all %d media posts newest first and once", len(seen), len(tw.media))
	}
}

// A token opens only on the tab that issued it: a Posts-tab page or since token on Media, a Media token on Reposts, is
// VALIDATION on that field with 0 reads (a warm interceptor makes the whole request line 0). A pre-W3 call that never set
// `tab` keeps working, and a Media since_token refresh returns the media posts newer than it.
func TestProfileTabsChain_TokensAreBoundToTheTab(t *testing.T) {
	w := newTabChain(t, nil)
	tw := seedTabWorld(t, w, 25, 25, 25)
	r := newTabChain(t, nil)
	legacy, err := r.tabCall(tw.viewer, tw.author.uid, timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED, 20, "", "")
	if err != nil || legacy.GetNextPageToken() == "" {
		t.Fatalf("pre-W3 call: err=%v next=%q", err, legacy.GetNextPageToken())
	}
	media, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, "", "")
	if err != nil || media.GetNextPageToken() == "" {
		t.Fatalf("media call: err=%v next=%q", err, media.GetNextPageToken())
	}
	rejects := []struct {
		name        string
		tab         timelinev1.UserTimelineTab
		since, page string
		field       string
	}{
		{"posts page token on media", tabMediaPB, "", legacy.GetNextPageToken(), "page_token"},
		{"posts since token on media", tabMediaPB, legacy.GetSinceToken(), "", "since_token"},
		{"media page token on reposts", tabRepostsPB, "", media.GetNextPageToken(), "page_token"},
		{"media since token on reposts", tabRepostsPB, media.GetSinceToken(), "", "since_token"},
		{"media page token on posts", tabPostsPB, "", media.GetNextPageToken(), "page_token"},
	}
	for _, tc := range rejects {
		t.Run(tc.name, func(t *testing.T) {
			_, err := r.tabCall(tw.viewer, tw.author.uid, tc.tab, 20, tc.since, tc.page)
			d := wireError(t, err, connect.CodeInvalidArgument)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if d.GetMetadata()["field"] != tc.field {
				t.Fatalf("metadata = %v, want field=%s", d.GetMetadata(), tc.field)
			}
			budgettest.Assert(t, "rejected tab token", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{})
		})
	}

	// The same-tab tokens open, and the legacy token still opens on the Posts tab it was issued for (set or unset).
	if _, err := r.tabCall(tw.viewer, tw.author.uid, tabPostsPB, 20, "", legacy.GetNextPageToken()); err != nil {
		t.Fatalf("pre-W3 posts token on the POSTS tab: %v", err)
	}
	// A refresh on the Media tab returns the new media post and not a new plain post.
	fresh := w.post(t, tw.author, "fresh media")
	if _, err := w.fs.Doc("posts/"+fresh).Update(context.Background(), []firestore.Update{{Path: "hasMedia", Value: true}}); err != nil {
		t.Fatal(err)
	}
	plain := w.post(t, tw.author, "fresh plain")
	got, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, media.GetSinceToken(), "")
	if err != nil {
		t.Fatalf("media refresh: %v", err)
	}
	if ids := tabPostIDs(got); !slices.Contains(ids, fresh) || slices.Contains(ids, plain) {
		t.Fatalf("refresh rows = %v, want the new media post %s and not the plain post %s", ids, fresh, plain)
	}
}

// profile_tabs flag modes through the chain: off refuses MEDIA and REPOSTS with FEATURE_DISABLED feature=profile_tabs at
// no more than the interceptor's read and no write, while POSTS, REPLIES and an unset tab stay open; an allowlist lets
// only its uid in.
func TestProfileTabsChain_FlagModes(t *testing.T) {
	setup := newTabChain(t, nil)
	tw := seedTabWorld(t, setup, 3, 3, 3)

	assertRefused := func(t *testing.T, r *bmChain, u bmUser, tab timelinev1.UserTimelineTab) {
		t.Helper()
		_, err := r.tabCall(u, tw.author.uid, tab, 20, "", "")
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if d.GetMetadata()["feature"] != "profile_tabs" {
			t.Fatalf("metadata = %v, want feature=profile_tabs", d.GetMetadata())
		}
		budgettest.Assert(t, "refused tab", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 1}) // the interceptor only
	}

	t.Run("off", func(t *testing.T) {
		r := newTabChain(t, func(c *config.Config) { c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.Off} })
		assertRefused(t, r, tw.viewer, tabMediaPB)
		assertRefused(t, r, tw.viewer, tabRepostsPB)
		for _, tab := range []timelinev1.UserTimelineTab{
			timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED, tabPostsPB, timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES,
		} {
			if resp, err := r.tabCall(tw.viewer, tw.author.uid, tab, 20, "", ""); err != nil || len(resp.GetPosts()) == 0 {
				t.Fatalf("ungated tab %v with the flag off: err=%v rows=%d", tab, err, len(resp.GetPosts()))
			}
		}
	})

	t.Run("allowlist", func(t *testing.T) {
		r := newTabChain(t, func(c *config.Config) {
			c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.Allowlist, Allowlist: map[string]struct{}{tw.viewer.uid: {}}}
		})
		if resp, err := r.tabCall(tw.viewer, tw.author.uid, tabMediaPB, 20, "", ""); err != nil || len(resp.GetPosts()) != 3 {
			t.Fatalf("allowlisted viewer: err=%v rows=%d, want 3", err, len(resp.GetPosts()))
		}
		assertRefused(t, r, tw.other, tabMediaPB)
		assertRefused(t, r, tw.other, tabRepostsPB)
	})
}

// The profile rules apply to the new tabs: a REPOST of a blocked user's post is dropped from the viewer's Reposts tab while
// the other reposts stay, and an author who blocks the viewer is the same NOT_FOUND as GetProfile.
func TestProfileTabsChain_DropAndVisibilityRules(t *testing.T) {
	w := newTabChain(t, nil)
	ctx := context.Background()
	author, viewer, blocked, kept := w.user(t), w.user(t), w.user(t), w.user(t)
	// Two reposts of each of two users' posts, interleaved by creation order.
	blockedReposts := w.repostOthers(t, author, blocked, 2)
	keptReposts := w.repostOthers(t, author, kept, 2)

	if _, err := w.graph.Block(ctx, authed(viewer.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("tab-block"), UserId: blocked.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	r := newTabChain(t, nil)
	resp, err := r.tabCall(viewer, author.uid, tabRepostsPB, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	got := tabPostIDs(resp)
	if !slices.Equal(got, reversed(keptReposts)) {
		t.Fatalf("reposts = %v, want only the reposts of the unblocked user %v (not %v)", got, reversed(keptReposts), blockedReposts)
	}

	// The author blocks the viewer: NOT_FOUND, byte-identical to GetProfile's, on both new tabs.
	if _, err := w.graph.Block(ctx, authed(author.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("tab-block"), UserId: viewer.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	r2 := newTabChain(t, nil)
	_, profErr := r2.identity.GetProfile(ctx, authed(viewer.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: author.uid}}))
	want := wireError(t, profErr, connect.CodeNotFound)
	for _, tab := range []timelinev1.UserTimelineTab{tabMediaPB, tabRepostsPB} {
		_, err := r2.tabCall(viewer, author.uid, tab, 20, "", "")
		d := wireError(t, err, connect.CodeNotFound)
		if d.GetReason() != want.GetReason() || d.GetMessage() != want.GetMessage() || fmt.Sprint(d.GetMetadata()) != fmt.Sprint(want.GetMetadata()) {
			t.Fatalf("tab %v NOT_FOUND = %v, GetProfile NOT_FOUND = %v", tab, d, want)
		}
	}
}
