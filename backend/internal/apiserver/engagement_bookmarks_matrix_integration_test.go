//go:build integration

package apiserver

// W2-13 tester pass over the bookmark RPCs (ADR-0023, tickets W2-2..W2-5) on the real Build chain and the emulators.
// It adds what engagement_bookmarks_*_integration_test.go does not already cover: the flag modes with real data
// (including a user dropped from the allowlist), the late retry of a NO-OP key in both directions, the same post added
// ten times concurrently under different keys, the cap boundary at the default 1,000, the 24 h new-account quota window,
// the caller-bound cursor (a scheduled-list token, an expired token), NOT_FOUND byte identity against GetPost on the
// wire, the budget of Add / Remove on a COLD chain (a second chain, not the one that seeded the data) and the viewer
// state with FEATURE_ENGAGEMENT off. Helpers come from engagement_bookmarks_chain_integration_test.go and
// engagement_bookmarks_list_integration_test.go.

import (
	"bytes"
	"context"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcGetPost = "/dzeroth.posts.v1.PostService/GetPost"

// bookmarksBucket is the flag's percent bucket (flags.bucket is unexported): fnv32a("bookmarks:"+uid) % 100.
func bookmarksBucket(uid string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte("bookmarks:" + uid))
	return int(h.Sum32() % 100)
}

// bookmarksSpec returns the FEATURE_BOOKMARKS spec for mutate, leaving the abuse limits relaxed.
func bookmarksWith(spec flags.Spec) func(*config.Config) {
	return func(c *config.Config) { bookmarksOn(c); c.FeatureBookmarks = spec }
}

func (e *bmChain) enabledFeatures(t *testing.T, u bmUser) []string {
	t.Helper()
	me, err := e.identity.GetMe(context.Background(), authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	return me.Msg.GetEnabledFeatures()
}

func requireFeatureDisabled(t *testing.T, what string, err error) {
	t.Helper()
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "bookmarks" {
		t.Errorf("%s: metadata = %v, want feature=bookmarks", what, d.GetMetadata())
	}
}

// All four modes with real data. Each user already holds a bookmark (P1) written while the flag was on. A fresh chain
// then runs List, Add (a new post), Remove (P1) and List again for an "in" user and an "out" user:
//   - off: all three RPCs FEATURE_DISABLED, enabled_features does not list bookmarks;
//   - allowlist / percent: Add only for the cohort, but List and Remove keep working for a user outside it (dropped
//     from the allowlist, bucket too high): what they saved stays visible and removable (ADR-0023 D5);
//   - percent: the bucket is deterministic (the test recomputes it) and an allowlisted uid is in whatever its bucket;
//   - on: everything.
func TestBookmarksW213_FlagModesWithRealData(t *testing.T) {
	w := newBMChain(t, nil)
	author := w.user(t)
	p1, p2 := w.post(t, author, "p1"), w.post(t, author, "p2")

	// One user per side of the 50% bucket (the uid is random, so draw until both exist).
	var inU, outU bmUser
	var haveIn, haveOut bool
	for i := 0; i < 80 && (!haveIn || !haveOut); i++ {
		u := w.user(t)
		switch b := bookmarksBucket(u.uid); {
		case b < 50 && !haveIn:
			inU, haveIn = u, true
		case b >= 50 && !haveOut:
			outU, haveOut = u, true
		}
	}
	if !haveIn || !haveOut {
		t.Fatal("could not draw a user on each side of the 50% bucket")
	}
	users := []bmUser{inU, outU}

	// seed makes sure both users hold exactly P1 (the writer chain has the flag on for everyone).
	seed := func() {
		for _, u := range users {
			if _, err := w.remove(u, contractKey("bm-rm"), p2); err != nil {
				t.Fatalf("seed remove: %v", err)
			}
			if _, err := w.add(u, contractKey("bm-add"), p1); err != nil {
				t.Fatalf("seed add: %v", err)
			}
		}
	}

	allow := func(u bmUser) map[string]struct{} { return map[string]struct{}{u.uid: {}} }
	cases := []struct {
		name string
		spec flags.Spec
		// enabled says whether the flag is on for u.
		enabled func(u bmUser) bool
		off     bool // globally off: every RPC is FEATURE_DISABLED
	}{
		{"off", flags.Spec{Name: "bookmarks", Mode: flags.Off}, func(bmUser) bool { return false }, true},
		{"allowlist (inU only; outU was dropped)", flags.Spec{Name: "bookmarks", Mode: flags.Allowlist, Allowlist: allow(inU)},
			func(u bmUser) bool { return u == inU }, false},
		{"allowlist, empty", flags.Spec{Name: "bookmarks", Mode: flags.Allowlist}, func(bmUser) bool { return false }, false},
		{"percent 50", flags.Spec{Name: "bookmarks", Mode: flags.Percent, Percent: 50},
			func(u bmUser) bool { return bookmarksBucket(u.uid) < 50 }, false},
		{"percent 50 + allowlisted outU", flags.Spec{Name: "bookmarks", Mode: flags.Percent, Percent: 50, Allowlist: allow(outU)},
			func(bmUser) bool { return true }, false},
		{"percent 0", flags.Spec{Name: "bookmarks", Mode: flags.Percent, Percent: 0}, func(bmUser) bool { return false }, false},
		{"percent 100", flags.Spec{Name: "bookmarks", Mode: flags.Percent, Percent: 100}, func(bmUser) bool { return true }, false},
		{"on", flags.Spec{Name: "bookmarks", Mode: flags.On}, func(bmUser) bool { return true }, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seed()
			r := newBMChain(t, bookmarksWith(tc.spec)) // a cold reader chain: no cached flag or viewer state
			for i, u := range users {
				name := []string{"inU", "outU"}[i]
				listed := slices.Contains(r.enabledFeatures(t, u), "bookmarks")
				if listed != tc.enabled(u) {
					t.Errorf("%s: enabled_features lists bookmarks = %v, want %v", name, listed, tc.enabled(u))
				}

				before, lerr := r.list(u, 0, "")
				if tc.off {
					requireFeatureDisabled(t, name+" List", lerr)
					_, aerr := r.add(u, contractKey("bm-add"), p2)
					requireFeatureDisabled(t, name+" Add", aerr)
					_, rerr := r.remove(u, contractKey("bm-rm"), p1)
					requireFeatureDisabled(t, name+" Remove", rerr)
					if !w.bookmarkDocExists(t, u.uid, p1) {
						t.Errorf("%s: a refused Remove deleted the bookmark", name)
					}
					continue
				}
				if lerr != nil || fmt.Sprint(postIDs(before)) != fmt.Sprint([]string{p1}) {
					t.Errorf("%s: List = %v, %v; want [P1] whatever the cohort (a dropped user keeps what they saved)", name, postIDs(before), lerr)
				}
				// Add: only the cohort. A refusal costs no more than the account-status read and writes nothing.
				_, aerr := r.add(u, contractKey("bm-add"), p2)
				if tc.enabled(u) {
					if aerr != nil {
						t.Errorf("%s: Add in cohort: %v", name, aerr)
					}
				} else {
					requireFeatureDisabled(t, name+" Add", aerr)
					c := r.lineBudget(t, rpcAddBookmark)
					if c.Reads() > 1 || c.Writes() != 0 {
						t.Errorf("%s: refused Add reads/writes = %d/%d, want <=1/0 (the flag gate comes before any Firestore access)", name, c.Reads(), c.Writes())
					}
					if w.bookmarkDocExists(t, u.uid, p2) {
						t.Errorf("%s: a refused Add created a bookmark", name)
					}
				}
				// Remove always works (flag not globally off): the saved bookmark can be taken back.
				if _, err := r.remove(u, contractKey("bm-rm"), p1); err != nil {
					t.Errorf("%s: Remove outside/inside the cohort: %v", name, err)
				}
				if w.bookmarkDocExists(t, u.uid, p1) {
					t.Errorf("%s: P1 survived Remove", name)
				}
				after, err := r.list(u, 0, "")
				want := []string{}
				if tc.enabled(u) {
					want = []string{p2}
				}
				if err != nil || fmt.Sprint(postIDs(after)) != fmt.Sprint(want) {
					t.Errorf("%s: List after = %v, %v; want %v", name, postIDs(after), err, want)
				}
			}
		})
	}
}

