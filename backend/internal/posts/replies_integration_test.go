//go:build integration

// replies_integration_test.go: the reply path and GetThread against the Firestore emulator.
package posts

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

type blockMuter interface {
	Block(ctx context.Context, caller, key, target string) (graph.Relationship, error)
	Mute(ctx context.Context, caller, key, target string) (graph.Relationship, error)
}

func (in *createInstance) reply(t testing.TB, uid, key, text, parent string) (*Post, error) {
	t.Helper()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
		t.Errorf("warm profile: %v", err)
	}
	return in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: text, ReplyToPostID: parent, RepliesEnabled: true})
}

func (in *createInstance) thread(t testing.TB, uid string, ti ThreadInput) (*Thread, error) {
	t.Helper()
	in.svc.cursorKey = []byte("0123456789abcdef0123456789abcdef")
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	return in.svc.GetThread(ctx, uid, ti)
}

func replyCount(t *testing.T, in *createInstance, id string) int64 {
	t.Helper()
	return fieldInt(t, in.repo.client, postsCollection+"/"+id, "replyCount")
}

// TestReplies_Integration_CreateShapeAndPull: the reply doc shape, the parent counter, and that a reply never reaches a
// root-post (Home / Posts tab) query but is in the Replies tab query.
func TestReplies_Integration_CreateShapeAndPull(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")

	root, err := in.create(t, "uid-alice", key(1), "root post")
	if err != nil {
		t.Fatal(err)
	}
	r1, err := in.reply(t, "uid-bob", key(2), "first reply", root.ID)
	if err != nil {
		t.Fatal(err)
	}

	var d postDoc
	snap, err := client.Collection(postsCollection).Doc(r1.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.Kind != "REPLY" || !d.IsReply || d.ReplyToID != root.ID || d.ReplyToHandle != "alice" || d.ConversationID != root.ID {
		t.Fatalf("stored reply = %+v", d)
	}
	if got := replyCount(t, in, root.ID); got != 1 {
		t.Fatalf("parent replyCount = %d, want 1", got)
	}

	// A reply to the reply shares the conversation and bumps the reply's own counter.
	r2, err := in.reply(t, "uid-alice", key(3), "answer", r1.ID)
	if err != nil {
		t.Fatal(err)
	}
	if r2.ConversationID != root.ID || r2.ReplyToHandle != "bob" || replyCount(t, in, r1.ID) != 1 || replyCount(t, in, root.ID) != 1 {
		t.Fatalf("nested reply: %+v", r2)
	}

	// Pull model: never in a root-post query, present in the Replies-tab query.
	ctx := context.Background()
	rootsOnly, err := in.svc.ByAuthors(ctx, []string{"uid-alice", "uid-bob"}, Window{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(rootsOnly); len(got) != 1 || got[0] != root.ID {
		t.Fatalf("home/posts query = %v, want only the root post", got)
	}
	withReplies, err := in.svc.ByAuthor(ctx, "uid-bob", true, Window{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(withReplies); len(got) != 1 || got[0] != r1.ID {
		t.Fatalf("replies tab = %v, want [%s]", got, r1.ID)
	}
}

// TestReplies_Integration_ThreadOrderAndFiltering: chronological order, blocked and muted authors
// dropped, the focal/parent/root excluded, and paging.
func TestReplies_Integration_ThreadOrderAndFiltering(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	for _, u := range []string{"alice", "bob", "carol", "dave"} {
		in.signUp(t, "uid-"+u, u)
	}
	root, err := in.create(t, "uid-alice", key(1), "root")
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	byUser := map[string]string{}
	for i, u := range []string{"bob", "carol", "dave", "bob", "carol"} {
		time.Sleep(3 * time.Millisecond) // distinct Snowflake milliseconds
		p, err := in.reply(t, "uid-"+u, key(10+i), "reply "+u, root.ID)
		if err != nil {
			t.Fatal(err)
		}
		order = append(order, p.ID)
		byUser[p.ID] = u
	}

	// Alice blocks carol and mutes dave through the real graph module (posts reads graph.Snapshot).
	bm, ok := in.svc.graph.(blockMuter)
	if !ok {
		t.Fatal("graph service has no Block/Mute")
	}
	if _, err := bm.Block(context.Background(), "uid-alice", key(50), "uid-carol"); err != nil {
		t.Fatal(err)
	}
	if _, err := bm.Mute(context.Background(), "uid-alice", key(51), "uid-dave"); err != nil {
		t.Fatal(err)
	}

	th, err := in.thread(t, "uid-alice", ThreadInput{PostID: root.ID})
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, id := range order {
		if u := byUser[id]; u == "bob" {
			want = append(want, id)
		}
	}
	got := idsOf(th.Replies)
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("replies = %v, want bob's only, in order: %v", got, want)
	}
	if th.Parent != nil || th.ParentUnavailable {
		t.Fatalf("a root focal has no parent: %+v", th)
	}

	// A repeat read of the same thread works.
	_, err = in.thread(t, "uid-alice", ThreadInput{PostID: root.ID})
	if err != nil {
		t.Fatal(err)
	}

	// Paging at page size 2 visits every reply exactly once, in order, including the dropped ones' slots.
	var paged []string
	token := ""
	for i := 0; i < 10; i++ {
		page, err := in.thread(t, "uid-alice", ThreadInput{PostID: root.ID, PageSize: 2, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		paged = append(paged, idsOf(page.Replies)...)
		if token = page.NextPageToken; token == "" {
			break
		}
	}
	if len(paged) != 2 || paged[0] != want[0] || paged[1] != want[1] {
		t.Fatalf("paged = %v, want %v", paged, want)
	}
}

// TestReplies_Integration_DeleteParentRendersTombstoneAndReplyDeleteReleasesCounter.
func TestReplies_Integration_DeleteParentRendersTombstoneAndReplyDeleteReleasesCounter(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	root, err := in.create(t, "uid-alice", key(1), "root")
	if err != nil {
		t.Fatal(err)
	}
	r1, err := in.reply(t, "uid-bob", key(2), "reply", root.ID)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := in.reply(t, "uid-alice", key(3), "answer", r1.ID)
	if err != nil {
		t.Fatal(err)
	}

	// Deleting a reply releases the parent's counter in the same call.
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
	if err := in.svc.Delete(ctx, "uid-alice", key(4), r2.ID); err != nil {
		t.Fatal(err)
	}
	if got := replyCount(t, in, r1.ID); got != 0 {
		t.Fatalf("replyCount after deleting the reply = %d, want 0", got)
	}

	// Deleting the root (a different instance cache would converge in <= 60 s) leaves the reply with tombstones.
	ctx = authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
	if err := in.svc.Delete(ctx, "uid-alice", key(5), root.ID); err != nil {
		t.Fatal(err)
	}
	th, err := in.thread(t, "uid-bob", ThreadInput{PostID: r1.ID})
	if err != nil {
		t.Fatal(err)
	}
	if th.Focal.ID != r1.ID || th.Parent != nil || !th.ParentUnavailable || th.Root != nil || !th.RootUnavailable {
		t.Fatalf("thread after deleting the root: %+v", th)
	}

	// Replying to a deleted parent is the uniform NOT_FOUND, with no write.
	_, err = in.reply(t, "uid-bob", key(6), "late", root.ID)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound || ae.Message != postNotFoundText {
		t.Fatalf("err = %v, want NOT_FOUND post not found", err)
	}
}

// TestReplies_Integration_ConcurrentRepliesCountExactly: FieldValue.Increment on the parent loses no update.
func TestReplies_Integration_ConcurrentRepliesCountExactly(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	const n = 8
	for i := 0; i < n; i++ {
		in.signUp(t, "uid-u"+string(rune('a'+i)), "user"+string(rune('a'+i)))
	}
	root, err := in.create(t, "uid-alice", key(1), "root")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := in.reply(t, "uid-u"+string(rune('a'+i)), key(100+i), "r", root.ID)
			errs <- err
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := replyCount(t, in, root.ID); got != n {
		t.Fatalf("replyCount = %d, want %d", got, n)
	}
}
