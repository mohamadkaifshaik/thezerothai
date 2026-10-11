//go:build integration

package media

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func newIntegrationClient(t *testing.T) *firestore.Client {
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

// intEnv is the real Firestore repo and library behind the same service the unit tests drive with fakes.
type intEnv struct {
	*env
	client *firestore.Client
	real   *FirestoreRepo
	lib    *Library
}

func newIntEnv(t *testing.T, o envOpts) *intEnv {
	t.Helper()
	client := newIntegrationClient(t)
	real := NewFirestoreRepo(client, WriteDeps{Idempotency: idempotency.New(client), Quotas: quota.New(client)})
	e := newEnv(t, o)
	svc, err := New(Deps{
		Repo: real, Signer: e.sign, Objects: e.obj, Moderator: e.mod,
		Directory: fakeDirectory{created: testNow.Add(-30 * 24 * time.Hour)}, IDs: &seqIDs{n: rand.IntN(1 << 30)},
		PublicBaseURL: "https://cdn.test/media", MediaPerDay: 20, NewAccountMediaPerDay: 8, NewAccountWindow: 24 * time.Hour,
		VisionMonthlyCap: 100, Now: func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatal(err)
	}
	e.svc = svc
	return &intEnv{env: e, client: client, real: real, lib: NewLibrary(real, "https://cdn.test/media")}
}

func counted() (context.Context, *budget.Counter) { return budget.WithCounter(context.Background()) }

// TestIntegration_CreateUploadAndFinalizeBudgets asserts the documented worst cases (CreateUpload proto comment):
// CreateUpload reads 2 (idempotency, quotas) and writes 2 + n; a replay reads 1 and writes 0; FinalizeUpload reads
// n + 1 (the media docs and, cold, the Vision counter) and writes n + 1.
func TestIntegration_CreateUploadAndFinalizeBudgets(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	full, thumb := jpegBytes("F1"), jpegBytes("T1")
	in := CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{item(full, thumb, "image/jpeg"), item(jpegBytes("F2"), jpegBytes("T2"), "image/jpeg")}}

	ctx, c := counted()
	tgs, err := e.svc.CreateUpload(ctx, uidA, in)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "CreateUpload n=2", c, budgettest.Budget{Reads: 2, Writes: 2 + 2})
	if c.Writes() != 4 {
		t.Errorf("writes = %d, want exactly 2 + n = 4", c.Writes())
	}

	ctx, c = counted()
	replay, err := e.svc.CreateUpload(ctx, uidA, in)
	if err != nil || replay[0].MediaID != tgs[0].MediaID || replay[1].MediaID != tgs[1].MediaID {
		t.Fatalf("replay = %v, %v", replay, err)
	}
	budgettest.Assert(t, "CreateUpload replay", c, budgettest.Budget{Reads: 1, Writes: 0})

	ctx, c = counted()
	other := in
	other.Items = in.Items[:1]
	_, err = e.svc.CreateUpload(ctx, uidA, other)
	if err == nil {
		t.Fatal("a different body under the same key must be refused")
	}
	budgettest.Assert(t, "CreateUpload reused key", c, budgettest.Budget{Reads: 1, Writes: 0})

	e.put(uidA, tgs[0], full, thumb, "image/jpeg")
	e.put(uidA, tgs[1], jpegBytes("F2"), jpegBytes("T2"), "image/jpeg")
	ctx, c = counted()
	res, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: tgs[0].MediaID, Blurhash: "LEHV6n"}, {MediaID: tgs[1].MediaID}})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range res {
		if r.Status != StatusReady {
			t.Fatalf("result = %+v", r)
		}
	}
	budgettest.Assert(t, "FinalizeUpload n=2 cold", c, budgettest.Budget{Reads: 2 + 1, Writes: 2 + 1})

	// The Vision counter is a real document and the cap arithmetic reads it back.
	used, err := e.real.VisionUsed(context.Background(), monthKey(testNow))
	if err != nil || used != 2 {
		t.Fatalf("vision units = %d, %v", used, err)
	}
}