// A late retry of a NO-OP key must neither undo nor redo a newer toggle (the ADR-0023 note: no-op paths store the
// idempotency doc, 1 write). The existing lifecycle test replays a key that really removed something; these use keys
// that changed nothing.
func TestBookmarksW213_LateRetryOfNoOpKeys(t *testing.T) {
	w := newBMChain(t, nil)
	a, b := w.user(t), w.user(t)
	pid := w.post(t, a, "late retry")

	t.Run("Remove K was a no-op, Add K2, retry K must not delete", func(t *testing.T) {
		k, k2 := contractKey("bm-rm"), contractKey("bm-add")
		if st, err := w.remove(b, k, pid); err != nil || st.GetBookmarked() {
			t.Fatalf("Remove K (nothing bookmarked) = %v, %v", st, err)
		}
		if got := w.lastOutcome(rpcRemoveBookmark); got != "noop" {
			t.Fatalf("outcome = %q, want noop", got)
		}
		if _, err := w.add(b, k2, pid); err != nil {
			t.Fatal(err)
		}
		st, err := w.remove(b, k, pid) // the late retry of K
		if err != nil || st.GetBookmarked() || st.GetPostId() != pid {
			t.Fatalf("retry of Remove K = %v, %v; want the stored answer (not bookmarked)", st, err)
		}
		if got := w.lastOutcome(rpcRemoveBookmark); got != "replay" {
			t.Errorf("retry outcome = %q, want replay", got)
		}
		if !w.bookmarkDocExists(t, b.uid, pid) || !slices.Contains(w.bookmarkIDs(t, b.uid), pid) {
			t.Fatal("the late retry of a no-op Remove key deleted a bookmark added after it")
		}
		c := w.lineBudget(t, rpcRemoveBookmark)
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("replay writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
		}
	})

	t.Run("Add K was a no-op, Remove K2, retry K must not re-add", func(t *testing.T) {
		// B holds a bookmark from the previous subtest.
		k, k2 := contractKey("bm-add"), contractKey("bm-rm")
		before := w.quotaUsed(t, b.uid)
		if st, err := w.add(b, k, pid); err != nil || !st.GetBookmarked() {
			t.Fatalf("Add K (already bookmarked) = %v, %v", st, err)
		}
		if got := w.lastOutcome(rpcAddBookmark); got != "noop" {
			t.Fatalf("outcome = %q, want noop", got)
		}
		if _, err := w.remove(b, k2, pid); err != nil {
			t.Fatal(err)
		}
		st, err := w.add(b, k, pid) // the late retry of K
		if err != nil || !st.GetBookmarked() {
			t.Fatalf("retry of Add K = %v, %v; want the stored answer (bookmarked)", st, err)
		}
		if got := w.lastOutcome(rpcAddBookmark); got != "replay" {
			t.Errorf("retry outcome = %q, want replay", got)
		}
		if w.bookmarkDocExists(t, b.uid, pid) || slices.Contains(w.bookmarkIDs(t, b.uid), pid) {
			t.Fatal("the late retry of a no-op Add key re-created a bookmark removed after it")
		}
		if after := w.quotaUsed(t, b.uid); after != before {
			t.Errorf("quota %d -> %d across a no-op and its retry: only a real add may be charged", before, after)
		}
	})
}

