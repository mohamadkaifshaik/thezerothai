//go:build integration

package apiserver

// T16: the deletion chain on the emulators with fault injection. A rich account (posts, follow edges both ways,
// blocks both ways, a mute, a handle, a quota doc, a READY export with its object, a mention in someone else's post)
// is deleted by the production jobs handler wired over the REAL posts and graph Erasers, the real Firestore repo, the
// real Auth admin client (Auth emulator) and the real exports bucket (Storage emulator). Only the transport is faked:
// the jobs handler is driven directly, and every side effect is followed by an optional injected "instance death" (a
// panic the handler turns into a 500, exactly like a killed instance whose delivery Pub/Sub redelivers). One clean run
// counts the side effects; then each one is killed in turn, on a fresh account, and the final state must equal the
// clean run's. The T11 sweep and the graph/posts invariants run after every scenario.
//
// The start gate (120 s) and the 20 s work budget are LifecycleDeps test seams here (1 ns each), so a delivery runs
// exactly one step call and chains: every step boundary, checkpoint save and continuation publish is a crash point.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	fbauth "firebase.google.com/go/v4/auth"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

var errInjectedDeath = errors.New("injected instance death")

// crashPlan counts side effects and kills the "instance" after the at-th one (0 = never).
type crashPlan struct {
	mu    sync.Mutex
	n, at int
	ops   []string
	fired bool
}

func (c *crashPlan) after(op string) {
	c.mu.Lock()
	c.n++
	c.ops = append(c.ops, op)
	die := c.at == c.n
	if die {
		c.fired = true
	}
	c.mu.Unlock()
	if die {
		panic(errInjectedDeath)
	}
}

func (c *crashPlan) takeFired() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	f := c.fired
	c.fired = false
	return f
}

type crashRepo struct {
	identity.LifecycleRepo
	plan *crashPlan
}

func (r crashRepo) SaveJobState(ctx context.Context, uid string, ut time.Time, job identity.DeletionJob) error {
	err := r.LifecycleRepo.SaveJobState(ctx, uid, ut, job)
	if err == nil {
		r.plan.after("repo.SaveJobState")
	}
	return err
}

func (r crashRepo) DeletePrivate(ctx context.Context, uid string, limit int) (int, error) {
	n, err := r.LifecycleRepo.DeletePrivate(ctx, uid, limit)
	if err == nil {
		r.plan.after("repo.DeletePrivate")
	}
	return n, err
}

func (r crashRepo) DeleteHandleIfOwned(ctx context.Context, handleLower, uid string) (identity.HandleOutcome, error) {
	o, err := r.LifecycleRepo.DeleteHandleIfOwned(ctx, handleLower, uid)
	if err == nil {
		r.plan.after("repo.DeleteHandle")
	}
	return o, err
}

func (r crashRepo) DeleteQuotas(ctx context.Context, uid string) error {
	err := r.LifecycleRepo.DeleteQuotas(ctx, uid)
	if err == nil {
		r.plan.after("repo.DeleteQuotas")
	}
	return err
}

func (r crashRepo) DeleteExportDocs(ctx context.Context, ids []string) error {
	err := r.LifecycleRepo.DeleteExportDocs(ctx, ids)
	if err == nil {
		r.plan.after("repo.DeleteExportDocs")
	}
	return err
}

func (r crashRepo) DeleteUserDoc(ctx context.Context, uid string, seq int64) error {
	err := r.LifecycleRepo.DeleteUserDoc(ctx, uid, seq)
	if err == nil {
		r.plan.after("repo.DeleteUserDoc")
	}
	return err
}

type crashAuth struct {
	identity.AuthClient
	plan *crashPlan
}

func (a crashAuth) UpdateUser(ctx context.Context, uid string, u *fbauth.UserToUpdate) (*fbauth.UserRecord, error) {
	rec, err := a.AuthClient.UpdateUser(ctx, uid, u)
	if err == nil {
		a.plan.after("auth.UpdateUser")
	}
	return rec, err
}

func (a crashAuth) RevokeRefreshTokens(ctx context.Context, uid string) error {
	err := a.AuthClient.RevokeRefreshTokens(ctx, uid)
	if err == nil {
		a.plan.after("auth.RevokeRefreshTokens")
	}
	return err
}

