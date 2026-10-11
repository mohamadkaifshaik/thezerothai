//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/api/iterator"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// createInstance is one "Cloud Run instance" of identity + graph + posts on a shared emulator project, wired the
// way apiserver.Build wires them.
type createInstance struct {
	svc      *service
	repo     *FirestoreRepo
	identity identity.Service
	cache    *Cache
	// cold leaves the author's profile uncached for the next create. By default create() first warms it outside
	// the measured call: a successful CreatePost evicts the author's profile (Directory.Forget, ADR-0008 B2), so
	// the NEXT request on that instance pays the interceptor's read; the budget assertions model the warm
	// steady state the documented "2 warm" refers to.
	cold bool
	// skipSweep opts out of the posts invariant sweep (see skipInvariantSweep).
	skipSweep bool
}

// skipInvariantSweep opts this test out of the end-of-test posts invariant sweep; the reason documents why.
func (in *createInstance) skipInvariantSweep(reason string) {
	_ = reason
	in.skipSweep = true
}

func newCreateInstance(t *testing.T, client *firestore.Client, window time.Duration) *createInstance {
	t.Helper()
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, NewAccountWindow: window, BlocksPerDay: 100, NewAccountBlocksPerDay: 100})
	identitySvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	graphSvc.SetDirectory(identitySvc.(identity.Directory))

	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := NewFirestoreRepo(client)
	repo.SetWriters(WriteDeps{Idempotency: idempotency.New(client), Quotas: quota.New(client), Counters: identityRepo, IDs: node})
	cache := NewCache(time.Minute, 0, 0)
	svc := New(Deps{
		Repo: repo, Cache: cache, Directory: identitySvc.(identity.Directory), Graph: graphSvc,
		PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: window,
	}).(*service)
	in := &createInstance{svc: svc, repo: repo, identity: identitySvc, cache: cache}
	// Every scenario ends with the posts invariant sweep (users.postsCount == posts by authorId); registered after the
	// client's Close, so it runs before it.
	t.Cleanup(func() {
		if !in.skipSweep {
			assertPostsInvariants(t, client)
		}
	})
	return in
}

type allOn struct{}

func (allOn) Enabled(string, string) bool { return true }

func (in *createInstance) signUp(t *testing.T, uid, handle string) {
	t.Helper()
	if _, err := in.identity.CreateProfile(context.Background(), uid, "0123456789abcdef", handle, "Name "+uid); err != nil {
		t.Fatalf("CreateProfile %s: %v", uid, err)
	}
}

func (in *createInstance) create(t *testing.T, uid, key, text string) (*Post, *budget.Counter, error) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if !in.cold {
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
			t.Errorf("warm profile: %v", err) // not Fatal: create is also called from goroutines
		}
	}
	ctx, c := budget.WithCounter(ctx)
	p, err := in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: text})
	return p, c, err
}

// signUpFriends signs up n users (friend00..) and returns a post text mentioning all of them.
func (in *createInstance) signUpFriends(t *testing.T, n int) string {
	t.Helper()
	text := ""
	for i := 0; i < n; i++ {
		h := fmt.Sprintf("friend%02d", i)
		in.signUp(t, "uid-"+h, h)
		text += "@" + h + " "
	}
	return text
}

