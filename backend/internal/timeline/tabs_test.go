package timeline

// GetUserTimeline tabs (ADR-0024 D5, ticket W3-9): the effective tab, the Media and Reposts queries, the flag gate,
// the tab-bound tokens, the drop rules and the budget, over the fakes. The documented figures (24 reads at page 20,
// 54 at page 50 cold) include the account-status interceptor and the caller's userLikes read; the fake rig has the
// second (a charging viewer) but not the first, so it asserts 23 and 53. The apiserver integration test
// (profile_tabs_integration_test.go) asserts 24 and 54 through the real interceptor chain.

import (
	"context"
	"errors"
	"fmt"
	"reflect"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	pbUnspecified = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED
	pbPosts       = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_POSTS
	pbReplies     = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES
	pbMedia       = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_MEDIA
	pbReposts     = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPOSTS
)

// tabCall is r.user with the tab field: it keeps the request-log info of the call in r.info.
func (r *rig) tabCall(caller, target string, req *timelinev1.GetUserTimelineRequest) (*timelinev1.GetUserTimelineResponse, *budget.Counter, error) {
	r.t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(caller))
	r.info = info
	ctx, counter := budget.WithCounter(ictx)
	req.UserId = target
	resp, err := r.srv.GetUserTimeline(ctx, connect.NewRequest(req))
	if err != nil {
		return nil, counter, err
	}
	return resp.Msg, counter, nil
}

func (r *rig) tabPage(caller, target string, tab timelinev1.UserTimelineTab, size int32, since, page string) (*timelinev1.GetUserTimelineResponse, *budget.Counter, error) {
	r.t.Helper()
	return r.tabCall(caller, target, &timelinev1.GetUserTimelineRequest{Tab: tab, PageSize: size, SinceToken: since, PageToken: page})
}

func (r *rig) mustTab(caller, target string, tab timelinev1.UserTimelineTab, size int32, since, page string) *timelinev1.GetUserTimelineResponse {
	r.t.Helper()
	resp, _, err := r.tabPage(caller, target, tab, size, since, page)
	if err != nil {
		r.t.Fatalf("tab %v: %v", tab, err)
	}
	return resp
}

// chargingViewer stands in for engagement's viewer: it charges the one userLikes read a cold caller costs.
type chargingViewer struct{ calls int }

func (v *chargingViewer) Viewer(ctx context.Context, _ string) posts.ViewerSet {
	v.calls++
	budget.FromContext(ctx).AddReads(1)
	return posts.ViewerSet{}
}

// withViewer rebuilds r.srv with every flag on and a charging viewer, so the fake rig reads what the real chain reads.
func withViewer(r *rig) *chargingViewer {
	v := &chargingViewer{}
	r.srv = NewServer(Deps{
		Flags: fakeFlags{on: true}, Viewer: v, Posts: r.posts, Graph: r.graph, Directory: r.dir,
		CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
	})
	return v
}

// tabFixture is one author's mixed profile, oldest first: a plain root post, a media root post, a media reply, a media
// quote, a repost, a second media root post and a second repost.
type tabFixture struct {
	plain, media1, mediaReply, mediaQuote, repost1, media2, repost2 *posts.Post
}

func (f tabFixture) mediaIDs() []string { // newest first
	return []string{f.media2.ID, f.mediaQuote.ID, f.mediaReply.ID, f.media1.ID}
}

func (f tabFixture) repostIDs() []string { return []string{f.repost2.ID, f.repost1.ID} }

func (r *rig) seedTabFixture(target string) tabFixture {
	r.dir.profiles[target] = identity.Profile{UserID: target, Status: identity.AccountStatusActive}
	at := func(sec int) int64 { return r.ms(-time.Duration(sec) * time.Second) }
	var f tabFixture
	f.plain = r.posts.add(target, at(70))
	f.media1 = r.posts.add(target, at(60))
	f.media1.HasMedia = true
	f.mediaReply = r.posts.add(target, at(50))
	f.mediaReply.HasMedia, f.mediaReply.IsReply, f.mediaReply.Kind = true, true, posts.KindReply
	f.mediaQuote = r.posts.add(target, at(40))
	f.mediaQuote.HasMedia = true
	makeCopy(f.mediaQuote, posts.KindQuote)
	f.repost1 = r.posts.add(target, at(30))
	makeCopy(f.repost1, posts.KindRepost)
	f.media2 = r.posts.add(target, at(20))
	f.media2.HasMedia = true
	f.repost2 = r.posts.add(target, at(10))
	makeCopy(f.repost2, posts.KindRepost)
	return f
}