func TestIntegration_QuotaIsWholeCall(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	mk := func(n int, key string) error {
		items := make([]UploadItem, n)
		for i := range items {
			items[i] = item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")
		}
		ctx, c := counted()
		_, err := e.svc.CreateUpload(ctx, uidA, CreateUploadInput{IdempotencyKey: key, Purpose: PurposePost, Items: items})
		if err != nil {
			budgettest.Assert(t, "CreateUpload rejected", c, budgettest.Budget{Reads: 2, Writes: 0})
		}
		return err
	}
	for i := 0; i < 5; i++ { // 5 x 4 = 20 images: exactly the daily limit
		if err := mk(4, fmt.Sprintf("quota-key-%016d", i)); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	err := mk(1, "quota-key-over-0000001")
	_ = wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
}

func TestIntegration_ConcurrentFinalizeConverges(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "c")
	var wg sync.WaitGroup
	results := make([]Result, 6)
	errs := make([]error, 6)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err == nil {
				results[i] = r[0]
			}
			errs[i] = err
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
		if results[i].Status != StatusReady || results[i].Ref == nil || *results[i].Ref != *results[0].Ref {
			t.Fatalf("call %d = %+v, want every caller to see the same READY ref", i, results[i])
		}
	}
	docs, err := e.real.GetMany(context.Background(), []string{tg.MediaID})
	if err != nil || docs[tg.MediaID].Status != string(StatusReady) || docs[tg.MediaID].ExpireAt != nil {
		t.Fatalf("doc = %+v, %v", docs[tg.MediaID], err)
	}
}

// TestIntegration_LoadForPostInsideATransaction models CreatePost's transaction: the claim reads len(ids) docs
// before the first write, marks them attached, and a second attach (another post, or a replayed id) is refused.
func TestIntegration_LoadForPostInsideATransaction(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	var ids []string
	for _, tag := range []string{"a", "b"} {
		tg := e.upload(t, uidA, PurposePost, tag)
		if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6n"}}); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, tg.MediaID)
	}
	avatar := e.upload(t, uidA, PurposeAvatar, "av")
	if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: avatar.MediaID}}); err != nil {
		t.Fatal(err)
	}
	pending := e.upload(t, uidA, PurposePost, "pend")

	attach := func(uid string, ids []string, postID string) (*Claim, *budget.Counter, error) {
		ctx, c := counted()
		var claim *Claim
		_, err := store.RunTransaction(ctx, e.client, func(ctx context.Context, tx *firestore.Transaction) error {
			var err error
			claim, err = e.lib.LoadForPost(ctx, tx, uid, ids)
			if err != nil {
				return err
			}
			b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
			claim.Attach(b, postID)
			return b.Err()
		})
		return claim, c, err
	}

	claim, c, err := attach(uidA, ids, "0000000000000000777")
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "LoadForPost n=2", c, budgettest.Budget{Reads: 2, Writes: 2})
	if len(claim.Refs) != 2 || claim.Refs[0].ID != ids[0] || claim.Refs[0].ThumbURL == "" || claim.Refs[0].Blurhash != "LEHV6n" {
		t.Fatalf("refs = %+v", claim.Refs)
	}

	for name, tc := range map[string]struct {
		uid string
		ids []string
	}{
		"already attached":   {uidA, ids[:1]},
		"someone else's":     {uidB, ids[:1]},
		"an avatar":          {uidA, []string{avatar.MediaID}},
		"still pending":      {uidA, []string{pending.MediaID}},
		"unknown":            {uidA, []string{"0000000000000009999"}},
		"one bad among good": {uidA, []string{ids[0], pending.MediaID}},
	} {
		t.Run(name, func(t *testing.T) {
			_, _, err := attach(tc.uid, tc.ids, "0000000000000000888")
			if !IsNotReady(err) {
				t.Fatalf("err = %v, want ErrNotReady (one answer for every cause)", err)
			}
		})
	}
	if _, _, err := attach(uidA, []string{"../users/x"}, "0000000000000000888"); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("path-like id: %v", err)
	}
}

func TestIntegration_ResolveAvatar(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	av := e.upload(t, uidA, PurposeAvatar, "av")
	if _, err := e.lib.ResolveAvatar(context.Background(), uidA, av.MediaID); !IsNotReady(err) {
		t.Fatalf("a PENDING avatar must not resolve: %v", err)
	}
	if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: av.MediaID}}); err != nil {
		t.Fatal(err)
	}
	ctx, c := counted()
	ref, err := e.lib.ResolveAvatar(ctx, uidA, av.MediaID)
	if err != nil || ref.URL == "" || ref.ThumbURL == "" {
		t.Fatalf("ref = %+v, %v", ref, err)
	}
	budgettest.Assert(t, "ResolveAvatar", c, budgettest.Budget{Reads: 1})
	if _, err := e.lib.ResolveAvatar(context.Background(), uidB, av.MediaID); !IsNotReady(err) {
		t.Fatalf("another user's avatar must not resolve: %v", err)
	}
	post := e.upload(t, uidA, PurposePost, "po")
	if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: post.MediaID}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.lib.ResolveAvatar(context.Background(), uidA, post.MediaID); !IsNotReady(err) {
		t.Fatalf("a post image must not resolve as an avatar: %v", err)
	}
}