func countDocs(t *testing.T, client *firestore.Client, col string) int {
	t.Helper()
	n := 0
	it := client.Collection(col).Documents(context.Background())
	for {
		_, err := it.Next()
		if errors.Is(err, iterator.Done) {
			return n
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
}

func fieldInt(t *testing.T, client *firestore.Client, path, field string) int64 {
	t.Helper()
	snap, err := client.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, err := snap.DataAt(field)
	if err != nil {
		t.Fatalf("%s.%s: %v", path, field, err)
	}
	return v.(int64)
}

func key(i int) string { return fmt.Sprintf("key-%012d", i) }

// TestCreate_Integration_ShapeCountersAndBudget: the ADR-0003 post shape, users.postsCount +1, quotas.posts +1 and
// exactly one idempotency doc with expireAt 24 h out; the call stays within the documented budget.
func TestCreate_Integration_ShapeCountersAndBudget(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")

	p, c, err := in.create(t, "uid-alice", key(1), "hello #World")
	if err != nil {
		t.Fatal(err)
	}
	// Warm (profile cached by CreateProfile; the interceptor's read is not part of this call): 2 reads, 4 writes.
	budgettest.Assert(t, "CreatePost warm", c, budgettest.Budget{Reads: 2, Writes: 4})

	snap, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.AuthorID != "uid-alice" || d.Kind != "POST" || d.IsReply || d.ConversationID != p.ID || d.Visibility != "PUBLIC" ||
		d.Text != "hello #World" || len(d.Hashtags) != 1 || d.Hashtags[0] != "world" || len(d.Mentions) != 0 ||
		d.Author.Handle != "alice" || d.Author.UserID != "uid-alice" || d.LikeCount != 0 || d.ReplyCount != 0 {
		t.Fatalf("stored doc = %+v", d)
	}
	if want, _ := snowflake.Time(p.ID); !d.CreatedAt.Equal(want) {
		t.Fatalf("createdAt %v != snowflake ms %v", d.CreatedAt, want)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 1 {
		t.Fatalf("postsCount = %d", got)
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 1 {
		t.Fatalf("quotas.posts = %d", got)
	}
	if n := countDocs(t, client, "idempotency"); n != 1 {
		t.Fatalf("idempotency docs = %d, want 1", n)
	}
	it := client.Collection("idempotency").Documents(context.Background())
	idem, _ := it.Next()
	exp := idem.Data()["expireAt"].(time.Time)
	if d := time.Until(exp); d < 23*time.Hour+50*time.Minute || d > 24*time.Hour+time.Minute {
		t.Fatalf("expireAt is %v out, want ~24h", d)
	}
}

// TestCreate_Integration_Replays: sequential and 10-way concurrent replays create one post and return one id;
// a replay costs 1 read and 0 writes; a different body is IDEMPOTENCY_KEY_REUSED with 0 writes.
func TestCreate_Integration_Replays(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")

	first, _, err := in.create(t, "uid-alice", key(1), "once")
	if err != nil {
		t.Fatal(err)
	}
	again, c, err := in.create(t, "uid-alice", key(1), "once")
	if err != nil || again.ID != first.ID {
		t.Fatalf("replay: %v %v", again, err)
	}
	budgettest.Assert(t, "CreatePost replay (warm)", c, budgettest.Budget{Reads: 1, Writes: 0})

	_, c, err = in.create(t, "uid-alice", key(1), "something else")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED {
		t.Fatalf("err = %v, want IDEMPOTENCY_KEY_REUSED", err)
	}
	budgettest.Assert(t, "CreatePost reused key", c, budgettest.Budget{Reads: 1, Writes: 0}) // the idempotency doc only; docs say 1

	// Concurrent x10 with a fresh key, from this instance and a second one (cold caches).
	other := newCreateInstance(t, client, time.Nanosecond)
	var wg sync.WaitGroup
	ids := make([]string, 10)
	errs := make([]error, 10)
	for i := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			svc := in
			if i%2 == 1 {
				svc = other
			}
			p, _, err := svc.create(t, "uid-alice", key(2), "racing")
			if err == nil {
				ids[i] = p.ID
			}
			errs[i] = err
		}()
	}
	wg.Wait()
	for i := range ids {
		if errs[i] != nil || ids[i] != ids[0] {
			t.Fatalf("call %d: id=%q err=%v (first id %q)", i, ids[i], errs[i], ids[0])
		}
	}
	// "once" + "racing" = 2 posts, postsCount 2, quotas.posts 2, idempotency docs 2.
	if n := countDocs(t, client, postsCollection); n != 2 {
		t.Fatalf("posts = %d, want 2", n)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 2 {
		t.Fatalf("postsCount = %d, want 2", got)
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 2 {
		t.Fatalf("quotas.posts = %d, want 2", got)
	}
	if n := countDocs(t, client, "idempotency"); n != 2 {
		t.Fatalf("idempotency docs = %d, want 2", n)
	}
}

// TestCreate_Integration_Quota: at 100 (20 for an account younger than the window) QUOTA_EXCEEDED with
// metadata.quota=posts and no entity writes.
func TestCreate_Integration_Quota(t *testing.T) {
	tests := []struct {
		name   string
		window time.Duration
		used   int64
	}{
		{"established account", time.Nanosecond, 100},
		{"new account", 24 * time.Hour, 20},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := newTestClient(t)
			in := newCreateInstance(t, client, tt.window)
			in.signUp(t, "uid-alice", "alice")
			if _, err := client.Collection("quotas").Doc("uid-alice").Set(context.Background(), quota.Record{Day: quota.Today(), Posts: tt.used}); err != nil {
				t.Fatal(err)
			}
			_, c, err := in.create(t, "uid-alice", key(1), "over the limit")
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || ae.Code != connect.CodeResourceExhausted || ae.Metadata["quota"] != "posts" {
				t.Fatalf("err = %v, want QUOTA_EXCEEDED quota=posts", err)
			}
			if c.Writes() != 0 || countDocs(t, client, postsCollection) != 0 || countDocs(t, client, "idempotency") != 0 {
				t.Fatalf("a rejected create wrote: writes=%d", c.Writes())
			}
			if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 0 {
				t.Fatalf("postsCount = %d", got)
			}
		})
	}
}

func seedBlockedBy(t *testing.T, client *firestore.Client, uid string, blockedBy []string, overflow bool) {
	t.Helper()
	_, err := client.Collection("graph").Doc(uid).Set(context.Background(),
		map[string]any{"blockedBy": blockedBy, "blockedByOverflow": overflow}, firestore.MergeAll)
	if err != nil {
		t.Fatal(err)
	}
}

// TestCreate_Integration_Mentions: unknown handles stay text, a user who blocked the author is mentioned like any
// other (M2: no block oracle), overflow changes nothing, and the author graph is never read.
func TestCreate_Integration_Mentions(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	in.signUp(t, "uid-carol", "carol")
	seedBlockedBy(t, client, "uid-alice", []string{"uid-bob"}, false) // bob blocked alice

	handles := func(p *Post) []string {
		var out []string
		for _, m := range p.Mentions {
			out = append(out, m.Handle)
		}
		return out
	}

	p, c, err := in.create(t, "uid-alice", key(1), "no candidates here")
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "no mention candidate", c, budgettest.Budget{Reads: 2, Writes: 4})
	_ = p

	p, c, err = in.create(t, "uid-alice", key(2), "https://ex.com/?ref=@carol")
	if err != nil || len(p.Mentions) != 0 {
		t.Fatalf("URL mention: %v %v", p, err)
	}
	budgettest.Assert(t, "mention only inside a URL: 0 graph and 0 handle reads", c, budgettest.Budget{Reads: 2, Writes: 4})

	p, c, err = in.create(t, "uid-alice", key(3), "@ghost @bob @carol")
	if err != nil {
		t.Fatal(err)
	}
	if got := handles(p); len(got) != 2 || got[0] != "bob" || got[1] != "carol" || p.Mentions[0].UserID != "uid-bob" {
		t.Fatalf("mentions = %v, want bob and carol (ghost unknown; bob blocked the author but is kept, M2)", p.Mentions)
	}
	// 3 handles + idempotency 1 + quotas 1 = 5 (no interceptor read in this harness, no author-graph read).
	budgettest.Assert(t, "3 mention candidates, cold handles", c, budgettest.Budget{Reads: 5, Writes: 4})
	stored, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := stored.DataTo(&d); err != nil || len(d.Mentions) != 2 || d.Mentions[0] != (mentionDoc{UserID: "uid-bob", Handle: "bob"}) || d.Mentions[1] != (mentionDoc{UserID: "uid-carol", Handle: "carol"}) {
		t.Fatalf("stored mentions = %+v, %v", d.Mentions, err)
	}

	// Overflow of the author's blockedBy list changes nothing either: the graph is not consulted.
	seedBlockedBy(t, client, "uid-alice", nil, true)
	in2 := newCreateInstance(t, client, time.Nanosecond)
	p, _, err = in2.create(t, "uid-alice", key(4), "@carol hi")
	if err != nil || len(p.Mentions) != 1 || p.Mentions[0].Handle != "carol" {
		t.Fatalf("overflow: mentions=%v err=%v", p, err)
	}
}

// TestCreate_Integration_ElevenMentions: the parser caps at 10 and the cold read ceiling holds (10
// handles + idempotency 1 + quotas 1 = 12, +1 interceptor read in a real request = 13, under the documented 14).
func TestCreate_Integration_ElevenMentions(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	text := in.signUpFriends(t, 11)
	in2 := newCreateInstance(t, client, time.Nanosecond) // cold handle cache
	in2.cold = true
	p, c, err := in2.create(t, "uid-alice", key(1), text)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Mentions) != 10 {
		t.Fatalf("mentions = %d, want 10", len(p.Mentions))
	}
	// In2's profile cache is cold too: +1 (author profile) => 14 = the documented cold ceiling with no interceptor.
	budgettest.Assert(t, "CreatePost cold ceiling", c, budgettest.Budget{Reads: 14, Writes: 4})
}