// TestEffectiveTab: UNSPECIFIED defers to include_replies, any known tab wins and ignores it, an unknown number is
// refused (ADR-0024 D5). The binding value of each tab is fixed: posts and replies are the pre-W3 values.
func TestEffectiveTab(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		tab     timelinev1.UserTimelineTab
		replies bool
		want    userTab
		wantOK  bool
		gated   bool
	}{
		{"unspecified, include_replies false", pbUnspecified, false, "posts", true, false},
		{"unspecified, include_replies true", pbUnspecified, true, "replies", true, false},
		{"posts wins over include_replies true", pbPosts, true, "posts", true, false},
		{"posts, include_replies false", pbPosts, false, "posts", true, false},
		{"replies wins over include_replies false", pbReplies, false, "replies", true, false},
		{"replies, include_replies true", pbReplies, true, "replies", true, false},
		{"media, include_replies false", pbMedia, false, "media", true, true},
		{"media wins over include_replies true", pbMedia, true, "media", true, true},
		{"reposts, include_replies false", pbReposts, false, "reposts", true, true},
		{"reposts wins over include_replies true", pbReposts, true, "reposts", true, true},
		{"unknown number", timelinev1.UserTimelineTab(99), false, "", false, false},
		{"negative number", timelinev1.UserTimelineTab(-1), true, "", false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, ok := effectiveTab(tc.tab, tc.replies)
			if got != tc.want || ok != tc.wantOK {
				t.Fatalf("effectiveTab = (%q, %v), want (%q, %v)", got, ok, tc.want, tc.wantOK)
			}
			if ok && got.gated() != tc.gated {
				t.Fatalf("gated = %v, want %v", got.gated(), tc.gated)
			}
		})
	}
}

// TestTabs_RowsPerTab: every tab returns its rows newest first, a set tab wins over include_replies, and UNSPECIFIED
// is exactly today's include_replies behaviour. Media includes the author's replies and quotes with their own images
// and never a REPOST; Reposts is only REPOST items. Each tab runs its own query (never the Posts-tab ByAuthor).
func TestTabs_RowsPerTab(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		tab     timelinev1.UserTimelineTab
		replies bool
		want    func(f tabFixture) []string
		query   string // the one query the call ran
	}{
		{"unspecified, replies off: root posts", pbUnspecified, false, func(f tabFixture) []string {
			return []string{f.repost2.ID, f.media2.ID, f.repost1.ID, f.mediaQuote.ID, f.media1.ID, f.plain.ID}
		}, "ByAuthor"},
		{"unspecified, replies on: every post", pbUnspecified, true, func(f tabFixture) []string {
			return []string{f.repost2.ID, f.media2.ID, f.repost1.ID, f.mediaQuote.ID, f.mediaReply.ID, f.media1.ID, f.plain.ID}
		}, "ByAuthor"},
		{"posts tab beats include_replies true", pbPosts, true, func(f tabFixture) []string {
			return []string{f.repost2.ID, f.media2.ID, f.repost1.ID, f.mediaQuote.ID, f.media1.ID, f.plain.ID}
		}, "ByAuthor"},
		{"replies tab beats include_replies false", pbReplies, false, func(f tabFixture) []string {
			return []string{f.repost2.ID, f.media2.ID, f.repost1.ID, f.mediaQuote.ID, f.mediaReply.ID, f.media1.ID, f.plain.ID}
		}, "ByAuthor"},
		{"media, include_replies false", pbMedia, false, tabFixture.mediaIDs, "ByAuthorMedia"},
		{"media beats include_replies true", pbMedia, true, tabFixture.mediaIDs, "ByAuthorMedia"},
		{"reposts, include_replies false", pbReposts, false, tabFixture.repostIDs, "ByAuthorKind(REPOST)"},
		{"reposts beats include_replies true", pbReposts, true, tabFixture.repostIDs, "ByAuthorKind(REPOST)"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			f := r.seedTabFixture("bob")
			resp, _, err := r.tabCall("me", "bob", &timelinev1.GetUserTimelineRequest{Tab: tc.tab, IncludeReplies: tc.replies})
			if err != nil {
				t.Fatal(err)
			}
			if got := userIDs(resp); !reflect.DeepEqual(got, tc.want(f)) {
				t.Fatalf("rows = %v, want %v", got, tc.want(f))
			}
			if !reflect.DeepEqual(r.posts.queries, []string{tc.query}) {
				t.Fatalf("queries = %v, want [%s]", r.posts.queries, tc.query)
			}
		})
	}
}

