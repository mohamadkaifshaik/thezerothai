//go:build integration

package apiserver

// W4-20 (ADR-0028): search and trends over the real Build chain on the emulators. The package tests in internal/search run
// the service below the interceptors (the account-status read, the rate limiters, the daily cap, the read budget, the
// degraded-mode gate and the OIDC wall are all absent there), so the figures asserted here are the WHOLE-request figures
// of the proto doc comments, measured on the request log's fs_reads / fs_writes of a second Build over the same emulator
// project (cold caches), and the wire bytes are what a client receives.

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type searchChain struct {
	*chainEnv
	search searchv1connect.SearchServiceClient
	graph  graphv1connect.GraphServiceClient
}

// searchOn turns both flags and the graph on for everyone, the new-account window off (so every minted user is established)
// and every limit except the search ones relaxed (loopback seeding would trip them). The search buckets keep their shipped
// defaults unless a test lowers them.
func searchOn(c *config.Config) {
	relaxLimits(c)
	c.Quota.NewAccountWindow = time.Nanosecond
	c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	c.FeatureSearch = flags.Spec{Name: "search", Mode: flags.On}
	c.FeatureTrends = flags.Spec{Name: "trends", Mode: flags.On}
}

func newSearchChain(t *testing.T, mutate func(*config.Config)) *searchChain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		searchOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &searchChain{
		chainEnv: env,
		search:   searchv1connect.NewSearchServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

type sUser struct{ token, uid string }

// userWithHandle mints a user whose handle is exactly handle.
func (e *searchChain) userWithHandle(t *testing.T, handle string) sUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	if _, err := e.identity.CreateProfile(context.Background(), authed(tok, &identityv1.CreateProfileRequest{
		IdempotencyKey: contractKey("w4-profile"), Handle: handle, DisplayName: "Search " + handle,
	})); err != nil {
		t.Fatalf("CreateProfile(%s): %v", handle, err)
	}
	return sUser{tok, uid}
}

func (e *searchChain) user(t *testing.T) sUser { return e.userWithHandle(t, uniqueHandle("sq")) }

func randLetters(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte('a' + rand.IntN(26))
	}
	return string(b)
}

// uniqueTag is a hashtag body no other test (or run) shares.
func uniqueTag() string { return "w4" + randLetters(8) }

// seedTagged writes n posts of tag by author, oldest first (post i is i seconds newer than post 0); every mediaEvery-th
// post (0 = none) carries an image. The shape is the one posts.NewFirestoreRepo reads (see the search integration seed).
func seedTagged(t *testing.T, fs *firestore.Client, author, tag string, n, mediaEvery int) {
	t.Helper()
	base := time.Now().Add(-time.Duration(n+30) * time.Second).UTC().Truncate(time.Millisecond)
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
		hasMedia := mediaEvery > 0 && i%mediaEvery == 0
		doc := map[string]any{
			"authorId": author, "author": map[string]any{"userId": author, "handle": "h" + author[:6]},
			"kind": "POST", "isReply": false, "text": "post #" + tag, "conversationId": id, "hashtags": []string{tag},
			"mentions": []map[string]any{}, "likeCount": int64(i % 5), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
			"visibility": "PUBLIC", "createdAt": base.Add(time.Duration(i) * time.Second), "hasMedia": hasMedia,
		}
		if hasMedia {
			doc["media"] = []map[string]any{{"mediaId": "m" + id, "url": "https://x/" + id, "thumbUrl": "https://x/t" + id, "width": 10, "height": 10}}
		}
		if _, err := fs.Collection("posts").Doc(id).Set(context.Background(), doc); err != nil {
			t.Fatalf("seed post: %v", err)
		}
	}
}

