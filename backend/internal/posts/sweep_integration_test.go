//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Emulator tests of the publish sweep over the real FirestoreRepo, identity and quota (ADR-0021 "Sweep", CMP-D4). The
// clock is real: items are seeded relative to time.Now(), so nothing sleeps. Budgets are the RUN's: the due query plus the
// publish transactions, matching the "Sweep run" and "Publish one item" rows of the ADR cost table.

// sweepMedia is a MediaAttacher over media/{id} docs with the real validity rules (owned, READY or READY_UNSCREENED,
// not yet attached to a post) and a real Attach (media/{id}.postId). It counts its loads, so a test can prove the media
// were NOT read, and it can be told to panic.
type sweepMedia struct {
	client      *firestore.Client
	mu          sync.Mutex
	loads       int
	panicOnLoad bool
}

func (m *sweepMedia) loadCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.loads
}

func (m *sweepMedia) LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (MediaClaim, error) {
	m.mu.Lock()
	m.loads++
	boom := m.panicOnLoad
	m.mu.Unlock()
	if boom {
		panic("media attacher exploded")
	}
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = m.client.Collection("media").Doc(id)
	}
	snaps, err := tx.GetAll(refs)
	budget.FromContext(ctx).AddReads(int64(len(ids)))
	if err != nil {
		return nil, err
	}
	claim := &sweepClaim{client: m.client}
	for i, s := range snaps {
		if !s.Exists() {
			return nil, ErrMediaNotReady
		}
		d := s.Data()
		if d["ownerId"] != uid {
			return nil, ErrMediaNotReady
		}
		if st, _ := d["status"].(string); st != "READY" && st != "READY_UNSCREENED" {
			return nil, ErrMediaNotReady
		}
		if pid, _ := d["postId"].(string); pid != "" {
			return nil, ErrMediaNotReady // already attached elsewhere
		}
		claim.ids = append(claim.ids, ids[i])
		claim.refs = append(claim.refs, MediaRef{ID: ids[i], URL: "https://cdn.example/m/" + ids[i], ThumbURL: "https://cdn.example/t/" + ids[i], Width: 10, Height: 20})
	}
	return claim, nil
}

type sweepClaim struct {
	client *firestore.Client
	ids    []string
	refs   []MediaRef
}

func (c *sweepClaim) Refs() []MediaRef { return c.refs }
func (c *sweepClaim) Attach(b store.Batch, postID string) {
	for _, id := range c.ids {
		b.Update(c.client.Collection("media").Doc(id), []firestore.Update{{Path: "postId", Value: postID}})
	}
}

// faultRepo wraps the real repository so a test can act in the window between two steps of the sweep.
type faultRepo struct {
	*FirestoreRepo
	// afterDue runs after the due query returned a page.
	afterDue func()
	// beforePublish runs right before the publish transaction of an item.
	beforePublish func(p PublishParams)
	// publishPanic, when it returns non-nil for an item, panics OUTSIDE the transaction callback.
	publishPanic func(p PublishParams) any

	mu                        sync.Mutex
	inflightBy, maxInflightBy map[string]int
}

func (f *faultRepo) DueScheduled(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error) {
	page, err := f.FirestoreRepo.DueScheduled(ctx, now, limit, after)
	if err == nil && f.afterDue != nil {
		f.afterDue()
	}
	return page, err
}

func (f *faultRepo) PublishScheduled(ctx context.Context, p PublishParams) (PublishResult, error) {
	f.mu.Lock()
	if f.inflightBy == nil {
		f.inflightBy, f.maxInflightBy = map[string]int{}, map[string]int{}
	}
	f.inflightBy[p.UID]++
	f.maxInflightBy[p.UID] = max(f.maxInflightBy[p.UID], f.inflightBy[p.UID])
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.inflightBy[p.UID]--
		f.mu.Unlock()
	}()
	if f.publishPanic != nil {
		if v := f.publishPanic(p); v != nil {
			panic(v)
		}
	}
	if f.beforePublish != nil {
		f.beforePublish(p)
	}
	return f.FirestoreRepo.PublishScheduled(ctx, p)
}