// TestTabs_PagesCoverEveryRowOnce: a tab with 45, exactly 40, 1 and 0 rows among decoys of the other tabs is walked by
// next_page_token in pages of 20, every row once; an exactly full last page is followed by one empty call that reads
// the target, the graph and one empty query.
func TestTabs_PagesCoverEveryRowOnce(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		for _, tc := range []struct{ total, calls int }{{45, 3}, {40, 3}, {1, 1}, {0, 1}} {
			t.Run(fmt.Sprintf("%v/%d rows", tab, tc.total), func(t *testing.T) {
				t.Parallel()
				r := newRig(t)
				r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
				for i := 0; i < tc.total; i++ {
					p := r.posts.add("bob", r.ms(-time.Duration(2000-i)*time.Second))
					if tab == pbMedia {
						p.HasMedia = true
					} else {
						makeCopy(p, posts.KindRepost)
					}
				}
				// Decoys: a plain post, and the other tab's rows.
				for i := 0; i < 10; i++ {
					p := r.posts.add("bob", r.ms(-time.Duration(1500-i)*time.Second))
					switch {
					case i%3 == 0:
					case tab == pbMedia:
						makeCopy(p, posts.KindRepost)
					default:
						p.HasMedia = true
					}
				}
				seen := map[string]bool{}
				tok, calls := "", 0
				for {
					calls++
					resp, counter, err := r.tabPage("me", "bob", tab, 20, "", tok)
					if err != nil {
						t.Fatal(err)
					}
					for _, id := range userIDs(resp) {
						if seen[id] {
							t.Fatalf("duplicate %s", id)
						}
						seen[id] = true
					}
					if tc.total == 40 && calls == 3 && (len(resp.Posts) != 0 || resp.NextPageToken != "" || counter.Reads() != 3) {
						// users + graph + one empty query; no rows, so no embed filter and no second graph read.
						t.Fatalf("empty final call: %d posts next=%q reads=%d", len(resp.Posts), resp.NextPageToken, counter.Reads())
					}
					if tok = resp.NextPageToken; tok == "" {
						break
					}
					if calls > 10 {
						t.Fatal("did not terminate")
					}
				}
				if len(seen) != tc.total || calls != tc.calls {
					t.Fatalf("covered %d of %d rows in %d calls, want %d calls", len(seen), tc.total, calls, tc.calls)
				}
			})
		}
	}
}

// TestTabs_BudgetHasNoInstanceCache: a Media or Reposts open is one Limit(page) query every time (no author-recent
// read or write), and the reads are the documented ones minus the interceptor: users 1 + graph 1 + page + userLikes 1
// = page + 3 (documented 24 at page 20 and 54 at page 50 with the interceptor). Warm, only the query repeats.
func TestTabs_BudgetHasNoInstanceCache(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			v := withViewer(r)
			r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
			for i := 0; i < 60; i++ {
				p := r.posts.add("bob", r.ms(-time.Duration(2000-i)*time.Second))
				p.HasMedia = tab == pbMedia
				if tab == pbReposts {
					p.Kind = posts.KindRepost
				}
			}
			// fakeGraph charges every Snapshot call, while the real graph.Reader serves the embed filter's second call
			// from the 60 s cache checkVisible just filled (0 reads). A Reposts page has REPOST rows, so the fake
			// shows that one extra read; the apiserver integration test asserts the real figures.
			var fakeFilterRead int64
			if tab == pbReposts {
				fakeFilterRead = 1
			}
			for _, tc := range []struct {
				page int32
				want int64 // fake reads: users 1 + graph 1 + rows + userLikes 1
			}{{20, 23}, {50, 53}, {5, 8}, {0, 23}} {
				_, c, err := r.tabPage("me", "bob", tab, tc.page, "", "")
				if err != nil {
					t.Fatal(err)
				}
				want := tc.want + fakeFilterRead
				budgettest.Assert(t, fmt.Sprintf("GetUserTimeline %v page %d", tab, tc.page), c, budgettest.Budget{Reads: want})
				if c.Reads() != want || c.Writes() != 0 {
					t.Fatalf("page %d: reads=%d writes=%d, want %d reads and 0 writes", tc.page, c.Reads(), c.Writes(), want)
				}
			}
			if len(r.posts.recent) != 0 {
				t.Fatalf("a tab open stored an author-recent entry: %v", r.posts.recent)
			}
			if v.calls != 4 {
				t.Fatalf("viewer calls = %d, want 4", v.calls)
			}
			// A second open with every cache warm still queries Firestore.
			r.posts.queries = nil
			r.mustTab("me", "bob", tab, 20, "", "")
			r.mustTab("me", "bob", tab, 20, "", "")
			if len(r.posts.queries) != 2 {
				t.Fatalf("queries = %v, want 2 (no instance cache)", r.posts.queries)
			}
			wantCacheHit(t, r, false)
		})
	}
}

// TestTabs_EmptyTabCostsOneRow: an author with no rows on the tab costs the profile reads plus 1 for the empty query.
func TestTabs_EmptyTabCostsOneRow(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		r := newRig(t)
		r.seedUser("bob", 3) // plain posts only
		resp, c, err := r.tabPage("me", "bob", tab, 20, "", "")
		if err != nil || len(resp.Posts) != 0 || resp.NextPageToken != "" || resp.SinceToken == "" {
			t.Fatalf("%v: err=%v posts=%d next=%q since=%q", tab, err, len(resp.GetPosts()), resp.GetNextPageToken(), resp.GetSinceToken())
		}
		if c.Reads() != 3 { // users + graph + 1 empty query
			t.Fatalf("%v: empty tab reads = %d, want 3", tab, c.Reads())
		}
	}
}