// Ten parallel Adds of the SAME post under ten different keys (a double tap that got fresh keys, two devices): one
// bookmark doc, one array entry, the quota charged once. Contention may abort some callers; those get a retryable error
// and a sequential retry converges on the same single bookmark.
func TestBookmarksW213_SamePostDifferentKeysConcurrently(t *testing.T) {
	w := newBMChain(t, nil)
	a, b := w.user(t), w.user(t)
	pid := w.post(t, a, "contended")

	const n = 10
	errs := make([]error, n)
	keys := make([]string, n)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range errs {
		keys[i] = contractKey("bm-conc")
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, errs[i] = w.add(b, keys[i], pid)
		}()
	}
	close(start)
	wg.Wait()
	failed := 0
	for i, err := range errs {
		if err == nil {
			continue
		}
		failed++
		switch connect.CodeOf(err) {
		case connect.CodeAborted, connect.CodeUnavailable, connect.CodeDeadlineExceeded:
			t.Logf("add %d gave up under contention: %v", i, err)
		default:
			t.Errorf("add %d: %v", i, err)
		}
	}
	t.Logf("%d of %d parallel adds gave up under contention", failed, n)
	if !w.bookmarkDocExists(t, b.uid, pid) {
		// every caller failed: retry once, sequentially, to prove convergence
		if _, err := w.add(b, contractKey("bm-conc"), pid); err != nil {
			t.Fatal(err)
		}
	}
	docs, err := w.fs.Collection("users").Doc(b.uid).Collection("bookmarks").Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	ids := w.bookmarkIDs(t, b.uid)
	if len(docs) != 1 || len(ids) != 1 || ids[0] != pid {
		t.Errorf("docs %d, array %v: want one doc and [%s]", len(docs), ids, pid)
	}
	if q := w.quotaUsed(t, b.uid); q != 1 {
		t.Errorf("quotas.bookmarks = %d after %d adds of one post, want 1 (charged once)", q, n)
	}
	// Every key that succeeded replays to the same state and charges nothing more.
	for i, err := range errs {
		if err != nil {
			continue
		}
		if st, rerr := w.add(b, keys[i], pid); rerr != nil || !st.GetBookmarked() {
			t.Errorf("replay of key %d = %v, %v", i, st, rerr)
		}
	}
	if q := w.quotaUsed(t, b.uid); q != 1 {
		t.Errorf("quotas.bookmarks = %d after the replays, want 1", q)
	}
}

// The cap at the default BOOKMARKS_MAX_PER_USER (1,000), through the chain: with 999 saved the 1,000th add succeeds, the
// 1,001st is LIMIT_REACHED limit=bookmarks with 0 writes, an existing bookmark still answers success, and one Remove
// makes room again. The 999 are seeded straight into userLikes.bookmarks (the array length is the exact cap check,
// ADR-0023 D4) so the test does not need 999 requests.
func TestBookmarksW213_CapBoundaryAtTheDefault(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, nil)
	if got := w.cfgCap(t); got != 1000 {
		t.Fatalf("default BOOKMARKS_MAX_PER_USER = %d, want 1000", got)
	}
	a, b := w.user(t), w.user(t)
	p1000, p1001 := w.post(t, a, "the 1000th"), w.post(t, a, "the 1001st")
	filler := make([]string, 999)
	for i := range filler {
		filler[i] = fmt.Sprintf("%019d", 7_000_000+i)
	}
	if _, err := w.fs.Doc("userLikes/"+b.uid).Set(ctx, map[string]any{"bookmarks": filler}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}

	if st, err := w.add(b, contractKey("bm-add"), p1000); err != nil || !st.GetBookmarked() {
		t.Fatalf("the 1,000th add = %v, %v; want success", st, err)
	}
	if n := len(w.bookmarkIDs(t, b.uid)); n != 1000 {
		t.Fatalf("userLikes.bookmarks has %d ids, want 1000", n)
	}
	_, err := w.add(b, contractKey("bm-add"), p1001)
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if d.GetMetadata()["limit"] != "bookmarks" {
		t.Errorf("metadata = %v, want limit=bookmarks", d.GetMetadata())
	}
	if c := w.lineBudget(t, rpcAddBookmark); c.Writes() != 0 {
		t.Errorf("the refused 1,001st add wrote %d docs", c.Writes())
	}
	if w.bookmarkDocExists(t, b.uid, p1001) || len(w.bookmarkIDs(t, b.uid)) != 1000 {
		t.Error("the 1,001st add changed state")
	}
	if _, err := w.add(b, contractKey("bm-add"), p1000); err != nil {
		t.Errorf("an existing bookmark at the cap must still succeed: %v", err)
	}
	if _, err := w.remove(b, contractKey("bm-rm"), p1000); err != nil {
		t.Fatal(err)
	}
	if _, err := w.add(b, contractKey("bm-add"), p1001); err != nil {
		t.Errorf("after a remove there is room for the 1,001st: %v", err)
	}
}

