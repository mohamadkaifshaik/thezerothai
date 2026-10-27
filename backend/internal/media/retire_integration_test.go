//go:build integration

package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// ADR-0024 Amendment 1 A4 over the real Firestore repo and, for the eraser, the Storage emulator. The users/{uid}
// read is a fake here (it lives in identity and is charged there; the apiserver chain test asserts the whole job at 2
// reads and 1 write). The emulator does not implement objects.patch, so a counting tagger records the customTime
// patches the step makes and delegates to the real Buckets (which accepts the emulator's 501).

type countingTagger struct {
	mu    sync.Mutex
	inner PublicTagger
	calls []taggedObject
}

func (c *countingTagger) SetPublicCustomTime(ctx context.Context, object string, at time.Time) error {
	c.mu.Lock()
	c.calls = append(c.calls, taggedObject{object: object, at: at})
	c.mu.Unlock()
	return c.inner.SetPublicCustomTime(ctx, object, at)
}

type retireIntEnv struct {
	client  *firestore.Client
	repo    *FirestoreRepo
	lib     *Library
	buckets *Buckets
	tagger  *countingTagger
	users   *fakeProfileImages
	jobs    *Jobs
}

func newRetireIntEnv(t *testing.T, mode config.ProfileMediaRetire) *retireIntEnv {
	t.Helper()
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client := newIntegrationClient(t)
	repo := NewFirestoreRepo(client, WriteDeps{})
	n := rand.Int64()
	buckets, err := NewBuckets(fmt.Sprintf("demo-upload-%d", n), fmt.Sprintf("demo-public-%d", n))
	if err != nil {
		t.Fatal(err)
	}
	e := &retireIntEnv{
		client: client, repo: repo, lib: NewLibrary(repo, "https://cdn.test/media"), buckets: buckets,
		tagger: &countingTagger{inner: buckets}, users: &fakeProfileImages{urls: map[string][]string{}},
	}
	e.jobs = NewJobs(repo, buckets, fakePosts{}, nil).WithProfileRetire(RetireDeps{
		Mode: mode, Users: e.users, Tagger: e.tagger, Now: func() time.Time { return retireNow },
	})
	return e
}

// seed writes a READY profile image the way FinalizeUpload leaves it (public objects included when put is true).
func (e *retireIntEnv) seed(t *testing.T, owner string, purpose Purpose, put bool) string {
	t.Helper()
	id := fmt.Sprintf("%019d", 5_000_000_000_000_000_000+rand.Int64N(1_000_000_000))
	d := Doc{
		OwnerID: owner, Purpose: string(purpose), Status: string(StatusReady), ContentType: "image/webp", Bytes: 1000, ThumbBytes: 100,
		Width: 1500, Height: 500, PublicPath: "m/" + id + ".webp", ThumbPath: "m/" + id + "_t.webp", CreatedAt: retireNow.Add(-24 * time.Hour),
	}
	if _, err := e.client.Collection("media").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if put {
		for _, name := range []string{d.PublicPath, d.ThumbPath} {
			if err := e.buckets.Public.Put(context.Background(), name, "image/webp", func(w io.Writer) error { _, err := io.WriteString(w, "bytes"); return err }); err != nil {
				t.Fatalf("put %s: %v", name, err)
			}
		}
	}
	return id
}

func (e *retireIntEnv) msg(owner string, purpose Purpose, id string, at time.Time) RetireMessage {
	full, thumb := "https://cdn.test/media/m/"+id+".webp", "https://cdn.test/media/m/"+id+"_t.webp"
	return RetireMessage{Kind: JobKindProfileMediaRetired, UID: owner, Purpose: string(purpose), OldURL: full, OldThumbURL: thumb, ChangedAt: at}
}

func (e *retireIntEnv) raw(t *testing.T, id string) map[string]any {
	t.Helper()
	s, err := e.client.Collection("media").Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("media/%s: %v", id, err)
	}
	return s.Data()
}

func (e *retireIntEnv) objectExists(t *testing.T, name string) bool {
	t.Helper()
	_, err := e.buckets.Public.Attrs(context.Background(), name)
	switch {
	case err == nil:
		return true
	case errors.Is(err, objstore.ErrObjectNotFound):
		return false
	}
	t.Fatalf("attrs %s: %v", name, err)
	return false
}