// pctUIDs finds one uid inside and one outside a 50 % bucket of flag name.
func pctUIDs(t *testing.T, name string) (in, out string) {
	t.Helper()
	pct := flags.NewRegistry(flags.Spec{Name: name, Mode: flags.Percent, Percent: 50})
	for i := 0; i < 1000 && (in == "" || out == ""); i++ {
		uid := fmt.Sprintf("pct-%d", i)
		if pct.Enabled(uid, name) {
			in = uid
		} else {
			out = uid
		}
	}
	if in == "" || out == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	return in, out
}

// TestTabs_FlagMatrix (ADR-0024 D9): MEDIA and REPOSTS need profile_tabs on for the caller, else FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=profile_tabs and 0 reads and no query; Posts, Replies and UNSPECIFIED are
// ungated in every mode. The gate does not depend on FEATURE_ENGAGEMENT or on the target's existence.
func TestTabs_FlagMatrix(t *testing.T) {
	t.Parallel()
	const in, out = "in-cohort", "out-of-cohort"
	pIn, pOut := pctUIDs(t, ProfileTabsFlagName)
	postsOn := flags.Spec{Name: "posts", Mode: flags.On}
	allow := map[string]struct{}{in: {}, pIn: {}}
	tabs := func(s ...flags.Spec) []flags.Spec { return append([]flags.Spec{postsOn}, s...) }
	pct := flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Percent, Percent: 50}
	tests := []struct {
		name  string
		specs []flags.Spec
		uid   string
		gated bool // whether MEDIA and REPOSTS are refused
	}{
		{"off", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Off}), in, true},
		{"off beats an allowlist", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Off, Allowlist: allow}), in, true},
		{"not registered", tabs(), in, true},
		{"allowlist, caller in", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Allowlist, Allowlist: allow}), in, false},
		{"allowlist, caller out", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Allowlist, Allowlist: allow}), out, true},
		{"allowlist empty", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Allowlist}), in, true},
		{"percent, caller in the bucket", tabs(pct), pIn, false},
		{"percent, caller outside", tabs(pct), pOut, true},
		{"percent 0", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.Percent}), in, true},
		{"on", tabs(flags.Spec{Name: ProfileTabsFlagName, Mode: flags.On}), out, false},
		{"engagement off, profile_tabs on", tabs(flags.Spec{Name: "engagement", Mode: flags.Off}, flags.Spec{Name: ProfileTabsFlagName, Mode: flags.On}), in, false},
	}
	for _, tc := range tests {
		for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts, pbPosts, pbReplies, pbUnspecified} {
			t.Run(tc.name+"/"+tab.String(), func(t *testing.T) {
				t.Parallel()
				r := newRig(t)
				r.srv = NewServer(Deps{
					Flags: flags.NewRegistry(tc.specs...), Posts: r.posts, Graph: r.graph, Directory: r.dir,
					CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
				})
				r.seedTabFixture("bob")
				resp, counter, err := r.tabPage(tc.uid, "bob", tab, 20, "", "")
				refused := tc.gated && (tab == pbMedia || tab == pbReposts)
				if !refused {
					if err != nil {
						t.Fatalf("err = %v, want success", err)
					}
					if len(resp.Posts) == 0 {
						t.Fatal("no rows")
					}
					return
				}
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
					t.Fatalf("err = %#v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
				}
				if ae.Metadata["feature"] != ProfileTabsFlagName {
					t.Fatalf("metadata feature = %q, want %q", ae.Metadata["feature"], ProfileTabsFlagName)
				}
				if counter.Reads() != 0 || len(r.posts.queries) != 0 || len(r.graph.calls) != 0 {
					t.Fatalf("a refused call read %d docs, ran queries %v, graph calls %v", counter.Reads(), r.posts.queries, r.graph.calls)
				}
				if got, _ := r.info.Get("feature_disabled"); got != true {
					t.Fatalf("feature_disabled = %v, want true", got)
				}
				if got, _ := r.info.Get("feature"); got != ProfileTabsFlagName {
					t.Fatalf("feature = %v, want %s", got, ProfileTabsFlagName)
				}
			})
		}
	}
}

// TestTabs_FlagGateRunsBeforeValidationAndTokens: a refused tab never reaches user_id validation, token parsing or the
// directory, so a flag-off caller learns nothing about the target (0 reads, no profile lookup).
func TestTabs_FlagGateRunsBeforeValidationAndTokens(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.srv = NewServer(Deps{
		Flags: offFor{[]string{ProfileTabsFlagName}}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
		CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
	})
	for _, tc := range []struct{ name, target, page string }{
		{"missing user id", "", ""}, {"unknown user", "nobody", ""}, {"garbage page token", "bob", "not-a-token"},
	} {
		_, counter, err := r.tabPage("me", tc.target, pbMedia, 20, "", tc.page)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || counter.Reads() != 0 {
			t.Fatalf("%s: err=%v reads=%d, want FEATURE_DISABLED and 0 reads", tc.name, err, counter.Reads())
		}
	}
	// The ungated Posts tab with the same flags still validates.
	_, _, err := r.tabPage("me", "", pbPosts, 20, "", "")
	wantField(t, err, "user_id")
}