// cfgCap reads the configured cap the chain was built with (config.Load: the env default).
func (e *bmChain) cfgCap(t *testing.T) int {
	t.Helper()
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	return cfg.Quota.BookmarksMaxPerUser
}

// The new-account quota window is 24 h from users/{uid}.createdAt: an account 23 h old gets the new-account limit, an
// account 25 h old the established one (a boundary the existing tests only reach through a 1 ns window).
func TestBookmarksW213_NewAccountWindowIs24Hours(t *testing.T) {
	ctx := context.Background()
	setup := newBMChain(t, nil)
	a := setup.user(t)
	young, old := setup.user(t), setup.user(t)
	posts := make([]string, 4)
	for i := range posts {
		posts[i] = setup.post(t, a, fmt.Sprint("q", i))
	}
	setAge := func(u bmUser, age time.Duration) {
		if _, err := setup.fs.Doc("users/"+u.uid).Update(ctx, []firestore.Update{{Path: "createdAt", Value: time.Now().Add(-age)}}); err != nil {
			t.Fatal(err)
		}
	}
	setAge(young, 23*time.Hour)
	setAge(old, 25*time.Hour)

	r := newBMChain(t, func(c *config.Config) {
		bookmarksOn(c)
		c.Quota.BookmarksPerDay, c.Quota.NewAccountBookmarksPerDay = 3, 1
		if c.Quota.NewAccountWindow != 24*time.Hour {
			t.Fatalf("NewAccountWindow = %v, want the 24 h default", c.Quota.NewAccountWindow)
		}
	})
	exhausted := func(u bmUser, post string) bool {
		_, err := r.add(u, contractKey("bm-add"), post)
		if err == nil {
			return false
		}
		d := wireError(t, err, connect.CodeResourceExhausted)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		return true
	}
	// young (23 h): 1 allowed, the 2nd refused.
	if exhausted(young, posts[0]) || !exhausted(young, posts[1]) {
		t.Errorf("a 23 h old account must get exactly the new-account limit of 1")
	}
	// old (25 h): 3 allowed, the 4th refused.
	for i := 0; i < 3; i++ {
		if exhausted(old, posts[i]) {
			t.Errorf("a 25 h old account was refused add %d: it gets the established limit of 3", i+1)
		}
	}
	if !exhausted(old, posts[3]) {
		t.Error("a 25 h old account got a 4th add past the established limit of 3")
	}
}

// ListBookmarks tokens are caller- and list-bound and expire after 24 h; each failure is INVALID_ARGUMENT VALIDATION
// page_token at 0 Firestore reads. The scheduled list's token (same uid, other list) is the cross-list case.
func TestBookmarksW213_CursorAuthz(t *testing.T) {
	ctx := context.Background()
	var key []byte
	w, r := listChains(t, func(c *config.Config) {
		bookmarksOn(c)
		c.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
		key = c.CursorHMACKey
	})
	author, v := w.user(t), w.user(t)
	var last string
	for i := 0; i < 3; i++ {
		last = w.post(t, author, fmt.Sprint("c", i))
		w.bookmarkDirect(t, v.uid, last, i)
	}
	first, err := r.list(v, 2, "")
	if err != nil || first.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v, %v", first, err)
	}

	// A scheduled-list token of the SAME user.
	for i := 0; i < 3; i++ {
		if _, err := w.posts.SchedulePost(ctx, authed(v.token, &postsv1.SchedulePostRequest{
			IdempotencyKey: contractKey("bm-sched"), Text: fmt.Sprint("later ", i),
			PublishAt: timestamppb.New(time.Now().Add(time.Duration(3+i) * time.Hour).Add(17 * time.Second)),
		})); err != nil {
			t.Fatalf("SchedulePost: %v", err)
		}
	}
	sched, err := w.posts.ListScheduledPosts(ctx, authed(v.token, &postsv1.ListScheduledPostsRequest{PageSize: 2}))
	if err != nil || sched.Msg.GetNextPageToken() == "" {
		t.Fatalf("scheduled page 1 = %v, %v", sched, err)
	}
	schedToken := sched.Msg.GetNextPageToken()

	expired := cursor.EncodeAt(key, "bookmarks|"+v.uid, cursor.Cursor{CreatedAt: time.Now().Add(-time.Hour), DocID: last}, time.Now().Add(-25*time.Hour))
	justInside := cursor.EncodeAt(key, "bookmarks|"+v.uid, cursor.Cursor{CreatedAt: time.Now().Add(-time.Hour), DocID: last}, time.Now().Add(-23*time.Hour))
	// The forging helper is right: the same construction one hour short of the TTL is accepted.
	if _, err := r.list(v, 2, justInside); err != nil {
		t.Fatalf("a token issued 23 h ago must still open (the forge is the control for the expiry case): %v", err)
	}

	for name, token := range map[string]string{
		"a token from the scheduled list (same uid)": schedToken,
		"a bookmarks token issued 25 h ago":          expired,
	} {
		_, err := r.list(v, 2, token)
		d := wireError(t, err, connect.CodeInvalidArgument)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if d.GetMetadata()["field"] != "page_token" {
			t.Errorf("%s: metadata = %v, want field=page_token", name, d.GetMetadata())
		}
		budgettest.Assert(t, "ListBookmarks "+name, r.lineBudget(t, rpcListBookmarks), budgettest.Budget{})
		if c := r.lineBudget(t, rpcListBookmarks); c.Reads() != 0 || c.Writes() != 0 {
			t.Errorf("%s: reads/writes = %d/%d, want 0/0", name, c.Reads(), c.Writes())
		}
	}
	// The other direction: a bookmarks token opens nothing on the scheduled list.
	if _, err := w.posts.ListScheduledPosts(ctx, authed(v.token, &postsv1.ListScheduledPostsRequest{PageSize: 2, PageToken: first.GetNextPageToken()})); err == nil {
		t.Error("a bookmarks page token was accepted by ListScheduledPosts")
	} else if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("code = %v, want INVALID_ARGUMENT", connect.CodeOf(err))
	}
}

