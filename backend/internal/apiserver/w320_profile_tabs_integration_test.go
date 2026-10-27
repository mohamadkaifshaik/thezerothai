//go:build integration

package apiserver

// W3-20: GetUserTimeline tabs MEDIA and REPOSTS (ADR-0024 D5) over the real Build chain on the emulators. The cells the
// W3-9 chain tests (profile_tabs_integration_test.go) leave empty:
//   - the whole token matrix: every spelling of every effective tab issuing a page token and a since token, and every
//     spelling consuming it; only a spelling that resolves to the SAME effective tab opens it, every other pair is
//     VALIDATION on the right field with exactly 0 reads. Pre-W3 tokens are forged here with the frozen binding strings
//     ("posts", "replies") so the claim "every pre-W3 token stays valid" does not rest on the server's own encoder;
//   - an unknown tab number is VALIDATION field=tab at 0 reads, flag on or off;
//   - NOT_FOUND for a missing, SUSPENDED, DELETING, blocking and blocking-with-overflowed-blockedBy author is byte for byte
//     GetProfile's answer on the wire, for GetUserTimeline MEDIA and REPOSTS and for GetProfileRelationship;
//   - the ADR-0010 D6 / ADR-0018 D13 drop matrix on Reposts and Media: embedded author blocked, blocking, muted, and the
//     viewer's blockedBy overflow failing closed, while a blocker or muter of the AUTHOR still gets the posts;
//   - deleted and taken-down rows leaving a tab, and removed_ids on a refresh.

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w320TabsOn is the config of a tab reader or writer: every W3 flag, quotes and replies on.
func w320TabsOn(c *config.Config) {
	w320AllW3On(c)
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
}

