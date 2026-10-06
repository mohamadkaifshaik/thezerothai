//go:build integration

package posts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func (in *createInstance) del(uid, id string) (*budget.Counter, error) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	ctx, c := budget.WithCounter(ctx)
	return c, in.svc.Delete(ctx, uid, "0123456789abcdef", id)
}

func (in *createInstance) get(caller, id string) (*budget.Counter, *Post, error) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: caller, SignInProvider: authn.SignInProviderGoogle})
	// Warm the caller's own profile (the account-status interceptor's read, outside this RPC's budget).
	_, _ = in.svc.directory.GetProfiles(ctx, []string{caller})
	ctx, c := budget.WithCounter(ctx)
	p, err := in.svc.GetForViewer(ctx, caller, id)
	return c, p, err
}

func postExists(t *testing.T, client *firestore.Client, id string) bool {
	t.Helper()
	snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	if err != nil && snap == nil {
		return false
	}
	return snap.Exists()
}

// TestDelete_Integration_BudgetsAndNoOps covers the DeletePost acceptance criteria on the emulator.
func TestDelete_Integration_BudgetsAndNoOps(t *testing.T) {
	client := newTestClient(t)
	author := newCreateInstance(t, client, time.Nanosecond)
	author.signUp(t, "uid-alice", "alice")
	author.signUp(t, "uid-bob", "bob")
	mine, _, err := author.create(t, "uid-alice", key(1), "mine")
	if err != nil {
		t.Fatal(err)
	}
	theirs, _, err := author.create(t, "uid-bob", key(2), "theirs")
	if err != nil {
		t.Fatal(err)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 1 {
		t.Fatalf("postsCount = %d", got)
	}

	// A second, cold instance: the post read is the only read (the interceptor's read is outside the call).
	in := newCreateInstance(t, client, time.Nanosecond)

	// Another user's post: success, 0 writes, 0 deletes, the post survives.
	c, err := in.del("uid-alice", theirs.ID)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeletePost not owner", c, budgettest.Budget{Reads: 1})
	if !postExists(t, client, theirs.ID) {
		t.Fatal("another user's post was deleted")
	}
	// Unknown id: the same shape.
	c, err = in.del("uid-alice", pid(424242))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeletePost unknown", c, budgettest.Budget{Reads: 1})

	// Own post, cold: 1 read, 1 write (postsCount), 1 delete.
	c, err = in.del("uid-alice", mine.ID)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeletePost own cold", c, budgettest.Budget{Reads: 1, Writes: 1, Deletes: 1})
	if c.Writes() != 1 || c.Deletes() != 1 {
		t.Fatalf("writes=%d deletes=%d, want exactly 1/1", c.Writes(), c.Deletes())
	}
	if postExists(t, client, mine.ID) {
		t.Fatal("post still exists")
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 0 {
		t.Fatalf("postsCount = %d, want 0", got)
	}

	// Second delete: success, 1 read (the post is gone), 0 writes, 0 deletes, no second decrement.
	c, err = in.del("uid-alice", mine.ID)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeletePost repeat", c, budgettest.Budget{Reads: 1})
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 0 {
		t.Fatalf("postsCount = %d after a repeat, want 0", got)
	}

	// Warm own delete: the post is in this instance's cache (own create), so 0 reads.
	warm, _, err := in.create(t, "uid-alice", key(3), "warm")
	if err != nil {
		t.Fatal(err)
	}
	c, err = in.del("uid-alice", warm.ID)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeletePost own warm", c, budgettest.Budget{Reads: 0, Writes: 1, Deletes: 1})
	if c.Reads() != 0 {
		t.Fatalf("warm reads = %d, want 0", c.Reads())
	}
}

// TestDelete_Integration_ConcurrentDeletesDecrementOnce: 5 concurrent deletes of one post (from 5 cold
// instances, so every one passes the read and races to the batch) decrement postsCount exactly once.
func TestDelete_Integration_ConcurrentDeletesDecrementOnce(t *testing.T) {
	client := newTestClient(t)
	author := newCreateInstance(t, client, time.Nanosecond)
	author.signUp(t, "uid-alice", "alice")
	var ids []string
	for i := 1; i <= 2; i++ {
		p, _, err := author.create(t, "uid-alice", key(i), "p")
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, p.ID)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 2 {
		t.Fatalf("postsCount = %d, want 2", got)
	}

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		writes  int64
		deletes int64
		start   = make(chan struct{})
		errs    = make([]error, 5)
	)
	for i := 0; i < 5; i++ {
		in := newCreateInstance(t, client, time.Nanosecond)
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			c, err := in.del("uid-alice", ids[0])
			errs[i] = err
			mu.Lock()
			writes += c.Writes()
			deletes += c.Deletes()
			mu.Unlock()
		}()
	}
	close(start)
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("delete %d: %v", i, err)
		}
	}
	if writes != 1 || deletes != 1 {
		t.Fatalf("total writes=%d deletes=%d across 5 deletes, want exactly 1/1", writes, deletes)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 1 {
		t.Fatalf("postsCount = %d, want 1 (decremented once)", got)
	}
	if !postExists(t, client, ids[1]) {
		t.Fatal("the other post must survive")
	}
}

