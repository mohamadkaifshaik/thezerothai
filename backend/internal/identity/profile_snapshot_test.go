package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// P2 tests: the trigger side (UpdateProfile / ChangeHandle) over fakeRepo, and the job side over the lifecycle
// harness. The Firestore-backed paths are covered by backend/internal/apiserver's emulator test.

type fakeSnapFlags struct{ on bool }

func (f fakeSnapFlags) Enabled(_, name string) bool { return f.on && name == ProfileSnapshotFlag }

type fakeSnapQuota struct {
	perDay int64
	used   int64
	calls  int
}

func (q *fakeSnapQuota) Reserve(_ context.Context, _ string, perDay int64) error {
	q.calls++
	q.perDay = perDay
	if q.used >= perDay {
		return apierr.New(connect.CodeResourceExhausted, 0, "daily limit reached")
	}
	q.used++
	return nil
}

type snapEnv struct {
	repo  *fakeRepo
	svc   *service
	pub   *fakePublisher
	quota *fakeSnapQuota
}

func newSnapEnv(t *testing.T, flagOn bool) *snapEnv {
	t.Helper()
	repo := newFakeRepo()
	pub := &fakePublisher{log: &opLog{}}
	q := &fakeSnapQuota{}
	svc := New(repo, NewCache(60e9), 7*24*60*60*1e9,
		WithProfileSnapshots(ProfileSnapshotDeps{Publisher: pub, Flags: fakeSnapFlags{on: flagOn}, Quota: q, PerDay: 5}),
	).(*service)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return &snapEnv{repo: repo, svc: svc, pub: pub, quota: q}
}

func strp(s string) *string { return &s }

func TestUpdateProfile_DisplayNameChange_BumpsVersionAndEnqueues(t *testing.T) {
	e := newSnapEnv(t, true)
	got, err := e.svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, DisplayName: strp("Alice B.")})
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if got.SnapshotVersion != 1 {
		t.Fatalf("snapshotVersion = %d, want 1", got.SnapshotVersion)
	}
	msg, ok := e.pub.pop()
	if !ok || msg.Kind != JobKindProfileSnapshot || msg.UID != "uid-1" || msg.SnapshotVersion != 1 {
		t.Fatalf("published %+v ok=%v, want one profile_snapshot_refresh for uid-1 v1", msg, ok)
	}
	if e.pub.count() != 0 || e.quota.calls != 1 || e.quota.perDay != 5 {
		t.Fatalf("extra publishes or quota calls: pub=%d quota=%d perDay=%d", e.pub.count(), e.quota.calls, e.quota.perDay)
	}
}

func TestUpdateProfile_NoSnapshotChange_NoJobNoQuota(t *testing.T) {
	e := newSnapEnv(t, true)
	cases := map[string]UpdateProfileParams{
		"bio only":       {IdempotencyKey: validKey, Bio: strp("hello")},
		"same name":      {IdempotencyKey: validKey, DisplayName: strp("Alice A.")},
		"same name trim": {IdempotencyKey: validKey, DisplayName: strp("  Alice A.  ")},
	}
	for name, p := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := e.svc.UpdateProfile(context.Background(), "uid-1", p)
			if err != nil {
				t.Fatalf("UpdateProfile: %v", err)
			}
			if got.SnapshotVersion != 0 || e.pub.count() != 0 || e.quota.calls != 0 {
				t.Fatalf("version=%d published=%d quota=%d, want 0/0/0", got.SnapshotVersion, e.pub.count(), e.quota.calls)
			}
		})
	}
}

func TestUpdateProfile_FlagOff_BumpsVersionButNoQuotaNoJob(t *testing.T) {
	e := newSnapEnv(t, false)
	got, err := e.svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, DisplayName: strp("Alice B.")})
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if got.SnapshotVersion != 1 || e.pub.count() != 0 || e.quota.calls != 0 {
		t.Fatalf("version=%d published=%d quota=%d, want 1/0/0", got.SnapshotVersion, e.pub.count(), e.quota.calls)
	}
}