// TestCreate_Integration_RetriedAttemptDrawsAFreshID: when the first transaction attempt aborts, the committed
// post's id and createdAt come from the retrying attempt (ADR-0010 D13/D18).
func TestCreate_Integration_RetriedAttemptDrawsAFreshID(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	var seen []string
	in.repo.attemptHook = func(attempt int, id string) error {
		seen = append(seen, id)
		if attempt == 1 {
			// Make the next attempt's Snowflake ms differ without sleeping: spin until the wall clock moves on.
			drawn, _ := snowflake.Time(id)
			for time.Now().UnixMilli() <= drawn.UnixMilli() {
				runtime.Gosched()
			}
			return status.Error(codes.Aborted, "simulated lock conflict")
		}
		return nil
	}
	p, _, err := in.create(t, "uid-alice", key(1), "retry me")
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 2 || p.ID != seen[1] || p.ID == seen[0] {
		t.Fatalf("attempt ids = %v, committed %s: want the second attempt's id", seen, p.ID)
	}
	first, _ := snowflake.Time(seen[0])
	if !p.CreatedAt.After(first) {
		t.Fatalf("createdAt %v must be later than the aborted attempt's %v", p.CreatedAt, first)
	}
	if countDocs(t, client, postsCollection) != 1 || fieldInt(t, client, "users/uid-alice", "postsCount") != 1 {
		t.Fatal("an aborted attempt must leave nothing behind")
	}
}