func setGraph(t *testing.T, client *firestore.Client, uid string, updates []firestore.Update) {
	t.Helper()
	if _, err := client.Collection("graph").Doc(uid).Update(context.Background(), updates); err != nil {
		t.Fatalf("update graph/%s: %v", uid, err)
	}
}

// TestGetPost_Integration_VisibilityAndBudget: the GetPost acceptance criteria with real identity and graph.
func TestGetPost_Integration_VisibilityAndBudget(t *testing.T) {
	client := newTestClient(t)
	setup := newCreateInstance(t, client, time.Nanosecond)
	setup.signUp(t, "uid-alice", "alice")
	setup.signUp(t, "uid-bob", "bob")
	bobPost, _, err := setup.create(t, "uid-bob", key(1), "from bob")
	if err != nil {
		t.Fatal(err)
	}

	// Cold instance, caller alice: post 1 + author users 1 + caller graph 1 = 3 (the caller's own profile read
	// belongs to the interceptor), 0 writes.
	in := newCreateInstance(t, client, time.Nanosecond)
	c, p, err := in.get("uid-alice", bobPost.ID)
	if err != nil || p.ID != bobPost.ID {
		t.Fatalf("get: %v %v", p, err)
	}
	budgettest.Assert(t, "GetPost cold", c, budgettest.Budget{Reads: 3})
	// Warm: everything cached.
	c, _, err = in.get("uid-alice", bobPost.ID)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetPost warm", c, budgettest.Budget{})

	// Alice blocked or muted bob: still returned.
	setGraph(t, client, "uid-alice", []firestore.Update{
		{Path: "blocked", Value: firestore.ArrayUnion("uid-bob")}, {Path: "muted", Value: firestore.ArrayUnion("uid-bob")}})
	in = newCreateInstance(t, client, time.Nanosecond)
	if _, _, err := in.get("uid-alice", bobPost.ID); err != nil {
		t.Fatalf("a caller who blocked the author still gets the post: %v", err)
	}

	// Bob blocked alice (alice.blockedBy has bob): NOT_FOUND, same bytes as a deleted post.
	setGraph(t, client, "uid-alice", []firestore.Update{{Path: "blockedBy", Value: firestore.ArrayUnion("uid-bob")}})
	in = newCreateInstance(t, client, time.Nanosecond)
	_, _, blockedErr := in.get("uid-alice", bobPost.ID)
	wantPostNotFound(t, blockedErr)
	_, _, missingErr := in.get("uid-alice", pid(777))
	wantPostNotFound(t, missingErr)
	if blockedErr.Error() != missingErr.Error() {
		t.Fatalf("not byte-identical: %q vs %q", blockedErr, missingErr)
	}

	// Overflowed blockedBy: bob's own graph is consulted, +1 read.
	setGraph(t, client, "uid-alice", []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove("uid-bob")}, {Path: "blockedByOverflow", Value: true}})
	setGraph(t, client, "uid-bob", []firestore.Update{{Path: "blocked", Value: firestore.ArrayUnion("uid-alice")}})
	in = newCreateInstance(t, client, time.Nanosecond)
	c, _, err = in.get("uid-alice", bobPost.ID)
	wantPostNotFound(t, err)
	budgettest.Assert(t, "GetPost overflow", c, budgettest.Budget{Reads: 4})
	if c.Reads() != 4 {
		t.Fatalf("overflow reads = %d, want exactly 4 (3 + 1)", c.Reads())
	}

	// Deleted by its author: NOT_FOUND once the 60 s cache entry is gone (here: another cold instance at once).
	if _, err := setup.del("uid-bob", bobPost.ID); err != nil {
		t.Fatal(err)
	}
	setGraph(t, client, "uid-alice", []firestore.Update{{Path: "blockedByOverflow", Value: false}})
	in = newCreateInstance(t, client, time.Nanosecond)
	_, _, err = in.get("uid-alice", bobPost.ID)
	wantPostNotFound(t, err)

	// Suspended author: same answer.
	live, _, err := setup.create(t, "uid-bob", key(9), "again")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Collection("users").Doc("uid-bob").Update(context.Background(), []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	in = newCreateInstance(t, client, time.Nanosecond)
	_, _, err = in.get("uid-alice", live.ID)
	wantPostNotFound(t, err)
}