// No request field can name another user's bookmarks: the path comes from the token. B cannot remove, read or see the
// state of A's bookmark, and a post_id that looks like a Firestore path is a plain VALIDATION failure at 0 writes.
func TestBookmarksW213_NoPathReachesAnotherUsersBookmarks(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, nil)
	author, a, b := w.user(t), w.user(t), w.user(t)
	pid := w.post(t, author, "a saved this")
	if _, err := w.add(a, contractKey("bm-add"), pid); err != nil {
		t.Fatal(err)
	}

	// B "removes" A's bookmark by the same post id: a no-op in B's own namespace.
	if st, err := w.remove(b, contractKey("bm-rm"), pid); err != nil || st.GetBookmarked() {
		t.Fatalf("B Remove = %v, %v", st, err)
	}
	if !w.bookmarkDocExists(t, a.uid, pid) || !slices.Contains(w.bookmarkIDs(t, a.uid), pid) {
		t.Fatal("B's RemoveBookmark deleted A's bookmark")
	}
	// B sees nothing of it, anywhere.
	if gp, err := w.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid})); err != nil || gp.Msg.GetPost().GetBookmarkedByViewer() {
		t.Fatalf("GetPost as B = %v, %v: A's bookmark leaked", gp, err)
	}
	if l, err := w.list(b, 0, ""); err != nil || len(l.GetBookmarks()) != 0 {
		t.Fatalf("B's list = %v, %v", l, err)
	}
	// B's own Add lands under B only; A is untouched (still one doc, quota charged to B).
	if _, err := w.add(b, contractKey("bm-add"), pid); err != nil {
		t.Fatal(err)
	}
	if !w.bookmarkDocExists(t, b.uid, pid) || w.quotaUsed(t, a.uid) != 1 || w.quotaUsed(t, b.uid) != 1 {
		t.Error("an Add moved or shared state between users")
	}

	for _, id := range []string{"users/" + a.uid + "/bookmarks/" + pid, "../" + a.uid, pid + "/x", "a b", "%2e%2e"} {
		_, aerr := w.add(b, contractKey("bm-add"), id)
		_, rerr := w.remove(b, contractKey("bm-rm"), id)
		for _, err := range map[string]error{"Add": aerr, "Remove": rerr} {
			d := wireError(t, err, connect.CodeInvalidArgument)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		}
		if c := w.lineBudget(t, rpcAddBookmark); c.Writes() != 0 {
			t.Errorf("post_id %q: Add wrote %d docs", id, c.Writes())
		}
	}
	if !w.bookmarkDocExists(t, a.uid, pid) {
		t.Error("A's bookmark is gone after the path-shaped ids")
	}
}