func storedPostDoc(t *testing.T, client *firestore.Client, id string) postDoc {
	t.Helper()
	snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	return d
}

func seedGraphDoc(t *testing.T, client *firestore.Client, uid string, fields map[string]any) {
	t.Helper()
	if _, err := client.Collection("graph").Doc(uid).Set(context.Background(), fields, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
}

// TestCreate_Integration_ColdReplayAndReusedKeyBudget (audit #8, AC3b): a replay and a reused key from a cold instance
// (nothing cached, a second "Cloud Run instance") stay within the documented 14-read ceiling, write nothing, and the
// replay returns the original id. The text has 10 mentions, the worst case, which the replay path must not re-resolve
// beyond the ceiling.
func TestCreate_Integration_ColdReplayAndReusedKeyBudget(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	text := in.signUpFriends(t, 10)
	first, _, err := in.create(t, "uid-alice", key(1), text)
	if err != nil || len(first.Mentions) != 10 {
		t.Fatalf("first create: %v %v", first, err)
	}

	cold := newCreateInstance(t, client, time.Nanosecond)
	cold.cold = true
	again, c, err := cold.create(t, "uid-alice", key(1), text)
	if err != nil || again.ID != first.ID {
		t.Fatalf("cold replay: %v %v", again, err)
	}
	budgettest.Assert(t, "CreatePost replay (cold)", c, budgettest.Budget{Reads: 14, Writes: 0, Deletes: 0})

	cold2 := newCreateInstance(t, client, time.Nanosecond)
	cold2.cold = true
	_, c, err = cold2.create(t, "uid-alice", key(1), text+"changed")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED {
		t.Fatalf("err = %v, want IDEMPOTENCY_KEY_REUSED", err)
	}
	budgettest.Assert(t, "CreatePost reused key (cold)", c, budgettest.Budget{Reads: 14, Writes: 0, Deletes: 0})
	if n := countDocs(t, client, postsCollection); n != 1 {
		t.Fatalf("posts = %d, want 1", n)
	}
}

// TestCreate_Integration_QuotaRollsOverAtISTMidnight (audit #12, D9): a quota record from yesterday (IST) at the daily
// limit does not block today's create, and the counter restarts at 1 on today's date.
func TestCreate_Integration_QuotaRollsOverAtISTMidnight(t *testing.T) {
	tests := []struct {
		name   string
		window time.Duration
		used   int64
	}{
		{"established account", time.Nanosecond, 100},
		{"new account", 24 * time.Hour, 20},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := newTestClient(t)
			in := newCreateInstance(t, client, tt.window)
			in.signUp(t, "uid-alice", "alice")
			yesterday := quota.TodayAt(time.Now().Add(-24 * time.Hour))
			if yesterday == quota.Today() {
				t.Fatalf("test setup: yesterday == today (%s)", yesterday)
			}
			if _, err := client.Collection("quotas").Doc("uid-alice").Set(context.Background(), quota.Record{Day: yesterday, Posts: tt.used}); err != nil {
				t.Fatal(err)
			}
			_, c, err := in.create(t, "uid-alice", key(1), "a new day")
			if err != nil {
				t.Fatalf("create after rollover: %v", err)
			}
			budgettest.Assert(t, "CreatePost after IST rollover", c, budgettest.Budget{Reads: 2, Writes: 4})
			snap, err := client.Doc("quotas/uid-alice").Get(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if day, _ := snap.DataAt("day"); day != quota.Today() {
				t.Fatalf("quotas.day = %v, want %s", day, quota.Today())
			}
			if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 1 {
				t.Fatalf("quotas.posts = %d, want 1 (reset, not %d+1)", got, tt.used)
			}
		})
	}
}