func (a crashAuth) DeleteUser(ctx context.Context, uid string) error {
	err := a.AuthClient.DeleteUser(ctx, uid)
	if err == nil {
		a.plan.after("auth.DeleteUser")
	}
	return err
}

type crashObjects struct {
	identity.ObjectStore
	plan *crashPlan
}

func (o crashObjects) Delete(ctx context.Context, object string) error {
	err := o.ObjectStore.Delete(ctx, object)
	if err == nil {
		o.plan.after("obj.Delete")
	}
	return err
}

// noIDs is the engagement IDGenerator of a chain that never creates a REPOST.
type noIDs struct{}

func (noIDs) Generate() string { return "" }

// crashStep kills the instance after a registered Eraser's step call returned (its deletes are committed, its
// checkpoint is not yet saved).
type crashStep struct {
	identity.StepEraser
	plan *crashPlan
}

func (s crashStep) Run(ctx context.Context, uid string, cp []byte) ([]byte, bool, error) {
	next, done, err := s.StepEraser.Run(ctx, uid, cp)
	if err == nil {
		s.plan.after("step." + s.Name())
	}
	return next, done, err
}

// memPublisher is the jobs topic: continuations queue here, and the crash plan can kill the instance right after
// the publish (the message IS published, the delivery is not acked).
type memPublisher struct {
	plan *crashPlan
	mu   sync.Mutex
	q    []identity.JobMessage
}

func (p *memPublisher) Publish(_ context.Context, data []byte) error {
	var m identity.JobMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	p.mu.Lock()
	p.q = append(p.q, m)
	p.mu.Unlock()
	p.plan.after("publish")
	return nil
}

func (p *memPublisher) drain() []identity.JobMessage {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.q
	p.q = nil
	return out
}

// crashChain is a second Lifecycle over the same emulators as the lifecycleEnv's Build chain, wired for fault
// injection. Its handler is the production JobsHandler.
type crashChain struct {
	h    http.Handler
	plan *crashPlan
	pub  *memPublisher
	l    *identity.Lifecycle
}

// steppingClock is a clock that moves 1 ms on every read. The crash chain runs with a 1 ns work budget so every delivery
// does exactly one step call; on a coarse real clock two calls can share a tick, a run then records fewer side effects
// than the clean run, and a death planned at one of the last operations never fires (issue #259). The other source of run-to-run variation was the 120 s start gate: pastGate removes it.
func steppingClock() func() time.Time {
	var mu sync.Mutex
	now := time.Now()
	return func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		now = now.Add(time.Millisecond)
		return now
	}
}

func (e *lifecycleEnv) newCrashChain(t *testing.T, plan *crashPlan) *crashChain {
	t.Helper()
	authc := emulatorAuth{host: os.Getenv("FIREBASE_AUTH_EMULATOR_HOST"), project: e.cfg.ProjectID}
	graphRepo := graph.NewFirestoreRepo(e.fs)
	idRepo := identity.NewFirestoreRepo(e.fs, graphRepo)
	graphRepo.SetCounters(idRepo)
	graphRepo.SetProfiles(idRepo)
	postsRepo := posts.NewFirestoreRepo(e.fs)
	// The purge copy phase and the engagement step need the same collaborators as Build wires (P5).
	postsRepo.SetWriters(posts.WriteDeps{Counters: idRepo})
	engRepo := engagement.NewFirestoreRepo(e.fs, engagement.WriteDeps{Quotas: quota.New(e.fs), Writer: postsRepo, Counters: idRepo, IDs: noIDs{}})
	postsRepo.SetRepostLinks(engRepo)
	objs, err := objstore.New(e.bucket.BucketName())
	if err != nil {
		t.Fatal(err)
	}
	pub := &memPublisher{plan: plan}
	l, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: crashRepo{idRepo, plan}, Cache: identity.NewCache(e.cfg.CacheTTL), Publisher: pub,
		Auth: crashAuth{authc, plan}, Objects: crashObjects{objs, plan},
		Log: slog.New(slog.NewJSONHandler(io.Discard, nil)), ProjectID: e.cfg.ProjectID,
		ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute,
		Now:        steppingClock(),
		WorkBudget: time.Nanosecond, StartGate: time.Nanosecond, RetryBackoff: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []identity.StepEraser{postsEraserStep(postsRepo), graphEraserStep(graphRepo), engagementEraserStep(engRepo), scheduledEraserStep(posts.NewScheduledEraser(postsRepo)), bookmarkEraserStep(engagement.NewBookmarkEraser(engRepo)), messagingEraserStep(messaging.NewFirestoreRepo(e.fs, nil), nil), listsEraserStep(lists.NewEraser(lists.NewFirestoreRepo(e.fs, nil, nil)))} {
		if err := l.RegisterEraser(identity.BeforeIdentity, crashStep{s, plan}); err != nil {
			t.Fatal(err)
		}
	}
	return &crashChain{h: l.JobsHandler(), plan: plan, pub: pub, l: l}
}