// TestTabs_UnknownTabIsValidation: a tab number from a newer client is VALIDATION field=tab with 0 reads, whatever the
// flags, and the log names it as unknown rather than echoing the number.
func TestTabs_UnknownTabIsValidation(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedTabFixture("bob")
	_, counter, err := r.tabPage("me", "bob", timelinev1.UserTimelineTab(42), 20, "", "")
	wantField(t, err, "tab")
	if counter.Reads() != 0 || len(r.posts.queries) != 0 {
		t.Fatalf("reads=%d queries=%v, want none", counter.Reads(), r.posts.queries)
	}
	if got, _ := r.info.Get(fieldTab); got != tabUnknownLog {
		t.Fatalf("%s = %v, want %s", fieldTab, got, tabUnknownLog)
	}
}

// TestTabs_LogsTheEffectiveTab: the request log carries tab=<effective tab> on every call, a refused one included.
func TestTabs_LogsTheEffectiveTab(t *testing.T) {
	t.Parallel()
	tests := []struct {
		tab     timelinev1.UserTimelineTab
		replies bool
		want    string
	}{
		{pbUnspecified, false, "posts"}, {pbUnspecified, true, "replies"}, {pbPosts, true, "posts"},
		{pbReplies, false, "replies"}, {pbMedia, true, "media"}, {pbReposts, false, "reposts"},
	}
	for _, tc := range tests {
		r := newRig(t)
		r.seedTabFixture("bob")
		if _, _, err := r.tabCall("me", "bob", &timelinev1.GetUserTimelineRequest{Tab: tc.tab, IncludeReplies: tc.replies}); err != nil {
			t.Fatal(err)
		}
		if got, ok := r.info.Get(fieldTab); !ok || got != tc.want {
			t.Fatalf("tab=%v replies=%v: logged %v (set=%v), want %s", tc.tab, tc.replies, got, ok, tc.want)
		}
	}
	r := newRig(t)
	r.srv = NewServer(Deps{Flags: fakeFlags{}, Posts: r.posts, Graph: r.graph, Directory: r.dir, CursorKey: testKey, TokenTTL: time.Hour})
	_, _, _ = r.tabPage("me", "bob", pbMedia, 20, "", "")
	if got, _ := r.info.Get(fieldTab); got != nil {
		// fakeFlags{} is off for FEATURE_POSTS too, so the posts guard answers before the tab is known.
		t.Fatalf("a call refused by the posts flag logged tab=%v", got)
	}
	r.srv = NewServer(Deps{Flags: offFor{[]string{ProfileTabsFlagName}}, Posts: r.posts, Graph: r.graph, Directory: r.dir, CursorKey: testKey, TokenTTL: time.Hour})
	_, _, _ = r.tabPage("me", "bob", pbMedia, 20, "", "")
	if got, _ := r.info.Get(fieldTab); got != "media" {
		t.Fatalf("a refused Media call logged tab=%v, want media", got)
	}
}

// tabToken is one call that issues tokens, and the tab it was made with.
type tabToken struct {
	name    string
	tab     timelinev1.UserTimelineTab
	replies bool
	binds   userTab // the effective tab the tokens must bind
}

var tabTokenSources = []tabToken{
	{"unspecified", pbUnspecified, false, tabPosts},
	{"unspecified+replies", pbUnspecified, true, tabReplies},
	{"posts", pbPosts, false, tabPosts},
	{"posts+replies", pbPosts, true, tabPosts},
	{"replies", pbReplies, false, tabReplies},
	{"replies+replies", pbReplies, true, tabReplies},
	{"media", pbMedia, false, tabMedia},
	{"media+replies", pbMedia, true, tabMedia},
	{"reposts", pbReposts, false, tabReposts},
	{"reposts+replies", pbReposts, true, tabReposts},
}

