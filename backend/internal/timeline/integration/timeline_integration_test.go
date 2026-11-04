//go:build integration

// Package integration runs the timeline RPCs against the Firestore emulator with the real identity, graph and
// posts services, wired the way apiserver.Build wires them. It lives in its own directory so the timeline
// package's import lint (only the posts, graph and identity seams) still covers timeline itself.
//
// These tests call the Connect handler directly, below the interceptors.
package integration

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"slices"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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
	// info holds the request-log fields of the most recent home() call.
	info *logger.RequestInfo
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
	})
	identitySvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithBlockChecker(graphSvc))
	dir := identitySvc.(identity.Directory)
	graphSvc.SetDirectory(dir)

	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := posts.NewFirestoreRepo(client)
	repo.SetWriters(posts.WriteDeps{Idempotency: idempotency.New(client), Counters: identityRepo, IDs: node})
	pcache := posts.NewCache(time.Minute, 20_000, 1_000)
	postsSvc := posts.New(posts.Deps{
		Repo: repo, Cache: pcache, Events: posts.NopEvents{}, Directory: dir, Graph: graphSvc,
	})
	srv := timeline.NewServer(timeline.Deps{
		Flags: allOn{}, Posts: postsSvc, Graph: graphSvc, Directory: dir,
		Removals:  posts.NewRemovalLog(repo, time.Minute, nil, posts.WithAuthorScopedFromForTest(time.Now().Add(-24*time.Hour))),
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

func (in *instance) home(t *testing.T, uid, since, page string, size int32) (*timelinev1.GetHomeTimelineResponse, error) {
	t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(uid))
	in.info = info
	ctx := ictx
	resp, err := in.srv.GetHomeTimeline(ctx, connect.NewRequest(&timelinev1.GetHomeTimelineRequest{PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
}

func (in *instance) user(t *testing.T, uid, target string, since, page string, size int32) (*timelinev1.GetUserTimelineResponse, error) {
	t.Helper()
	ctx := ctxFor(uid)
	resp, err := in.srv.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: target, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
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

// F = 60, page 20: a cold open walks the whole feed once; the same refresh with no new posts on a fresh instance
// (author-recent empty, graph warm) returns nothing; a refresh with new posts returns them.
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
	resp, err := in.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	// A cold page may be short (exact-prefix cut; the client follows next_page_token).
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
		page, err := in.home(t, "me", "", tok, 20)
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
	ra, err := a.home(t, "me", resp.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(ra.Posts) == 0 {
		t.Fatal("the clamped since should re-deliver the recent posts")
	}
	// Refresh with no new posts on a fresh instance: author-recent empty, graph warm.
	b := newInstanceAt(t, client, later)
	b.warm(t, "me")
	r0, err := b.home(t, "me", ra.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(r0.Posts) != 0 {
		t.Fatalf("refresh with nothing new returned %d posts, want 0", len(r0.Posts))
	}

	// A new post by a followee shows up in the refresh.
	newID := b.post(t, fs[0], 3)
	d := newInstanceAt(t, client, later)
	d.warm(t, "me")
	r1, err := d.home(t, "me", ra.SinceToken, "", 20)
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
}

// A small feed: no chunk fills k, so a cold open caches every author (empty ones too). A post by the caller through
// the same instance's posts service updates the entry in place, and the next refresh shows it.
func TestHome_Integration_OwnPostUpdatesAuthorRecentInPlace(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	fs := world(t, seed, 5)
	seed.post(t, fs[0], 1)
	seed.post(t, fs[1], 1)

	warm := newInstance(t, client)
	open, err := warm.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(open.Posts) != 2 {
		t.Fatalf("cold open = %d posts, want 2", len(open.Posts))
	}
	mine := warm.post(t, "me", 99)
	warm.warm(t, "me")
	r2, err := warm.home(t, "me", open.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	hit := false
	for _, id := range homeIDs(r2) {
		hit = hit || id == mine
	}
	if !hit {
		t.Fatal("own post missing from the next refresh")
	}
}

// Home column with the real graph: muted and blocked-by authors never appear, even when a stale
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
	resp, err := fresh.home(t, "me", "", "", 50)
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

// F = 5,000 (a seeded graph doc, 8 of the followees have posts): the call returns a short page with a next token, and
// is fast on the emulator (queries run in bounded parallel).
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
	resp, err := cold.home(t, "me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	took := time.Since(start)
	// k = 1 per chunk, and every chunk holding a post filled it, so the exact prefix is short: at least the newest
	// post, with a next_page_token to continue (decision 3).
	if len(resp.Posts) == 0 || resp.NextPageToken == "" {
		t.Fatalf("posts = %d next=%q, want a short non-empty page with a next token", len(resp.Posts), resp.NextPageToken)
	}
	if took > 2*time.Second {
		t.Fatalf("worst case took %v on the emulator, want < 2 s", took)
	}
}

func TestUser_Integration_PagesAndWarmCache(t *testing.T) {
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
	p1, err := in.user(t, "me", "bob", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Posts) != 20 || p1.NextPageToken == "" {
		t.Fatalf("page 1: %d posts next=%q", len(p1.Posts), p1.NextPageToken)
	}
	// Warm first page: everything from caches.
	w, err := in.user(t, "me", "bob", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(userIDs(w)) != fmt.Sprint(userIDs(p1)) {
		t.Fatal("cache-served first page differs from the queried one")
	}

	seen := map[string]bool{}
	var calls int
	for tok := ""; ; {
		calls++
		page, err := in.user(t, "me", "bob", "", tok, 20)
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

	// Exactly 40 posts: page 3 is empty, has no next token.
	tok := ""
	for i := 0; i < 2; i++ {
		page, err := in.user(t, "me", "carol", "", tok, 20)
		if err != nil {
			t.Fatal(err)
		}
		tok = page.NextPageToken
	}
	last, err := in.user(t, "me", "carol", "", tok, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(last.Posts) != 0 || last.NextPageToken != "" {
		t.Fatalf("empty final page: %d posts next=%q, want 0 and no token", len(last.Posts), last.NextPageToken)
	}

	// A refresh on a cold instance whose clock is 5 minutes ahead (past the settle window): the clamped since
	// re-delivers the recent posts; the next one has nothing new.
	later := func() time.Time { return time.Now().Add(5 * time.Minute) }
	a := newInstanceAt(t, client, later)
	ra, err := a.user(t, "me", "bob", p1.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	b := newInstanceAt(t, client, later)
	r0, err := b.user(t, "me", "bob", ra.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(r0.Posts) != 0 {
		t.Fatalf("refresh with nothing new returned %d posts", len(r0.Posts))
	}

	// A page of 50 returns every post.
	big, err := newInstance(t, client).user(t, "me", "bob", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
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
	_, errBlock := cold.user(t, "me", "blocker", "", "", 20)
	_, errMissing := cold.user(t, "me", "nobody", "", "", 20)
	var a, b *apierr.Error
	if !errors.As(errBlock, &a) || !errors.As(errMissing, &b) {
		t.Fatalf("errors = %v / %v, want NOT_FOUND both", errBlock, errMissing)
	}
	if a.Code != connect.CodeNotFound || a.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED || a.Message != "profile not found" ||
		a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message {
		t.Fatalf("blocked %v differs from missing %v", a, b)
	}
	for _, target := range []string{"blocked", "muted", "plain"} {
		resp, err := cold.user(t, "me", target, "", "", 20)
		if err != nil || len(resp.Posts) != 1 {
			t.Fatalf("%s: err=%v posts=%d, want 1", target, err, len(resp.GetPosts()))
		}
	}
}

// Tokens older than 24 h but inside TIMELINE_TOKEN_TTL are accepted through the real codec (a server whose clock is
// 25 h ahead opens a token sealed now); 31 days later it is VALIDATION since_token.
func TestHome_Integration_TokenTTL(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2)
	resp, err := in.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	later := newInstanceAt(t, client, func() time.Time { return time.Now().Add(25 * time.Hour) })
	if _, err := later.home(t, "me", resp.SinceToken, "", 20); err != nil {
		t.Fatalf("25 h old since token rejected: %v", err)
	}
	way := newInstanceAt(t, client, func() time.Time { return time.Now().Add(31 * 24 * time.Hour) })
	_, err = way.home(t, "me", resp.SinceToken, "", 20)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "since_token" {
		t.Fatalf("31 d old token: err=%v, want VALIDATION since_token", err)
	}
}

// Home column with real status and graph data: SUSPENDED, DELETING and users-doc-missing authors stay
// (the home never reads status), a both-block author is dropped even though a stale `following` lists them, a
// non-followed author is absent, and a caller whose blockedByOverflow is set sees the same authors.
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

	check := func(name string, in *instance) []string {
		t.Helper()
		resp, err := in.home(t, "me", "", "", 50)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		var authors []string
		for _, v := range resp.Posts {
			got[v.Post.Author.UserId] = true
			authors = append(authors, v.Post.Author.UserId)
		}
		slices.Sort(authors)
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
		return authors
	}
	base := check("baseline", newInstance(t, client))

	if _, err := client.Collection("graph").Doc("me").Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	if over := check("blockedByOverflow caller", newInstance(t, client)); !slices.Equal(over, base) {
		t.Fatalf("overflow caller sees authors %v, want the same %v as without overflow", over, base)
	}
}

// Older home page at F = 5,000 with every chunk dense (167 chunks, each holding 2 posts, so k=1 chunks fill and
// the older page queries them all): the older page returns posts, repeats none of the first page, and carries no
// since_token.
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

	first, err := newInstance(t, client).home(t, "me", "", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Posts) == 0 || first.NextPageToken == "" {
		t.Fatalf("first page: %d posts next=%q, want a short page with a next token", len(first.Posts), first.NextPageToken)
	}
	older, err := newInstance(t, client).home(t, "me", "", first.NextPageToken, 50)
	if err != nil {
		t.Fatal(err)
	}
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
}

// A cold first page with p < 20 still fills the 20-entry author-recent query, and a smaller page is cut from it.
func TestUser_Integration_ColdSmallPage(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	seed.signUp(t, "me")
	seed.signUp(t, "bob")
	for i := 0; i < 25; i++ {
		seed.post(t, "bob", i)
	}
	resp, err := newInstance(t, client).user(t, "me", "bob", "", "", 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Posts) != 5 || resp.NextPageToken == "" {
		t.Fatalf("p=5: %d posts next=%q, want 5 and a next token", len(resp.Posts), resp.NextPageToken)
	}
}

// TestModeration_Integration_HiddenPostsLeaveEveryFeed checks that a takedown and a
// suspension (HideAuthor) remove posts from Home and the profile timeline as seen by a cold instance (the cache TTL
// bound), and a restore brings exactly them back.
func TestModeration_Integration_HiddenPostsLeaveEveryFeed(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2) // me follows f1, f2
	p11, _ := in.post(t, "f1", 1), in.post(t, "f1", 2)
	_, _ = in.post(t, "f2", 1), in.post(t, "f2", 2)

	resp, err := newInstance(t, client).home(t, "me", "", "", 20)
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
	resp, err = cold.home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if ids := homeIDs(resp); len(ids) != 1 {
		t.Fatalf("home after moderation = %v, want only f1's second post", ids)
	}
	for _, target := range []string{"f1", "f2"} {
		u, err := newInstance(t, client).user(t, "me", target, "", "", 20)
		want := map[string]int{"f1": 1, "f2": 0}[target]
		if err != nil || len(u.GetPosts()) != want {
			t.Fatalf("user %s: err=%v posts=%d, want %d", target, err, len(u.GetPosts()), want)
		}
	}

	if _, err := mod.Restore(context.Background(), p11, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, done, err := mod.RestoreAuthor(context.Background(), "f2", posts.ModerationCheckpoint{}, time.Now()); err != nil || !done {
		t.Fatalf("restore author: done=%v err=%v", done, err)
	}
	resp, err = newInstance(t, client).home(t, "me", "", "", 20)
	if err != nil || len(homeIDs(resp)) != 4 {
		t.Fatalf("home after restore: err=%v ids=%v", err, homeIDs(resp))
	}
}

// TestModeration_Integration_RemovedIDsReachRefreshingClients checks removed_ids end to end on the emulator: a post
// hidden by opsctl's writers (takedown, suspension) is listed in removed_ids of the next refresh of a client whose
// since token was issued before the hide, on both timelines, and not for a client whose token was issued after
// (beyond the lag that covers stale caches). A restored post is not listed. Cold opens and page calls never carry it.
func TestModeration_Integration_RemovedIDsReachRefreshingClients(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2) // me follows f1, f2
	p11, p12 := in.post(t, "f1", 1), in.post(t, "f1", 2)
	p21 := in.post(t, "f2", 1)

	// The client opens the feeds before the moderator acts: these are its since tokens.
	coldHome, err := newInstance(t, client).home(t, "me", "", "", 20)
	if err != nil || len(coldHome.GetRemovedIds()) != 0 || coldHome.GetSinceToken() == "" {
		t.Fatalf("cold home: err=%v removed=%v", err, coldHome.GetRemovedIds())
	}
	coldUser, err := newInstance(t, client).user(t, "me", "f1", "", "", 20)
	if err != nil || len(coldUser.GetRemovedIds()) != 0 {
		t.Fatalf("cold user: err=%v removed=%v", err, coldUser.GetRemovedIds())
	}

	mod := posts.NewFirestoreRepo(client)
	if _, err := mod.Takedown(context.Background(), p11, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, done, err := mod.HideAuthor(context.Background(), "f2", posts.ModerationCheckpoint{}, time.Now()); err != nil || !done {
		t.Fatalf("hide author: done=%v err=%v", done, err)
	}

	// A client whose token predates the hide: a fresh instance (cold log cache) lists both.
	resp, err := newInstance(t, client).home(t, "me", coldHome.GetSinceToken(), "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.GetRemovedIds(); len(got) != 2 || !contains(got, p11) || !contains(got, p21) || contains(got, p12) {
		t.Fatalf("home removed_ids = %v, want {%s, %s}", got, p11, p21)
	}
	uresp, err := newInstance(t, client).user(t, "me", "f1", coldUser.GetSinceToken(), "", 20)
	if err != nil || !contains(uresp.GetRemovedIds(), p11) {
		t.Fatalf("user removed_ids = %v err=%v, want it to list %s", uresp.GetRemovedIds(), err, p11)
	}

	// Other modes never carry removed_ids.
	if page, err := newInstance(t, client).home(t, "me", "", "", 20); err != nil || len(page.GetRemovedIds()) != 0 {
		t.Fatalf("cold open after the hide: err=%v removed=%v", err, page.GetRemovedIds())
	}

	// A client whose token was issued well after the hide (beyond the lag) is not told again. The timeline clocks
	// of the instance that issues the token and of the one that serves the refresh are 10 and 11 minutes ahead.
	later := func(d time.Duration) func() time.Time { return func() time.Time { return time.Now().Add(d) } }
	issued, err := newInstanceAt(t, client, later(10*time.Minute)).home(t, "me", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	after, err := newInstanceAt(t, client, later(11*time.Minute)).home(t, "me", issued.GetSinceToken(), "", 20)
	if err != nil || len(after.GetRemovedIds()) != 0 {
		t.Fatalf("token issued after the hide: err=%v removed=%v, want none", err, after.GetRemovedIds())
	}

	// Restores overwrite the entries: a client with the old token is no longer told to drop the posts.
	if _, err := mod.Restore(context.Background(), p11, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, done, err := mod.RestoreAuthor(context.Background(), "f2", posts.ModerationCheckpoint{}, time.Now()); err != nil || !done {
		t.Fatalf("restore author: done=%v err=%v", done, err)
	}
	resp, err = newInstance(t, client).home(t, "me", coldHome.GetSinceToken(), "", 20)
	if err != nil || len(resp.GetRemovedIds()) != 0 {
		t.Fatalf("after restore: err=%v removed=%v, want none", err, resp.GetRemovedIds())
	}
}

// TestModeration_Integration_SuspensionOfAnUnfollowedUserDoesNotResetOthers is the RID-2 regression end to end
// (amendment 2026-10-18 (b)): suspending a 60-post account (more than one response can list) neither
// rejects the since_token of a viewer who does not follow it nor leaks a single id into removed_ids, on a cold
// instance too; a viewer of that account's own profile is told to reset, and a followed author's takedown is still
// delivered through the same cold cache.
func TestModeration_Integration_SuspensionOfAnUnfollowedUserDoesNotResetOthers(t *testing.T) {
	client := newClient(t)
	in := newInstance(t, client)
	world(t, in, 2) // me follows f1, f2
	in.signUp(t, "spam")
	p11 := in.post(t, "f1", 1)

	coldHome, err := newInstance(t, client).home(t, "me", "", "", 20)
	if err != nil || coldHome.GetSinceToken() == "" {
		t.Fatalf("cold home: err=%v", err)
	}
	coldSpam, err := newInstance(t, client).user(t, "me", "spam", "", "", 20)
	if err != nil {
		t.Fatalf("cold user: %v", err)
	}

	// 60 posts by the account that will be suspended, written straight to the collection (the post quota is not under test).
	for i := range 60 {
		id := fmt.Sprintf("%019d", 9_000_000_000_000_000_000+int64(i))
		if _, err := client.Collection("posts").Doc(id).Set(context.Background(), map[string]any{"authorId": "spam", "createdAt": time.Now(), "kind": "POST"}); err != nil {
			t.Fatal(err)
		}
	}
	mod := posts.NewFirestoreRepo(client)
	if _, done, err := mod.HideAuthor(context.Background(), "spam", posts.ModerationCheckpoint{}, time.Now()); err != nil || !done {
		t.Fatalf("hide author: done=%v err=%v", done, err)
	}
	if _, err := mod.Takedown(context.Background(), p11, time.Now()); err != nil {
		t.Fatal(err)
	}

	resp, err := newInstance(t, client).home(t, "me", coldHome.GetSinceToken(), "", 20)
	if err != nil {
		t.Fatalf("a suspension of a user the viewer does not follow reset the viewer's feed: %v", err)
	}
	if got := resp.GetRemovedIds(); len(got) != 1 || got[0] != p11 {
		t.Fatalf("home removed_ids = %v, want only the followed author's takedown %s", got, p11)
	}

	_, err = newInstance(t, client).user(t, "me", "spam", coldSpam.GetSinceToken(), "", 20)
	if err == nil {
		t.Fatal("the suspended account's own profile feed must be reset (60 ids cannot be listed)")
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

// userTab is user() with the tab field.
func (in *instance) userTab(t *testing.T, uid, target string, tab timelinev1.UserTimelineTab, since, page string, size int32) (*timelinev1.GetUserTimelineResponse, error) {
	t.Helper()
	return in.userTabOn(t, in.srv, uid, target, tab, since, page, size)
}

func (in *instance) userTabOn(t *testing.T, srv *timeline.Server, uid, target string, tab timelinev1.UserTimelineTab, since, page string, size int32) (*timelinev1.GetUserTimelineResponse, error) {
	t.Helper()
	ctx := ctxFor(uid)
	resp, err := srv.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: target, Tab: tab, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
}

// Against the real posts repo: the Media tab is the author's hasMedia posts (replies and quotes with
// images included), the Reposts tab the author's REPOST items, both newest first, one Limit(page) query each with no
// instance cache. The same tabs through the real interceptor chain are in
// internal/apiserver/profile_tabs_integration_test.go. The emulator does not enforce the
// two composite indexes, so this proves the query shape and the window, not index coverage.
func TestUser_Integration_MediaAndRepostsTabs(t *testing.T) {
	client := newClient(t)
	seed := newInstance(t, client)
	seed.signUp(t, "me")
	seed.signUp(t, "bob")
	ctx := context.Background()
	var media, reposts []string // oldest first
	for i := 0; i < 60; i++ {
		id := seed.post(t, "bob", i)
		doc := client.Collection("posts").Doc(id)
		switch {
		case i%2 == 0:
			if _, err := doc.Update(ctx, []firestore.Update{{Path: "hasMedia", Value: true}}); err != nil {
				t.Fatal(err)
			}
			media = append(media, id)
		case i%10 == 1: // 6 reposts of someone else's post
			upd := []firestore.Update{
				{Path: "kind", Value: "REPOST"},
				{Path: "embeddedAuthorId", Value: "uid-other"},
				{Path: "embedded", Value: map[string]any{"postId": "9", "author": map[string]any{"userId": "uid-other", "handle": "other"}, "text": "copy"}},
			}
			if _, err := doc.Update(ctx, upd); err != nil {
				t.Fatal(err)
			}
			reposts = append(reposts, id)
		}
	}
	rev := func(xs []string) []string {
		out := make([]string, len(xs))
		for i, x := range xs {
			out[len(xs)-1-i] = x
		}
		return out
	}
	tabMedia, tabReposts := timelinev1.UserTimelineTab_USER_TIMELINE_TAB_MEDIA, timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPOSTS

	in := newInstance(t, client)
	p1, err := in.userTab(t, "me", "bob", tabMedia, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := userIDs(p1); fmt.Sprint(got) != fmt.Sprint(rev(media)[:20]) || p1.NextPageToken == "" {
		t.Fatalf("media page 1 = %v next=%q, want the newest 20 media posts and a token", got, p1.NextPageToken)
	}
	// No instance cache: a warm repeat queries the 20 rows again.
	_, err = in.userTab(t, "me", "bob", tabMedia, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	p2, err := in.userTab(t, "me", "bob", tabMedia, "", p1.NextPageToken, 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := userIDs(p2); fmt.Sprint(got) != fmt.Sprint(rev(media)[20:]) || p2.NextPageToken != "" {
		t.Fatalf("media page 2 = %v next=%q, want the last 10 media posts and no token", got, p2.NextPageToken)
	}
	_, err = newInstance(t, client).userTab(t, "me", "bob", tabMedia, "", "", 50)
	if err != nil {
		t.Fatal(err)
	}

	r1, err := newInstance(t, client).userTab(t, "me", "bob", tabReposts, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := userIDs(r1); fmt.Sprint(got) != fmt.Sprint(rev(reposts)) || r1.NextPageToken != "" {
		t.Fatalf("reposts = %v next=%q, want the 6 reposts newest first and no token", got, r1.NextPageToken)
	}

	// A Posts-tab token (and a Media token) is VALIDATION on the other tab.
	posts1, err := in.user(t, "me", "bob", "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct {
		tab         timelinev1.UserTimelineTab
		since, page string
		field       string
	}{
		"posts page token on media":   {tabMedia, "", posts1.NextPageToken, "page_token"},
		"posts since token on media":  {tabMedia, posts1.SinceToken, "", "since_token"},
		"media page token on reposts": {tabReposts, "", p1.NextPageToken, "page_token"},
		"media since token on posts":  {timelinev1.UserTimelineTab_USER_TIMELINE_TAB_POSTS, p1.SinceToken, "", "since_token"},
	} {
		_, err := in.userTab(t, "me", "bob", tc.tab, tc.since, tc.page, 20)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != tc.field {
			t.Fatalf("%s: err=%v, want VALIDATION field=%s", name, err, tc.field)
		}
	}

	// profile_tabs off: MEDIA and REPOSTS are FEATURE_DISABLED (feature=profile_tabs); the Posts tab is open.
	off := timeline.NewServer(timeline.Deps{
		Flags: noProfileTabs{}, Posts: in.posts, Graph: in.graph, Directory: in.dir,
		CursorKey: cursorKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second,
	})
	for _, tab := range []timelinev1.UserTimelineTab{tabMedia, tabReposts} {
		_, err := in.userTabOn(t, off, "me", "bob", tab, "", "", 20)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED ||
			ae.Metadata["feature"] != "profile_tabs" {
			t.Fatalf("flag off, tab %v: err=%v, want FEATURE_DISABLED feature=profile_tabs", tab, err)
		}
	}
	if resp, err := in.userTabOn(t, off, "me", "bob", timelinev1.UserTimelineTab_USER_TIMELINE_TAB_POSTS, "", "", 20); err != nil || len(resp.Posts) == 0 {
		t.Fatalf("flag off, Posts tab: err=%v", err)
	}
}

// noProfileTabs enables every flag except profile_tabs.
type noProfileTabs struct{}

func (noProfileTabs) Enabled(_, name string) bool { return name != "profile_tabs" }