func (c *crashChain) deliver(msg identity.JobMessage, attempt int) int {
	raw, _ := json.Marshal(msg)
	body, _ := json.Marshal(map[string]any{
		"message": map[string]any{"data": base64.StdEncoding.EncodeToString(raw), "messageId": "m"}, "subscription": "s", "deliveryAttempt": attempt,
	})
	rec := httptest.NewRecorder()
	c.h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/pubsub/jobs", bytes.NewReader(body)))
	return rec.Code
}

// pump plays Pub/Sub: the head message is redelivered until it is acked (204); continuations queue behind it, whether
// or not the delivery that published them survived. It returns the number of injected deaths and deliveries.
func (c *crashChain) pump(t *testing.T, first identity.JobMessage) (deaths, deliveries int) {
	t.Helper()
	queue, attempt := []identity.JobMessage{first}, 1
	for deliveries < 400 {
		if len(queue) == 0 {
			return deaths, deliveries
		}
		code := c.deliver(queue[0], attempt)
		deliveries++
		if c.plan.takeFired() {
			deaths++
		}
		queue = append(queue, c.pub.drain()...)
		if code == http.StatusNoContent {
			queue, attempt = queue[1:], 1
		} else {
			attempt++
		}
	}
	t.Fatalf("job still in flight after %d deliveries; ops %v", deliveries, c.plan.ops)
	return deaths, deliveries
}

// richAccount is the T16 seed: one account with every kind of relationship and a READY export.
type richAccount struct {
	a testUser
	f1, f2 /* A follows */, g1, g2/* follow A */ testUser
	blockedByA, blocksA, mutedByA testUser
	handle                        string
	exportID                      string
	dmConv                        string // a conversation tree with a gone peer: A's erasure deletes all of it (ADR-0027 D8)
	roles                         map[string]string
	cohort                        []string
}

func (e *lifecycleEnv) call(t *testing.T, what string, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
}