// TestTabs_TokensAreBoundToTheEffectiveTab (ADR-0024 D5, D14): a since_token or page_token opens exactly on the
// calls whose EFFECTIVE tab is the one that issued it (so every pre-W3 token stays valid: UNSPECIFIED + false is the
// Posts tab and UNSPECIFIED + true the Replies tab), and is VALIDATION on that field with 0 reads on any other tab.
func TestTabs_TokensAreBoundToTheEffectiveTab(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
	// 25 rows on every tab: media posts, reposts, plain posts and replies, so each tab has a second page.
	for i := 0; i < 25; i++ {
		base := -time.Duration(4000-4*i) * time.Second
		m := r.posts.add("bob", r.ms(base))
		m.HasMedia = true
		makeCopy(r.posts.add("bob", r.ms(base+time.Second)), posts.KindRepost)
		r.posts.add("bob", r.ms(base+2*time.Second))
		rep := r.posts.add("bob", r.ms(base+3*time.Second))
		rep.IsReply, rep.Kind = true, posts.KindReply
	}
	type tokPair struct{ since, page string }
	tokens := map[string]tokPair{}
	for _, src := range tabTokenSources {
		resp := r.mustCall(src)
		if resp.SinceToken == "" || resp.NextPageToken == "" {
			t.Fatalf("%s: setup needs a since_token and a next_page_token, got %q / %q", src.name, resp.SinceToken, resp.NextPageToken)
		}
		tokens[src.name] = tokPair{resp.SinceToken, resp.NextPageToken}
	}
	for _, src := range tabTokenSources {
		for _, dst := range tabTokenSources {
			t.Run(src.name+" token on "+dst.name, func(t *testing.T) {
				for _, kind := range []string{"since", "page"} {
					req := &timelinev1.GetUserTimelineRequest{Tab: dst.tab, IncludeReplies: dst.replies, PageSize: 20}
					field := fieldSince
					if kind == "since" {
						req.SinceToken = tokens[src.name].since
					} else {
						req.PageToken, field = tokens[src.name].page, fieldPage
					}
					_, counter, err := r.tabCall("me", "bob", req)
					if src.binds == dst.binds {
						if err != nil {
							t.Fatalf("%s token on the same effective tab %s: %v", kind, dst.binds, err)
						}
						continue
					}
					wantField(t, err, field)
					if counter.Reads() != 0 {
						t.Fatalf("a rejected %s token read %d docs, want 0", kind, counter.Reads())
					}
				}
			})
		}
	}
}

func (r *rig) mustCall(src tabToken) *timelinev1.GetUserTimelineResponse {
	r.t.Helper()
	resp, _, err := r.tabCall("me", "bob", &timelinev1.GetUserTimelineRequest{Tab: src.tab, IncludeReplies: src.replies, PageSize: 20})
	if err != nil {
		r.t.Fatalf("%s: %v", src.name, err)
	}
	return resp
}

// TestTabs_TokensAreBoundToCallerAndTarget: the Media and Reposts tokens keep the caller and target binding.
func TestTabs_TokensAreBoundToCallerAndTarget(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		r := newRig(t)
		r.dir.profiles["carol"] = identity.Profile{UserID: "carol", Status: identity.AccountStatusActive}
		r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
		for i := 0; i < 25; i++ {
			p := r.posts.add("bob", r.ms(-time.Duration(2000-i)*time.Second))
			if tab == pbMedia {
				p.HasMedia = true
			} else {
				makeCopy(p, posts.KindRepost)
			}
		}
		first := r.mustTab("me", "bob", tab, 20, "", "")
		for _, tc := range []struct{ caller, target string }{{"mallory", "bob"}, {"me", "carol"}} {
			_, c, err := r.tabPage(tc.caller, tc.target, tab, 20, first.SinceToken, "")
			wantField(t, err, fieldSince)
			_, c2, err2 := r.tabPage(tc.caller, tc.target, tab, 20, "", first.NextPageToken)
			wantField(t, err2, fieldPage)
			if c.Reads() != 0 || c2.Reads() != 0 {
				t.Fatalf("%v %v: rejected tokens read %d + %d docs", tab, tc, c.Reads(), c2.Reads())
			}
		}
	}
}

// TestTabs_RefreshReturnsOnlyNewRowsOfTheTab: a since_token refresh on Media or Reposts queries inside (since, now]
// and never touches the author-recent entry, so a new media post appears and a new plain post does not.
func TestTabs_RefreshReturnsOnlyNewRowsOfTheTab(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.seedTabFixture("bob")
			cold := r.mustTab("me", "bob", tab, 20, "", "")
			r.clock.Advance(time.Minute)
			fresh := r.posts.add("bob", r.ms(-30*time.Second))
			if tab == pbMedia {
				fresh.HasMedia = true
			} else {
				makeCopy(fresh, posts.KindRepost)
			}
			decoy := r.posts.add("bob", r.ms(-20*time.Second)) // a plain post: on neither tab
			r.posts.queries = nil
			resp := r.mustTab("me", "bob", tab, 20, cold.SinceToken, "")
			got := userIDs(resp)
			if !contains(got, fresh.ID) || contains(got, decoy.ID) {
				t.Fatalf("refresh = %v, want the new row %s and not the plain post %s", got, fresh.ID, decoy.ID)
			}
			if len(r.posts.queries) != 1 {
				t.Fatalf("refresh ran %v, want one query", r.posts.queries)
			}
			if resp.SinceToken == "" {
				t.Fatal("refresh returned no since_token")
			}
		})
	}
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// TestTabs_RemovedIDsOnRefresh: removed_ids reach a Media or Reposts refresh, scoped to the one author, like the
// Posts tab; a cold open never consults the log.
func TestTabs_RemovedIDsOnRefresh(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			r.seedTabFixture("bob")
			f := withRemovals(r, &fakeRemovals{ids: []string{"77"}})
			cold := r.mustTab("me", "bob", tab, 20, "", "")
			if len(f.cutoffs) != 0 || len(cold.RemovedIds) != 0 {
				t.Fatalf("a cold open consulted the log: %v / %v", f.cutoffs, cold.RemovedIds)
			}
			r.clock.Advance(time.Minute)
			resp := r.mustTab("me", "bob", tab, 20, cold.SinceToken, "")
			if !reflect.DeepEqual(resp.RemovedIds, []string{"77"}) || len(f.cutoffs) != 1 {
				t.Fatalf("removed_ids = %v, log calls = %d", resp.RemovedIds, len(f.cutoffs))
			}
			if !reflect.DeepEqual(f.scopes[0].Authors, []string{"bob"}) {
				t.Fatalf("scope = %v, want the one profile author", f.scopes[0].Authors)
			}
			// A log that cannot answer rejects the since_token exactly like the Posts tab.
			f.truncated = true
			_, _, err := r.tabPage("me", "bob", tab, 20, cold.SinceToken, "")
			wantField(t, err, fieldSince)
		})
	}
}

