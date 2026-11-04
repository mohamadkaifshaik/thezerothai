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
	// cold leaves the author's profile uncached for the next create. By default create() first warms it, because a
	// successful CreatePost evicts the author's profile (Directory.Forget) and the next request on that instance would
	// otherwise load it again.
	cold bool
	// skipSweep opts out of the posts invariant sweep (see skipInvariantSweep).
	skipSweep bool
}

// skipInvariantSweep opts this test out of the end-of-test posts invariant sweep; the reason documents why.
func (in *createInstance) skipInvariantSweep(reason string) {
	in.skipSweep = true
}

func newCreateInstance(t *testing.T, client *firestore.Client) *createInstance {
	t.Helper()
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}})
	identitySvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	graphSvc.SetDirectory(identitySvc.(identity.Directory))

	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := NewFirestoreRepo(client)
	repo.SetWriters(WriteDeps{Idempotency: idempotency.New(client), Counters: identityRepo, IDs: node})
	cache := NewCache(time.Minute, 0, 0)
	svc := New(Deps{
		Repo: repo, Cache: cache, Directory: identitySvc.(identity.Directory), Graph: graphSvc,
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

func (in *createInstance) create(t *testing.T, uid, key, text string) (*Post, error) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if !in.cold {
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
			t.Errorf("warm profile: %v", err) // not Fatal: create is also called from goroutines
		}
	}
	return in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: text})
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

// TestCreate_Integration_ShapeAndCounters: the post shape, users.postsCount +1, no quotas doc and
// exactly one idempotency doc with expireAt 24 h out.
func TestCreate_Integration_ShapeAndCounters(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")

	p, err := in.create(t, "uid-alice", key(1), "hello #World")
	if err != nil {
		t.Fatal(err)
	}

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
	assertNoQuotaDoc(t, client, "uid-alice")
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
// a replay returns the first post; a different body is IDEMPOTENCY_KEY_REUSED and writes nothing.
func TestCreate_Integration_Replays(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")

	first, err := in.create(t, "uid-alice", key(1), "once")
	if err != nil {
		t.Fatal(err)
	}
	again, err := in.create(t, "uid-alice", key(1), "once")
	if err != nil || again.ID != first.ID {
		t.Fatalf("replay: %v %v", again, err)
	}

	_, err = in.create(t, "uid-alice", key(1), "something else")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED {
		t.Fatalf("err = %v, want IDEMPOTENCY_KEY_REUSED", err)
	}

	// Concurrent x10 with a fresh key, from this instance and a second one (cold caches).
	other := newCreateInstance(t, client)
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
			p, err := svc.create(t, "uid-alice", key(2), "racing")
			if err == nil {
				ids[i] = p.ID
			}
			errs[i] = err
		}()
	}
	wg.Wait()
	// A contended create takes 2 to 3 s on the emulator (lock waits and the SDK's backoff), so on a slow runner a
	// racer can pass the 5 s transaction deadline. That racer gets the retryable UNAVAILABLE "busy" answer, which is
	// correct; what must never happen is a second post or a second counter bump. So: at least one racer succeeds,
	// every success has the same id, a busy racer's retry with the same key replays that id, and the counts below
	// stay exact.
	winner := ""
	for i := range ids {
		if errs[i] != nil {
			var busy *apierr.Error
			if !errors.As(errs[i], &busy) || busy.Code != connect.CodeUnavailable {
				t.Fatalf("call %d: err=%v, want success or the retryable UNAVAILABLE", i, errs[i])
			}
			continue
		}
		if winner == "" {
			winner = ids[i]
		}
		if ids[i] != winner {
			t.Fatalf("call %d: id=%q, want %q", i, ids[i], winner)
		}
	}
	if winner == "" {
		t.Fatalf("no racer succeeded: %v", errs)
	}
	for i := range ids {
		if errs[i] == nil {
			continue
		}
		p, err := in.create(t, "uid-alice", key(2), "racing")
		if err != nil || p.ID != winner {
			t.Fatalf("retry of busy call %d: %v %v, want the replay of %q", i, p, err, winner)
		}
	}
	// "once" + "racing" = 2 posts, postsCount 2, idempotency docs 2.
	if n := countDocs(t, client, postsCollection); n != 2 {
		t.Fatalf("posts = %d, want 2", n)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 2 {
		t.Fatalf("postsCount = %d, want 2", got)
	}
	assertNoQuotaDoc(t, client, "uid-alice")
	if n := countDocs(t, client, "idempotency"); n != 2 {
		t.Fatalf("idempotency docs = %d, want 2", n)
	}
}