// rich seeds the account through the production RPCs: edges both ways, blocks both ways, a mute, 2 posts, a mention of
// A in someone else's post, and one export taken to READY. Counters, quotas, graph docs and the handle are real.
func (e *lifecycleEnv) rich(t *testing.T) richAccount {
	t.Helper()
	ctx := context.Background()
	r := richAccount{a: e.newUser(t)}
	r.f1, r.f2, r.g1, r.g2 = e.newUser(t), e.newUser(t), e.newUser(t), e.newUser(t)
	r.blockedByA, r.blocksA, r.mutedByA = e.newUser(t), e.newUser(t), e.newUser(t)
	key := func(what string, u testUser) string { return fmt.Sprintf("rich-%s-%s", what, u.uid[:12]) }

	me, err := e.identity.GetMe(ctx, authed(r.a.token, &identityv1.GetMeRequest{}))
	e.call(t, "GetMe", err)
	r.handle = me.Msg.GetProfile().GetHandle()

	e.follow(t, r.a, r.f1)
	e.follow(t, r.a, r.f2)
	e.follow(t, r.g1, r.a)
	e.follow(t, r.g2, r.a)
	_, err = e.graph.Block(ctx, authed(r.a.token, &graphv1.BlockRequest{IdempotencyKey: key("block", r.blockedByA), UserId: r.blockedByA.uid}))
	e.call(t, "Block (A blocks X)", err)
	_, err = e.graph.Block(ctx, authed(r.blocksA.token, &graphv1.BlockRequest{IdempotencyKey: key("blockA", r.blocksA), UserId: r.a.uid}))
	e.call(t, "Block (Y blocks A)", err)
	_, err = e.graph.Mute(ctx, authed(r.a.token, &graphv1.MuteRequest{IdempotencyKey: key("mute", r.mutedByA), UserId: r.mutedByA.uid}))
	e.call(t, "Mute", err)
	for i := range 2 {
		_, err = e.posts.CreatePost(ctx, authed(r.a.token, &postsv1.CreatePostRequest{IdempotencyKey: fmt.Sprintf("rich-post-%s-%d", r.a.uid[:12], i), Text: fmt.Sprintf("a post %d #rich", i)}))
		e.call(t, "CreatePost", err)
	}
	_, err = e.posts.CreatePost(ctx, authed(r.f1.token, &postsv1.CreatePostRequest{IdempotencyKey: "rich-mention-" + r.f1.uid[:12], Text: "hello @" + r.handle}))
	e.call(t, "CreatePost (mention)", err)

	// Scheduled posts live under users/{uid}/scheduled, which deleting users/{uid} does not remove (ADR-0021).
	e.seedScheduled(t, r.a.uid, "rich-sched-pending-0001", "PENDING")
	e.seedScheduled(t, r.a.uid, "rich-sched-cancelled-01", "CANCELLED")
	// Bookmarks live under users/{uid}/bookmarks (ADR-0023), also not removed with users/{uid}.
	e.seedBookmarks(t, r.a.uid, 3)
	// Conversations live in their own root collection and under users/{uid}/dmInbox, which deleting users/{uid} does not
	// remove (ADR-0027 D8). This one has a peer that deleted its account already, so A's erasure deletes the whole tree.
	r.dmConv = e.seedGoneConversation(t, r.a.uid)

	exp, err := e.identity.RequestAccountExport(ctx, authed(r.a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "rich-export-" + r.a.uid[:12]}))
	e.call(t, "RequestAccountExport", err)
	r.exportID = exp.Msg.GetExportId()
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	snap, err := e.fs.Doc("exports/" + r.exportID).Get(ctx)
	e.call(t, "read export", err)
	if st, _ := snap.DataAt("status"); st != "READY" {
		t.Fatalf("export status = %v, want READY", st)
	}

	r.roles = map[string]string{
		r.a.uid: "A", r.f1.uid: "f1", r.f2.uid: "f2", r.g1.uid: "g1", r.g2.uid: "g2",
		r.blockedByA.uid: "X(blocked by A)", r.blocksA.uid: "Y(blocks A)", r.mutedByA.uid: "Z(muted by A)",
	}
	for uid := range r.roles {
		r.cohort = append(r.cohort, uid)
	}
	slices.Sort(r.cohort)
	return r
}

// seedBookmarks writes n users/{uid}/bookmarks documents and the matching userLikes.bookmarks set (ADR-0023 D3).
func (e *lifecycleEnv) seedBookmarks(t *testing.T, uid string, n int) {
	t.Helper()
	ids := make([]string, n)
	for i := range ids {
		ids[i] = fmt.Sprintf("%019d", 900+i)
		if _, err := e.fs.Doc("users/"+uid+"/bookmarks/"+ids[i]).Set(context.Background(), map[string]any{"createdAt": time.Now().UTC().Add(time.Duration(i) * time.Minute)}); err != nil {
			t.Fatalf("seed bookmark: %v", err)
		}
	}
	if _, err := e.fs.Doc("userLikes/"+uid).Set(context.Background(), map[string]any{"bookmarks": ids}, firestore.MergeAll); err != nil {
		t.Fatalf("seed userLikes.bookmarks: %v", err)
	}
}