// TestCreate_Integration_MentionsD6Matrix (audit #14, ADR-0010 D6 CreatePost column): whatever the author's relationship
// to the mentioned user, the mention is stored unchanged (M2: no block/privacy oracle) and the author graph is never
// read: one handle read + idempotency + quotas = 3 reads.
func TestCreate_Integration_MentionsD6Matrix(t *testing.T) {
	statusSet := func(t *testing.T, client *firestore.Client, uid, status string) {
		t.Helper()
		if _, err := client.Doc("users/"+uid).Update(context.Background(), []firestore.Update{{Path: "status", Value: status}}); err != nil {
			t.Fatal(err)
		}
	}
	tests := []struct {
		name   string
		text   string
		handle string // expected stored mention handle
		uid    string
		setup  func(t *testing.T, client *firestore.Client)
	}{
		{"own handle", "note to self @alice", "alice", "uid-alice", func(*testing.T, *firestore.Client) {}},
		{"A follows B", "@bob hi", "bob", "uid-bob", func(t *testing.T, c *firestore.Client) {
			seedGraphDoc(t, c, "uid-alice", map[string]any{"following": []string{"uid-bob"}})
		}},
		{"both block", "@bob hi", "bob", "uid-bob", func(t *testing.T, c *firestore.Client) {
			seedGraphDoc(t, c, "uid-alice", map[string]any{"blocked": []string{"uid-bob"}, "blockedBy": []string{"uid-bob"}})
			seedGraphDoc(t, c, "uid-bob", map[string]any{"blocked": []string{"uid-alice"}, "blockedBy": []string{"uid-alice"}})
		}},
		{"A mutes B", "@bob hi", "bob", "uid-bob", func(t *testing.T, c *firestore.Client) {
			seedGraphDoc(t, c, "uid-alice", map[string]any{"muted": []string{"uid-bob"}})
		}},
		{"B SUSPENDED", "@bob hi", "bob", "uid-bob", func(t *testing.T, c *firestore.Client) { statusSet(t, c, "uid-bob", "SUSPENDED") }},
		{"B DELETING", "@bob hi", "bob", "uid-bob", func(t *testing.T, c *firestore.Client) { statusSet(t, c, "uid-bob", "DELETING") }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := newTestClient(t)
			in := newCreateInstance(t, client, time.Nanosecond)
			in.signUp(t, "uid-alice", "alice")
			in.signUp(t, "uid-bob", "bob")
			tt.setup(t, client)
			p, c, err := in.create(t, "uid-alice", key(1), tt.text)
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Mentions) != 1 || p.Mentions[0].Handle != tt.handle || p.Mentions[0].UserID != tt.uid {
				t.Fatalf("mentions = %+v, want %s -> %s kept", p.Mentions, tt.handle, tt.uid)
			}
			if d := storedPostDoc(t, client, p.ID); len(d.Mentions) != 1 || d.Mentions[0] != (mentionDoc{UserID: tt.uid, Handle: tt.handle}) {
				t.Fatalf("stored mentions = %+v", d.Mentions)
			}
			budgettest.Assert(t, "CreatePost 1 mention, any relationship: no graph read", c, budgettest.Budget{Reads: 3, Writes: 4})
		})
	}
}