// TestIntegration_PostDeleteJobAndPurge runs the job and the account Eraser against real documents, and checks
// every query is bounded (the Eraser pages by opsPage).
func TestIntegration_PostDeleteJobAndPurge(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	var ids []string
	for _, tag := range []string{"a", "b", "c"} {
		tg := e.upload(t, uidA, PurposePost, tag)
		if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}}); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, tg.MediaID)
	}
	const post = "0000000000000000555"
	ctx := context.Background()
	if _, err := e.client.Collection(mediaCollection).Doc(ids[0]).Update(ctx, []firestore.Update{{Path: "postId", Value: post}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Collection(mediaCollection).Doc(ids[1]).Update(ctx, []firestore.Update{{Path: "postId", Value: post}}); err != nil {
		t.Fatal(err)
	}
	// Seed the public objects the fake bucket would hold.
	for _, id := range ids {
		e.obj.public["m/"+id+".jpg"] = "image/jpeg"
		e.obj.public["m/"+id+"_t.jpg"] = "image/jpeg"
	}

	j := NewJobs(e.real, e.obj, fakePosts{live: map[string]bool{}}, nil)
	cctx, c := counted()
	out, err := j.Handle(cctx, msg(t, PostDeleteMessage{UID: uidA, PostID: post, MediaIDs: ids[:2]}))
	if err != nil || out != "done" {
		t.Fatalf("job = %q, %v", out, err)
	}
	// reads: the post (fake here: 1 in production) + len(MediaIDs); deletes: len(MediaIDs).
	budgettest.Assert(t, "post_delete n=2", c, budgettest.Budget{Reads: 2, Deletes: 2})
	docs, err := e.real.GetMany(ctx, ids)
	if err != nil || len(docs) != 1 || docs[ids[2]] == nil {
		t.Fatalf("docs left = %v, %v: only the unattached image remains", docs, err)
	}
	if len(e.obj.public) != 2 {
		t.Fatalf("public objects = %v", e.obj.public)
	}
	again, err := j.Handle(ctx, msg(t, PostDeleteMessage{UID: uidA, PostID: post, MediaIDs: ids[:2]}))
	if err != nil || again != "duplicate" {
		t.Fatalf("redelivery = %q, %v", again, err)
	}

	p := NewPurger(e.real, e.obj, "https://cdn.test/media")
	pctx, pc := counted()
	cp, done, err := p.PurgeUser(pctx, uidA, Checkpoint{})
	if err != nil || !done || cp.Deleted != 1 {
		t.Fatalf("purge = %+v done=%v err=%v", cp, done, err)
	}
	budgettest.Assert(t, "PurgeUser 1 doc", pc, budgettest.Budget{Reads: 1, Deletes: 1})
	if len(e.obj.public) != 0 {
		t.Fatalf("public objects left = %v", e.obj.public)
	}
}

func TestIntegration_VisionCounterIsAnAtomicIncrement(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	ctx := context.Background()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := e.real.AddVisionUnits(ctx, "202610", 2); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	got, err := e.real.VisionUsed(ctx, "202610")
	if err != nil || got != 16 {
		t.Fatalf("units = %d, %v, want 16", got, err)
	}
	if got, err := e.real.VisionUsed(ctx, "209901"); err != nil || got != 0 {
		t.Fatalf("a month with no counter reads 0, got %d, %v", got, err)
	}
}

func TestIntegration_ListByOwnerPagesWithALimit(t *testing.T) {
	e := newIntEnv(t, envOpts{})
	ctx := context.Background()
	for i := 0; i < 7; i++ {
		id := fmt.Sprintf("%019d", 9000+i)
		if _, err := e.client.Collection(mediaCollection).Doc(id).Set(ctx, Doc{OwnerID: uidA, Status: string(StatusRejected), CreatedAt: testNow}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.client.Collection(mediaCollection).Doc("0000000000000009100").Set(ctx, Doc{OwnerID: uidB, CreatedAt: testNow}); err != nil {
		t.Fatal(err)
	}
	var all []string
	after := ""
	for {
		cctx, c := counted()
		page, err := e.real.ListByOwner(cctx, uidA, after, 3)
		if err != nil {
			t.Fatal(err)
		}
		if len(page) > 3 {
			t.Fatalf("page of %d exceeds the limit", len(page))
		}
		budgettest.Assert(t, "ListByOwner", c, budgettest.Budget{Reads: 3})
		for _, d := range page {
			all = append(all, d.ID)
		}
		if len(page) < 3 {
			break
		}
		after = page[len(page)-1].ID
	}
	if len(all) != 7 {
		t.Fatalf("listed %d, want 7 (not Bob's)", len(all))
	}
}