// seedScheduled writes one users/{uid}/scheduled document in the stored shape (ADR-0021): a PENDING one holds a draft,
// a CANCELLED one does not and carries an expireAt. The key makes the id.
func (e *lifecycleEnv) seedScheduled(t *testing.T, uid, key, status string) {
	t.Helper()
	id, err := posts.ScheduledID(uid, key)
	if err != nil {
		t.Fatalf("ScheduledID: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Minute)
	publishAt := now.Add(48 * time.Hour) // a CANCELLED one is later, so the export order (publishAt) is stable
	if status == "CANCELLED" {
		publishAt = now.Add(72 * time.Hour)
	}
	doc := map[string]any{
		"schemaVersion": 1, "status": status, "publishAt": publishAt, "attempts": 0,
		"requestHash": "h", "createdAt": now, "updatedAt": now,
	}
	if status == "CANCELLED" {
		doc["expireAt"] = now.Add(7 * 24 * time.Hour)
	} else {
		doc["draft"] = map[string]any{"text": "scheduled draft of " + status, "madeWithAi": true}
	}
	if _, err := e.fs.Doc("users/"+uid+"/scheduled/"+id).Set(context.Background(), doc); err != nil {
		t.Fatalf("seed scheduled: %v", err)
	}
}

// beginDeletion requests the deletion through the real chain and returns the seq-0 job message.
func (e *lifecycleEnv) beginDeletion(t *testing.T, r richAccount, key string) identity.JobMessage {
	t.Helper()
	_, err := e.identity.DeleteAccount(context.Background(), authed(r.a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: key}))
	e.call(t, "DeleteAccount", err)
	for _, m := range e.pull(t) {
		if m["kind"] == identity.JobKindAccountDelete && m["uid"] == r.a.uid {
			return identity.JobMessage{Kind: identity.JobKindAccountDelete, UID: r.a.uid, Seq: 0}
		}
	}
	t.Fatal("DeleteAccount published no job message")
	return identity.JobMessage{}
}

// digest describes the end state of the counterparts by role (never by uid), so two runs on different uids compare.
func (e *lifecycleEnv) digest(t *testing.T, r richAccount) string {
	t.Helper()
	ctx := context.Background()
	role := func(uid string) string {
		if n, ok := r.roles[uid]; ok {
			return n
		}
		return "?" + uid
	}
	roles := func(v any) string {
		var out []string
		for uid := range stringSet(v) {
			out = append(out, role(uid))
		}
		slices.Sort(out)
		return strings.Join(out, ",")
	}
	var lines []string
	for _, uid := range r.cohort {
		u, err := e.fs.Doc("users/" + uid).Get(ctx)
		if err != nil || !u.Exists() {
			lines = append(lines, role(uid)+": gone")
			continue
		}
		g, err := e.fs.Doc("graph/" + uid).Get(ctx)
		e.call(t, "graph doc", err)
		field := func(snap interface{ DataAt(string) (any, error) }, name string) any {
			v, _ := snap.DataAt(name)
			return v
		}
		lines = append(lines, fmt.Sprintf("%s: followers=%d following=%d posts=%d | following=[%s] blocked=[%s] blockedBy=[%s] muted=[%s]",
			role(uid), asInt(field(u, "followersCount")), asInt(field(u, "followingCount")), asInt(field(u, "postsCount")),
			roles(field(g, "following")), roles(field(g, "blocked")), roles(field(g, "blockedBy")), roles(field(g, "muted"))))
	}
	slices.Sort(lines)
	return strings.Join(lines, "\n")
}

// requireRichErased checks everything of A's that must be gone and the rest of the end state.
func (e *lifecycleEnv) requireRichErased(t *testing.T, r richAccount) {
	t.Helper()
	ctx := context.Background()
	for _, path := range []string{"users/" + r.a.uid, "graph/" + r.a.uid, "quotas/" + r.a.uid, "handles/" + strings.ToLower(r.handle), "exports/" + r.exportID} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if present, _ := e.authUser(t, r.a.uid); present {
		t.Error("the Firebase Auth user survived")
	}
	if _, err := e.bucket.Object(r.exportID + ".json").Attrs(ctx); err == nil {
		t.Error("the export object survived")
	}
	if docs, err := e.fs.Doc("users/" + r.a.uid).Collection("scheduled").Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("users/{uid}/scheduled survived the scheduled step: %d docs, err %v", len(docs), err)
	}
	if docs, err := e.fs.Doc("users/" + r.a.uid).Collection("bookmarks").Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("users/{uid}/bookmarks survived the bookmarks step: %d docs, err %v", len(docs), err)
	}
	if fsDocExists(t, e.fs, "userLikes/"+r.a.uid) {
		t.Error("userLikes survived (or the bookmarks step recreated it)")
	}
	for _, other := range []testUser{r.blockedByA, r.blocksA, r.mutedByA} {
		if !fsDocExists(t, e.fs, "users/"+other.uid) {
			t.Errorf("counterpart %s was deleted with A", other.uid)
		}
	}
	if r.dmConv != "" {
		e.requireMessagingGone(t, r.dmConv)
		if fsDocExists(t, e.fs, "users/"+r.a.uid+"/dmInbox/"+r.dmConv) {
			t.Error("users/{uid}/dmInbox survived the messaging step")
		}
	}
	e.requireNoResidue(t, r.a.uid)
	e.requireInvariants(t, r.cohort)
}