// TestIntegration_RetireBudgetAndRedelivery: the media side of the step is 1 read (media/{id}) and 1 write (the
// document), 2 customTime patches; a redelivery after completion is 1 read, 0 writes and no GCS call.
func TestIntegration_RetireBudgetAndRedelivery(t *testing.T) {
	e := newRetireIntEnv(t, config.ProfileMediaRetireAll)
	id := e.seed(t, uidA, PurposeBanner, false)
	at := retireNow.Add(-30 * time.Minute)

	ctx, c := counted()
	out, err := e.jobs.Retire(ctx, e.msg(uidA, PurposeBanner, id, at))
	if err != nil || out != "retired" {
		t.Fatalf("Retire = %q, %v", out, err)
	}
	budgettest.Assert(t, "retire", c, budgettest.Budget{Reads: 1, Writes: 1})
	if c.Reads() != 1 || c.Writes() != 1 {
		t.Errorf("reads=%d writes=%d, want exactly 1 and 1 (media doc read, document write; the users read is identity's)", c.Reads(), c.Writes())
	}
	if len(e.tagger.calls) != 2 {
		t.Errorf("customTime patches = %d, want 2 (full and thumb)", len(e.tagger.calls))
	}
	if e.users.reads != 1 {
		t.Errorf("users reads = %d, want 1 (the fresh users/{uid} read)", e.users.reads)
	}

	ctx, c = counted()
	out, err = e.jobs.Retire(ctx, e.msg(uidA, PurposeBanner, id, at))
	if err != nil || out != "duplicate" {
		t.Fatalf("redelivery = %q, %v", out, err)
	}
	budgettest.Assert(t, "retire redelivery", c, budgettest.Budget{Reads: 1, Writes: 0})
	if c.Writes() != 0 || len(e.tagger.calls) != 2 {
		t.Errorf("a redelivery wrote %d times and made %d patches in total (want 0 writes, still 2 patches)", c.Writes(), len(e.tagger.calls))
	}

	// A refused message costs the same 1 read and 0 writes.
	other := e.seed(t, uidB, PurposeBanner, false)
	ctx, c = counted()
	if out, err = e.jobs.Retire(ctx, e.msg(uidA, PurposeBanner, other, at)); err != nil || out != "refused" {
		t.Fatalf("another owner's image = %q, %v", out, err)
	}
	budgettest.Assert(t, "retire refused", c, budgettest.Budget{Reads: 1, Writes: 0})
	if _, has := e.raw(t, other)["retiredAt"]; has {
		t.Error("another owner's document was marked retired")
	}
}

// TestIntegration_RetireWritesOnlyTheTwoFields: a field-level Update of retiredAt and expireAt under a LastUpdateTime
// precondition; nothing else on the document moves, a stale precondition and a missing document are ErrConflict, and a
// missing document is never recreated (Update, not Set).
func TestIntegration_RetireWritesOnlyTheTwoFields(t *testing.T) {
	e := newRetireIntEnv(t, config.ProfileMediaRetireAll)
	id := e.seed(t, uidA, PurposeAvatar, false)
	before := e.raw(t, id)
	docs, err := e.repo.GetMany(context.Background(), []string{id})
	if err != nil {
		t.Fatal(err)
	}
	stale := docs[id].UpdateTime
	at := retireNow.Add(-time.Hour)
	exp := at.Add(RetiredDocTTL)

	if err := e.repo.Retire(context.Background(), id, stale, at, exp); err != nil {
		t.Fatalf("Retire: %v", err)
	}
	after := e.raw(t, id)
	if r, _ := after["retiredAt"].(time.Time); !r.Equal(at) {
		t.Errorf("retiredAt = %v, want %v", after["retiredAt"], at)
	}
	if x, _ := after["expireAt"].(time.Time); !x.Equal(exp) {
		t.Errorf("expireAt = %v, want %v", after["expireAt"], exp)
	}
	for k, v := range before {
		if k == "retiredAt" || k == "expireAt" {
			continue
		}
		if fmt.Sprint(after[k]) != fmt.Sprint(v) {
			t.Errorf("field %s changed: %v -> %v", k, v, after[k])
		}
	}

	// The document moved since it was read: the precondition fails and nothing is written.
	if err := e.repo.Retire(context.Background(), id, stale, at.Add(time.Hour), exp); !errors.Is(err, ErrConflict) {
		t.Errorf("stale precondition: err = %v, want ErrConflict", err)
	}
	if r, _ := e.raw(t, id)["retiredAt"].(time.Time); !r.Equal(at) {
		t.Errorf("a lost precondition changed retiredAt to %v", r)
	}

	// A document that is gone (the eraser got there first) is ErrConflict and stays gone.
	if _, err := e.client.Collection("media").Doc(id).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := e.repo.Retire(context.Background(), id, time.Now().Truncate(time.Microsecond), at, exp); !errors.Is(err, ErrConflict) {
		t.Errorf("missing document: err = %v, want ErrConflict", err)
	}
	if snap, err := e.client.Collection("media").Doc(id).Get(context.Background()); err == nil && snap.Exists() {
		t.Error("Retire recreated a purged document")
	}
}

