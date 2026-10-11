//go:build integration

// Package integration runs the timeline RPCs against the Firestore emulator with the real identity, graph and
// posts services, wired the way apiserver.Build wires them. It lives in its own directory so the timeline
// package's import lint (only the posts, graph and identity seams) still covers timeline itself.
//
// Budgets: every figure asserted here is the documented ceiling MINUS the account-status interceptor's caller
// `users` read (ADR-0010 D17), because these tests call the Connect handler directly, below the interceptors.
package integration

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/timeline"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

var cursorKey = []byte("0123456789abcdef0123456789abcdef")

type allOn struct{}

func (allOn) Enabled(string, string) bool { return true }

func newClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

// instance is one "Cloud Run instance": its own caches over the shared emulator project. A new instance is the
// cold-cache case.
type instance struct {
	client   *firestore.Client
	srv      *timeline.Server
	posts    posts.Service
	identity identity.Service
	dir      identity.Directory
	graph    graph.Reader
	pcache   *posts.Cache
	followFn func(ctx context.Context, caller, target string) error
	blockFn  func(ctx context.Context, caller, target string) error
	muteFn   func(ctx context.Context, caller, target string) error
}

func newInstance(t *testing.T, client *firestore.Client) *instance {
	return newInstanceAt(t, client, nil)
}

// newInstanceAt is newInstance with the timeline clock set (nil = real time), to step past the settle window.
func newInstanceAt(t *testing.T, client *firestore.Client, now func() time.Time) *instance {
	t.Helper()
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{
		Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, CursorKey: cursorKey,
		FollowsPerDay: 500, NewAccountFollowsPerDay: 500, BlocksPerDay: 500, NewAccountBlocksPerDay: 500, NewAccountWindow: time.Nanosecond,
	})
	identitySvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithBlockChecker(graphSvc))
	dir := identitySvc.(identity.Directory)
	graphSvc.SetDirectory(dir)

	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := posts.NewFirestoreRepo(client)
	repo.SetWriters(posts.WriteDeps{Idempotency: idempotency.New(client), Quotas: quota.New(client), Counters: identityRepo, IDs: node})
	pcache := posts.NewCache(time.Minute, 20_000, 1_000)
	postsSvc := posts.New(posts.Deps{
		Repo: repo, Cache: pcache, Events: posts.NopEvents{}, Directory: dir, Graph: graphSvc,
		PostsPerDay: 100, NewAccountPostsPerDay: 100, NewAccountWindow: time.Nanosecond,
	})
	srv := timeline.NewServer(timeline.Deps{
		Flags: allOn{}, Posts: postsSvc, Graph: graphSvc, Directory: dir,
		CursorKey: cursorKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: now,
	})
	key := func(a, b string) string { return fmt.Sprintf("k-%s-%s-0123456789abcdef", a, b) }
	return &instance{
		client: client, srv: srv, posts: postsSvc, identity: identitySvc, dir: dir, graph: graphSvc, pcache: pcache,
		followFn: func(ctx context.Context, c, tg string) error {
			_, err := graphSvc.Follow(ctx, c, key(c, tg), tg)
			return err
		},
		blockFn: func(ctx context.Context, c, tg string) error {
			_, err := graphSvc.Block(ctx, c, key(c, tg), tg)
			return err
		},
		muteFn: func(ctx context.Context, c, tg string) error {
			_, err := graphSvc.Mute(ctx, c, key(c, tg), tg)
			return err
		},
	}
}