// sweepIT is one "Cloud Run instance" of identity + posts wired like apiserver.Build, on a shared emulator project.
type sweepIT struct {
	t      *testing.T
	client *firestore.Client
	idRepo *identity.FirestoreRepo
	idSvc  identity.Service
	dir    identity.Directory
	repo   *FirestoreRepo
	fault  *faultRepo
	media  *sweepMedia
	events *sweepEvents
	logs   *lockedBuffer
	svc    *service
	deps   Deps
}

type sweepITOption func(*Deps)

func newSweepIT(t *testing.T, opts ...sweepITOption) *sweepIT {
	t.Helper()
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	idRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(idRepo)
	graphRepo.SetProfiles(idRepo)
	idSvc := identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	e := &sweepIT{t: t, client: client, idRepo: idRepo, idSvc: idSvc, dir: idSvc.(identity.Directory), events: &sweepEvents{}, logs: &lockedBuffer{}}
	e.media = &sweepMedia{client: client}
	e.repo = NewFirestoreRepo(client)
	e.repo.SetWriters(WriteDeps{Quotas: quota.New(client), Counters: idRepo, IDs: node, Media: e.media, Profiles: idRepo})
	e.fault = &faultRepo{FirestoreRepo: e.repo}
	e.deps = Deps{
		Repo: e.repo, Cache: NewCache(time.Minute, 0, 0), Events: e.events, Directory: e.dir,
		PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: 24 * time.Hour,
		Scheduled: e.repo, Schedule: defaultScheduleLimits(), CursorKey: schedKey,
		Sweep: SweepDeps{
			Repo: e.fault, Flags: sweepFlags{}, Limits: defaultSweepLimits(),
			Log: slog.New(slog.NewJSONHandler(e.logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
		},
	}
	for _, o := range opts {
		o(&e.deps)
	}
	e.svc = New(e.deps).(*service)
	// Every scenario ends with the posts invariant sweep (users.postsCount == posts by authorId).
	t.Cleanup(func() { assertPostsInvariants(t, client) })
	return e
}

// cold builds an instance whose identity directory has nothing cached (a fresh Cloud Run instance), so every handle in a
// draft is a real read: the worst case of the cost table.
func (e *sweepIT) cold() *service {
	d := e.deps
	d.Directory = identity.New(e.idRepo, identity.NewCache(time.Minute), 7*24*time.Hour).(identity.Directory)
	return New(d).(*service)
}

// second builds another instance (its own caches) over the same emulator project, repository and fakes.
func (e *sweepIT) second() *service {
	return New(e.deps).(*service)
}

func (e *sweepIT) signUp(uid, handle string) {
	e.t.Helper()
	if _, err := e.idSvc.CreateProfile(context.Background(), uid, "0123456789abcdef", handle, "Name "+uid); err != nil {
		e.t.Fatalf("CreateProfile %s: %v", uid, err)
	}
}

// signUpFriends signs up n users and returns a post text mentioning all of them.
func (e *sweepIT) signUpFriends(n int) string {
	e.t.Helper()
	text := ""
	for i := 0; i < n; i++ {
		h := fmt.Sprintf("friend%02d", i)
		e.signUp("uid-"+h, h)
		text += "@" + h + " "
	}
	return text
}

func (e *sweepIT) setUserField(uid, field string, value any) {
	e.t.Helper()
	if _, err := e.client.Collection("users").Doc(uid).Update(context.Background(), []firestore.Update{{Path: field, Value: value}}); err != nil {
		e.t.Fatalf("set users/%s.%s: %v", uid, field, err)
	}
}

func (e *sweepIT) seedMedia(owner string, fields map[string]any, ns ...int) {
	e.t.Helper()
	for _, n := range ns {
		d := map[string]any{"ownerId": owner, "status": "READY"}
		for k, v := range fields {
			d[k] = v
		}
		if _, err := e.client.Collection("media").Doc(sweepMediaID(n)).Set(context.Background(), d); err != nil {
			e.t.Fatal(err)
		}
	}
}

// seedDue stores a PENDING item of uid due 10 minutes ago (+ n seconds, which orders the items). mut adjusts it.
func (e *sweepIT) seedDue(uid string, n int, mut ...func(*ScheduledPost)) *ScheduledPost {
	e.t.Helper()
	id, err := ScheduledID(uid, schedKeyFor(n))
	if err != nil {
		e.t.Fatal(err)
	}
	now := time.Now().UTC()
	p := &ScheduledPost{
		ID: id, UID: uid, SchemaVersion: ScheduledSchemaVersion, PublishAt: now.Add(-10 * time.Minute).Add(time.Duration(n) * time.Second),
		Status: ScheduledPending, RequestHash: "h", CreatedAt: now.Add(-time.Hour), UpdatedAt: now.Add(-time.Hour),
		Draft: &ScheduledDraft{Text: fmt.Sprintf("hello %d", n)},
	}
	for _, m := range mut {
		m(p)
	}
	ref := e.client.Collection("users").Doc(uid).Collection("scheduled").Doc(id)
	if _, err := ref.Set(context.Background(), toScheduledDoc(p)); err != nil {
		e.t.Fatalf("seed %s: %v", id, err)
	}
	return p
}

func (e *sweepIT) raw(p *ScheduledPost) map[string]any {
	e.t.Helper()
	snap, err := e.client.Collection("users").Doc(p.UID).Collection("scheduled").Doc(p.ID).Get(context.Background())
	if err != nil {
		e.t.Fatalf("raw get: %v", err)
	}
	return snap.Data()
}

func (e *sweepIT) exists(p *ScheduledPost) bool {
	e.t.Helper()
	snap, err := e.client.Collection("users").Doc(p.UID).Collection("scheduled").Doc(p.ID).Get(context.Background())
	return err == nil && snap.Exists()
}

// postsOf returns the stored post docs of an author.
func (e *sweepIT) postsOf(uid string) []postDoc {
	e.t.Helper()
	var out []postDoc
	it := e.client.Collection(postsCollection).Where("authorId", "==", uid).Limit(50).Documents(context.Background())
	defer it.Stop()
	for {
		snap, err := it.Next()
		if errors.Is(err, iterator.Done) {
			return out
		}
		if err != nil {
			e.t.Fatal(err)
		}
		var d postDoc
		if err := snap.DataTo(&d); err != nil {
			e.t.Fatal(err)
		}
		out = append(out, d)
	}
}

func (e *sweepIT) quotaPosts(uid string) int64 {
	e.t.Helper()
	snap, err := e.client.Collection("quotas").Doc(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	var rec quota.Record
	if err := snap.DataTo(&rec); err != nil {
		e.t.Fatal(err)
	}
	return rec.Posts
}

func (e *sweepIT) postsCount(uid string) int64 {
	e.t.Helper()
	return fieldInt(e.t, e.client, "users/"+uid, "postsCount")
}

func (e *sweepIT) sweepWith(svc *service) (SweepResult, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	res, err := svc.Sweep(ctx)
	return res, c, err
}

func (e *sweepIT) sweep() (SweepResult, *budget.Counter) {
	e.t.Helper()
	res, c, err := e.sweepWith(e.svc)
	if err != nil {
		e.t.Fatalf("Sweep: %v", err)
	}
	return res, c
}

// assertCost fails when the run's cost is not exactly reads and writes (the ADR table rows are exact for a given path).
func assertCost(t *testing.T, name string, c *budget.Counter, reads, writes int64) {
	t.Helper()
	if c.Reads() != reads || c.Writes() != writes {
		t.Errorf("%s: cost = %d reads %d writes, want %d and %d", name, c.Reads(), c.Writes(), reads, writes)
	}
}

// TestSweepIT_PublishHappyPath: a due item becomes a post exactly like a CreatePost would have made it (author snapshot
// from the in-transaction profile, mentions resolved at publish, media from the fresh claim and attached), the item is
// PUBLISHED with its postId and no draft, the counters moved, and the post-commit hooks ran.
func TestSweepIT_PublishHappyPath(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.signUp("uid-bob", "bob")
	e.seedMedia("uid-alice", nil, 1, 2)
	it := e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{
			Text: "hi @bob @nobody #Topic", ReplyPolicy: ReplyPolicyMentionedOnly, PaidPartnership: true, MadeWithAI: true,
			// The stored URLs are stale on purpose: the published refs must come from the fresh claim.
			Media: []MediaRef{{ID: sweepMediaID(1), URL: "https://stale/1", AltText: "first alt"}, {ID: sweepMediaID(2), URL: "https://stale/2"}},
		}
	})

	res, c := e.sweep()
	if res.Outcome != SweepOK || res.Due != 1 || res.Published != 1 || res.Transient != 0 || len(res.Failed) != 0 {
		t.Fatalf("res = %+v", res)
	}
	// due query 1 + scheduled 1 + users 1 + quotas 1 + media 2 + handles 3 (bob, nobody: two candidates, cold cache => 2)
	// reads; writes: post, users.postsCount, quotas, scheduled, 2 media.
	if c.Reads() > 1+1+1+1+2+2 || c.Writes() != 6 {
		t.Errorf("run cost = %d reads %d writes, want <= 8 reads and exactly 6 writes", c.Reads(), c.Writes())
	}

	doc := e.raw(it)
	postID, _ := doc["postId"].(string)
	if doc["status"] != "PUBLISHED" || postID == "" || doc["draft"] != nil || doc["expireAt"] == nil || doc["failure"] != nil {
		t.Fatalf("scheduled doc = %v, want PUBLISHED with a postId, no draft, an expireAt", doc)
	}
	if exp := doc["expireAt"].(time.Time); time.Until(exp) < 167*time.Hour || time.Until(exp) > 169*time.Hour {
		t.Errorf("expireAt = %v, want about now + 7 days", exp)
	}

	posts := e.postsOf("uid-alice")
	if len(posts) != 1 {
		t.Fatalf("posts = %d, want 1", len(posts))
	}
	snap := storedPostDoc(t, e.client, postID)
	created, _ := snowflake.Time(postID)
	if snap.AuthorID != "uid-alice" || snap.Author.UserID != "uid-alice" || snap.Author.Handle != "alice" || snap.Author.DisplayName != "Name uid-alice" ||
		snap.Kind != string(KindPost) || snap.Text != "hi @bob @nobody #Topic" || snap.ConversationID != postID || !snap.CreatedAt.Equal(created) {
		t.Errorf("post = %+v", snap)
	}
	if len(snap.Hashtags) != 1 || snap.Hashtags[0] != "topic" || len(snap.Mentions) != 1 || snap.Mentions[0].UserID != "uid-bob" {
		t.Errorf("hashtags %v mentions %v, want [topic] and only the resolvable @bob", snap.Hashtags, snap.Mentions)
	}
	if snap.ReplyPolicy != "MENTIONED_ONLY" || !snap.PaidPartnership || !snap.MadeWithAI {
		t.Errorf("policy %q pp %v ai %v", snap.ReplyPolicy, snap.PaidPartnership, snap.MadeWithAI)
	}
	if len(snap.Media) != 2 || snap.Media[0].URL != "https://cdn.example/m/"+sweepMediaID(1) || snap.Media[0].AltText != "first alt" || snap.Media[1].AltText != "" {
		t.Errorf("media = %+v, want the fresh claim's refs with the draft's alt texts", snap.Media)
	}
	for _, n := range []int{1, 2} {
		if got, _ := e.mediaDoc(n)["postId"].(string); got != postID {
			t.Errorf("media %d attached to %q, want %q", n, got, postID)
		}
	}
	if e.postsCount("uid-alice") != 1 || e.quotaPosts("uid-alice") != 1 {
		t.Errorf("postsCount %d quota posts %d, want 1 and 1", e.postsCount("uid-alice"), e.quotaPosts("uid-alice"))
	}

	// The same post-commit hooks as CreatePost: PostEvents.Created (mention notifications, ADR-0017) with the resolved
	// mentions, and the author's cached profile dropped.
	e.events.mu.Lock()
	defer e.events.mu.Unlock()
	if len(e.events.created) != 1 || e.events.created[0].ID != postID || len(e.events.created[0].Mentions) != 1 || e.events.created[0].Mentions[0].UserID != "uid-bob" {
		t.Errorf("PostEvents.Created = %+v", e.events.created)
	}
	if _, ok := e.svc.cache.GetPost(postID); !ok {
		t.Error("the published post is not in the instance cache")
	}
}

func (e *sweepIT) mediaDoc(n int) map[string]any {
	e.t.Helper()
	snap, err := e.client.Collection("media").Doc(sweepMediaID(n)).Get(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	return snap.Data()
}

// TestSweepIT_PublishBudget pins the ADR cost table: "Publish one item" typical 3 reads (planning 4), worst 17, and 4 writes
// (+ one per image); the run adds the due query's reads.
func TestSweepIT_PublishBudget(t *testing.T) {
	t.Run("typical: no images, no mentions", func(t *testing.T) {
		e := newSweepIT(t)
		e.signUp("uid-alice", "alice")
		e.seedDue("uid-alice", 1)
		res, c := e.sweep()
		if res.Published != 1 {
			t.Fatalf("res = %+v", res)
		}
		// scheduled 1 + users 1 + quotas 1 = 3 reads (+ the query's 1); post, postsCount, quotas, scheduled = 4 writes.
		assertCost(t, "publish (typical)", c, 3+1, 4)
	})
	t.Run("worst case: 4 images and 10 mentions", func(t *testing.T) {
		e := newSweepIT(t)
		e.signUp("uid-alice", "alice")
		text := e.signUpFriends(10)
		e.seedMedia("uid-alice", nil, 1, 2, 3, 4)
		e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
			p.Draft = &ScheduledDraft{Text: text}
			for i := 1; i <= 4; i++ {
				p.Draft.Media = append(p.Draft.Media, MediaRef{ID: sweepMediaID(i)})
			}
		})
		// A cold instance: the sign-ups above warmed this one's handle cache, so every @mention would be free there.
		res, c, err := e.sweepWith(e.cold())
		if err != nil || res.Published != 1 {
			t.Fatalf("res = %+v err = %v", res, err)
		}
		// scheduled 1 + users 1 + quotas 1 + media 4 + handles 10 = 17 reads (+ the query's 1); 4 writes + 4 media updates.
		assertCost(t, "publish (worst case)", c, 17+1, 8)
		if p := e.postsOf("uid-alice"); len(p) != 1 || len(p[0].Mentions) != 10 || len(p[0].Media) != 4 {
			t.Errorf("post = %+v", p)
		}
	})
	t.Run("nothing due is one read", func(t *testing.T) {
		e := newSweepIT(t)
		res, c := e.sweep()
		if res.Due != 0 {
			t.Fatalf("res = %+v", res)
		}
		assertCost(t, "empty sweep", c, 1, 0)
	})
	t.Run("flag off is zero reads", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.Sweep.Flags = sweepFlags{ScheduledPostsFlagName: true} })
		e.signUp("uid-alice", "alice")
		it := e.seedDue("uid-alice", 1)
		res, c := e.sweep()
		if res.Outcome != SweepFlagOff {
			t.Fatalf("res = %+v", res)
		}
		assertCost(t, "flag off", c, 0, 0)
		if e.raw(it)["status"] != "PENDING" {
			t.Error("the item moved although the sweep is off")
		}
	})
	t.Run("readonly is zero reads", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.Sweep.ReadOnly = true })
		e.signUp("uid-alice", "alice")
		e.seedDue("uid-alice", 1)
		res, c := e.sweep()
		if res.Outcome != SweepDegraded {
			t.Fatalf("res = %+v", res)
		}
		assertCost(t, "readonly", c, 0, 0)
	})
}