// failingRetireRepo fails the first Retire (a crash between the object patches and the document write).
type failingRetireRepo struct {
	Repo
	failed bool
}

func (r *failingRetireRepo) Retire(ctx context.Context, id string, updateTime, retiredAt, expireAt time.Time) error {
	if !r.failed {
		r.failed = true
		return errors.New("crashed before the document write")
	}
	return r.Repo.Retire(ctx, id, updateTime, retiredAt, expireAt)
}

func TestIntegration_RetireCrashBetweenTheObjectsAndTheDocumentConverges(t *testing.T) {
	e := newRetireIntEnv(t, config.ProfileMediaRetireAll)
	id := e.seed(t, uidA, PurposeBanner, true)
	at := retireNow.Add(-time.Hour)
	flaky := &failingRetireRepo{Repo: e.repo}
	jobs := NewJobs(flaky, e.buckets, fakePosts{}, nil).WithProfileRetire(RetireDeps{
		Mode: config.ProfileMediaRetireAll, Users: e.users, Tagger: e.tagger, Now: func() time.Time { return retireNow },
	})

	if out, err := jobs.Retire(context.Background(), e.msg(uidA, PurposeBanner, id, at)); err == nil {
		t.Fatalf("first delivery = %q, want the crash", out)
	}
	if _, has := e.raw(t, id)["retiredAt"]; has {
		t.Fatal("the document was retired by a delivery that crashed before writing it")
	}
	if len(e.tagger.calls) != 2 {
		t.Fatalf("patches after the crash = %d, want the 2 objects tagged first (objects first, document last)", len(e.tagger.calls))
	}

	out, err := jobs.Retire(context.Background(), e.msg(uidA, PurposeBanner, id, at))
	if err != nil || out != "retired" {
		t.Fatalf("redelivery = %q, %v, want retired", out, err)
	}
	if len(e.tagger.calls) != 4 {
		t.Errorf("patches = %d, want 4 (the redelivery repeats the same two)", len(e.tagger.calls))
	}
	for _, c := range e.tagger.calls {
		if !c.at.Equal(at) {
			t.Errorf("patch at %v, want the message's changedAt %v every time (customTime never moves back)", c.at, at)
		}
	}
	if r, _ := e.raw(t, id)["retiredAt"].(time.Time); !r.Equal(at) {
		t.Errorf("retiredAt = %v", e.raw(t, id)["retiredAt"])
	}
	if out, err = jobs.Retire(context.Background(), e.msg(uidA, PurposeBanner, id, at)); err != nil || out != "duplicate" {
		t.Errorf("third delivery = %q, %v", out, err)
	}
}