// seedMany writes n root posts for author with createdAt = base+i ms, in batches of 500.
func seedMany(t *testing.T, client *firestore.Client, author string, n int, base int) {
	t.Helper()
	for lo := 0; lo < n; lo += 500 {
		b := client.Batch() //nolint:staticcheck // SA1019: atomic batch, same as the production seam
		for i := lo; i < n && i < lo+500; i++ {
			id := pid(base + i)
			p := &Post{
				ID: id, AuthorID: author, Author: AuthorSnapshot{UserID: author, Handle: "h"}, Kind: KindPost,
				Text: "t" + id, ConversationID: id, Visibility: VisibilityPublic,
				Hashtags: []string{"go"}, Mentions: []Mention{{UserID: "uid-m", Handle: "mm"}},
				CreatedAt: time.UnixMilli(1_700_000_000_000 + int64(base+i)).UTC(),
			}
			b.Set(client.Collection(postsCollection).Doc(id), toDoc(p))
		}
		if _, err := b.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
}

func countByAuthor(t *testing.T, client *firestore.Client, uid string) int {
	t.Helper()
	it := client.Collection(postsCollection).Where("authorId", "==", uid).Documents(context.Background())
	n := 0
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

// TestPurge_Integration_CrashResume: U has 1,203 posts; the purge is "killed" after the first batch and a re-run
// with the checkpoint finishes it. No posts doc with authorId == U remains; another user's posts are untouched.
func TestPurge_Integration_CrashResume(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	const uid = "uid-u"
	seedMany(t, client, uid, 1203, 1)
	seedMany(t, client, "uid-keep", 7, 5000)

	// Dry run: counts only, 0 writes.
	dctx, dc := budget.WithCounter(context.Background())
	plan, err := repo.PlanPurge(dctx, uid)
	if err != nil || plan.Posts != 1203 {
		t.Fatalf("plan = %+v, %v", plan, err)
	}
	if dc.Writes() != 0 || dc.Deletes() != 0 || dc.Reads() > 2 {
		t.Fatalf("dry run reads=%d writes=%d deletes=%d", dc.Reads(), dc.Writes(), dc.Deletes())
	}
	if got := countByAuthor(t, client, uid); got != 1203 {
		t.Fatalf("dry run changed data: %d posts", got)
	}

	ctx, c := budget.WithCounter(context.Background())
	// First batch, then the process "dies".
	cp, done, err := repo.PurgeUser(ctx, uid, Checkpoint{})
	if err != nil || done || cp.Deleted != 500 {
		t.Fatalf("first batch: cp=%+v done=%v err=%v", cp, done, err)
	}
	if got := countByAuthor(t, client, uid); got != 703 {
		t.Fatalf("after the first batch %d remain, want 703", got)
	}
	// Re-run from a fresh (zero) checkpoint would also work; resume with the saved one.
	calls := 1
	for !done {
		if cp, done, err = repo.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
		if calls++; calls > 10 {
			t.Fatal("purge did not finish")
		}
	}
	if cp.Deleted != 1203 || calls != 3 {
		t.Fatalf("deleted=%d calls=%d, want 1203 in 3 calls", cp.Deleted, calls)
	}
	if got := countByAuthor(t, client, uid); got != 0 {
		t.Fatalf("%d posts remain for the purged user", got)
	}
	if got := countByAuthor(t, client, "uid-keep"); got != 7 {
		t.Fatalf("another user's posts: %d, want 7", got)
	}
	// O(posts): one read and one delete per post, no counter writes (the user doc is deleted anyway).
	budgettest.Assert(t, "purge-posts 1203", c, budgettest.Budget{Reads: 1203, Deletes: 1203})
	if c.Writes() != 0 {
		t.Fatalf("writes = %d, want 0 (no counter updates)", c.Writes())
	}

	// Purging a user with no posts finishes in one call and one read.
	ectx, ec := budget.WithCounter(context.Background())
	if _, done, err := repo.PurgeUser(ectx, uid, Checkpoint{}); err != nil || !done || ec.Reads() != 1 {
		t.Fatalf("empty purge: done=%v err=%v reads=%d", done, err, ec.Reads())
	}
}

// TestExport_Integration: pages through > 500 posts, newest first, handles only, valid JSON.
func TestExport_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedMany(t, client, "uid-u", 1203, 1)
	seedMany(t, client, "uid-other", 3, 9000)

	ctx, c := budget.WithCounter(context.Background())
	var buf bytes.Buffer
	if err := repo.ExportUser(ctx, "uid-u", &buf); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "export-posts 1203", c, budgettest.Budget{Reads: 1203 + 1})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Fatalf("export wrote: %d/%d", c.Writes(), c.Deletes())
	}
	var out struct {
		UserID string `json:"userId"`
		Posts  []struct {
			ID        string    `json:"id"`
			Text      string    `json:"text"`
			CreatedAt time.Time `json:"createdAt"`
			Hashtags  []string  `json:"hashtags"`
			Mentions  []string  `json:"mentions"`
		} `json:"posts"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if out.UserID != "uid-u" || len(out.Posts) != 1203 {
		t.Fatalf("userId=%q posts=%d", out.UserID, len(out.Posts))
	}
	if out.Posts[0].ID != pid(1203) || out.Posts[1202].ID != pid(1) {
		t.Fatalf("order: first=%s last=%s", out.Posts[0].ID, out.Posts[1202].ID)
	}
	if p := out.Posts[0]; p.Text != "t"+pid(1203) || len(p.Hashtags) != 1 || p.Hashtags[0] != "go" || len(p.Mentions) != 1 || p.Mentions[0] != "mm" || p.CreatedAt.IsZero() {
		t.Fatalf("post = %+v", p)
	}
	if bytes.Contains(buf.Bytes(), []byte("uid-m")) || bytes.Contains(buf.Bytes(), []byte("uid-other")) {
		t.Fatal("export leaked a uid it must not contain")
	}

	// No posts: valid JSON with an empty array.
	buf.Reset()
	if err := repo.ExportUser(context.Background(), "uid-none", &buf); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || len(out.Posts) != 0 {
		t.Fatalf("empty export: %v %q", err, buf.String())
	}
}