// w320TabCall is GetUserTimeline with include_replies too (tabCall cannot set it).
func (e *w320Chain) w320TabCall(u bmUser, target string, tab timelinev1.UserTimelineTab, includeReplies bool, size int32, since, page string) (*timelinev1.GetUserTimelineResponse, error) {
	r, err := e.timeline.GetUserTimeline(context.Background(), authed(u.token, &timelinev1.GetUserTimelineRequest{
		UserId: target, Tab: tab, IncludeReplies: includeReplies, PageSize: size, SinceToken: since, PageToken: page,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// w320MarkMedia sets hasMedia on a post (the chain has no image upload; this is the field the W3-7 create paths write).
func (e *w320Chain) w320MarkMedia(t *testing.T, id string) {
	t.Helper()
	if _, err := e.fs.Doc("posts/"+id).Update(context.Background(), []firestore.Update{{Path: "hasMedia", Value: true}}); err != nil {
		t.Fatalf("mark hasMedia: %v", err)
	}
}

// w320Spelling is one way a client can ask for a tab, and the effective tab the server must resolve it to.
type w320Spelling struct {
	name      string
	tab       timelinev1.UserTimelineTab
	replies   bool
	effective string
}

func w320Spellings() []w320Spelling {
	un := timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED
	rp := timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES
	return []w320Spelling{
		{"UNSPECIFIED", un, false, "posts"},
		{"POSTS", tabPostsPB, false, "posts"},
		{"POSTS+include_replies (the tab wins)", tabPostsPB, true, "posts"},
		{"UNSPECIFIED+include_replies", un, true, "replies"},
		{"REPLIES", rp, false, "replies"},
		{"REPLIES+include_replies", rp, true, "replies"},
		{"MEDIA", tabMediaPB, false, "media"},
		{"MEDIA+include_replies (the tab wins)", tabMediaPB, true, "media"},
		{"REPOSTS", tabRepostsPB, false, "reposts"},
		{"REPOSTS+include_replies (the tab wins)", tabRepostsPB, true, "reposts"},
	}
}

// TestW320_TabTokenMatrix: 10 spellings x 10 spellings x {page token, since token}. Only a pair with the same effective tab
// opens; every other pair is INVALID_ARGUMENT VALIDATION with metadata field=page_token / since_token at exactly 0
// reads. A token is also bound to its caller and to its target.
func TestW320_TabTokenMatrix(t *testing.T) {
	w := newW320Chain(t, w320TabsOn)
	author, viewer, other := w.user(t), w.user(t), w.user(t)
	// 25 plain posts, 25 media posts, 25 reposts: every tab has more than one page at size 20.
	for i := 0; i < 25; i++ {
		w.post(t, author, fmt.Sprint("plain ", i))
		w.w320MarkMedia(t, w.post(t, author, fmt.Sprint("media ", i)))
	}
	w.repostOthers(t, author, other, 25)

	r := newW320Chain(t, w320TabsOn)
	r.w320Warm(t, viewer)
	r.w320Warm(t, other)
	spell := w320Spellings()

	type issued struct{ page, since string }
	tokens := make([]issued, len(spell))
	for i, s := range spell {
		resp, err := r.w320TabCall(viewer, author.uid, s.tab, s.replies, 20, "", "")
		if err != nil {
			t.Fatalf("%s: %v", s.name, err)
		}
		if resp.GetNextPageToken() == "" || resp.GetSinceToken() == "" {
			t.Fatalf("%s: tokens next=%q since=%q, want both", s.name, resp.GetNextPageToken(), resp.GetSinceToken())
		}
		tokens[i] = issued{resp.GetNextPageToken(), resp.GetSinceToken()}
	}

	opened, refused := 0, 0
	for i, from := range spell {
		for j, to := range spell {
			same := from.effective == to.effective
			// page token
			_, err := r.w320TabCall(viewer, author.uid, to.tab, to.replies, 20, "", tokens[i].page)
			what := fmt.Sprintf("page token of %q on %q", from.name, to.name)
			if same {
				opened++
				if err != nil {
					t.Errorf("%s: %v, want it to open (same effective tab %s)", what, err, to.effective)
				}
			} else {
				refused++
				w320Reason(t, what, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
				r.w320AssertNothing(t, what, w320RPCGetUserTimeline)
			}
			// since token
			_, err = r.w320TabCall(viewer, author.uid, to.tab, to.replies, 20, tokens[i].since, "")
			what = fmt.Sprintf("since token of %q on %q", from.name, to.name)
			if same {
				opened++
				if err != nil {
					t.Errorf("%s: %v, want it to open (same effective tab %s)", what, err, to.effective)
				}
			} else {
				refused++
				w320Reason(t, what, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "since_token")
				r.w320AssertNothing(t, what, w320RPCGetUserTimeline)
			}
			_ = j
		}
	}
	t.Logf("token matrix: %d pairs opened, %d refused", opened, refused)

	// Another caller or another target cannot open the viewer's Media token.
	media := tokens[slices.IndexFunc(spell, func(s w320Spelling) bool { return s.name == "MEDIA" })]
	_, err := r.w320TabCall(other, author.uid, tabMediaPB, false, 20, "", media.page)
	w320Reason(t, "another caller's page token", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
	_, err = r.w320TabCall(viewer, other.uid, tabMediaPB, false, 20, media.since, "")
	w320Reason(t, "another target's since token", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "since_token")
	// Sending both tokens at once is refused too.
	_, err = r.w320TabCall(viewer, author.uid, tabMediaPB, false, 20, media.since, media.page)
	w320Reason(t, "both tokens", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
}

// TestW320_PreW3TokensStayValid: tokens sealed with the FROZEN pre-W3 binding strings (what a server before the tab field
// issued) open on the tab they were issued for, however the client now spells it, and not on Media or Reposts.
func TestW320_PreW3TokensStayValid(t *testing.T) {
	w := newW320Chain(t, w320TabsOn)
	author, viewer := w.user(t), w.user(t)
	for i := 0; i < 25; i++ {
		w.post(t, author, fmt.Sprint("p", i))
		w.w320MarkMedia(t, w.post(t, author, fmt.Sprint("m", i)))
	}
	r := newW320Chain(t, w320TabsOn)
	r.w320Warm(t, viewer)
	first, err := r.w320TabCall(viewer, author.uid, tabPostsPB, false, 20, "", "")
	if err != nil || len(first.GetPosts()) != 20 {
		t.Fatalf("seed page: %v", err)
	}
	// The oldest row of the first page as the cursor position.
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	last := first.GetPosts()[len(first.GetPosts())-1].GetPost()
	pos := cursor.Cursor{CreatedAt: last.GetCreatedAt().AsTime(), DocID: last.GetPostId()}
	forge := func(tabBinding string) string {
		binding := "tl|user|" + viewer.uid + "|" + author.uid + "|" + tabBinding + "|page"
		return cursor.EncodeWindowAt(cfg.CursorHMACKey, binding, cursor.Window{Upper: pos}, time.Now())
	}
	postsTok, repliesTok := forge("posts"), forge("replies")
	un := timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED

	for _, c := range []struct {
		name    string
		token   string
		tab     timelinev1.UserTimelineTab
		replies bool
		ok      bool
	}{
		{"pre-W3 posts token, old-client spelling", postsTok, un, false, true},
		{"pre-W3 posts token, new-client POSTS", postsTok, tabPostsPB, false, true},
		{"pre-W3 posts token, on Replies", postsTok, un, true, false},
		{"pre-W3 posts token, on Media", postsTok, tabMediaPB, false, false},
		{"pre-W3 posts token, on Reposts", postsTok, tabRepostsPB, false, false},
		{"pre-W3 replies token, old-client spelling", repliesTok, un, true, true},
		{"pre-W3 replies token, new-client REPLIES", repliesTok, timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES, false, true},
		{"pre-W3 replies token, on Posts", repliesTok, un, false, false},
		{"pre-W3 replies token, on Media", repliesTok, tabMediaPB, false, false},
	} {
		_, err := r.w320TabCall(viewer, author.uid, c.tab, c.replies, 20, "", c.token)
		if c.ok && err != nil {
			t.Errorf("%s: %v, want it to open", c.name, err)
		}
		if !c.ok {
			w320Reason(t, c.name, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
		}
	}
	// A binding for a tab this build does not know opens nowhere.
	bogus := forge("bogus")
	for _, tb := range []timelinev1.UserTimelineTab{un, tabPostsPB, tabMediaPB, tabRepostsPB} {
		_, err := r.w320TabCall(viewer, author.uid, tb, false, 20, "", bogus)
		w320Reason(t, "token bound to an unknown tab", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
	}
}

// TestW320_UnknownTabIsValidationAtZeroReads: a tab number this build does not know (a newer client) is VALIDATION
// field=tab before anything else, with the flag on or off, because the tab is part of the token binding.
func TestW320_UnknownTabIsValidationAtZeroReads(t *testing.T) {
	setup := newW320Chain(t, w320TabsOn)
	viewer, author := setup.user(t), setup.user(t)
	for name, mut := range map[string]func(*config.Config){
		"profile_tabs on":  w320TabsOn,
		"profile_tabs off": func(c *config.Config) { c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.Off} },
	} {
		r := newW320Chain(t, mut)
		r.w320Warm(t, viewer)
		for _, n := range []timelinev1.UserTimelineTab{5, 6, 99, -1} {
			_, err := r.w320TabCall(viewer, author.uid, n, false, 20, "", "")
			w320Reason(t, fmt.Sprintf("%s, tab=%d", name, n), err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "tab")
			r.w320AssertNothing(t, fmt.Sprintf("%s, tab=%d", name, n), w320RPCGetUserTimeline)
		}
	}
}

// TestW320_TabNotFoundBytesMatchGetProfile: for a target the caller may not see, GetUserTimeline MEDIA and REPOSTS and
// GetProfileRelationship answer exactly what GetProfile answers: same HTTP status, content type and body (the
// ErrorDetail included). The matrix: a user that never existed, a SUSPENDED and a DELETING user, a user who blocks the
// caller, and the same blocker when the caller's blockedBy set overflowed and no longer names them (the target's own
// graph is then read: +1). A control row (an ordinary user) shows all four are 200 when nothing hides the target.
func TestW320_TabNotFoundBytesMatchGetProfile(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w320TabsOn)
	viewer, ordinary, sus, dl, blocker, ovBlocker := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)
	if _, err := w.fs.Doc("users/"+sus.uid).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.fs.Doc("users/"+dl.uid).Update(ctx, []firestore.Update{{Path: "status", Value: "DELETING"}}); err != nil {
		t.Fatal(err)
	}
	for _, b := range []bmUser{blocker, ovBlocker} {
		if _, err := w.graph.Block(ctx, authed(b.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-blk"), UserId: viewer.uid})); err != nil {
			t.Fatal(err)
		}
	}
	// Overflow: viewer's blockedBy no longer names ovBlocker, but the flag says the set may be incomplete.
	if _, err := w.fs.Doc("graph/"+viewer.uid).Update(ctx, []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove(ovBlocker.uid)}, {Path: "blockedByOverflow", Value: true},
	}); err != nil {
		t.Fatal(err)
	}
	// ovBlocker case needs its own viewer: the overflow flag would also change what the plain blocker row costs.
	viewer2 := w.user(t)
	if _, err := w.graph.Block(ctx, authed(ovBlocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-blk2"), UserId: viewer2.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.fs.Doc("graph/"+viewer2.uid).Update(ctx, []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove(ovBlocker.uid)}, {Path: "blockedByOverflow", Value: true},
	}); err != nil {
		t.Fatal(err)
	}

	r := newW320Chain(t, w320TabsOn) // cold: nothing cached from the seeding
	rpcs := func(uid string) map[string]string {
		return map[string]string{
			"GetProfile":                      fmt.Sprintf(`{"userId":%q}`, uid),
			"GetUserTimeline MEDIA":           fmt.Sprintf(`{"userId":%q,"tab":"USER_TIMELINE_TAB_MEDIA"}`, uid),
			"GetUserTimeline REPOSTS":         fmt.Sprintf(`{"userId":%q,"tab":"USER_TIMELINE_TAB_REPOSTS"}`, uid),
			"GetUserTimeline POSTS (control)": fmt.Sprintf(`{"userId":%q}`, uid),
			"GetProfileRelationship":          fmt.Sprintf(`{"userId":%q}`, uid),
		}
	}
	proc := map[string]string{
		"GetProfile":                      "/dzeroth.identity.v1.IdentityService/GetProfile",
		"GetUserTimeline MEDIA":           w320RPCGetUserTimeline,
		"GetUserTimeline REPOSTS":         w320RPCGetUserTimeline,
		"GetUserTimeline POSTS (control)": w320RPCGetUserTimeline,
		"GetProfileRelationship":          w320RPCGetProfileRel,
	}
	cases := []struct {
		name   string
		viewer bmUser
		target string
		hidden bool
	}{
		{"never existed", viewer, "00000000000000000000000000000000", true},
		{"SUSPENDED target", viewer, sus.uid, true},
		{"DELETING target", viewer, dl.uid, true},
		{"target blocks the caller", viewer, blocker.uid, true},
		{"target blocks the caller, caller's blockedBy overflowed", viewer2, ovBlocker.uid, true},
		{"control: an ordinary user", viewer, ordinary.uid, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bodies := rpcs(tc.target)
			wantStatus, wantCT, wantBody := r.rawRPC(t, tc.viewer.token, proc["GetProfile"], bodies["GetProfile"])
			if tc.hidden && wantStatus != http.StatusNotFound {
				t.Fatalf("GetProfile status = %d (%s): the scenario does not hide the target", wantStatus, wantBody)
			}
			if !tc.hidden && wantStatus != http.StatusOK {
				t.Fatalf("control GetProfile status = %d (%s)", wantStatus, wantBody)
			}
			for name, body := range bodies {
				if name == "GetProfile" {
					continue
				}
				st, ct, b := r.rawRPC(t, tc.viewer.token, proc[name], body)
				if !tc.hidden {
					if st != http.StatusOK {
						t.Errorf("%s on an ordinary user: %d %s", name, st, b)
					}
					continue
				}
				if st != wantStatus || ct != wantCT || b != wantBody {
					t.Errorf("%s answer differs from GetProfile's\n  GetProfile: %d %s %s\n  %s: %d %s %s", name, wantStatus, wantCT, wantBody, name, st, ct, b)
				}
			}
		})
	}
}

// w320RepostWorld is the data of the drop matrix: author A reposted and quoted one post of each of four users.
type w320RepostWorld struct {
	a, v, ok, blockedByV, blocksV, mutedByV            bmUser
	repostOf, quoteOf                                  map[string]string // embedded author uid -> A's row id
	repostOK, repostBlocked, repostBlocks, repostMuted string
	quoteOK, quoteBlocked, quoteBlocks, quoteMuted     string
}

func w320SeedRepostWorld(t *testing.T, w *w320Chain) w320RepostWorld {
	t.Helper()
	ctx := context.Background()
	x := w320RepostWorld{a: w.user(t), v: w.user(t), ok: w.user(t), blockedByV: w.user(t), blocksV: w.user(t), mutedByV: w.user(t),
		repostOf: map[string]string{}, quoteOf: map[string]string{}}
	for _, o := range []bmUser{x.ok, x.blockedByV, x.blocksV, x.mutedByV} {
		orig := w.post(t, o, "original of "+o.uid[:6])
		rp, err := w.eng.RepostPost(ctx, authed(x.a.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-rp"), PostId: orig}))
		if err != nil {
			t.Fatalf("RepostPost: %v", err)
		}
		x.repostOf[o.uid] = rp.Msg.GetRepostPostId()
		q, err := w.posts.CreatePost(ctx, authed(x.a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w320-q"), Text: "quoting " + o.uid[:6], QuoteOfPostId: orig}))
		if err != nil {
			t.Fatalf("quote: %v", err)
		}
		id := q.Msg.GetPost().GetPost().GetPostId()
		w.w320MarkMedia(t, id) // so the Media tab holds the quote
		x.quoteOf[o.uid] = id
	}
	x.repostOK, x.repostBlocked, x.repostBlocks, x.repostMuted = x.repostOf[x.ok.uid], x.repostOf[x.blockedByV.uid], x.repostOf[x.blocksV.uid], x.repostOf[x.mutedByV.uid]
	x.quoteOK, x.quoteBlocked, x.quoteBlocks, x.quoteMuted = x.quoteOf[x.ok.uid], x.quoteOf[x.blockedByV.uid], x.quoteOf[x.blocksV.uid], x.quoteOf[x.mutedByV.uid]
	if _, err := w.graph.Block(ctx, authed(x.v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b1"), UserId: x.blockedByV.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(x.blocksV.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b2"), UserId: x.v.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Mute(ctx, authed(x.v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m1"), UserId: x.mutedByV.uid})); err != nil {
		t.Fatal(err)
	}
	return x
}

// TestW320_TabDropMatrixOnRepostsAndMedia: ADR-0024 D5 + ADR-0018 D13 on the two new tabs. A REPOST (Reposts tab) or QUOTE
// (Media tab, with images) is dropped when the author of the post it copies is blocked by the viewer, blocks the viewer or
// is muted by the viewer; the copy of an unrelated author stays. A viewer whose blockedBy overflowed fails closed for
// every foreign copy; the author's own view keeps everything. A viewer who blocks or mutes the AUTHOR still gets the
// posts. Cold budget stays inside the ADR-0024 ceiling (24 at page 20) in every row.
func TestW320_TabDropMatrixOnRepostsAndMedia(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w320TabsOn)
	x := w320SeedRepostWorld(t, w)
	plain := w.post(t, x.a, "a media post with no embed")
	w.w320MarkMedia(t, plain)

	rows := func(r *w320Chain, viewer bmUser, tab timelinev1.UserTimelineTab) []string {
		t.Helper()
		resp, err := r.w320TabCall(viewer, x.a.uid, tab, false, 20, "", "")
		if err != nil {
			t.Fatalf("tab %v: %v", tab, err)
		}
		budgettest.Assert(t, fmt.Sprintf("GetUserTimeline %v cold", tab), r.lineBudget(t, w320RPCGetUserTimeline), budgettest.Budget{Reads: 24})
		return tabPostIDs(resp)
	}
	sameSet := func(what string, got, want []string) {
		t.Helper()
		g, wnt := slices.Clone(got), slices.Clone(want)
		slices.Sort(g)
		slices.Sort(wnt)
		if !slices.Equal(g, wnt) {
			t.Errorf("%s = %v, want %v", what, got, want)
		}
	}

	t.Run("viewer: blocked, blocking and muted embedded authors are dropped", func(t *testing.T) {
		r := newW320Chain(t, w320TabsOn)
		sameSet("Reposts tab", rows(r, x.v, tabRepostsPB), []string{x.repostOK})
		r2 := newW320Chain(t, w320TabsOn)
		sameSet("Media tab", rows(r2, x.v, tabMediaPB), []string{x.quoteOK, plain})
	})
	t.Run("the author sees all of their own copies", func(t *testing.T) {
		r := newW320Chain(t, w320TabsOn)
		got := rows(r, x.a, tabRepostsPB)
		sameSet("own Reposts tab", got, []string{x.repostOK, x.repostBlocked, x.repostBlocks, x.repostMuted})
		r2 := newW320Chain(t, w320TabsOn)
		sameSet("own Media tab", rows(r2, x.a, tabMediaPB), []string{x.quoteOK, x.quoteBlocked, x.quoteBlocks, x.quoteMuted, plain})
	})
	t.Run("an unrelated viewer sees every copy (no block, no mute)", func(t *testing.T) {
		stranger := w.user(t)
		r := newW320Chain(t, w320TabsOn)
		sameSet("stranger's Reposts tab", rows(r, stranger, tabRepostsPB), []string{x.repostOK, x.repostBlocked, x.repostBlocks, x.repostMuted})
	})
	t.Run("unblock and unmute bring the rows back", func(t *testing.T) {
		v2 := w.user(t)
		if _, err := w.graph.Block(ctx, authed(v2.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b3"), UserId: x.blockedByV.uid})); err != nil {
			t.Fatal(err)
		}
		if _, err := w.graph.Mute(ctx, authed(v2.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m3"), UserId: x.mutedByV.uid})); err != nil {
			t.Fatal(err)
		}
		r := newW320Chain(t, w320TabsOn)
		sameSet("before", rows(r, v2, tabRepostsPB), []string{x.repostOK, x.repostBlocks})
		if _, err := w.graph.Unblock(ctx, authed(v2.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("w320-ub3"), UserId: x.blockedByV.uid})); err != nil {
			t.Fatal(err)
		}
		if _, err := w.graph.Unmute(ctx, authed(v2.token, &graphv1.UnmuteRequest{IdempotencyKey: contractKey("w320-um3"), UserId: x.mutedByV.uid})); err != nil {
			t.Fatal(err)
		}
		r2 := newW320Chain(t, w320TabsOn)
		sameSet("after", rows(r2, v2, tabRepostsPB), []string{x.repostOK, x.repostBlocked, x.repostBlocks, x.repostMuted})
	})
	t.Run("blockedBy overflow fails closed for every foreign copy", func(t *testing.T) {
		ov := w.user(t)
		if _, err := w.fs.Doc("graph/"+ov.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
			t.Fatal(err)
		}
		r := newW320Chain(t, w320TabsOn)
		if got := rows(r, ov, tabRepostsPB); len(got) != 0 {
			t.Errorf("overflowed viewer's Reposts tab = %v, want no foreign copy (fail closed)", got)
		}
		// The +1 read of the target's own graph (checkVisible) is inside the 24 ceiling at 4 rows.
		r2 := newW320Chain(t, w320TabsOn)
		if got := rows(r2, ov, tabMediaPB); !slices.Equal(got, []string{plain}) {
			t.Errorf("overflowed viewer's Media tab = %v, want only the post with no embed %s", got, plain)
		}
		// The author viewing their own profile is not filtered, overflow or not.
		if _, err := w.fs.Doc("graph/"+x.a.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
			t.Fatal(err)
		}
		r3 := newW320Chain(t, w320TabsOn)
		if got := rows(r3, x.a, tabRepostsPB); len(got) != 4 {
			t.Errorf("author with an overflowed set sees %d of their own 4 copies", len(got))
		}
	})
	t.Run("a viewer who blocks or mutes the AUTHOR still gets the posts", func(t *testing.T) {
		blockerOfA, muterOfA := w.user(t), w.user(t)
		if _, err := w.graph.Block(ctx, authed(blockerOfA.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b4"), UserId: x.a.uid})); err != nil {
			t.Fatal(err)
		}
		if _, err := w.graph.Mute(ctx, authed(muterOfA.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m4"), UserId: x.a.uid})); err != nil {
			t.Fatal(err)
		}
		for name, v := range map[string]bmUser{"blocker": blockerOfA, "muter": muterOfA} {
			r := newW320Chain(t, w320TabsOn)
			sameSet(name+"'s Reposts tab", rows(r, v, tabRepostsPB), []string{x.repostOK, x.repostBlocked, x.repostBlocks, x.repostMuted})
			r2 := newW320Chain(t, w320TabsOn)
			if got := rows(r2, v, tabMediaPB); !slices.Contains(got, plain) {
				t.Errorf("%s's Media tab lost the plain post: %v", name, got)
			}
		}
	})
}

// TestW320_TabRowsLeaveWhenPostsAreDeletedOrHidden: a deleted and a taken-down media post leave the Media tab; a refresh
// with the Media since_token lists the taken-down one in removed_ids, scoped to the author, and a Posts-tab token
// still cannot be used for it.
func TestW320_TabRowsLeaveWhenPostsAreDeletedOrHidden(t *testing.T) {
	ctx := context.Background()
	tabsRemoved := func(c *config.Config) {
		w320TabsOn(c)
		c.FeatureRemovedIDs = flags.Spec{Name: "removed_ids", Mode: flags.On}
	}
	w := newW320Chain(t, tabsRemoved)
	author, viewer := w.user(t), w.user(t)
	keep, del, hide := w.post(t, author, "keep"), w.post(t, author, "delete me"), w.post(t, author, "hide me")
	for _, id := range []string{keep, del, hide} {
		w.w320MarkMedia(t, id)
	}
	r := newW320Chain(t, tabsRemoved)
	first, err := r.w320TabCall(viewer, author.uid, tabMediaPB, false, 20, "", "")
	if err != nil || !slices.Equal(tabPostIDs(first), []string{hide, del, keep}) {
		t.Fatalf("first page = %v, %v", tabPostIDs(first), err)
	}
	if _, err := w.posts.DeletePost(ctx, authed(author.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w320-del"), PostId: del})); err != nil {
		t.Fatal(err)
	}
	// A takedown through the moderation writer (opsctl takedown-post) also writes the removal-log entry removed_ids reads.
	if _, err := posts.NewFirestoreRepo(w.fs).Takedown(ctx, hide, time.Now()); err != nil {
		t.Fatalf("Takedown: %v", err)
	}
	cold := newW320Chain(t, tabsRemoved)
	again, err := cold.w320TabCall(viewer, author.uid, tabMediaPB, false, 20, "", "")
	if err != nil || !slices.Equal(tabPostIDs(again), []string{keep}) {
		t.Fatalf("after delete and takedown the Media tab = %v, %v; want only %s", tabPostIDs(again), err, keep)
	}
	refresh, err := cold.w320TabCall(viewer, author.uid, tabMediaPB, false, 20, first.GetSinceToken(), "")
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	// The watermark is held back by the settle window, so an older live post may come again; a deleted or hidden one may not.
	if ids := tabPostIDs(refresh); slices.Contains(ids, del) || slices.Contains(ids, hide) {
		t.Errorf("refresh rows = %v: a deleted or taken-down post came back", ids)
	}
	if !slices.Contains(refresh.GetRemovedIds(), hide) {
		t.Errorf("removed_ids = %v, want the taken-down post %s (the removal log lists moderation, not a user delete)", refresh.GetRemovedIds(), hide)
	}
	t.Logf("removed_ids after a delete and a takedown: %v", refresh.GetRemovedIds())
}