// TestIntegration_RetiredImageIsRefusedByTheResolvers: ResolveAvatar and ResolveBanner answer the one MEDIA_NOT_READY
// error for a retired image, so it can never be set again.
func TestIntegration_RetiredImageIsRefusedByTheResolvers(t *testing.T) {
	e := newRetireIntEnv(t, config.ProfileMediaRetireAll)
	avatar, banner := e.seed(t, uidA, PurposeAvatar, false), e.seed(t, uidA, PurposeBanner, false)
	ctx := context.Background()
	if _, err := e.lib.ResolveAvatar(ctx, uidA, avatar); err != nil {
		t.Fatalf("before the retire: %v", err)
	}
	if _, err := e.lib.ResolveBanner(ctx, uidA, banner); err != nil {
		t.Fatalf("before the retire: %v", err)
	}
	for _, c := range []struct {
		purpose Purpose
		id      string
	}{{PurposeAvatar, avatar}, {PurposeBanner, banner}} {
		if out, err := e.jobs.Retire(ctx, e.msg(uidA, c.purpose, c.id, retireNow.Add(-time.Minute))); err != nil || out != "retired" {
			t.Fatalf("Retire %s = %q, %v", c.purpose, out, err)
		}
	}
	if _, err := e.lib.ResolveAvatar(ctx, uidA, avatar); !errors.Is(err, ErrNotReady) {
		t.Errorf("ResolveAvatar of a retired image: err = %v, want ErrNotReady", err)
	}
	if _, err := e.lib.ResolveBanner(ctx, uidA, banner); !errors.Is(err, ErrNotReady) {
		t.Errorf("ResolveBanner of a retired image: err = %v, want ErrNotReady", err)
	}
	if !IsNotReady(ErrNotReady) {
		t.Error("ErrNotReady must map to MEDIA_NOT_READY")
	}
	// Retiring one image never retires the owner's other one.
	other := e.seed(t, uidA, PurposeAvatar, false)
	if _, err := e.lib.ResolveAvatar(ctx, uidA, other); err != nil {
		t.Errorf("an unretired avatar of the same owner: %v", err)
	}
}

// TestIntegration_EraserCoversRetiredImagesInsideTheGrace: an account deleted between the retire and the document's TTL
// loses the objects and the documents at once, and the export lists the retired documents until then.
func TestIntegration_EraserCoversRetiredImagesInsideTheGrace(t *testing.T) {
	e := newRetireIntEnv(t, config.ProfileMediaRetireAll)
	ctx := context.Background()
	avatar, banner := e.seed(t, uidA, PurposeAvatar, true), e.seed(t, uidA, PurposeBanner, true)
	current := e.seed(t, uidA, PurposeBanner, true)
	bobs := e.seed(t, uidB, PurposeAvatar, true)
	for _, c := range []struct {
		purpose Purpose
		id      string
	}{{PurposeAvatar, avatar}, {PurposeBanner, banner}} {
		if out, err := e.jobs.Retire(ctx, e.msg(uidA, c.purpose, c.id, retireNow.Add(-time.Minute))); err != nil || out != "retired" {
			t.Fatalf("Retire %s = %q, %v", c.purpose, out, err)
		}
	}
	for _, id := range []string{avatar, banner, current} {
		if !e.objectExists(t, "m/"+id+".webp") || !e.objectExists(t, "m/"+id+"_t.webp") {
			t.Fatalf("objects of %s must still exist during the grace (the step only tags them)", id)
		}
	}

	p := NewPurger(e.repo, e.buckets, "https://cdn.test/media")
	var out bytes.Buffer
	if err := p.WriteSection(ctx, uidA, &out); err != nil {
		t.Fatal(err)
	}
	var export struct {
		Media []struct {
			ID        string     `json:"id"`
			RetiredAt *time.Time `json:"retiredAt"`
		} `json:"media"`
	}
	if err := json.Unmarshal(out.Bytes(), &export); err != nil || len(export.Media) != 3 {
		t.Fatalf("export = %s (%v), want the retired avatar and banner and the current banner", out.String(), err)
	}
	retired := 0
	for _, m := range export.Media {
		if m.RetiredAt != nil {
			retired++
		}
	}
	if retired != 2 {
		t.Errorf("retired export entries = %d, want 2", retired)
	}

	ctx2, c := counted()
	_, done, err := p.PurgeUser(ctx2, uidA, Checkpoint{})
	if err != nil || !done {
		t.Fatalf("PurgeUser done=%v err=%v", done, err)
	}
	// Reads: one per document (3), deletes: one per document.
	budgettest.Assert(t, "purge with retired documents", c, budgettest.Budget{Reads: 3, Writes: 0, Deletes: 3})
	for _, id := range []string{avatar, banner, current} {
		if e.objectExists(t, "m/"+id+".webp") || e.objectExists(t, "m/"+id+"_t.webp") {
			t.Errorf("objects of %s survived the account purge", id)
		}
		if snap, err := e.client.Collection("media").Doc(id).Get(ctx); err == nil && snap.Exists() {
			t.Errorf("media/%s survived the account purge", id)
		}
	}
	if !e.objectExists(t, "m/"+bobs+".webp") {
		t.Error("another user's object was deleted")
	}
}
