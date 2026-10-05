//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
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
}

func newCreateInstance(t *testing.T, client *firestore.Client, window time.Duration) *createInstance {
	t.Helper()
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, NewAccountWindow: window})
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
	return &createInstance{svc: svc, repo: repo, identity: identitySvc, cache: cache}
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
	budgettest.Assert(t, "CreatePost reused key", c, budgettest.Budget{Reads: 2, Writes: 0})

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

// TestCreate_Integration_Mentions: unknown handles stay text, blockers are dropped, overflow drops everything, and
// text without a candidate never reads the author graph (2 reads: idempotency + quotas).
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

	p, c, err = in.create(t, "uid-alice", key(2), "https://ex.com/?ref=@carol")
	if err != nil || len(p.Mentions) != 0 {
		t.Fatalf("URL mention: %v %v", p, err)
	}
	budgettest.Assert(t, "mention only inside a URL: 0 graph and 0 handle reads", c, budgettest.Budget{Reads: 2, Writes: 4})

	p, c, err = in.create(t, "uid-alice", key(3), "@ghost @bob @carol")
	if err != nil {
		t.Fatal(err)
	}
	if got := handles(p); len(got) != 1 || got[0] != "carol" || p.Mentions[0].UserID != "uid-carol" {
		t.Fatalf("mentions = %v, want only carol (ghost unknown, bob blocked the author)", p.Mentions)
	}
	// graph 1 + 3 handles + idempotency 1 + quotas 1 = 6 (no interceptor read in this harness).
	budgettest.Assert(t, "3 mention candidates, cold handles", c, budgettest.Budget{Reads: 6, Writes: 4})
	stored, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := stored.DataTo(&d); err != nil || len(d.Mentions) != 1 || d.Mentions[0] != (mentionDoc{UserID: "uid-carol", Handle: "carol"}) {
		t.Fatalf("stored mentions = %+v, %v", d.Mentions, err)
	}

	// Overflow: fail closed. A fresh instance so the graph is read again.
	seedBlockedBy(t, client, "uid-alice", nil, true)
	in2 := newCreateInstance(t, client, time.Nanosecond)
	p, _, err = in2.create(t, "uid-alice", key(4), "@carol hi")
	if err != nil || len(p.Mentions) != 0 {
		t.Fatalf("overflow: mentions=%v err=%v", p, err)
	}
}

// TestCreate_Integration_ElevenMentions: the parser caps at 10 and the cold read ceiling holds (graph 1 + 10
// handles + idempotency 1 + quotas 1 = 13, +1 interceptor read in a real request = the documented 14).
func TestCreate_Integration_ElevenMentions(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")
	text := ""
	for i := 0; i < 11; i++ {
		h := fmt.Sprintf("friend%02d", i)
		in.signUp(t, "uid-"+h, h)
		text += "@" + h + " "
	}
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
			time.Sleep(3 * time.Millisecond) // make the ms differ
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