// TestSweepIT_SkipsNonPendingItems: only PENDING docs are due. CANCELLED, PUBLISHED and FAILED docs (even with a past
// publishAt) are not touched, and a Cancel that lands between the query and the transaction wins (no post, no write).
func TestSweepIT_SkipsNonPendingItems(t *testing.T) {
	t.Run("terminal states are not due", func(t *testing.T) {
		e := newSweepIT(t)
		e.signUp("uid-alice", "alice")
		cancelled := e.seedDue("uid-alice", 1, func(p *ScheduledPost) { p.Status, p.Draft = ScheduledCancelled, nil })
		published := e.seedDue("uid-alice", 2, func(p *ScheduledPost) { p.Status, p.Draft, p.PostID = ScheduledPublished, nil, "1234567890123456789" })
		failed := e.seedDue("uid-alice", 3, func(p *ScheduledPost) { p.Status, p.Draft, p.Failure = ScheduledFailed, nil, FailureQuotaExceeded })
		res, c := e.sweep()
		if res.Due != 0 || res.Published != 0 {
			t.Fatalf("res = %+v, want nothing due", res)
		}
		assertCost(t, "only terminal docs", c, 1, 0)
		for _, it := range []*ScheduledPost{cancelled, published, failed} {
			if got := e.raw(it)["status"]; got == "PENDING" {
				t.Errorf("a terminal item changed to %v", got)
			}
		}
		if len(e.postsOf("uid-alice")) != 0 {
			t.Error("a post was created from a terminal item")
		}
	})
	t.Run("cancelled after the query: the transaction ends as a no-op", func(t *testing.T) {
		e := newSweepIT(t)
		e.signUp("uid-alice", "alice")
		it := e.seedDue("uid-alice", 1)
		e.fault.beforePublish = func(p PublishParams) {
			if _, _, err := e.repo.CancelScheduled(context.Background(), p.UID, p.ID, time.Now(), 168*time.Hour); err != nil {
				t.Errorf("CancelScheduled: %v", err)
			}
		}
		res, c := e.sweep()
		if res.Noop != 1 || res.Published != 0 {
			t.Fatalf("res = %+v, want a no-op", res)
		}
		// query 1 + the publish transaction's scheduled read 1 (the Cancel above runs on its own, uncounted context); no write.
		assertCost(t, "cancel race", c, 2, 0)
		if got := e.raw(it); got["status"] != "CANCELLED" || got["failure"] != nil {
			t.Errorf("doc = %v, want the user's CANCELLED untouched", got)
		}
		if len(e.postsOf("uid-alice")) != 0 || e.postsCount("uid-alice") != 0 || e.quotaPosts("uid-alice") != 0 {
			t.Error("a cancelled item published or reserved quota")
		}
	})
}