// TestCreate_Integration_NoDailyQuota: a legacy quotas/{uid} showing the old daily limit used up (100, or 20 for a new
// account) no longer blocks CreatePost, and the doc is left untouched.
func TestCreate_Integration_NoDailyQuota(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	if _, err := client.Collection("quotas").Doc("uid-alice").Set(context.Background(), map[string]any{"day": quota.Today(), "posts": int64(100)}); err != nil {
		t.Fatal(err)
	}
	if _, err := in.create(t, "uid-alice", key(1), "past the old limit"); err != nil {
		t.Fatalf("create past the old daily quota: %v", err)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 1 {
		t.Fatalf("postsCount = %d, want 1", got)
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 100 {
		t.Fatalf("quotas.posts = %d, want the seeded 100 untouched", got)
	}
}

// assertNoQuotaDoc fails when quotas/{uid} exists: CreatePost no longer counts a daily quota.
func assertNoQuotaDoc(t *testing.T, client *firestore.Client, uid string) {
	t.Helper()
	if _, err := client.Doc("quotas/" + uid).Get(context.Background()); err == nil {
		t.Errorf("quotas/%s was written; posts no longer count a daily quota", uid)
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
	in := newCreateInstance(t, client)
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

	_, err := in.create(t, "uid-alice", key(1), "no candidates here")
	if err != nil {
		t.Fatal(err)
	}

	p, err := in.create(t, "uid-alice", key(2), "https://ex.com/?ref=@carol")
	if err != nil || len(p.Mentions) != 0 {
		t.Fatalf("URL mention: %v %v", p, err)
	}

	p, err = in.create(t, "uid-alice", key(3), "@ghost @bob @carol")
	if err != nil {
		t.Fatal(err)
	}
	if got := handles(p); len(got) != 2 || got[0] != "bob" || got[1] != "carol" || p.Mentions[0].UserID != "uid-bob" {
		t.Fatalf("mentions = %v, want bob and carol (ghost unknown; bob blocked the author but is kept, M2)", p.Mentions)
	}
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
	in2 := newCreateInstance(t, client)
	p, err = in2.create(t, "uid-alice", key(4), "@carol hi")
	if err != nil || len(p.Mentions) != 1 || p.Mentions[0].Handle != "carol" {
		t.Fatalf("overflow: mentions=%v err=%v", p, err)
	}
}

// TestCreate_Integration_ElevenMentions: the parser caps at 10 mentions, from a cold instance.
func TestCreate_Integration_ElevenMentions(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	text := in.signUpFriends(t, 11)
	in2 := newCreateInstance(t, client) // cold handle cache
	in2.cold = true
	p, err := in2.create(t, "uid-alice", key(1), text)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Mentions) != 10 {
		t.Fatalf("mentions = %d, want 10", len(p.Mentions))
	}
}

// TestCreate_Integration_RetriedAttemptDrawsAFreshID: when the first transaction attempt aborts, the committed
// post's id and createdAt come from the retrying attempt.
func TestCreate_Integration_RetriedAttemptDrawsAFreshID(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
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
	p, err := in.create(t, "uid-alice", key(1), "retry me")
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

// TestCreate_Integration_ColdReplayAndReusedKey (audit #8, AC3b): a replay and a reused key from a cold instance
// (nothing cached, a second "Cloud Run instance") write nothing, and the
// replay returns the original id. The text has 10 mentions, the worst case.
func TestCreate_Integration_ColdReplayAndReusedKey(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	text := in.signUpFriends(t, 10)
	first, err := in.create(t, "uid-alice", key(1), text)
	if err != nil || len(first.Mentions) != 10 {
		t.Fatalf("first create: %v %v", first, err)
	}

	cold := newCreateInstance(t, client)
	cold.cold = true
	again, err := cold.create(t, "uid-alice", key(1), text)
	if err != nil || again.ID != first.ID {
		t.Fatalf("cold replay: %v %v", again, err)
	}

	cold2 := newCreateInstance(t, client)
	cold2.cold = true
	_, err = cold2.create(t, "uid-alice", key(1), text+"changed")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED {
		t.Fatalf("err = %v, want IDEMPOTENCY_KEY_REUSED", err)
	}
	if n := countDocs(t, client, postsCollection); n != 1 {
		t.Fatalf("posts = %d, want 1", n)
	}
}

// TestCreate_Integration_MentionsD6Matrix (audit #14): whatever the author's relationship
// to the mentioned user, the mention is stored unchanged (M2: no block/privacy oracle) and the author graph is never
// read.
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
			in := newCreateInstance(t, client)
			in.signUp(t, "uid-alice", "alice")
			in.signUp(t, "uid-bob", "bob")
			tt.setup(t, client)
			p, err := in.create(t, "uid-alice", key(1), tt.text)
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Mentions) != 1 || p.Mentions[0].Handle != tt.handle || p.Mentions[0].UserID != tt.uid {
				t.Fatalf("mentions = %+v, want %s -> %s kept", p.Mentions, tt.handle, tt.uid)
			}
			if d := storedPostDoc(t, client, p.ID); len(d.Mentions) != 1 || d.Mentions[0] != (mentionDoc{UserID: tt.uid, Handle: tt.handle}) {
				t.Fatalf("stored mentions = %+v", d.Mentions)
			}
		})
	}
}

// TestCreate_Integration_StoredMentionsAndHashtagsTable (audit #19, D17): the example rows end to end,
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
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	in.signUp(t, "uid-carol", "carol")
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, err := in.create(t, "uid-alice", key(100+i), tt.in)
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
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	p, err := in.create(t, "uid-alice", key(1), "a\u2028b")
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
		in := newCreateInstance(t, client)    // the mentioning instance
		other := newCreateInstance(t, client) // where the rename and the claim happen
		in.signUp(t, "uid-alice", "alice")
		other.signUp(t, "uid-bob", "bob")

		p, err := in.create(t, "uid-alice", key(1), "@bob first")
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

		p, err = in.create(t, "uid-alice", key(3), "@bob second")
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