// rawRPC POSTs the Connect JSON protocol so two RPCs' error bodies can be compared byte for byte.
func (e *bmChain) rawRPC(t *testing.T, token, procedure, body string) (int, string, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, e.url+procedure, bytes.NewReader([]byte(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header.Get("Content-Type"), string(out)
}

// AddBookmark is no block / existence oracle: for every post the caller cannot see, its NOT_FOUND is the GetPost
// NOT_FOUND byte for byte on the wire (status, content type, body with the ErrorDetail), and it writes nothing and
// charges nothing. The matrix: missing, deleted, taken down, suspended author, DELETING author, the author blocks the
// caller, the caller blocks the author, and a QUOTE whose embedded author blocks the caller or is blocked by it.
func TestBookmarksW213_NotFoundBytesMatchGetPost(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, func(c *config.Config) {
		bookmarksOn(c)
		c.RateLimit.LikesPerUserPerMinute = 1_000_000
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
	})
	v := w.user(t)
	mk := func() (bmUser, string) { u := w.user(t); return u, w.post(t, u, "target") }

	del := w.user(t)
	deletedPost := w.post(t, del, "to delete")
	if _, err := w.posts.DeletePost(ctx, authed(del.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: deletedPost})); err != nil {
		t.Fatal(err)
	}
	_, hidden := mk()
	if _, err := w.fs.Doc("posts/"+hidden).Set(ctx, map[string]any{"moderation": "TAKEN_DOWN"}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	sus, suspended := mk()
	if _, err := w.fs.Doc("posts/"+suspended).Set(ctx, map[string]any{"moderation": "SUSPENDED_AUTHOR"}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	if _, err := w.fs.Doc("users/"+sus.uid).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	dl, deleting := mk()
	if _, err := w.fs.Doc("users/"+dl.uid).Update(ctx, []firestore.Update{{Path: "status", Value: "DELETING"}}); err != nil {
		t.Fatal(err)
	}
	blocker, byBlocker := mk()
	if _, err := w.graph.Block(ctx, authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: v.uid})); err != nil {
		t.Fatal(err)
	}
	blocked, ofBlocked := mk()
	if _, err := w.graph.Block(ctx, authed(v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: blocked.uid})); err != nil {
		t.Fatal(err)
	}
	// Quotes: C quotes E's post; E blocks the caller (embedded author blocks caller), and F's quoted author is blocked by the caller.
	c := w.user(t)
	e, eOriginal := mk()
	quoteOfBlocker, err := w.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bm-q"), Text: "quote", QuoteOfPostId: eOriginal}))
	if err != nil {
		t.Fatalf("CreatePost quote: %v", err)
	}
	f, fOriginal := mk()
	quoteOfBlocked, err := w.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bm-q"), Text: "quote 2", QuoteOfPostId: fOriginal}))
	if err != nil {
		t.Fatalf("CreatePost quote 2: %v", err)
	}
	if _, err := w.graph.Block(ctx, authed(e.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: v.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: f.uid})); err != nil {
		t.Fatal(err)
	}

	// visible marks the two cases GetPost itself answers 200 for: a post is hidden from the caller only when the AUTHOR
	// (or the embedded author) blocks the caller, never because the caller blocked them (the caller sees an
	// EMBED_VIEWER_STATE_BLOCKED stub on a quote). AddBookmark follows GetPost in both directions: parity is the property.
	cases := []struct {
		name    string
		id      string
		visible bool
	}{
		{"never existed", "1234567890123456789", false},
		{"deleted", deletedPost, false},
		{"taken down", hidden, false},
		{"suspended author", suspended, false},
		{"DELETING author", deleting, false},
		{"author blocks the caller", byBlocker, false},
		{"quote, embedded author blocks caller", quoteOfBlocker.Msg.GetPost().GetPost().GetPostId(), false},
		{"caller blocks the author (GetPost answers 200)", ofBlocked, true},
		{"quote, caller blocks embedded author (GetPost answers 200)", quoteOfBlocked.Msg.GetPost().GetPost().GetPostId(), true},
	}
	r := newBMChain(t, func(cfg *config.Config) { // cold: nothing cached from the seeding
		bookmarksOn(cfg)
		cfg.RateLimit.LikesPerUserPerMinute = 1_000_000
		cfg.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	})
	before := w.quotaUsed(t, v.uid)
	wantCharged := int64(0)
	for _, tc := range cases {
		gs, gct, gb := r.rawRPC(t, v.token, rpcGetPost, fmt.Sprintf(`{"postId":%q}`, tc.id))
		as, act, ab := r.rawRPC(t, v.token, rpcAddBookmark, fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, contractKey("bm-add"), tc.id))
		if tc.visible {
			if gs != http.StatusOK || as != http.StatusOK {
				t.Errorf("%s: GetPost %d, AddBookmark %d; both must be 200 (%s)", tc.name, gs, as, ab)
			}
			wantCharged++
			continue
		}
		if gs != http.StatusNotFound {
			t.Errorf("%s: GetPost status = %d body %s; the scenario is not an invisible post", tc.name, gs, gb)
			continue
		}
		if as != gs || act != gct || ab != gb {
			t.Errorf("%s: AddBookmark answer differs from GetPost's\n  GetPost:     %d %s %s\n  AddBookmark: %d %s %s", tc.name, gs, gct, gb, as, act, ab)
		}
		if w.bookmarkDocExists(t, v.uid, tc.id) {
			t.Errorf("%s: a refused add created a bookmark", tc.name)
		}
	}
	if after := w.quotaUsed(t, v.uid); after-before != wantCharged {
		t.Errorf("quota %d -> %d: want exactly the %d visible adds charged, no refused one", before, after, wantCharged)
	}
	if ids := w.bookmarkIDs(t, v.uid); int64(len(ids)) != wantCharged {
		t.Errorf("userLikes.bookmarks = %v, want only the %d visible posts", ids, wantCharged)
	}
}