// TestSweepIT_TwoConcurrentSweepsPublishExactlyOnce: overlapping runs (a Scheduler retry plus the next tick) are safe
// because the publish transaction requires PENDING and commits PUBLISHED in the same write as the post.
func TestSweepIT_TwoConcurrentSweepsPublishExactlyOnce(t *testing.T) {
	e := newSweepIT(t)
	const authors = 4
	for a := 0; a < authors; a++ {
		uid := fmt.Sprintf("uid-a%d", a)
		e.signUp(uid, fmt.Sprintf("author%d", a))
		e.seedDue(uid, 1)
	}
	other := e.second()

	var wg sync.WaitGroup
	results := make([]SweepResult, 2)
	errs := make([]error, 2)
	for i, svc := range []*service{e.svc, other} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], _, errs[i] = e.sweepWith(svc)
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("sweep %d: %v", i, err)
		}
	}
	if got := results[0].Published + results[1].Published; got != authors {
		t.Errorf("published = %d + %d, want %d in total (each item exactly once)", results[0].Published, results[1].Published, authors)
	}
	for a := 0; a < authors; a++ {
		uid := fmt.Sprintf("uid-a%d", a)
		if n := len(e.postsOf(uid)); n != 1 {
			t.Errorf("%s has %d posts, want exactly 1", uid, n)
		}
		if e.postsCount(uid) != 1 || e.quotaPosts(uid) != 1 {
			t.Errorf("%s: postsCount %d quota %d, want 1 and 1", uid, e.postsCount(uid), e.quotaPosts(uid))
		}
	}
}