// TestAccountLifecycle_RichAccountCrashAtEverySideEffect is the T16 crash-resume matrix: kill the instance after each
// side effect of a complete deletion in turn and require the same end state as a run without a crash.
func TestAccountLifecycle_RichAccountCrashAtEverySideEffect(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds one rich account per crash point")
	}
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	// Clean run: fixes the number of side effects and the expected end state.
	clean := e.rich(t)
	cleanPlan := &crashPlan{}
	cc := e.newCrashChain(t, cleanPlan)
	msg := e.beginDeletion(t, clean, "crash-clean-delete-0001")
	e.pastGate(t, clean.a.uid) // the first delivery must not be nacked by the start gate, or the clean run repeats the Auth disable
	deaths, deliveries := cc.pump(t, msg)
	if deaths != 0 {
		t.Fatalf("clean run had %d deaths", deaths)
	}
	e.requireRichErased(t, clean)
	want := e.digest(t, clean)
	total := cleanPlan.n
	t.Logf("clean run: %d side effects over %d deliveries; ops %v", total, deliveries, cleanPlan.ops)
	if total < 15 {
		t.Fatalf("a clean run recorded only %d side effects; the scenario is too small to mean anything", total)
	}
	assertOrder(t, cleanPlan.ops)

	for k := 1; k <= total; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k, cleanPlan.ops[k-1]), func(t *testing.T) {
			r := e.rich(t)
			plan := &crashPlan{at: k}
			cc := e.newCrashChain(t, plan)
			msg := e.beginDeletion(t, r, fmt.Sprintf("crash-delete-key-%04d", k))
			e.pastGate(t, r.a.uid)
			deaths, _ := cc.pump(t, msg)
			if deaths != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d)\n got  %v\n want %v", deaths, plan.n, total, plan.ops, cleanPlan.ops)
			}
			assertOrder(t, plan.ops)
			e.requireRichErased(t, r)
			if got := e.digest(t, r); got != want {
				t.Errorf("end state differs from the clean run.\n--- clean\n%s\n--- death after op %d (%s)\n%s", want, k, plan.ops[k-1], got)
			}
		})
	}
}

// assertOrder checks ADR-0011 Q1 on the recorded side effects whatever the crash: the Auth disable first, posts then
// graph, the identity step, the Auth user, and users/{uid} last with nothing after it.
func assertOrder(t *testing.T, ops []string) {
	t.Helper()
	first := func(op string) int { return slices.Index(ops, op) }
	chain := []string{"auth.UpdateUser", "step.posts", "step.graph", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}
	for _, op := range chain {
		if first(op) < 0 {
			t.Fatalf("%q never happened: %v", op, ops)
		}
	}
	for i := 1; i < len(chain); i++ {
		if first(chain[i-1]) > first(chain[i]) {
			t.Errorf("%q came after %q: %v", chain[i-1], chain[i], ops)
		}
	}
	if last := slices.Index(ops, "repo.DeleteUserDoc"); last != len(ops)-1 {
		t.Errorf("operations after users/{uid} was deleted: %v", ops[last+1:])
	}
	if first("obj.Delete") < 0 || first("obj.Delete") > first("repo.DeleteExportDocs") {
		t.Errorf("export object must be deleted before its doc: %v", ops)
	}
}

// relaxLimits lifts the per-minute and per-day abuse limits that would throttle seeding hundreds of accounts from
// one loopback address. The limits themselves are covered by their own tests.
func relaxLimits(c *config.Config) {
	c.RateLimit.PreAuthIPPerMinute = 1_000_000
	c.RateLimit.PerIPPerMinute = 1_000_000
	c.RateLimit.PerUserPerMinute = 1_000_000
	c.RateLimit.PostCreatePerMinute = 1_000_000
	c.RateLimit.GraphFollowPerMinute = 1_000_000
	c.RateLimit.GraphBlockPerMinute = 1_000_000
	c.RateLimit.GraphMutationsPerDay = 1_000_000
	c.RateLimit.ReadBudgetPerUIDPerDay = 100_000_000
	c.Quota.PostsPerDay, c.Quota.NewAccountPostsPerDay = 1_000_000, 1_000_000
	c.Quota.FollowsPerDay, c.Quota.NewAccountFollowsPerDay = 1_000_000, 1_000_000
	c.Quota.BlocksPerDay, c.Quota.NewAccountBlocksPerDay = 1_000_000, 1_000_000
}