// The documented budgets on a COLD chain (a second chain that did not seed the data): Add 7 reads / 4 writes, Add replay
// 5 reads, Remove 2 reads / 2 writes / 1 delete, Remove replay 2 reads, and +2 reads for a REPOST id. Each measured call
// runs on its own fresh chain so no instance cache (account status, posts, graph, userLikes, profile) is warm.
func TestBookmarksW213_ColdChainBudgets(t *testing.T) {
	cfg := func(c *config.Config) {
		bookmarksOn(c)
		c.RateLimit.LikesPerUserPerMinute = 1_000_000
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	}
	w := newBMChain(t, cfg)
	a, v := w.user(t), w.user(t)
	pid := w.post(t, a, "budget")
	rp, err := w.eng.RepostPost(context.Background(), authed(a.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("bm-rp"), PostId: pid}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()
	exact := func(name string, c interface{ Reads() int64 }, wantReads int64) {
		t.Helper()
		if c.Reads() != wantReads {
			t.Errorf("%s reads = %d, want exactly %d", name, c.Reads(), wantReads)
		}
	}

	addKey, rmKey := contractKey("bm-add"), contractKey("bm-rm")
	r1 := newBMChain(t, cfg)
	if _, err := r1.add(v, addKey, pid); err != nil {
		t.Fatal(err)
	}
	c := r1.lineBudget(t, rpcAddBookmark)
	budgettest.Assert(t, "Add cold", c, budgettest.Budget{Reads: 7, Writes: 4})
	exact("Add cold", c, 7)
	if c.Writes() != 4 || c.Deletes() != 0 {
		t.Errorf("Add cold writes/deletes = %d/%d, want 4/0", c.Writes(), c.Deletes())
	}

	r2 := newBMChain(t, cfg)
	if _, err := r2.add(v, addKey, pid); err != nil {
		t.Fatal(err)
	}
	c = r2.lineBudget(t, rpcAddBookmark)
	budgettest.Assert(t, "Add replay cold", c, budgettest.Budget{Reads: 5})
	exact("Add replay cold", c, 5)
	if c.Writes() != 0 {
		t.Errorf("Add replay writes = %d, want 0", c.Writes())
	}

	r3 := newBMChain(t, cfg)
	if _, err := r3.remove(v, rmKey, pid); err != nil {
		t.Fatal(err)
	}
	c = r3.lineBudget(t, rpcRemoveBookmark)
	budgettest.Assert(t, "Remove cold", c, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})
	exact("Remove cold", c, 2)
	if c.Writes() != 2 || c.Deletes() != 1 {
		t.Errorf("Remove cold writes/deletes = %d/%d, want 2/1", c.Writes(), c.Deletes())
	}

	r4 := newBMChain(t, cfg)
	if _, err := r4.remove(v, rmKey, pid); err != nil {
		t.Fatal(err)
	}
	c = r4.lineBudget(t, rpcRemoveBookmark)
	budgettest.Assert(t, "Remove replay cold", c, budgettest.Budget{Reads: 2})
	exact("Remove replay cold", c, 2)
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("Remove replay writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}

	r5 := newBMChain(t, cfg)
	if st, err := r5.add(v, contractKey("bm-add"), repostID); err != nil || st.GetPostId() != pid {
		t.Fatalf("Add(REPOST id) = %v, %v", st, err)
	}
	c = r5.lineBudget(t, rpcAddBookmark)
	budgettest.Assert(t, "Add REPOST cold", c, budgettest.Budget{Reads: 9, Writes: 4})
	if c.Reads() > 9 || c.Writes() != 4 { // the doc comment is the worst case (+2 for a REPOST id); a cold chain measures 8 (+1)
		t.Errorf("Add REPOST cold reads/writes = %d/%d, want <=9/4", c.Reads(), c.Writes())
	}
}

// With FEATURE_ENGAGEMENT off and FEATURE_BOOKMARKS on, viewer state shows bookmarked_by_viewer and never the like /
// repost flags, on GetPost, GetThread (focal and replies), the Home timeline and a profile timeline: the userLikes doc
// holds a like and a repost of the same post, which must not reach the wire (ADR-0023 D3/D5).
func TestBookmarksW213_EngagementOffShowsOnlyBookmarkedState(t *testing.T) {
	ctx := context.Background()
	withReplies := func(c *config.Config) { bookmarksOn(c); c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On} }
	w := newBMChain(t, withReplies)
	a, v := w.user(t), w.user(t)
	pid := w.post(t, a, "root")
	rep, err := w.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bm-reply"), Text: "a reply", ReplyToPostId: pid}))
	if err != nil {
		t.Fatalf("reply: %v", err)
	}
	replyID := rep.Msg.GetPost().GetPost().GetPostId()
	if _, err := w.graph.Follow(ctx, authed(v.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("bm-fol"), UserId: a.uid})); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{pid, replyID} {
		if _, err := w.add(v, contractKey("bm-add"), id); err != nil {
			t.Fatal(err)
		}
	}
	// A like and a repost of both posts sit in userLikes (written while engagement was on, say).
	if _, err := w.fs.Doc("userLikes/"+v.uid).Set(ctx, map[string]any{"recent": []string{pid, replyID}, "recentReposts": []string{pid, replyID}}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}

	r := newBMChain(t, withReplies) // cold, engagement default off
	check := func(where string, p *postsv1.PostView) {
		t.Helper()
		if p == nil {
			t.Errorf("%s: post missing", where)
			return
		}
		if !p.GetBookmarkedByViewer() {
			t.Errorf("%s: bookmarked_by_viewer = false, want true", where)
		}
		if p.GetLikedByViewer() || p.GetRepostedByViewer() {
			t.Errorf("%s: liked/reposted = %v/%v with FEATURE_ENGAGEMENT off, want false/false", where, p.GetLikedByViewer(), p.GetRepostedByViewer())
		}
	}
	gp, err := r.posts.GetPost(ctx, authed(v.token, &postsv1.GetPostRequest{PostId: pid}))
	if err != nil {
		t.Fatal(err)
	}
	check("GetPost", gp.Msg.GetPost())

	th, err := r.posts.GetThread(ctx, authed(v.token, &postsv1.GetThreadRequest{PostId: pid, PageSize: 10}))
	if err != nil {
		t.Fatalf("GetThread: %v", err)
	}
	check("GetThread focal", th.Msg.GetFocal())
	if len(th.Msg.GetReplies()) != 1 {
		t.Fatalf("GetThread replies = %d, want 1", len(th.Msg.GetReplies()))
	}
	check("GetThread reply", th.Msg.GetReplies()[0])
	thReply, err := r.posts.GetThread(ctx, authed(v.token, &postsv1.GetThreadRequest{PostId: replyID, PageSize: 10}))
	if err != nil {
		t.Fatal(err)
	}
	check("GetThread as reply: focal", thReply.Msg.GetFocal())
	check("GetThread as reply: parent", thReply.Msg.GetParent())

	ht, err := r.timeline.GetHomeTimeline(ctx, authed(v.token, &timelinev1.GetHomeTimelineRequest{PageSize: 10}))
	if err != nil || len(ht.Msg.GetPosts()) == 0 {
		t.Fatalf("GetHomeTimeline = %v, %v", ht, err)
	}
	for i, p := range ht.Msg.GetPosts() {
		check(fmt.Sprintf("Home timeline post %d", i), p)
	}
	ut, err := r.timeline.GetUserTimeline(ctx, authed(v.token, &timelinev1.GetUserTimelineRequest{UserId: a.uid, PageSize: 10}))
	if err != nil || len(ut.Msg.GetPosts()) == 0 {
		t.Fatalf("GetUserTimeline = %v, %v", ut, err)
	}
	for i, p := range ut.Msg.GetPosts() {
		check(fmt.Sprintf("profile timeline post %d", i), p)
	}
	bl, err := r.list(v, 0, "")
	if err != nil || len(bl.GetBookmarks()) != 2 {
		t.Fatalf("ListBookmarks = %v, %v", bl, err)
	}
	for i, row := range bl.GetBookmarks() {
		check(fmt.Sprintf("ListBookmarks row %d", i), row.GetPost())
	}
}