// TestSweepIT_FiveDueItemsOfOneAuthor: 3 are published one after another, 2 are deferred to the next run without any
// write (review L-3); the next run publishes the rest.
func TestSweepIT_FiveDueItemsOfOneAuthor(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	items := make([]*ScheduledPost, 5)
	for i := range items {
		items[i] = e.seedDue("uid-alice", i+1)
	}

	res, c := e.sweep()
	if res.Due != 5 || res.Published != 3 || res.Deferred != 2 {
		t.Fatalf("res = %+v, want 5 due, 3 published, 2 deferred", res)
	}
	for i, it := range items {
		want := "PUBLISHED"
		if i >= 3 {
			want = "PENDING"
		}
		if got := e.raw(it); got["status"] != want || (want == "PENDING" && got["attempts"] != int64(0)) {
			t.Errorf("item %d = %v, want %s untouched", i+1, got["status"], want)
		}
	}
	// 5 reads for the query + 3 publishes x 3 reads; 3 x 4 writes. The deferred items cost no write.
	assertCost(t, "5 due of one author", c, 5+9, 12)
	if e.fault.maxInflightBy["uid-alice"] != 1 {
		t.Errorf("one author's items overlapped: max in flight %d", e.fault.maxInflightBy["uid-alice"])
	}
	if e.postsCount("uid-alice") != 3 || e.quotaPosts("uid-alice") != 3 {
		t.Errorf("postsCount %d quota %d, want 3 and 3", e.postsCount("uid-alice"), e.quotaPosts("uid-alice"))
	}

	res2, _ := e.sweep()
	if res2.Published != 2 || res2.Deferred != 0 {
		t.Fatalf("second run = %+v, want the remaining 2 published", res2)
	}
}