// TestCreate_Integration_StoredMentionsAndHashtagsTable (audit #19, D17): the ADR-0010 D7/D8 example rows end to end,
// reading the stored postDoc (not the parser output), plus the stored text.
func TestCreate_Integration_StoredMentionsAndHashtagsTable(t *testing.T) {
	var eleven, elevenTags []string
	for i := 0; i < 11; i++ {
		eleven = append(eleven, fmt.Sprintf("#t%c", 'a'+i))
		elevenTags = append(elevenTags, fmt.Sprintf("t%c", 'a'+i))
	}
	elevenTags = elevenTags[:10]
	tests := []struct {
		name         string
		in           string
		wantText     string // "" = unchanged
		wantTags     []string
		wantMentions []string
	}{
		{"mention case-insensitive dedupe", "@Bob @bob", "", nil, []string{"bob"}},
		{"email is not a mention", "mail bob@example.com", "", nil, nil},
		{"parenthesised and possessive", "(@bob) and @carol's", "", nil, []string{"bob", "carol"}},
		{"double at", "@@bob", "", nil, nil},
		{"too short", "@ab", "", nil, nil},
		{"hashtag case-insensitive dedupe", "#Go #go #GO", "", []string{"go"}, nil},
		{"devanagari keeps vowel signs", "#भारत", "", []string{"भारत"}, nil},
		{"digits only is not a tag", "#123", "", nil, nil},
		{"mid-word hash", "a#b", "", nil, nil},
		{"11 hashtags store 10, text unchanged", strings.Join(eleven, " "), "", elevenTags, nil},
		{"NFC: decomposed e+acute", "#cafe\u0301", "#caf\u00e9", []string{"caf\u00e9"}, nil},
	}
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	in.signUp(t, "uid-carol", "carol")
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, _, err := in.create(t, "uid-alice", key(100+i), tt.in)
			if err != nil {
				t.Fatal(err)
			}
			d := storedPostDoc(t, client, p.ID)
			wantText := tt.wantText
			if wantText == "" {
				wantText = tt.in
			}
			if d.Text != wantText {
				t.Fatalf("stored text = %q, want %q", d.Text, wantText)
			}
			if len(d.Hashtags) != len(tt.wantTags) {
				t.Fatalf("stored hashtags = %q, want %q", d.Hashtags, tt.wantTags)
			}
			for j := range tt.wantTags {
				if d.Hashtags[j] != tt.wantTags[j] {
					t.Fatalf("stored hashtags = %q, want %q", d.Hashtags, tt.wantTags)
				}
			}
			if len(d.Mentions) != len(tt.wantMentions) {
				t.Fatalf("stored mentions = %+v, want %v", d.Mentions, tt.wantMentions)
			}
			for j, h := range tt.wantMentions {
				if d.Mentions[j].Handle != h || d.Mentions[j].UserID != "uid-"+h {
					t.Fatalf("stored mentions = %+v, want %v", d.Mentions, tt.wantMentions)
				}
			}
		})
	}
}