// TestTabs_VisibilityMatrix: the Media and Reposts tabs share the Posts tab's target rules. A missing, non-ACTIVE or
// caller-blocking target is NOT_FOUND byte-identical to GetProfile's (and across the tabs); a caller who blocks or
// mutes the target still gets the rows; the profile reads are the Posts tab's (a refused target stops there, before
// any query).
func TestTabs_VisibilityMatrix(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		setup     func(r *rig)
		wantFound bool
		maxReads  int64 // the profile reads before the query (target users, caller graph, target graph on overflow)
		// copiesDropped: the caller's blockedBy overflowed, so every foreign REPOST or QUOTE row fails closed (D13).
		copiesDropped bool
	}{
		{"stranger", func(r *rig) {}, true, 2, false},
		{"missing or non-ACTIVE (Directory drops it)", func(r *rig) { delete(r.dir.profiles, "bob") }, false, 1, false},
		{"B blocks A", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{BlockedBy: following("bob")} }, false, 2, false},
		{"both block each other", func(r *rig) {
			r.graph.snaps["me"] = graph.Snapshot{BlockedBy: following("bob"), Blocked: following("bob")}
		}, false, 2, false},
		{"A blocks B: rows returned", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{Blocked: following("bob")} }, true, 2, false},
		{"A mutes B: rows returned", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{Muted: following("bob")} }, true, 2, false},
		{"overflow, B blocks A (target graph)", func(r *rig) {
			r.graph.snaps["me"] = graph.Snapshot{BlockedByOverflow: true}
			r.graph.snaps["bob"] = graph.Snapshot{Blocked: following("me")}
		}, false, 3, false},
		{"overflow, no block: +1 read", func(r *rig) { r.graph.snaps["me"] = graph.Snapshot{BlockedByOverflow: true} }, true, 3, true},
	}
	const fixtureRows, fakeFilterRead = 7, 1 // the fixture's posts; the fake graph charges the embed filter's second call
	var wire []byte
	for _, tc := range tests {
		for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts, pbPosts} {
			t.Run(tc.name+"/"+tab.String(), func(t *testing.T) {
				r := newRig(t)
				f := r.seedTabFixture("bob")
				tc.setup(r)
				resp, counter, err := r.tabPage("me", "bob", tab, 20, "", "")
				if !tc.wantFound {
					b := notFound(t, err)
					if wire == nil {
						wire = b
					} else if string(wire) != string(b) {
						t.Fatalf("NOT_FOUND bytes differ: %s vs %s", wire, b)
					}
					if len(r.posts.queries) != 0 {
						t.Fatalf("a NOT_FOUND target ran queries %v", r.posts.queries)
					}
					if counter.Reads() > tc.maxReads {
						t.Fatalf("reads = %d, want <= %d", counter.Reads(), tc.maxReads)
					}
					return
				}
				if err != nil {
					t.Fatalf("err = %v, want rows", err)
				}
				got := userIDs(resp)
				switch {
				case tab == pbMedia && !contains(got, f.media2.ID):
					t.Fatalf("media rows = %v, want %s", got, f.media2.ID)
				case tab == pbPosts && !contains(got, f.media2.ID):
					t.Fatalf("posts rows = %v, want %s", got, f.media2.ID)
				case tab == pbReposts && !tc.copiesDropped && !contains(got, f.repost2.ID):
					t.Fatalf("repost rows = %v, want %s", got, f.repost2.ID)
				case tab == pbReposts && tc.copiesDropped && len(got) != 0:
					t.Fatalf("repost rows = %v, want none (blockedBy overflow fails closed)", got)
				}
				if counter.Reads() > tc.maxReads+fixtureRows+fakeFilterRead {
					t.Fatalf("reads = %d, want <= %d profile + %d rows + %d filter", counter.Reads(), tc.maxReads, fixtureRows, fakeFilterRead)
				}
			})
		}
	}
}