// TestSweepIT_RetriedAttemptDrawsAFreshIDAndCollisionRedraws: the post id (and createdAt) is drawn inside every
// attempt, exactly as in CreatePost (ADR-0010 D13/D18): an Aborted attempt and an id collision both redraw.
func TestSweepIT_RetriedAttemptDrawsAFreshIDAndCollisionRedraws(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{
		{"an aborted attempt is retried by the client", errAborted()},
		{"an id collision at commit redraws", errAlreadyExists()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepIT(t)
			e.signUp("uid-alice", "alice")
			it := e.seedDue("uid-alice", 1)
			var seen []string
			e.repo.attemptHook = func(attempt int, id string) error {
				seen = append(seen, id)
				if attempt == 1 {
					return tc.err
				}
				return nil
			}
			res, _ := e.sweep()
			if res.Published != 1 || len(seen) != 2 {
				t.Fatalf("res = %+v, attempts = %d, want 1 published after 2 attempts", res, len(seen))
			}
			if got, _ := e.raw(it)["postId"].(string); got != seen[1] || got == seen[0] {
				t.Errorf("postId = %q, want the second attempt's %q (not %q)", got, seen[1], seen[0])
			}
			if n := len(e.postsOf("uid-alice")); n != 1 || e.postsCount("uid-alice") != 1 {
				t.Errorf("posts = %d postsCount = %d, want 1 and 1: the failed attempt left nothing behind", n, e.postsCount("uid-alice"))
			}
		})
	}
}