func TestUpdateProfile_DailyQuotaExhausted_RejectsBeforeWrite(t *testing.T) {
	e := newSnapEnv(t, true)
	e.quota.used = 5
	_, err := e.svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, DisplayName: strp("Alice B.")})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeResourceExhausted {
		t.Fatalf("err = %v, want RESOURCE_EXHAUSTED", err)
	}
	if e.repo.updateCalls != 0 || e.pub.count() != 0 {
		t.Fatalf("a rejected edit wrote (updates=%d) or published (%d)", e.repo.updateCalls, e.pub.count())
	}
	// A bio-only edit never spends the snapshot quota, so it still works at the limit.
	if _, err := e.svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, Bio: strp("hi")}); err != nil {
		t.Fatalf("bio-only edit at the limit: %v", err)
	}
}

func TestUpdateProfile_PublishFailure_NeverFailsTheRPC(t *testing.T) {
	e := newSnapEnv(t, true)
	e.pub.err = errors.New("pubsub down")
	got, err := e.svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, DisplayName: strp("Alice B.")})
	if err != nil || got.DisplayName != "Alice B." {
		t.Fatalf("UpdateProfile = %+v, %v; want success", got, err)
	}
}

func TestChangeHandle_EnqueuesOnlyWhenTheSnapshotChanged(t *testing.T) {
	e := newSnapEnv(t, true)
	ctx := context.Background()

	// A true no-op (same handle) does not move the version: no job.
	if _, err := e.svc.ChangeHandle(ctx, "uid-1", validKey, "Alice"); err != nil {
		t.Fatalf("no-op ChangeHandle: %v", err)
	}
	if e.pub.count() != 0 {
		t.Fatalf("no-op rename published %d jobs", e.pub.count())
	}

	got, err := e.svc.ChangeHandle(ctx, "uid-1", validKey, "Alicia")
	if err != nil {
		t.Fatalf("ChangeHandle: %v", err)
	}
	msg, ok := e.pub.pop()
	if !ok || msg.Kind != JobKindProfileSnapshot || msg.SnapshotVersion != got.SnapshotVersion || got.SnapshotVersion != 1 {
		t.Fatalf("published %+v ok=%v for version %d", msg, ok, got.SnapshotVersion)
	}
	if e.quota.calls != 0 {
		t.Fatalf("handle rename spent the snapshot-edit quota (%d calls); the 7-day cooldown bounds it", e.quota.calls)
	}
}

func TestChangeHandle_CooldownRefusal_NoJob(t *testing.T) {
	e := newSnapEnv(t, true)
	ctx := context.Background()
	if _, err := e.svc.ChangeHandle(ctx, "uid-1", validKey, "Alicia"); err != nil {
		t.Fatal(err)
	}
	e.pub.pop()
	if _, err := e.svc.ChangeHandle(ctx, "uid-1", validKey, "Alicia2"); err == nil {
		t.Fatal("second rename inside the cooldown must fail")
	}
	if e.pub.count() != 0 {
		t.Fatalf("a refused rename published %d jobs", e.pub.count())
	}
}

// --- job side ---

type fakeSnapWriter struct {
	calls   int
	uid     string
	fields  SnapshotFields
	version int64
	// applied is the version already on the posts: a replay of the same version rewrites nothing.
	applied int64
	posts   int
	err     error
}

func (w *fakeSnapWriter) RefreshAuthor(_ context.Context, uid string, f SnapshotFields, version int64) (int, error) {
	w.calls++
	w.uid, w.fields, w.version = uid, f, version
	if w.err != nil {
		return 0, w.err
	}
	if w.applied >= version {
		return 0, nil
	}
	w.applied = version
	return w.posts, nil
}

func snapHarness(t *testing.T, on bool, w *fakeSnapWriter) *harness {
	t.Helper()
	return newHarness(t, func(d *LifecycleDeps) {
		d.Snapshots = w
		d.Flags = fakeSnapFlags{on: on}
	})
}

func seedRenamed(h *harness, uid string, version int64) {
	p := h.seedActive(uid, "NewName")
	p.SnapshotVersion = version
	p.DisplayName = "New Display"
	h.repo.seed(p)
}