// TestAccountLifecycle_RichAccountConcurrentDeliveries: the same rich account erased by racing deliveries of one
// message through the production chain (T8/T16: "two concurrent deliveries"). The end state equals a serial run's, the
// sweep is clean and the invariants hold.
func TestAccountLifecycle_RichAccountConcurrentDeliveries(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	serial := e.rich(t)
	msg := e.beginDeletion(t, serial, "rich-serial-delete-01")
	e.pastGate(t, serial.a.uid)
	for code := 0; code != http.StatusNoContent; {
		code = e.deliverJSON(t, msg)
	}
	e.requireRichErased(t, serial)
	want := e.digest(t, serial)

	for round := range 2 {
		r := e.rich(t)
		msg := e.beginDeletion(t, r, fmt.Sprintf("rich-race-delete-%02d", round))
		e.pastGate(t, r.a.uid)
		var wg sync.WaitGroup
		codes := make([]int, 3)
		start := make(chan struct{})
		for i := range codes {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				codes[i] = e.deliverJSON(t, msg)
			}()
		}
		close(start)
		wg.Wait()
		for i, c := range codes {
			for tries := 0; c != http.StatusNoContent && tries < 8; tries++ {
				c = e.deliverJSON(t, msg)
			}
			if c != http.StatusNoContent {
				t.Errorf("round %d racer %d never reached 204", round, i)
			}
		}
		// A racing delivery may have chained a continuation: drain until the job is done.
		for _, m := range e.pull(t) {
			if m["kind"] == identity.JobKindAccountDelete {
				for code := 0; code != http.StatusNoContent; {
					code = e.deliver(t, m)
				}
			}
		}
		e.requireRichErased(t, r)
		if got := e.digest(t, r); got != want {
			t.Errorf("round %d: end state differs from the serial run.\n--- serial\n%s\n--- racing\n%s", round, want, got)
		}
		_ = ctx
	}
}

// emulatorAuth is an identity.AuthClient over the Auth emulator's REST admin API. The real Admin SDK client may only be
// built in the files ADR-0011 control C2 allows (TestAuthAdminConfinement), so the fault-injection chain talks to the
// emulator directly. The one behavioural difference is that an already-deleted user is reported as success here,
// instead of through the SDK's not-found error that identity's wrapper classifies; that classification against the real
// SDK is TestAccountLifecycle_AuthUserAlreadyGone.
type emulatorAuth struct{ host, project string }

func (a emulatorAuth) post(ctx context.Context, op string, body map[string]any) (int, []byte, error) {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:%s", a.host, a.project, op), bytes.NewReader(raw))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer owner")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out, nil
}

func (a emulatorAuth) call(ctx context.Context, op string, body map[string]any) error {
	status, out, err := a.post(ctx, op, body)
	switch {
	case err != nil:
		return err
	case status == http.StatusOK:
		return nil
	case strings.Contains(string(out), "USER_NOT_FOUND"):
		return nil
	}
	return fmt.Errorf("auth emulator %s: status %d: %s", op, status, out)
}

func (a emulatorAuth) GetUser(_ context.Context, uid string) (*fbauth.UserRecord, error) {
	return &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: uid}}, nil
}

func (a emulatorAuth) UpdateUser(ctx context.Context, uid string, _ *fbauth.UserToUpdate) (*fbauth.UserRecord, error) {
	// The only update the lifecycle makes is Disabled(true).
	return &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: uid}}, a.call(ctx, "update", map[string]any{"localId": uid, "disableUser": true})
}

func (a emulatorAuth) RevokeRefreshTokens(ctx context.Context, uid string) error {
	return a.call(ctx, "update", map[string]any{"localId": uid, "validSince": fmt.Sprint(time.Now().Unix())})
}

func (a emulatorAuth) DeleteUser(ctx context.Context, uid string) error {
	return a.call(ctx, "delete", map[string]any{"localId": uid})
}