func ctxFor(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

func (in *instance) signUp(t *testing.T, uid string) {
	t.Helper()
	if _, err := in.identity.CreateProfile(context.Background(), uid, "0123456789abcdef", "h"+uid, "Name "+uid); err != nil {
		t.Fatalf("CreateProfile %s: %v", uid, err)
	}
}

func (in *instance) post(t *testing.T, uid string, i int) string {
	t.Helper()
	p, err := in.posts.Create(ctxFor(uid), uid, posts.CreateInput{IdempotencyKey: fmt.Sprintf("post-%s-%08d-xxxx", uid, i), Text: fmt.Sprintf("post %d by %s", i, uid)})
	if err != nil {
		t.Fatalf("Create %s/%d: %v", uid, i, err)
	}
	return p.ID
}

// seedFollowing writes the caller's following array directly (follow edges are not under test here).
func seedFollowing(t *testing.T, client *firestore.Client, uid string, following []string) {
	t.Helper()
	if _, err := client.Collection("graph").Doc(uid).Update(context.Background(), []firestore.Update{{Path: "following", Value: following}}); err != nil {
		t.Fatalf("seed following: %v", err)
	}
}

func (in *instance) home(t *testing.T, uid, since, page string, size int32) (*timelinev1.GetHomeTimelineResponse, *budget.Counter, error) {
	t.Helper()
	ctx, c := budget.WithCounter(ctxFor(uid))
	resp, err := in.srv.GetHomeTimeline(ctx, connect.NewRequest(&timelinev1.GetHomeTimelineRequest{PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, c, err
	}
	return resp.Msg, c, nil
}

func (in *instance) user(t *testing.T, uid, target string, since, page string, size int32) (*timelinev1.GetUserTimelineResponse, *budget.Counter, error) {
	t.Helper()
	ctx, c := budget.WithCounter(ctxFor(uid))
	resp, err := in.srv.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: target, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, c, err
	}
	return resp.Msg, c, nil
}

// warm primes the caller's graph cache outside the measured call (the documented "graph warm" cases).
func (in *instance) warm(t *testing.T, uid string) {
	t.Helper()
	if _, err := in.graph.Snapshot(ctxFor(uid), uid); err != nil {
		t.Fatal(err)
	}
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

// world signs up "me" and f1..fn (each follows nothing) and seeds me.following = f1..fn.
func world(t *testing.T, in *instance, n int) []string {
	t.Helper()
	in.signUp(t, "me")
	var fs []string
	for i := 1; i <= n; i++ {
		u := fmt.Sprintf("f%d", i)
		in.signUp(t, u)
		fs = append(fs, u)
	}
	seedFollowing(t, in.client, "me", fs)
	return fs
}

// F = 60, page 20: cold open <= 2 + 3*14 = 44 (43 without the interceptor); the same refresh with 0 new posts on
// a fresh instance (author-recent empty, graph warm) is exactly C = 3 reads; a refresh with new posts costs
// C + new; an own post appears on the next refresh with 0 queries (author-recent updated in place).
func TestHome_Integration_F60ColdRefreshAndOwnPost(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	fs := world(t, seed, 60)
	var seeded []string
	for i, f := range fs {
		if i%2 == 0 {
			seeded = append(seeded, seed.post(t, f, 1), seed.post(t, f, 2))
		}
	}

	in := newInstance(t, client) // cold instance
	resp, c, err := in.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetHomeTimeline cold F=60 p=20", c, budgettest.Budget{Reads: 43})
	t.Logf("BUDGET GetHomeTimeline cold F=60 p=20 reads=%d (ceiling 43 + interceptor)", c.Reads())
	// A cold page may be short (ADR-0004 exact-prefix cut; the client follows next_page_token).
	if len(resp.Posts) == 0 || len(resp.Posts) > 20 || resp.NextPageToken == "" || resp.SinceToken == "" {
		t.Fatalf("cold page: %d posts next=%q since=%q", len(resp.Posts), resp.NextPageToken, resp.SinceToken)
	}
	// Strictly descending by id (ids are Snowflakes, so id order is time order).
	ids := homeIDs(resp)
	for i := 1; i < len(ids); i++ {
		if ids[i-1] <= ids[i] {
			t.Fatalf("not descending at %d: %s then %s", i, ids[i-1], ids[i])
		}
	}

	// Walk the whole feed once: every seeded post exactly once.
	seen := map[string]bool{}
	for _, id := range ids {
		seen[id] = true
	}
	for tok := resp.NextPageToken; tok != ""; {
		page, _, err := in.home(t, "me", "", tok, 20)
		if err != nil {
			t.Fatal(err)
		}
		for _, id := range homeIDs(page) {
			if seen[id] {
				t.Fatalf("duplicate %s", id)
			}
			seen[id] = true
		}
		tok = page.NextPageToken
	}
	if len(seen) != len(seeded) {
		t.Fatalf("walked %d posts, want %d", len(seen), len(seeded))
	}

	// The cold since is clamped to the settle watermark (the posts are < 15 s old), so the first refresh, run on an
	// instance whose clock is 5 minutes ahead, re-delivers them (the client dedupes) and moves since past them.
	later := func() time.Time { return time.Now().Add(5 * time.Minute) }
	a := newInstanceAt(t, client, later)
	a.warm(t, "me")
	ra, _, err := a.home(t, "me", resp.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(ra.Posts) == 0 {
		t.Fatal("the clamped since should re-deliver the recent posts")
	}
	// Refresh with 0 new posts on a fresh instance: author-recent empty, graph warm => exactly C.
	b := newInstanceAt(t, client, later)
	b.warm(t, "me")
	r0, c0, err := b.home(t, "me", ra.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if c0.Reads() != 3 || len(r0.Posts) != 0 {
		t.Fatalf("refresh with nothing new: reads = %d posts = %d, want C = 3 and 0 posts", c0.Reads(), len(r0.Posts))
	}
	t.Logf("BUDGET GetHomeTimeline refresh 0 new F=60 reads=%d (C=3, graph warm)", c0.Reads())

	// A new post by a followee: one chunk returns it instead of an empty result, so reads stay C (+1 per extra doc).
	newID := b.post(t, fs[0], 3)
	d := newInstanceAt(t, client, later)
	d.warm(t, "me")
	r1, c1, err := d.home(t, "me", ra.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, id := range homeIDs(r1) {
		found = found || id == newID
	}
	if !found {
		t.Fatalf("new post %s missing from the refresh", newID)
	}
	if c1.Reads() > 4 {
		t.Fatalf("refresh with 1 new post: reads = %d, want <= C + 1 = 4", c1.Reads())
	}
}

// A small feed: no chunk fills k, so a cold open caches every author (empty ones too). A post by the caller through
// the same instance's posts service updates the entry in place, and the next refresh runs 0 queries and 0 reads.
func TestHome_Integration_OwnPostUpdatesAuthorRecentInPlace(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	fs := world(t, seed, 5)
	seed.post(t, fs[0], 1)
	seed.post(t, fs[1], 1)

	warm := newInstance(t, client)
	open, _, err := warm.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(open.Posts) != 2 {
		t.Fatalf("cold open = %d posts, want 2", len(open.Posts))
	}
	mine := warm.post(t, "me", 99)
	warm.warm(t, "me")
	r2, c2, err := warm.home(t, "me", open.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if c2.Reads() != 0 {
		t.Fatalf("refresh after an own post: reads = %d, want 0", c2.Reads())
	}
	hit := false
	for _, id := range homeIDs(r2) {
		hit = hit || id == mine
	}
	if !hit {
		t.Fatal("own post missing from the next refresh")
	}
}

// ADR-0010 D6 home column with the real graph: muted and blocked-by authors never appear, even when a stale
// `following` still lists them; the blocked author is gone as well (the block removed the edge).
func TestHome_Integration_BlockAndMuteMatrix(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	in.signUp(t, "me")
	var fs []string
	ctx := context.Background()
	for i := 1; i <= 4; i++ { // f1 muted, f2 blocks me, f3 blocked by me (via Block), f4 plain
		u := fmt.Sprintf("f%d", i)
		in.signUp(t, u)
		in.post(t, u, 1)
		if err := in.followFn(ctx, "me", u); err != nil {
			t.Fatal(err)
		}
		fs = append(fs, u)
	}
	if err := in.muteFn(ctx, "me", "f1"); err != nil {
		t.Fatal(err)
	}
	// f2 blocks me while my (stale) following still lists f2.
	if err := in.blockFn(ctx, "f2", "me"); err != nil {
		t.Fatal(err)
	}
	if err := in.blockFn(ctx, "me", "f3"); err != nil {
		t.Fatal(err)
	}
	seedFollowing(t, client, "me", fs) // restore the stale following that lists every author

	fresh := newInstance(t, client)
	resp, _, err := fresh.home(t, "me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, v := range resp.Posts {
		got[v.Post.Author.UserId] = true
	}
	if len(got) != 1 || !got["f4"] {
		t.Fatalf("home authors = %v, want only f4", got)
	}
}

// F = 5,000 (a seeded graph doc, 8 of the followees have posts): worst-case reads <= 2 + C + 2p = 269 (268 without
// the interceptor), C = 167, at most 4 queries in flight, and the call is fast on the emulator.
func TestHome_Integration_WorstCaseAtTheFollowingCap(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	in.signUp(t, "me")
	var following []string
	for i := 0; i < 5000; i++ {
		following = append(following, fmt.Sprintf("ghost%05d", i))
	}
	for i := 0; i < 8; i++ {
		u := fmt.Sprintf("real%d", i)
		in.signUp(t, u)
		in.post(t, u, 1)
		following[i*600] = u
	}
	seedFollowing(t, client, "me", following)

	cold := newInstance(t, client)
	start := time.Now()
	resp, c, err := cold.home(t, "me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	took := time.Since(start)
	budgettest.Assert(t, "GetHomeTimeline F=5000 p=50", c, budgettest.Budget{Reads: 268})
	// k = 1 per chunk, and every chunk holding a post filled it, so the exact prefix is short: at least the newest
	// post, with a next_page_token to continue (ADR-0004 decision 3).
	if len(resp.Posts) == 0 || resp.NextPageToken == "" {
		t.Fatalf("posts = %d next=%q, want a short non-empty page with a next token", len(resp.Posts), resp.NextPageToken)
	}
	t.Logf("BUDGET GetHomeTimeline F=5000 p=50 reads=%d took=%v (local emulator)", c.Reads(), took)
	if took > 2*time.Second {
		t.Fatalf("worst case took %v on the emulator, want < 2 s", took)
	}
}

func TestHome_Integration_FollowingBoundaries(t *testing.T) {
	for _, tc := range []struct {
		f      int
		chunks int64
	}{{29, 1}, {30, 2}, {31, 2}} {
		t.Run(fmt.Sprintf("F=%d", tc.f), func(t *testing.T) {
			client := newClient(t)
			in := newInstance(t, client)
			in.signUp(t, "me")
			var fs []string
			for i := 0; i < tc.f; i++ {
				fs = append(fs, fmt.Sprintf("ghost%03d", i))
			}
			seedFollowing(t, client, "me", fs)
			cold := newInstance(t, client)
			_, c, err := cold.home(t, "me", "", "", 20)
			if err != nil {
				t.Fatal(err)
			}
			// graph (1) + one empty read per chunk.
			if c.Reads() != 1+tc.chunks {
				t.Fatalf("reads = %d, want %d", c.Reads(), 1+tc.chunks)
			}
		})
	}
}

func TestUser_Integration_PagesBudgetAndWarmCache(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	seed.signUp(t, "me")
	seed.signUp(t, "bob")
	seed.signUp(t, "carol")
	for i := 0; i < 45; i++ {
		seed.post(t, "bob", i)
	}
	for i := 0; i < 40; i++ {
		seed.post(t, "carol", i)
	}

	in := newInstance(t, client)
	p1, c1, err := in.user(t, "me", "bob", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	// target users (1) + caller graph (1) + Limit(20) = 22; with the interceptor 3 + p = 23.
	budgettest.Assert(t, "GetUserTimeline cold p=20", c1, budgettest.Budget{Reads: 22})
	t.Logf("BUDGET GetUserTimeline cold p=20 reads=%d (ceiling 22 + interceptor)", c1.Reads())
	if len(p1.Posts) != 20 || p1.NextPageToken == "" {
		t.Fatalf("page 1: %d posts next=%q", len(p1.Posts), p1.NextPageToken)
	}
	// Warm first page: everything from caches, 0 reads.
	w, cw, err := in.user(t, "me", "bob", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetUserTimeline warm first page", cw, budgettest.Budget{Reads: 0})
	if fmt.Sprint(userIDs(w)) != fmt.Sprint(userIDs(p1)) {
		t.Fatal("cache-served first page differs from the queried one")
	}

	seen := map[string]bool{}
	var calls int
	for tok := ""; ; {
		calls++
		page, _, err := in.user(t, "me", "bob", "", tok, 20)
		if err != nil {
			t.Fatal(err)
		}
		for _, id := range userIDs(page) {
			if seen[id] {
				t.Fatalf("duplicate %s", id)
			}
			seen[id] = true
		}
		if tok = page.NextPageToken; tok == "" {
			break
		}
	}
	if len(seen) != 45 || calls != 3 {
		t.Fatalf("45 posts: covered %d in %d calls, want 45 in 3", len(seen), calls)
	}

	// Exactly 40 posts: page 3 is empty, has no next token and costs 1 query read (users + graph warm).
	tok := ""
	for i := 0; i < 2; i++ {
		page, _, err := in.user(t, "me", "carol", "", tok, 20)
		if err != nil {
			t.Fatal(err)
		}
		tok = page.NextPageToken
	}
	last, cl, err := in.user(t, "me", "carol", "", tok, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(last.Posts) != 0 || last.NextPageToken != "" || cl.Reads() != 1 {
		t.Fatalf("empty final page: %d posts next=%q reads=%d, want 0 / \"\" / 1", len(last.Posts), last.NextPageToken, cl.Reads())
	}

	// A refresh on a cold instance whose clock is 5 minutes ahead (past the settle window): the clamped since
	// re-delivers the recent posts; the next one has nothing new and costs users + graph + 1 empty query = 3 reads.
	later := func() time.Time { return time.Now().Add(5 * time.Minute) }
	a := newInstanceAt(t, client, later)
	ra, _, err := a.user(t, "me", "bob", p1.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	b := newInstanceAt(t, client, later)
	r0, c0, err := b.user(t, "me", "bob", ra.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetUserTimeline cold refresh, 0 new", c0, budgettest.Budget{Reads: 3})
	if len(r0.Posts) != 0 {
		t.Fatalf("refresh with nothing new returned %d posts", len(r0.Posts))
	}

	// A page of 50 stays within 3 + p (52 without the interceptor).
	big, c50, err := newInstance(t, client).user(t, "me", "bob", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetUserTimeline cold p=50", c50, budgettest.Budget{Reads: 52})
	if len(big.Posts) != 45 || big.NextPageToken != "" {
		t.Fatalf("p=50: %d posts next=%q", len(big.Posts), big.NextPageToken)
	}
}

// D6 GetUserTimeline column: a blocking and a missing target are one NOT_FOUND; a caller who blocks or mutes the
// target still gets posts.
func TestUser_Integration_VisibilityMatrix(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	for _, u := range []string{"me", "blocker", "blocked", "muted", "plain"} {
		in.signUp(t, u)
		if u != "me" {
			in.post(t, u, 1)
		}
	}
	ctx := context.Background()
	if err := in.blockFn(ctx, "blocker", "me"); err != nil {
		t.Fatal(err)
	}
	if err := in.blockFn(ctx, "me", "blocked"); err != nil {
		t.Fatal(err)
	}
	if err := in.muteFn(ctx, "me", "muted"); err != nil {
		t.Fatal(err)
	}

	cold := newInstance(t, client)
	_, _, errBlock := cold.user(t, "me", "blocker", "", "", 20)
	_, _, errMissing := cold.user(t, "me", "nobody", "", "", 20)
	var a, b *apierr.Error
	if !errors.As(errBlock, &a) || !errors.As(errMissing, &b) {
		t.Fatalf("errors = %v / %v, want NOT_FOUND both", errBlock, errMissing)
	}
	if a.Code != connect.CodeNotFound || a.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED || a.Message != "profile not found" ||
		a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message {
		t.Fatalf("blocked %v differs from missing %v", a, b)
	}
	for _, target := range []string{"blocked", "muted", "plain"} {
		resp, _, err := cold.user(t, "me", target, "", "", 20)
		if err != nil || len(resp.Posts) != 1 {
			t.Fatalf("%s: err=%v posts=%d, want 1", target, err, len(resp.GetPosts()))
		}
	}
}

// Tokens older than 24 h but inside TIMELINE_TOKEN_TTL are accepted through the real codec (a server whose clock is
// 25 h ahead opens a token sealed now); 31 days later it is VALIDATION since_token with 0 reads.
func TestHome_Integration_TokenTTL(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2)
	resp, _, err := in.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	later := newInstanceAt(t, client, func() time.Time { return time.Now().Add(25 * time.Hour) })
	if _, _, err := later.home(t, "me", resp.SinceToken, "", 20); err != nil {
		t.Fatalf("25 h old since token rejected: %v", err)
	}
	way := newInstanceAt(t, client, func() time.Time { return time.Now().Add(31 * 24 * time.Hour) })
	_, c, err := way.home(t, "me", resp.SinceToken, "", 20)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "since_token" || c.Reads() != 0 {
		t.Fatalf("31 d old token: err=%v reads=%d, want VALIDATION since_token with 0 reads", err, c.Reads())
	}
}

// ADR-0010 D6 home column with real status and graph data: SUSPENDED, DELETING and users-doc-missing authors stay
// (D10: the home never reads status, so the reads are exactly graph + the returned docs), a both-block author is
// dropped even though a stale `following` lists them, a non-followed author is absent, and a caller whose
// blockedByOverflow is set pays no extra read.
func TestHome_Integration_D6Matrix(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	ctx := context.Background()
	for _, u := range []string{"me", "plain", "susp", "del", "gone", "both", "stranger"} {
		seed.signUp(t, u)
		if u != "me" {
			seed.post(t, u, 1)
		}
	}
	followed := []string{"plain", "susp", "del", "gone", "both"}
	for _, u := range followed {
		if err := seed.followFn(ctx, "me", u); err != nil {
			t.Fatal(err)
		}
	}
	if err := seed.blockFn(ctx, "me", "both"); err != nil {
		t.Fatal(err)
	}
	if err := seed.blockFn(ctx, "both", "me"); err != nil {
		t.Fatal(err)
	}
	seedFollowing(t, client, "me", followed) // stale following that still lists the both-block author
	for u, status := range map[string]string{"susp": "SUSPENDED", "del": "DELETING"} {
		if _, err := client.Collection("users").Doc(u).Update(ctx, []firestore.Update{{Path: "status", Value: status}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.Collection("users").Doc("gone").Delete(ctx); err != nil {
		t.Fatal(err)
	}

	check := func(name string, in *instance) int64 {
		t.Helper()
		resp, c, err := in.home(t, "me", "", "", 50)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for _, v := range resp.Posts {
			got[v.Post.Author.UserId] = true
		}
		for _, a := range []string{"plain", "susp", "del", "gone"} {
			if !got[a] {
				t.Errorf("%s: home is missing %s (status/doc state must not filter)", name, a)
			}
		}
		for _, a := range []string{"both", "stranger", "me"} {
			if got[a] {
				t.Errorf("%s: home shows %s", name, a)
			}
		}
		// graph (1) + one chunk returning the 4 docs; a status read would add 1.
		budgettest.Assert(t, "GetHomeTimeline D6 "+name, c, budgettest.Budget{Reads: 1 + 4})
		return c.Reads()
	}
	base := check("baseline", newInstance(t, client))

	if _, err := client.Collection("graph").Doc("me").Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	if over := check("blockedByOverflow caller", newInstance(t, client)); over != base {
		t.Fatalf("overflow caller reads = %d, want the same %d as without overflow (no extra read)", over, base)
	}
}

// Older home page at F = 5,000 with every chunk dense (167 chunks, each holding 2 posts, so k=1 chunks fill and
// the older page queries them all): the older page stays within 2 + C + 2p = 269 (268 without the interceptor).
func TestHome_Integration_OlderPageAtTheFollowingCap(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	seed.signUp(t, "me")
	following := make([]string, 5000)
	for i := range following {
		following[i] = fmt.Sprintf("u%05d", i)
	}
	// authors = me + sorted(following): index i+1, chunk (i+1)/30; i = 30j+15 puts one real author in every chunk.
	for j := 0; 30*j+15 < len(following); j++ {
		u := following[30*j+15]
		seed.signUp(t, u)
		seed.post(t, u, 1)
		seed.post(t, u, 2)
	}
	seedFollowing(t, client, "me", following)

	first, c1, err := newInstance(t, client).home(t, "me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetHomeTimeline dense F=5000 first page", c1, budgettest.Budget{Reads: 268})
	if len(first.Posts) == 0 || first.NextPageToken == "" {
		t.Fatalf("first page: %d posts next=%q, want a short page with a next token", len(first.Posts), first.NextPageToken)
	}
	older, c2, err := newInstance(t, client).home(t, "me", "", first.NextPageToken, 50)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetHomeTimeline dense F=5000 older page", c2, budgettest.Budget{Reads: 268})
	if len(older.Posts) == 0 {
		t.Fatal("older page returned no posts")
	}
	if older.SinceToken != "" {
		t.Fatal("an older page must not carry a since_token")
	}
	seen := map[string]bool{}
	for _, id := range homeIDs(first) {
		seen[id] = true
	}
	for _, id := range homeIDs(older) {
		if seen[id] {
			t.Fatalf("older page repeats %s", id)
		}
	}
	t.Logf("BUDGET GetHomeTimeline dense F=5000 first reads=%d older reads=%d (ceiling 268 + interceptor)", c1.Reads(), c2.Reads())
}

// A cold first page with p < 20 still fills the 20-entry author-recent query: 3 + max(p, 20), i.e. 22 here.
func TestUser_Integration_ColdSmallPageBudget(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	seed.signUp(t, "me")
	seed.signUp(t, "bob")
	for i := 0; i < 25; i++ {
		seed.post(t, "bob", i)
	}
	resp, c, err := newInstance(t, client).user(t, "me", "bob", "", "", 5)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetUserTimeline cold p=5", c, budgettest.Budget{Reads: 22})
	if len(resp.Posts) != 5 || resp.NextPageToken == "" {
		t.Fatalf("p=5: %d posts next=%q, want 5 and a next token", len(resp.Posts), resp.NextPageToken)
	}
	t.Logf("BUDGET GetUserTimeline cold p=5 reads=%d (ceiling 22 + interceptor)", c.Reads())
}

// TestModeration_Integration_HiddenPostsLeaveEveryFeedAtNoExtraReads is ADR-0016 acceptance 3 and 4: a takedown and a
// suspension (HideAuthor) remove posts from Home and the profile timeline as seen by a cold instance (the cache TTL
// bound), the hidden documents are the only extra cost (0 extra reads), and a restore brings exactly them back.
func TestModeration_Integration_HiddenPostsLeaveEveryFeedAtNoExtraReads(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2) // me follows f1, f2
	p11, _ := in.post(t, "f1", 1), in.post(t, "f1", 2)
	_, _ = in.post(t, "f2", 1), in.post(t, "f2", 2)

	resp, before, err := newInstance(t, client).home(t, "me", "", "", 20)
	if err != nil || len(homeIDs(resp)) != 4 {
		t.Fatalf("baseline home: err=%v ids=%v", err, homeIDs(resp))
	}

	mod := posts.NewFirestoreRepo(client)
	if _, err := mod.Takedown(context.Background(), p11, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, done, err := mod.HideAuthor(context.Background(), "f2", posts.ModerationCheckpoint{}, time.Now()); err != nil || !done {
		t.Fatalf("hide author: done=%v err=%v", done, err)
	}

	cold := newInstance(t, client)
	resp, after, err := cold.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if ids := homeIDs(resp); len(ids) != 1 {
		t.Fatalf("home after moderation = %v, want only f1's second post", ids)
	}
	if after.Reads() > before.Reads() {
		t.Errorf("reads after = %d > before = %d: filtering must not add reads", after.Reads(), before.Reads())
	}
	for _, target := range []string{"f1", "f2"} {
		u, _, err := newInstance(t, client).user(t, "me", target, "", "", 20)
		want := map[string]int{"f1": 1, "f2": 0}[target]
		if err != nil || len(u.GetPosts()) != want {
			t.Fatalf("user %s: err=%v posts=%d, want %d", target, err, len(u.GetPosts()), want)
		}
	}

	if _, err := mod.Restore(context.Background(), p11); err != nil {
		t.Fatal(err)
	}
	if _, done, err := mod.RestoreAuthor(context.Background(), "f2", posts.ModerationCheckpoint{}); err != nil || !done {
		t.Fatalf("restore author: done=%v err=%v", done, err)
	}
	resp, _, err = newInstance(t, client).home(t, "me", "", "", 20)
	if err != nil || len(homeIDs(resp)) != 4 {
		t.Fatalf("home after restore: err=%v ids=%v", err, homeIDs(resp))
	}
}