func TestJob_ProfileSnapshot_RewritesWithCurrentProfileAndIsReplaySafe(t *testing.T) {
	w := &fakeSnapWriter{posts: 7}
	h := snapHarness(t, true, w)
	seedRenamed(h, "uid-1", 3)
	msg := JobMessage{Kind: JobKindProfileSnapshot, UID: "uid-1", SnapshotVersion: 3}

	if code := h.deliver(msg, 1); code != http.StatusNoContent {
		t.Fatalf("delivery = %d, want 204", code)
	}
	if w.calls != 1 || w.uid != "uid-1" || w.version != 3 || w.fields.Handle != "NewName" || w.fields.DisplayName != "New Display" {
		t.Fatalf("writer got uid=%q version=%d fields=%+v calls=%d", w.uid, w.version, w.fields, w.calls)
	}
	recs := h.logs.records("account_job")
	if len(recs) != 1 || recs[0]["outcome"] != "refreshed" || recs[0]["updated_posts"] != float64(7) || recs[0]["account_job"] != "profile_snapshot" {
		t.Fatalf("log = %v", recs)
	}
	if strings.Contains(h.logs.String(), "uid-1") {
		t.Fatalf("raw uid in the log: %s", h.logs.String())
	}

	// Replay: acked, nothing rewritten.
	if code := h.deliver(msg, 2); code != http.StatusNoContent {
		t.Fatalf("replay = %d, want 204", code)
	}
	recs = h.logs.records("account_job")
	if got := recs[len(recs)-1]["outcome"]; got != "duplicate" {
		t.Fatalf("replay outcome = %v, want duplicate", got)
	}
}

func TestJob_ProfileSnapshot_UsesCurrentVersionNotTheMessage(t *testing.T) {
	// A message for v1 delivered after a second edit (v2) writes v2: the job never regresses a snapshot.
	w := &fakeSnapWriter{posts: 1}
	h := snapHarness(t, true, w)
	seedRenamed(h, "uid-1", 2)
	h.deliver(JobMessage{Kind: JobKindProfileSnapshot, UID: "uid-1", SnapshotVersion: 1}, 1)
	if w.version != 2 {
		t.Fatalf("writer version = %d, want the profile's current 2", w.version)
	}
}

func TestJob_ProfileSnapshot_FlagOffOrNoWriter_AcksWithoutWork(t *testing.T) {
	w := &fakeSnapWriter{posts: 1}
	h := snapHarness(t, false, w)
	seedRenamed(h, "uid-1", 1)
	if code := h.deliver(JobMessage{Kind: JobKindProfileSnapshot, UID: "uid-1", SnapshotVersion: 1}, 1); code != http.StatusNoContent {
		t.Fatalf("delivery = %d, want 204", code)
	}
	if w.calls != 0 {
		t.Fatalf("flag off still called the writer %d times", w.calls)
	}
	if got := h.logs.records("account_job")[0]["outcome"]; got != "dropped:disabled" {
		t.Fatalf("outcome = %v", got)
	}

	h2 := newHarness(t) // no Snapshots, no Flags
	seedRenamed(h2, "uid-1", 1)
	if code := h2.deliver(JobMessage{Kind: JobKindProfileSnapshot, UID: "uid-1", SnapshotVersion: 1}, 1); code != http.StatusNoContent {
		t.Fatalf("delivery without a writer = %d, want 204", code)
	}
}

func TestJob_ProfileSnapshot_Refusals(t *testing.T) {
	w := &fakeSnapWriter{posts: 1}
	h := snapHarness(t, true, w)
	h.seedDeleting("uid-del", "Gone", 0)
	cases := map[string]JobMessage{
		"deleting account": {Kind: JobKindProfileSnapshot, UID: "uid-del"},
		"missing account":  {Kind: JobKindProfileSnapshot, UID: "uid-none"},
		"invalid uid":      {Kind: JobKindProfileSnapshot, UID: "a/b"},
	}
	for name, msg := range cases {
		t.Run(name, func(t *testing.T) {
			if code := h.deliver(msg, 1); code != http.StatusNoContent {
				t.Fatalf("delivery = %d, want 204 (never retried)", code)
			}
		})
	}
	if w.calls != 0 {
		t.Fatalf("writer called %d times for refused messages", w.calls)
	}
}

func TestJob_ProfileSnapshot_WriterErrorNacks(t *testing.T) {
	w := &fakeSnapWriter{err: errors.New("firestore unavailable")}
	h := snapHarness(t, true, w)
	seedRenamed(h, "uid-1", 1)
	if code := h.deliver(JobMessage{Kind: JobKindProfileSnapshot, UID: "uid-1", SnapshotVersion: 1}, 1); code != http.StatusInternalServerError {
		t.Fatalf("delivery = %d, want 500 so Pub/Sub retries", code)
	}
}