func (e *searchChain) people(who sUser, query string, limit int32) (*searchv1.SearchPeopleResponse, error) {
	r, err := e.search.SearchPeople(context.Background(), authed(who.token, &searchv1.SearchPeopleRequest{Query: query, Limit: limit}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *searchChain) posts(who sUser, query string, tab searchv1.SearchTab, size int32, token string) (*searchv1.SearchPostsResponse, error) {
	r, err := e.search.SearchPosts(context.Background(), authed(who.token, &searchv1.SearchPostsRequest{Query: query, Tab: tab, PageSize: size, PageToken: token}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *searchChain) trends(who sUser, limit int32, prefix string) (*searchv1.GetTrendsResponse, error) {
	r, err := e.search.GetTrends(context.Background(), authed(who.token, &searchv1.GetTrendsRequest{Limit: limit, Prefix: prefix}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// lastLine is the newest request line of rpc.
func (e *searchChain) lastLine(t *testing.T, rpc string) map[string]any {
	t.Helper()
	lines := e.logs.requestLines(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	return lines[len(lines)-1]
}

// assertReads fails when the newest line of rpc logged more than max reads or any write / delete, and logs the figure.
func (e *searchChain) assertReads(t *testing.T, label, rpc string, max float64) float64 {
	t.Helper()
	l := e.lastLine(t, rpc)
	reads := logNum(l, "fs_reads")
	t.Logf("W4BUDGET case=%q reads=%v writes=%v deletes=%v ceil_reads=%v", label, reads, logNum(l, "fs_writes"), logNum(l, "fs_deletes"), max)
	if reads > max {
		t.Errorf("%s: fs_reads = %v, over the documented %v", label, reads, max)
	}
	if logNum(l, "fs_writes") != 0 || logNum(l, "fs_deletes") != 0 {
		t.Errorf("%s: fs_writes/fs_deletes = %v/%v, want 0/0", label, l["fs_writes"], l["fs_deletes"])
	}
	return reads
}

func detailOf(t *testing.T, err error) *commonv1.ErrorDetail {
	t.Helper()
	var ce *connect.Error
	if !asConnectErr(err, &ce) {
		t.Fatalf("err = %v, want a Connect error", err)
	}
	for _, d := range ce.Details() {
		if v, e := d.Value(); e == nil {
			if det, ok := v.(*commonv1.ErrorDetail); ok {
				return det
			}
		}
	}
	t.Fatalf("error %v has no ErrorDetail", err)
	return nil
}

func wantReason(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, key, val string) {
	t.Helper()
	d := wireError(t, err, code)
	if d.GetReason() != reason {
		t.Errorf("reason = %v, want %v", d.GetReason(), reason)
	}
	if key != "" && d.GetMetadata()[key] != val {
		t.Errorf("metadata[%s] = %q, want %q (all: %v)", key, d.GetMetadata()[key], val, d.GetMetadata())
	}
}

func marshalDet(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// --- Flags (W4-3: off / allowlist / percent / on; independent flags; GetMe) ------------------------------------------

func TestSearchChain_FlagModes(t *testing.T) {
	ctx := context.Background()
	setup := newSearchChain(t, nil)
	in, out := setup.user(t), setup.user(t)

	// Percent: a pool of users, split per flag name by the real registry (the bucket is fnv(name:uid)), so the test follows
	// the bucket function and the two flags land different users on each side.
	pool := make([]sUser, 24)
	for i := range pool {
		pool[i] = setup.user(t)
	}
	split := func(name string) (pIn, pOut sUser) {
		reg := flags.NewRegistry(flags.Spec{Name: name, Mode: flags.Percent, Percent: 50})
		for _, u := range pool {
			if reg.Enabled(u.uid, name) && pIn.uid == "" {
				pIn = u
			} else if !reg.Enabled(u.uid, name) && pOut.uid == "" {
				pOut = u
			}
		}
		if pIn.uid == "" || pOut.uid == "" {
			t.Fatalf("setup: no uid on each side of the 50 percent bucket of %s among %d users", name, len(pool))
		}
		return pIn, pOut
	}

	type rpcCase struct {
		name    string
		feature string
		call    func(e *searchChain, u sUser) error
		rpc     string
	}
	rpcs := []rpcCase{
		{"SearchPeople", "search", func(e *searchChain, u sUser) error { _, err := e.people(u, "ab", 5); return err }, searchv1connect.SearchServiceSearchPeopleProcedure},
		{"SearchPosts", "search", func(e *searchChain, u sUser) error {
			_, err := e.posts(u, "#"+uniqueTag(), searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
			return err
		}, searchv1connect.SearchServiceSearchPostsProcedure},
		{"GetTrends", "trends", func(e *searchChain, u sUser) error { _, err := e.trends(u, 0, ""); return err }, searchv1connect.SearchServiceGetTrendsProcedure},
	}
	for _, name := range []string{"search", "trends"} {
		pIn, pOut := split(name)
		spec := func(mode flags.Mode, allow ...string) flags.Spec {
			s := flags.Spec{Name: name, Mode: mode, Percent: 50}
			if len(allow) > 0 {
				s.Allowlist = map[string]struct{}{}
				for _, a := range allow {
					s.Allowlist[a] = struct{}{}
				}
			}
			return s
		}
		modes := []struct {
			label string
			spec  flags.Spec
			users map[string]bool // uid -> enabled
		}{
			{"off", spec(flags.Off), map[string]bool{in.uid: false, out.uid: false}},
			{"allowlist", spec(flags.Allowlist, in.uid), map[string]bool{in.uid: true, out.uid: false}},
			{"percent", spec(flags.Percent), map[string]bool{pIn.uid: true, pOut.uid: false}},
			{"on", spec(flags.On), map[string]bool{in.uid: true, out.uid: true}},
		}
		for _, m := range modes {
			t.Run(name+"/"+m.label, func(t *testing.T) {
				e := newSearchChain(t, func(c *config.Config) {
					if name == "search" {
						c.FeatureSearch = m.spec
					} else {
						c.FeatureTrends = m.spec
					}
				})
				all := map[string]sUser{in.uid: in, out.uid: out, pIn.uid: pIn, pOut.uid: pOut}
				for uid, want := range m.users {
					u := all[uid]
					for _, r := range rpcs {
						if r.feature != name {
							// The other flag is on: this RPC must work in every mode of this one (independence).
							if err := r.call(e, u); err != nil {
								t.Errorf("%s with the %s flag %s: %v", r.name, name, m.label, err)
							}
							continue
						}
						err := r.call(e, u)
						if want {
							if err != nil {
								t.Errorf("%s for an enabled caller: %v", r.name, err)
							}
							continue
						}
						wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", name)
						// FEATURE_DISABLED answers before any Firestore access beyond the interceptor's status read.
						e.assertReads(t, r.name+" flag "+m.label, r.rpc, 1)
					}
				}
			})
		}
	}

	// GetMe mirrors the flags: the allowlisted uid sees both, the other sees neither.
	e := newSearchChain(t, func(c *config.Config) {
		c.FeatureSearch = flags.Spec{Name: "search", Mode: flags.Allowlist, Allowlist: map[string]struct{}{in.uid: {}}}
		c.FeatureTrends = flags.Spec{Name: "trends", Mode: flags.Allowlist, Allowlist: map[string]struct{}{in.uid: {}}}
	})
	for _, tc := range []struct {
		u    sUser
		want bool
	}{{in, true}, {out, false}} {
		me, err := e.identity.GetMe(ctx, authed(tc.u.token, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for _, f := range me.Msg.GetEnabledFeatures() {
			got[f] = true
		}
		if got["search"] != tc.want || got["trends"] != tc.want {
			t.Errorf("GetMe enabled_features for allowlist=%v: %v", tc.want, me.Msg.GetEnabledFeatures())
		}
	}
}

// --- Budgets through the chain (W4-5, W4-7, W4-8, W4-10) ----------------------------------------------------------------

// The documented whole-request figures: SearchPeople 7 (limit 5) / 22 (limit 20), 0-2 warm; SearchPosts 33 first page of
// TOP / LATEST / MEDIA, 23 older LATEST page at 20, 33 MEDIA scan, 0-3 warm; GetTrends 2 cold, 0-1 warm. Writes 0.
func TestSearchChain_BudgetTable(t *testing.T) {
	setup := newSearchChain(t, func(c *config.Config) {
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On} // the userLikes read of the documented 33
	})
	caller := setup.user(t)
	// 24 handles share a prefix: more than the clamp of 20.
	pfx := "z" + randLetters(3)
	for i := 0; i < 24; i++ {
		setup.userWithHandle(t, fmt.Sprintf("%s%02d", pfx, i))
	}
	author := setup.user(t)
	tag := uniqueTag()
	seedTagged(t, setup.fs, author.uid, tag, 45, 3)
	if err := search.NewTrendsRepo(setup.fs).Put(context.Background(), &search.TrendsDoc{
		Items:      []search.TrendItem{{Tag: "launch", Posts: 9, Authors: 5}, {Tag: "lamp", Posts: 4, Authors: 3}, {Tag: "go", Posts: 4, Authors: 3}},
		ComputedAt: time.Now(), Watermark: search.Watermark{At: time.Now()},
	}); err != nil {
		t.Fatal(err)
	}

	cold := func() *searchChain {
		return newSearchChain(t, func(c *config.Config) { c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On} })
	}
	const (
		pe = searchv1connect.SearchServiceSearchPeopleProcedure
		po = searchv1connect.SearchServiceSearchPostsProcedure
		tr = searchv1connect.SearchServiceGetTrendsProcedure
	)

	t.Run("SearchPeople limit 5 and 20, cold then warm", func(t *testing.T) {
		e := cold()
		r, err := e.people(caller, pfx, 5)
		if err != nil || len(r.GetUsers()) != 5 {
			t.Fatalf("rows = %d, err = %v", len(r.GetUsers()), err)
		}
		e.assertReads(t, "SearchPeople limit 5 cold", pe, 7)
		if _, err = e.people(caller, pfx, 5); err != nil {
			t.Fatal(err)
		}
		e.assertReads(t, "SearchPeople limit 5 warm", pe, 2)

		e = cold()
		r, err = e.people(caller, "@"+strings.ToUpper(pfx), 50) // 50 clamps to 20; the sigil and case are normalised away
		if err != nil || len(r.GetUsers()) != 20 {
			t.Fatalf("rows = %d, err = %v (limit 50 must clamp to 20)", len(r.GetUsers()), err)
		}
		e.assertReads(t, "SearchPeople limit 20 cold", pe, 22)
		for i, it := range r.GetUsers() { // handleLower order
			if want := fmt.Sprintf("%s%02d", pfx, i); it.GetUser().GetHandle() != want {
				t.Errorf("row %d = %q, want %q", i, it.GetUser().GetHandle(), want)
			}
		}
		if _, err = e.people(caller, pfx, 20); err != nil {
			t.Fatal(err)
		}
		e.assertReads(t, "SearchPeople limit 20 warm", pe, 2)
	})

	t.Run("SearchPosts first pages, older pages, warm", func(t *testing.T) {
		for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_LATEST, searchv1.SearchTab_SEARCH_TAB_MEDIA} {
			e := cold()
			r, err := e.posts(caller, "#"+tag, tab, 20, "")
			if err != nil || len(r.GetPosts()) == 0 {
				t.Fatalf("%v: %d rows, err = %v", tab, len(r.GetPosts()), err)
			}
			e.assertReads(t, "SearchPosts "+tab.String()+" first page cold", po, 33)
			if _, err = e.posts(caller, "#"+tag, tab, 20, ""); err != nil {
				t.Fatal(err)
			}
			e.assertReads(t, "SearchPosts "+tab.String()+" warm", po, 3)
		}

		latest, err := setup.posts(caller, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 20, "")
		if err != nil || len(latest.GetPosts()) != 20 || latest.GetNextPageToken() == "" || latest.GetNormalizedTag() != tag {
			t.Fatalf("LATEST page 1: %d rows, token %q, tag %q, err %v", len(latest.GetPosts()), latest.GetNextPageToken(), latest.GetNormalizedTag(), err)
		}
		e := cold()
		older, err := e.posts(caller, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 20, latest.GetNextPageToken())
		if err != nil || len(older.GetPosts()) != 20 {
			t.Fatalf("LATEST older page: %d rows, err %v", len(older.GetPosts()), err)
		}
		e.assertReads(t, "SearchPosts LATEST older page 20 cold", po, 23)

		media, err := setup.posts(caller, tag, searchv1.SearchTab_SEARCH_TAB_MEDIA, 20, "")
		if err != nil || media.GetNextPageToken() == "" {
			t.Fatalf("MEDIA page 1: token %q, err %v", media.GetNextPageToken(), err)
		}
		e = cold()
		if _, err = e.posts(caller, tag, searchv1.SearchTab_SEARCH_TAB_MEDIA, 20, media.GetNextPageToken()); err != nil {
			t.Fatal(err)
		}
		e.assertReads(t, "SearchPosts MEDIA scan call cold", po, 33)
	})

	t.Run("GetTrends cold 2, warm at most 1, prefix at no extra read", func(t *testing.T) {
		e := cold()
		r, err := e.trends(caller, 0, "")
		if err != nil || len(r.GetTrends()) != 3 || r.GetComputedAt() == nil {
			t.Fatalf("trends = %v, err %v", r.GetTrends(), err)
		}
		e.assertReads(t, "GetTrends cold", tr, 2)
		r, err = e.trends(caller, 0, "#LAM")
		if err != nil || len(r.GetTrends()) != 1 || r.GetTrends()[0].GetTag() != "lamp" {
			t.Fatalf("prefix lam = %v, err %v (the tags are launch, lamp, go)", r.GetTrends(), err)
		}
		e.assertReads(t, "GetTrends prefix warm", tr, 1)
	})
}

// --- Grammar through the chain: each rejection costs the interceptor's read at most (W4-5, W4-7) ------------------------

func TestSearchChain_GrammarRejectionsReadNothing(t *testing.T) {
	e := newSearchChain(t, nil)
	caller := e.user(t)
	long := strings.Repeat("a", 51)
	bad := []struct{ name, q string }{
		{"empty", ""}, {"sigil only @", "@"}, {"sigil only #", "#"}, {"51 code points", long}, {"BEL control", "ab\x07"},
		{"RTL override", "ab‮"}, {"RLI isolate", "ab⁧c"}, {"newline", "ab\ncd"}, {"sigil plus 51", "#" + long},
	}
	for _, tc := range bad {
		t.Run("people/"+tc.name, func(t *testing.T) {
			_, err := e.people(caller, tc.q, 5)
			wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "query")
			e.assertReads(t, "people "+tc.name, searchv1connect.SearchServiceSearchPeopleProcedure, 1)
		})
		t.Run("posts/"+tc.name, func(t *testing.T) {
			_, err := e.posts(caller, tc.q, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
			wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "query")
			e.assertReads(t, "posts "+tc.name, searchv1connect.SearchServiceSearchPostsProcedure, 1)
		})
	}
	// One character: too short for people (VALIDATION), a valid tag for posts.
	_, err := e.people(caller, "a", 5)
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "query")
	e.assertReads(t, "people 1 char", searchv1connect.SearchServiceSearchPeopleProcedure, 1)
	if _, err = e.posts(caller, "a", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, ""); err != nil {
		t.Errorf("a one-character plain word is a valid tag for posts: %v", err)
	}
	// Unsupported (not an error): an answer with unsupported_query and nothing read beyond the interceptor.
	for _, tc := range []struct {
		name, q string
		people  bool
	}{
		{"people #tag", "#go", true}, {"people non-handle chars", "a-b", true}, {"people zero-width space", "ab​cd", true},
		{"posts @handle", "@alice", false}, {"posts digits only body", "#12345", false}, {"posts two words", "go lang", false},
		{"posts punctuation", "#go!", false},
	} {
		t.Run("unsupported/"+tc.name, func(t *testing.T) {
			if tc.people {
				r, err := e.people(caller, tc.q, 5)
				if err != nil || !r.GetUnsupportedQuery() || len(r.GetUsers()) != 0 {
					t.Fatalf("people(%q) = %v, %v; want unsupported", tc.q, r, err)
				}
				e.assertReads(t, tc.name, searchv1connect.SearchServiceSearchPeopleProcedure, 1)
				return
			}
			r, err := e.posts(caller, tc.q, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
			if err != nil || !r.GetUnsupportedQuery() || len(r.GetPosts()) != 0 {
				t.Fatalf("posts(%q) = %v, %v; want unsupported", tc.q, r, err)
			}
			e.assertReads(t, tc.name, searchv1connect.SearchServiceSearchPostsProcedure, 1)
		})
	}
	// GetTrends: a bad prefix and a negative limit are VALIDATION with no read beyond the interceptor.
	for _, tc := range []struct {
		name, prefix string
		limit        int32
		field        string
	}{{"control prefix", "a\x07", 0, "prefix"}, {"bidi prefix", "a‮", 0, "prefix"}, {"51-code-point prefix", long, 0, "prefix"}, {"negative limit", "", -1, "limit"}} {
		_, err := e.trends(caller, tc.limit, tc.prefix)
		wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", tc.field)
		e.assertReads(t, "trends "+tc.name, searchv1connect.SearchServiceGetTrendsProcedure, 1)
	}
}

// --- Cursor binding on the wire (W4-7) ----------------------------------------------------------------------------------

func TestSearchChain_PageTokenBinding(t *testing.T) {
	e := newSearchChain(t, nil)
	x, y := e.user(t), e.user(t)
	author := e.user(t)
	tag, other := uniqueTag(), uniqueTag()
	seedTagged(t, e.fs, author.uid, tag, 45, 0)
	seedTagged(t, e.fs, author.uid, other, 45, 0)
	p1, err := e.posts(x, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 20, "")
	if err != nil || p1.GetNextPageToken() == "" {
		t.Fatalf("page 1: token %q err %v", p1.GetNextPageToken(), err)
	}
	// The good token works for its caller, tag and tab.
	if r, err := e.posts(x, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 20, p1.GetNextPageToken()); err != nil || len(r.GetPosts()) != 20 {
		t.Fatalf("page 2: %v rows, err %v", len(r.GetPosts()), err)
	}
	tampered := p1.GetNextPageToken()[:len(p1.GetNextPageToken())-2] + "AA"
	if tampered == p1.GetNextPageToken() {
		tampered = p1.GetNextPageToken()[:len(p1.GetNextPageToken())-2] + "BB"
	}
	for _, tc := range []struct {
		name  string
		who   sUser
		query string
		tab   searchv1.SearchTab
		token string
	}{
		{"tampered", x, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, tampered},
		{"garbage", x, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, "not-a-token"},
		{"another caller", y, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, p1.GetNextPageToken()},
		{"another tag", x, other, searchv1.SearchTab_SEARCH_TAB_LATEST, p1.GetNextPageToken()},
		{"another tab", x, tag, searchv1.SearchTab_SEARCH_TAB_MEDIA, p1.GetNextPageToken()},
		{"a token on TOP", x, tag, searchv1.SearchTab_SEARCH_TAB_TOP, p1.GetNextPageToken()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := e.posts(tc.who, tc.query, tc.tab, 20, tc.token)
			wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "page_token")
			e.assertReads(t, "page_token "+tc.name, searchv1connect.SearchServiceSearchPostsProcedure, 1)
		})
	}
	// "Expired" needs a clock: it is proved below the chain (internal/search TestPageToken_Rejections, a fake clock).
}

// --- Rate limits and search_daily (W4-5, W4-7) --------------------------------------------------------------------------

func TestSearchChain_PerMinuteDefaults(t *testing.T) {
	e := newSearchChain(t, func(c *config.Config) { c.RateLimit.SearchCallsPerDay = 1_000_000 })
	// The shipped defaults: 30 / min for people, 20 / min for posts, counted per caller. The bucket refills 0.5 and 0.33
	// tokens a second, so a fast loop can win at most one extra token.
	for _, tc := range []struct {
		name   string
		lo, hi int
		call   func(u sUser, i int) error
	}{
		{"SearchPeople 30/min", 30, 32, func(u sUser, i int) error { _, err := e.people(u, "ab", 5); return err }},
		{"SearchPosts 20/min", 20, 22, func(u sUser, i int) error {
			_, err := e.posts(u, "#"+uniqueTag(), searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
			return err
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			u, v := e.user(t), e.user(t)
			ok := 0
			var limited error
			for i := 0; i < tc.hi+8; i++ {
				if err := tc.call(u, i); err != nil {
					limited = err
					break
				}
				ok++
			}
			if limited == nil || ok < tc.lo || ok > tc.hi {
				t.Fatalf("%d calls passed (want %d to %d) before %v", ok, tc.lo, tc.hi, limited)
			}
			wantReason(t, limited, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "", "")
			if err := tc.call(v, 0); err != nil {
				t.Errorf("a second caller is limited by the first one's bucket: %v", err)
			}
		})
	}
}

func TestSearchChain_SearchDailyIsOneSharedCap(t *testing.T) {
	e := newSearchChain(t, func(c *config.Config) {
		c.RateLimit.SearchPeoplePerUserPerMinute = 1_000_000
		c.RateLimit.SearchPostsPerUserPerMinute = 1_000_000
		c.RateLimit.SearchCallsPerDay = 4
	})
	u, other := e.user(t), e.user(t)
	post := func(who sUser) error {
		_, err := e.posts(who, "#"+uniqueTag(), searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		return err
	}
	person := func(who sUser) error { _, err := e.people(who, "ab", 5); return err }
	// Two of each spend the cap of 4 together.
	for i, call := range []func(sUser) error{person, post, person, post} {
		if err := call(u); err != nil {
			t.Fatalf("call %d inside the cap: %v", i+1, err)
		}
	}
	for _, call := range []func(sUser) error{person, post} {
		wantReason(t, call(u), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", "search_daily")
	}
	if l := e.lastLine(t, searchv1connect.SearchServiceSearchPostsProcedure); l["limit_name"] != "search_daily" {
		t.Errorf("request line limit_name = %v, want search_daily", l["limit_name"])
	}
	// GetTrends is not on the cap; another caller is not either.
	if _, err := e.trends(u, 0, ""); err != nil {
		t.Errorf("GetTrends after the cap: %v", err)
	}
	if err := person(other); err != nil {
		t.Errorf("another caller after the first one's cap: %v", err)
	}
}

// --- Block oracle on the wire (W4-5, W4-7) ------------------------------------------------------------------------------

func TestSearchChain_BlockOracleIsByteIdentical(t *testing.T) {
	ctx := context.Background()
	e := newSearchChain(t, nil)
	pfx := "y" + randLetters(3)
	caller := e.user(t)
	blocker := e.userWithHandle(t, pfx+"blk")
	friend := e.userWithHandle(t, pfx+"fnd")
	muted := e.userWithHandle(t, pfx+"mut")
	tagBlocked, tagNone, tagControl := uniqueTag(), uniqueTag(), uniqueTag()
	seedTagged(t, e.fs, blocker.uid, tagBlocked, 3, 0)
	seedTagged(t, e.fs, friend.uid, tagControl, 3, 0)
	if _, err := e.graph.Block(ctx, authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w4-block"), UserId: caller.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	if _, err := e.graph.Mute(ctx, authed(caller.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w4-mute"), UserId: muted.uid})); err != nil {
		t.Fatalf("Mute: %v", err)
	}
	e = newSearchChain(t, nil) // a fresh instance: no stale snapshot

	// People: the user who blocks the caller is absent, and the answer is the bytes of a prefix matching nobody.
	got, err := e.people(caller, pfx+"blk", 5)
	if err != nil {
		t.Fatal(err)
	}
	none, err := e.people(caller, "q"+randLetters(6), 5)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(marshalDet(t, got), marshalDet(t, none)) || len(got.GetUsers()) != 0 {
		t.Errorf("blocking user vs non-existent differ on the wire: %v vs %v", got, none)
	}
	// Controls, so the test cannot pass vacuously: an unblocked user and a MUTED user (a mute hides nothing here) are found.
	all, err := e.people(caller, pfx, 20)
	if err != nil {
		t.Fatal(err)
	}
	handles := map[string]bool{}
	for _, it := range all.GetUsers() {
		handles[it.GetUser().GetHandle()] = true
	}
	if !handles[pfx+"fnd"] || !handles[pfx+"mut"] || handles[pfx+"blk"] {
		t.Errorf("handles = %v, want the friend and the muted user, never the blocker", handles)
	}
	// ... and the blocker's own view of the caller is the mirror (the caller is blocked BY nobody, but the blocker blocks them).
	viaBlocker, err := e.people(blocker, pfx+"fnd", 5)
	if err != nil || len(viaBlocker.GetUsers()) != 1 {
		t.Errorf("blocker finds an unrelated user: %v, %v", viaBlocker, err)
	}

	// Posts: the blocker's tag answers like a tag nobody used, after the tag name itself is set aside.
	a, err := e.posts(caller, tagBlocked, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := e.posts(caller, tagNone, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	a2, b2 := proto.Clone(a).(*searchv1.SearchPostsResponse), proto.Clone(b).(*searchv1.SearchPostsResponse)
	a2.NormalizedTag, b2.NormalizedTag = "", ""
	if len(a.GetPosts()) != 0 || !bytes.Equal(marshalDet(t, a2), marshalDet(t, b2)) {
		t.Errorf("blocked-author tag vs empty tag differ on the wire: %v vs %v", a, b)
	}
	if c, err := e.posts(caller, tagControl, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, ""); err != nil || len(c.GetPosts()) != 3 {
		t.Errorf("control: a friend's tag shows %d posts, err %v", len(c.GetPosts()), err)
	}
	// Tabs agree: TOP and MEDIA hide the same posts.
	for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_MEDIA} {
		if r, err := e.posts(caller, tagBlocked, tab, 0, ""); err != nil || len(r.GetPosts()) != 0 {
			t.Errorf("%v shows %d posts of a blocking author, err %v", tab, len(r.GetPosts()), err)
		}
	}
}

// --- Degraded mode (reads keep working) ---------------------------------------------------------------------------------

func TestSearchChain_ReadonlyKeepsAnsweringReads(t *testing.T) {
	setup := newSearchChain(t, nil)
	caller := setup.user(t)
	tag := uniqueTag()
	seedTagged(t, setup.fs, caller.uid, tag, 3, 0)
	e := newSearchChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })
	if _, err := e.people(caller, "ab", 5); err != nil {
		t.Errorf("SearchPeople under readonly: %v", err)
	}
	if r, err := e.posts(caller, tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, ""); err != nil || len(r.GetPosts()) != 3 {
		t.Errorf("SearchPosts under readonly: %v rows, err %v", len(r.GetPosts()), err)
	}
	if _, err := e.trends(caller, 0, ""); err != nil {
		t.Errorf("GetTrends under readonly: %v", err)
	}
}

// --- Trends routes and the refresh end to end (W4-9, W4-9b, W4-10) -------------------------------------------------------

func postInternal(t *testing.T, base, path, auth string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, base+path, strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode
}

func trendsDoc(t *testing.T, fs *firestore.Client) *search.TrendsDoc {
	t.Helper()
	snap, err := fs.Collection("trends").Doc("current").Get(context.Background())
	if err != nil {
		t.Fatalf("read trends/current: %v", err)
	}
	var d search.TrendsDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	return &d
}

// primeTrends writes a trends/current whose watermark is a few minutes back and whose list is old enough not to be
// "fresh", so the next run scans the posts seeded by the test and (almost) nothing else in the shared emulator project.
func primeTrends(t *testing.T, fs *firestore.Client) time.Time {
	t.Helper()
	wm := time.Now().Add(-5 * time.Minute).UTC().Truncate(time.Millisecond)
	if err := search.NewTrendsRepo(fs).Put(context.Background(), &search.TrendsDoc{
		Items: []search.TrendItem{{Tag: "stale", Posts: 1, Authors: 3}}, ComputedAt: time.Now().Add(-48 * time.Hour).UTC(),
		WindowStart: wm.Add(-time.Hour), Watermark: search.Watermark{At: wm},
	}); err != nil {
		t.Fatal(err)
	}
	return wm
}

// seedAuthorsOnTag writes one post per author id on tag, all newer than the primed watermark.
func seedAuthorsOnTag(t *testing.T, fs *firestore.Client, tag string, authors ...string) {
	t.Helper()
	for i, a := range authors {
		id := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
		doc := map[string]any{
			"authorId": a, "author": map[string]any{"userId": a, "handle": "h" + a[:6]}, "kind": "POST", "isReply": false,
			"text": "t #" + tag, "conversationId": id, "hashtags": []string{tag}, "mentions": []map[string]any{},
			"likeCount": int64(0), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
			"visibility": "PUBLIC", "createdAt": time.Now().Add(-time.Duration(60-i) * time.Second).UTC(), "hasMedia": false,
		}
		if _, err := fs.Collection("posts").Doc(id).Set(context.Background(), doc); err != nil {
			t.Fatal(err)
		}
	}
}

func refreshCfg(c *config.Config) {
	c.Search.TrendsMaxPostsPerRun = 100_000 // the emulator project is shared with other tests' posts
	c.Search.TrendsMinInterval = time.Hour
	c.Search.TrendsDenylist = []string{"banned"}
}

func TestSearchChain_TrendsRefreshEndToEnd(t *testing.T) {
	e := newSearchChain(t, refreshCfg)
	const path = "/internal/cron/trends-refresh"
	if got := func() int {
		req, _ := http.NewRequest(http.MethodGet, e.url+path, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}(); got != http.StatusMethodNotAllowed {
		t.Errorf("GET %s = %d, want 405", path, got)
	}

	a, b, c, d := e.user(t), e.user(t), e.user(t), e.user(t)
	launch, spam, banned := uniqueTag(), uniqueTag(), uniqueTag()
	primeTrends(t, e.fs)
	seedAuthorsOnTag(t, e.fs, launch, a.uid, b.uid, c.uid)             // 3 distinct authors: trends
	seedAuthorsOnTag(t, e.fs, spam, d.uid, d.uid, d.uid, d.uid, d.uid) // 5 posts, 1 author: does not
	seedAuthorsOnTag(t, e.fs, banned, a.uid, b.uid, c.uid)             // denylisted: absent (the denylist matches an exact tag, so add it)

	// The denylist is by exact tag: configure this run's banned tag.
	e2 := newSearchChain(t, func(cfg *config.Config) { refreshCfg(cfg); cfg.Search.TrendsDenylist = []string{banned} })
	if got := postInternal(t, e2.url, path, ""); got != http.StatusNoContent {
		t.Fatalf("POST %s = %d, want 204", path, got)
	}
	doc := trendsDoc(t, e2.fs)
	byTag := map[string]search.TrendItem{}
	for _, it := range doc.Items {
		byTag[it.Tag] = it
	}
	if it, ok := byTag[launch]; !ok || it.Authors != 3 || it.Posts != 3 {
		t.Errorf("#launch = %+v (present %v), want 3 authors 3 posts", it, ok)
	}
	if _, ok := byTag[spam]; ok {
		t.Errorf("a tag with one author trends: %+v", byTag[spam])
	}
	if _, ok := byTag[banned]; ok {
		t.Errorf("a denylisted tag trends: %+v", byTag[banned])
	}
	if time.Since(doc.ComputedAt) > time.Minute {
		t.Errorf("computedAt = %v, the run did not write", doc.ComputedAt)
	}
	// The request log of the run: one trends_refresh line, 1 write, no uid.
	var refreshLine string
	for _, line := range strings.Split(e2.logs.buf.String(), "\n") {
		if strings.Contains(line, `"msg":"trends_refresh"`) {
			refreshLine = line
		}
	}
	if refreshLine == "" {
		t.Fatalf("no trends_refresh line in the log")
	}
	for _, uid := range []string{a.uid, b.uid, c.uid, d.uid} {
		if strings.Contains(e2.logs.buf.String(), uid) {
			t.Errorf("the log carries a uid: %s", uid)
		}
	}

	// GetTrends from a cold instance now serves it, and the typeahead prefix filters it.
	reader := newSearchChain(t, nil)
	r, err := reader.trends(a, 30, launch[:6])
	if err != nil || len(r.GetTrends()) != 1 || r.GetTrends()[0].GetTag() != launch || r.GetTrends()[0].GetRank() < 1 {
		t.Fatalf("GetTrends(prefix) = %v, %v", r.GetTrends(), err)
	}
	if r.GetComputedAt() == nil {
		t.Error("computed_at unset")
	}

	// A retry minutes later is "fresh": the list is not replaced and the line is trends_skipped.
	before := trendsDoc(t, e2.fs).ComputedAt
	if got := postInternal(t, e2.url, path, ""); got != http.StatusNoContent {
		t.Fatalf("retry = %d, want 204", got)
	}
	if after := trendsDoc(t, e2.fs).ComputedAt; !after.Equal(before) {
		t.Errorf("a retry within TRENDS_MIN_INTERVAL replaced the list (%v -> %v)", before, after)
	}
	if !strings.Contains(e2.logs.buf.String(), `"reason":"fresh"`) {
		t.Errorf("no trends_skipped reason=fresh line")
	}
}

func TestSearchChain_TrendsRefreshSwitches(t *testing.T) {
	setup := newSearchChain(t, refreshCfg)
	const path = "/internal/cron/trends-refresh"
	u := setup.user(t)
	for _, tc := range []struct {
		name    string
		mutate  func(*config.Config)
		wantRun bool
		reason  string
	}{
		{"flag off is the kill switch", func(c *config.Config) { c.FeatureTrends = flags.Spec{Name: "trends", Mode: flags.Off} }, false, "flag_off"},
		{"readonly degraded mode", func(c *config.Config) { c.Degraded = config.DegradedReadonly }, false, "readonly"},
		{"percent 0 is a rollout, not a kill switch", func(c *config.Config) {
			c.FeatureTrends = flags.Spec{Name: "trends", Mode: flags.Percent, Percent: 0}
		}, true, ""},
		{"empty allowlist is not a kill switch", func(c *config.Config) {
			c.FeatureTrends = flags.Spec{Name: "trends", Mode: flags.Allowlist}
		}, true, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newSearchChain(t, func(c *config.Config) { refreshCfg(c); tc.mutate(c) })
			primeTrends(t, e.fs)
			seedAuthorsOnTag(t, e.fs, uniqueTag(), u.uid)
			before := trendsDoc(t, e.fs)
			if got := postInternal(t, e.url, path, ""); got != http.StatusNoContent {
				t.Fatalf("status = %d, want 204", got)
			}
			after := trendsDoc(t, e.fs)
			logs := e.logs.buf.String()
			if tc.wantRun {
				if !after.ComputedAt.After(before.ComputedAt) || !strings.Contains(logs, `"msg":"trends_refresh"`) {
					t.Errorf("the refresh did not run: computedAt %v -> %v", before.ComputedAt, after.ComputedAt)
				}
				return
			}
			if !after.ComputedAt.Equal(before.ComputedAt) || len(after.Items) != len(before.Items) {
				t.Errorf("a switched-off refresh wrote: %+v -> %+v", before, after)
			}
			var skipped string
			for _, line := range strings.Split(logs, "\n") {
				if strings.Contains(line, `"msg":"trends_skipped"`) {
					skipped = line
				}
			}
			if !strings.Contains(skipped, `"reason":"`+tc.reason+`"`) || !strings.Contains(skipped, `"fs_reads":0`) || !strings.Contains(skipped, `"fs_writes":0`) {
				t.Errorf("want one trends_skipped line reason=%s with 0 reads and 0 writes, got %q", tc.reason, skipped)
			}
		})
	}
}

// The /internal/* wall: with the verifier configured, neither trends route does anything for a missing, garbage or
// Auth-emulator token (a real Google-signed token, wrong audience included, cannot be minted offline; the verifier's own
// audience and email checks are unit-tested in pkg/platform/pubsubpush).
func TestSearchChain_TrendsRoutesNeedOIDC(t *testing.T) {
	setup := newSearchChain(t, refreshCfg)
	u := setup.user(t)
	primeTrends(t, setup.fs)
	seedAuthorsOnTag(t, setup.fs, uniqueTag(), u.uid)
	before := trendsDoc(t, setup.fs)
	walled := newSearchChain(t, func(c *config.Config) {
		refreshCfg(c)
		c.InternalOIDCAudience = "https://api.example.test"
		c.InternalOIDCAllowedEmails = []string{"scheduler@demo.iam.gserviceaccount.com"}
	})
	for _, path := range []string{"/internal/cron/trends-refresh", "/api/internal/cron/trends-refresh", "/internal/cron/daily-maintenance", "/api/internal/cron/daily-maintenance"} {
		for name, auth := range map[string]string{"no header": "", "garbage bearer": "Bearer not.a.jwt", "an Auth emulator ID token": "Bearer " + u.token} {
			if got := postInternal(t, walled.url, path, auth); got != http.StatusUnauthorized {
				t.Errorf("POST %s with %s = %d, want 401", path, name, got)
			}
		}
	}
	if after := trendsDoc(t, setup.fs); !after.ComputedAt.Equal(before.ComputedAt) {
		t.Errorf("an unauthenticated request ran the refresh")
	}
	if strings.Contains(walled.logs.buf.String(), `"msg":"trends_refresh"`) {
		t.Errorf("a rejected request reached the refresher")
	}
}

// The daily-maintenance route runs the backstop and then the trends step (F1 = B).
func TestSearchChain_DailyMaintenanceRunsTheTrendsStep(t *testing.T) {
	e := newSearchChain(t, refreshCfg)
	u := e.user(t)
	primeTrends(t, e.fs)
	tag := uniqueTag()
	x, y := e.user(t), e.user(t)
	seedAuthorsOnTag(t, e.fs, tag, u.uid, x.uid, y.uid)
	before := trendsDoc(t, e.fs)
	status := postInternal(t, e.url, "/internal/cron/daily-maintenance", "")
	t.Logf("daily-maintenance status = %d", status)
	after := trendsDoc(t, e.fs)
	if !after.ComputedAt.After(before.ComputedAt) {
		t.Fatalf("the trends step did not run (status %d, log: %s)", status, e.logs.buf.String())
	}
	found := false
	for _, it := range after.Items {
		found = found || it.Tag == tag
	}
	if !found {
		t.Errorf("#%s missing from %+v", tag, after.Items)
	}
}

// --- Hidden rows on real documents (W4-5 suspended user, W4-7 taken-down post) --------------------------------------

func TestSearchChain_SuspendedUsersAndTakenDownPostsAreAbsent(t *testing.T) {
	ctx := context.Background()
	setup := newSearchChain(t, nil)
	pfx := "x" + randLetters(3)
	caller := setup.user(t)
	active := setup.userWithHandle(t, pfx+"ok")
	suspended := setup.userWithHandle(t, pfx+"sus")
	deleting := setup.userWithHandle(t, pfx+"del")
	for u, status := range map[sUser]string{suspended: "SUSPENDED", deleting: "DELETING"} {
		if _, err := setup.fs.Collection("users").Doc(u.uid).Update(ctx, []firestore.Update{{Path: "status", Value: status}}); err != nil {
			t.Fatal(err)
		}
	}
	tag := uniqueTag()
	seedTagged(t, setup.fs, active.uid, tag, 4, 0)
	snap, err := setup.fs.Collection("posts").Where("hashtags", "array-contains", tag).Limit(1).Documents(ctx).GetAll()
	if err != nil || len(snap) != 1 {
		t.Fatalf("find a seeded post: %v %v", snap, err)
	}
	if _, err := snap[0].Ref.Update(ctx, []firestore.Update{{Path: "moderation", Value: "TAKEN_DOWN"}}); err != nil {
		t.Fatal(err)
	}

	e := newSearchChain(t, nil) // cold: nothing cached from the writes above
	r, err := e.people(caller, pfx, 20)
	if err != nil || len(r.GetUsers()) != 1 || r.GetUsers()[0].GetUser().GetHandle() != pfx+"ok" {
		t.Errorf("people(%s) = %v, %v; want only the active user", pfx, r.GetUsers(), err)
	}
	for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_LATEST} {
		p, err := e.posts(caller, tag, tab, 0, "")
		if err != nil || len(p.GetPosts()) != 3 {
			t.Errorf("%v shows %d posts, want 3 (one is taken down), err %v", tab, len(p.GetPosts()), err)
		}
	}
}

// --- Observability (ADR-0028 D10): the request lines carry kinds, lengths and counts, never the query ----------------------

func TestSearchChain_RequestLinesCarryNoRawQuery(t *testing.T) {
	e := newSearchChain(t, nil)
	u := e.user(t)
	secret := "zq" + randLetters(10)
	if _, err := e.people(u, "@"+secret, 5); err != nil {
		t.Fatal(err)
	}
	if _, err := e.people(u, "@"+secret, 5); err != nil { // the second one is a cache hit
		t.Fatal(err)
	}
	if _, err := e.people(u, secret+"-x", 5); err != nil { // unsupported
		t.Fatal(err)
	}
	if _, err := e.posts(u, "#"+secret, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := e.trends(u, 0, secret[:6]); err != nil {
		t.Fatal(err)
	}
	pe := e.logs.requestLines(searchv1connect.SearchServiceSearchPeopleProcedure)
	if len(pe) != 3 {
		t.Fatalf("people lines = %d, want 3", len(pe))
	}
	if pe[0]["query_kind"] != "handle" || logNum(pe[0], "query_len") != float64(len("@"+secret)) || pe[0]["cache_hit"] != false || logNum(pe[0], "results") != 0 {
		t.Errorf("first people line = %v", pe[0])
	}
	if pe[1]["cache_hit"] != true {
		t.Errorf("second people line cache_hit = %v, want true", pe[1]["cache_hit"])
	}
	if pe[2]["query_kind"] != "unsupported" {
		t.Errorf("unsupported people line query_kind = %v", pe[2]["query_kind"])
	}
	po := e.lastLine(t, searchv1connect.SearchServiceSearchPostsProcedure)
	if po["query_kind"] == nil || po["tab"] != "LATEST" || logNum(po, "query_len") == 0 {
		t.Errorf("posts line = %v", po)
	}
	tr := e.lastLine(t, searchv1connect.SearchServiceGetTrendsProcedure)
	for _, k := range []string{"results", "cache_hit", "computed_age_s", "fs_reads"} {
		if _, ok := tr[k]; !ok {
			t.Errorf("GetTrends line lacks %s: %v", k, tr)
		}
	}
	e.logs.mu.Lock()
	all := e.logs.buf.String()
	e.logs.mu.Unlock()
	if strings.Contains(all, secret) {
		t.Errorf("a log line carries the raw query")
	}
}