// Input edges of the three RPCs on the wire: idempotency_key 15 / 16 / 64 / 65 characters and non-ASCII, post_id of 0 /
// 18 / 19 / 20 digits, emoji and RTL; a refusal is INVALID_ARGUMENT VALIDATION with the field named, at 0 writes. A
// negative or oversized page_size is clamped (20 / 50), never an error.
func TestBookmarksW213_InputEdges(t *testing.T) {
	w := newBMChain(t, nil)
	a, v := w.user(t), w.user(t)
	pid := w.post(t, a, "input edges")
	key := func(n int) string { return strings.Repeat("k", n) }

	type tc struct {
		name, key, post, field string
	}
	cases := []tc{
		{"key 15 chars", key(15), pid, "idempotency_key"},
		{"key 65 chars", key(65), pid, "idempotency_key"},
		{"key with a space", "key with space 0001", pid, "idempotency_key"},
		{"key with emoji", "key-\U0001F516-0000000001", pid, "idempotency_key"},
		{"key RTL", "key-مرحبا-0000001", pid, "idempotency_key"},
		{"empty key", "", pid, "idempotency_key"},
		{"empty post id", key(16), "", "post_id"},
		{"18 digits", key(16), pid[1:], "post_id"},
		{"20 digits", key(16), pid + "1", "post_id"},
		{"letters", key(16), "abcdefghijklmnopqrs", "post_id"},
		{"emoji", key(16), "\U0001F516\U0001F516\U0001F516", "post_id"},
		{"zero-width space inside", key(16), pid[:9] + string(rune(0x200b)) + pid[9:], "post_id"},
	}
	for _, c := range cases {
		_, aerr := w.add(v, c.key, c.post)
		_, rerr := w.remove(v, c.key, c.post)
		for rpc, err := range map[string]error{"Add": aerr, "Remove": rerr} {
			d := wireError(t, err, connect.CodeInvalidArgument)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if d.GetMetadata()["field"] != c.field {
				t.Errorf("%s %s: metadata = %v, want field=%s", c.name, rpc, d.GetMetadata(), c.field)
			}
		}
	}
	if w.bookmarkDocExists(t, v.uid, pid) || w.quotaUsed(t, v.uid) != 0 {
		t.Error("a refused request changed state")
	}
	// The boundary lengths that ARE valid.
	for _, n := range []int{16, 64} {
		if _, err := w.add(v, key(n), pid); err != nil {
			t.Errorf("key of %d chars refused: %v", n, err)
		}
		if _, err := w.remove(v, key(n), pid); err != nil {
			t.Errorf("remove with a key of %d chars refused: %v", n, err)
		}
	}

	// page_size: negative and zero give the default 20, huge gives 50; never an error.
	for _, p := range []int32{-5, 0, 1 << 30} {
		if _, err := w.list(v, p, ""); err != nil {
			t.Errorf("page_size %d: %v", p, err)
		}
	}
	// An emoji / oversized page_token is VALIDATION, not a 500.
	for _, tok := range []string{"\U0001F516", strings.Repeat("A", 5000)} {
		_, err := w.list(v, 0, tok)
		d := wireError(t, err, connect.CodeInvalidArgument)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	}
}