// TestTabs_DropRules: a REPOST (Reposts tab) or QUOTE with its own image (Media tab) whose embedded author the caller
// blocks or mutes, or who blocks the caller, is dropped (ADR-0010 D6); the control row stays; the viewer's own copies
// stay on their own profile without a graph read; a tombstone copy (no embedded author) is kept.
func TestTabs_DropRules(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		snap graph.Snapshot
		kept bool
	}{
		{"embedded author blocked by viewer", graph.Snapshot{Blocked: following(embAuthor)}, false},
		{"embedded author muted by viewer", graph.Snapshot{Muted: following(embAuthor)}, false},
		{"embedded author blocks viewer", graph.Snapshot{BlockedBy: following(embAuthor)}, false},
		{"blockedBy overflow fails closed", graph.Snapshot{BlockedByOverflow: true}, false},
		{"unrelated graph keeps the copy", graph.Snapshot{}, true},
	}
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		for _, tc := range tests {
			t.Run(tab.String()+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				r := newRig(t)
				r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
				ctl := r.posts.add("bob", r.ms(-3*time.Second))
				cp := r.posts.add("bob", r.ms(-2*time.Second))
				switch tab {
				case pbMedia:
					ctl.HasMedia, cp.HasMedia = true, true // a plain media post and a media quote
					makeCopy(cp, posts.KindQuote)
				default:
					makeCopy(ctl, posts.KindRepost) // a repost of another author
					ctl.EmbeddedAuthorID, ctl.Embedded.Author = "uid-other", posts.AuthorSnapshot{UserID: "uid-other"}
					makeCopy(cp, posts.KindRepost)
				}
				r.graph.snaps["me"] = tc.snap
				resp := r.mustTab("me", "bob", tab, 20, "", "")
				got := userIDs(resp)
				if tc.snap.BlockedByOverflow && tab == pbReposts {
					// Overflow fails closed for every foreign copy, the control repost included.
					if contains(got, cp.ID) {
						t.Fatalf("overflow kept a foreign copy: %v", got)
					}
					return
				}
				assertCopy(t, got, ctl.ID, cp.ID, tc.kept)
			})
		}
	}
	t.Run("own profile keeps the viewer's own copies at no graph read", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		r.dir.profiles["me"] = identity.Profile{UserID: "me", Status: identity.AccountStatusActive}
		cp := r.posts.add("me", r.ms(-2*time.Second))
		makeCopy(cp, posts.KindRepost)
		r.graph.snaps["me"] = graph.Snapshot{Blocked: following(embAuthor)}
		resp, counter, err := r.tabPage("me", "me", pbReposts, 20, "", "")
		if err != nil || !contains(userIDs(resp), cp.ID) {
			t.Fatalf("own copy dropped: err=%v %v", err, userIDs(resp))
		}
		if counter.Reads() != 2 || len(r.graph.calls) != 0 { // users + the one query row
			t.Fatalf("reads = %d, graph calls = %v, want 2 and none", counter.Reads(), r.graph.calls)
		}
	})
	t.Run("a tombstone copy has no embedded author and is kept", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
		cp := r.posts.add("bob", r.ms(-2*time.Second))
		cp.Kind, cp.Embedded = posts.KindRepost, &posts.Embedded{PostID: "9", Unavailable: true}
		r.graph.snaps["me"] = graph.Snapshot{Blocked: following(embAuthor)}
		if got := userIDs(r.mustTab("me", "bob", pbReposts, 20, "", "")); !contains(got, cp.ID) {
			t.Fatalf("tombstone dropped: %v", got)
		}
	})
}

// TestTabs_HiddenRowsAreDropped: a post a moderator hid (takedown or suspended author) and a non-public post never
// appear on the Media or Reposts tab, whatever the query returned.
func TestTabs_HiddenRowsAreDropped(t *testing.T) {
	t.Parallel()
	for _, tab := range []timelinev1.UserTimelineTab{pbMedia, pbReposts} {
		r := newRig(t)
		r.dir.profiles["bob"] = identity.Profile{UserID: "bob", Status: identity.AccountStatusActive}
		mk := func(sec int) *posts.Post {
			p := r.posts.add("bob", r.ms(-time.Duration(sec)*time.Second))
			if tab == pbMedia {
				p.HasMedia = true
			} else {
				makeCopy(p, posts.KindRepost)
			}
			return p
		}
		live, taken, followersOnly := mk(30), mk(20), mk(10)
		taken.Moderation = "TAKEN_DOWN"
		followersOnly.Visibility = posts.VisibilityFollowers
		if got := userIDs(r.mustTab("me", "bob", tab, 20, "", "")); !reflect.DeepEqual(got, []string{live.ID}) {
			t.Fatalf("%v rows = %v, want only the live post %s", tab, got, live.ID)
		}
	}
}