// TestCreate_Integration_LineSeparatorStoredAsNewline (audit #20, D21 G2): U+2028 in the request is stored as \n.
func TestCreate_Integration_LineSeparatorStoredAsNewline(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	p, _, err := in.create(t, "uid-alice", key(1), "a\u2028b")
	if err != nil {
		t.Fatal(err)
	}
	if d := storedPostDoc(t, client, p.ID); d.Text != "a\nb" || p.Text != "a\nb" {
		t.Fatalf("stored text = %q, returned %q, want %q", d.Text, p.Text, "a\nb")
	}
}

// TestCreate_Integration_ReclaimedHandleResolvesToNewOwner (audit #21, D21 G5): bob is mentioned (this instance caches
// bob -> uid-bob), bob renames to bob2 and carol claims "bob" on another instance. Once this instance sees bob2's
// profile (a rename seen through a fresher profile) the stale positive entry is a miss and the stored mention is
// carol's. The 11 s expiry row needs a clock seam: identity.Cache.now is unexported, so a posts-package test cannot
// advance it without a sleep (see the skipped subtest).
func TestCreate_Integration_ReclaimedHandleResolvesToNewOwner(t *testing.T) {
	t.Run("9 s old entry contradicted by the renamed profile: carol wins", func(t *testing.T) {
		client := newTestClient(t)
		in := newCreateInstance(t, client, time.Nanosecond)    // the mentioning instance
		other := newCreateInstance(t, client, time.Nanosecond) // where the rename and the claim happen
		in.signUp(t, "uid-alice", "alice")
		other.signUp(t, "uid-bob", "bob")

		p, _, err := in.create(t, "uid-alice", key(1), "@bob first")
		if err != nil || len(p.Mentions) != 1 || p.Mentions[0].UserID != "uid-bob" {
			t.Fatalf("before the rename: %+v %v", p, err)
		}
		if _, err := other.identity.ChangeHandle(context.Background(), "uid-bob", key(2), "bob2"); err != nil {
			t.Fatalf("rename: %v", err)
		}
		other.signUp(t, "uid-carol", "bob")
		in.svc.directory.Forget("uid-bob")
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-bob"}); err != nil {
			t.Fatal(err)
		}

		p, _, err = in.create(t, "uid-alice", key(3), "@bob second")
		if err != nil {
			t.Fatal(err)
		}
		if len(p.Mentions) != 1 || p.Mentions[0].UserID != "uid-carol" {
			t.Fatalf("mentions = %+v, want bob -> uid-carol", p.Mentions)
		}
		if d := storedPostDoc(t, client, p.ID); len(d.Mentions) != 1 || d.Mentions[0] != (mentionDoc{UserID: "uid-carol", Handle: "bob"}) {
			t.Fatalf("stored mentions = %+v, want uid-carol", d.Mentions)
		}
	})
	t.Run("11 s old entry: carol wins", func(t *testing.T) {
		t.Skip("blocked: identity.Cache.now is unexported, so the entry's age cannot be advanced from package posts without a sleep; covered by identity/resolve_handles_g5_test.go")
	})
}
