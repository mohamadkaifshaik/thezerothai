//go:build integration

package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// The orphan sweep over the real Firestore repo (the due query, the preconditioned writes and deletes) and the Storage
// emulator (the objects). The holders are fakes here; their real queries are tested in posts and articles. Every test
// runs in its own Firestore project and its own buckets.

// hookedOrphanRepo runs before(id) ahead of every SetOrphanState: a writer that commits between the sweep's read and
// its write.
type hookedOrphanRepo struct {
	*FirestoreRepo
	before func(id string)
	// deleteErr, when set, fails DeleteOrphan without touching the document (a document delete that did not finish).
	deleteErr error
}

func (h *hookedOrphanRepo) DeleteOrphan(ctx context.Context, id string, ut time.Time) error {
	if h.deleteErr != nil {
		return h.deleteErr
	}
	return h.FirestoreRepo.DeleteOrphan(ctx, id, ut)
}

func (h *hookedOrphanRepo) SetOrphanState(ctx context.Context, id string, ut time.Time, st OrphanState) (time.Time, error) {
	if h.before != nil {
		h.before(id)
	}
	return h.FirestoreRepo.SetOrphanState(ctx, id, ut, st)
}

type orphanIntEnv struct {
	client   *firestore.Client
	repo     *FirestoreRepo
	hooked   *hookedOrphanRepo
	lib      *Library
	buckets  *Buckets
	drafts   *fakeDraftHolds
	profiles *fakeProfileImages
	sweeper  *OrphanSweeper
}

func newOrphanIntEnv(t *testing.T, mode config.ProfileMediaRetire) *orphanIntEnv {
	t.Helper()
	return newOrphanIntEnvMode(t, mode, config.MediaOrphanSweepDelete)
}

// newOrphanIntEnvMode is newOrphanIntEnv under a MEDIA_ORPHAN_SWEEP mode.
func newOrphanIntEnvMode(t *testing.T, mode config.ProfileMediaRetire, sweep config.MediaOrphanSweep) *orphanIntEnv {
	t.Helper()
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client := newIntegrationClient(t)
	repo := NewFirestoreRepo(client, WriteDeps{})
	n := rand.Int64()
	buckets, err := NewBuckets(fmt.Sprintf("demo-orphan-upload-%d", n), fmt.Sprintf("demo-orphan-public-%d", n))
	if err != nil {
		t.Fatal(err)
	}
	e := &orphanIntEnv{
		client: client, repo: repo, hooked: &hookedOrphanRepo{FirestoreRepo: repo}, lib: NewLibrary(repo, "https://cdn.test/media"),
		buckets: buckets, drafts: &fakeDraftHolds{held: map[string]map[string]bool{}},
		profiles: &fakeProfileImages{urls: map[string][]string{}},
	}
	e.sweeper, err = NewOrphanSweeper(OrphanSweepDeps{Repo: e.hooked, Objects: buckets, Drafts: e.drafts, Profiles: e.profiles, RetireMode: mode, Mode: sweep})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func putBytes(w io.Writer) error { _, err := io.WriteString(w, "bytes"); return err }

// seed writes a READY image the way FinalizeUpload leaves it, with orphanCheckAt = checkAt (zero = none), and puts its
// two public objects and (leftover) private ones.
func (e *orphanIntEnv) seed(t *testing.T, owner string, purpose Purpose, checkAt time.Time) *Doc {
	t.Helper()
	id := fmt.Sprintf("%019d", 6_000_000_000_000_000_000+rand.Int64N(1_000_000_000))
	suffix := fmt.Sprintf("%032x", rand.Int64())
	d := &Doc{
		ID: id, OwnerID: owner, Purpose: string(purpose), Status: string(StatusReady), ContentType: ContentTypeJPEG, Bytes: 1000, ThumbBytes: 100,
		Width: 1200, Height: 800, UploadPath: uploadObject(owner, id, "jpg"), ThumbUploadPath: uploadThumbObject(owner, id, "jpg"),
		NameSuffix: suffix, PublicPath: publicObject(id, suffix, "jpg"), ThumbPath: publicThumbObject(id, suffix, "jpg"),
		CreatedAt: sweepNow.Add(-8 * 24 * time.Hour), OrphanCheckAt: optTime(checkAt),
	}
	ctx := context.Background()
	if _, err := e.client.Collection(mediaCollection).Doc(id).Set(ctx, d); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{d.PublicPath, d.ThumbPath} {
		if err := e.buckets.Public.Put(ctx, name, ContentTypeJPEG, putBytes); err != nil {
			t.Fatalf("put %s: %v", name, err)
		}
	}
	for _, name := range []string{d.UploadPath, d.ThumbUploadPath} {
		if err := e.buckets.Upload.Put(ctx, name, ContentTypeJPEG, putBytes); err != nil {
			t.Fatalf("put %s: %v", name, err)
		}
	}
	return d
}

func (e *orphanIntEnv) get(t *testing.T, id string) *Doc {
	t.Helper()
	docs, err := e.repo.GetMany(context.Background(), []string{id})
	if err != nil {
		t.Fatal(err)
	}
	return docs[id]
}

func storeHas(t *testing.T, s *objstore.Store, name string) bool {
	t.Helper()
	_, err := s.Attrs(context.Background(), name)
	switch {
	case err == nil:
		return true
	case errors.Is(err, objstore.ErrObjectNotFound):
		return false
	}
	t.Fatalf("attrs %s: %v", name, err)
	return false
}

func (e *orphanIntEnv) objectsLeft(t *testing.T, d *Doc) int {
	t.Helper()
	n := 0
	for _, name := range []string{d.PublicPath, d.ThumbPath} {
		if storeHas(t, e.buckets.Public, name) {
			n++
		}
	}
	for _, name := range []string{d.UploadPath, d.ThumbUploadPath} {
		if storeHas(t, e.buckets.Upload, name) {
			n++
		}
	}
	return n
}

func (e *orphanIntEnv) sweep(t *testing.T, at time.Time, limit int) OrphanSweepResult {
	t.Helper()
	res, err := e.sweeper.Sweep(context.Background(), at, limit)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	return res
}

// attachInTx is CreatePost's media step: LoadForPost and Attach in one transaction.
func (e *orphanIntEnv) attachInTx(ctx context.Context, uid, id, postID string) error {
	_, err := store.RunTransaction(ctx, e.client, func(ctx context.Context, tx *firestore.Transaction) error {
		claim, err := e.lib.LoadForPost(ctx, tx, uid, []string{id})
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		claim.Attach(b, postID)
		return b.Err()
	})
	return err
}

// TestIntegration_OrphanSweepDeletesAnUnattachedImage: an unattached READY image past N is marked, then deleted with every
// object a run at least OrphanGrace later; reruns write nothing.
func TestIntegration_OrphanSweepDeletesAnUnattachedImage(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	d := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	if e.objectsLeft(t, d) != 4 {
		t.Fatal("seed did not store the objects")
	}

	if res := e.sweep(t, sweepNow, 10); res.Due != 1 || res.Marked != 1 {
		t.Fatalf("phase 1 = %+v", res)
	}
	got := e.get(t, d.ID)
	if got == nil || !timeIs(got.OrphanedAt, sweepNow) || !timeIs(got.OrphanCheckAt, sweepNow.Add(OrphanGrace)) || e.objectsLeft(t, d) != 4 {
		t.Fatalf("after phase 1: doc=%+v objects=%d", got, e.objectsLeft(t, d))
	}
	// Redelivery of phase 1 (same day): nothing is due, nothing written.
	before := got.UpdateTime
	if res := e.sweep(t, sweepNow.Add(time.Hour), 10); res.Due != 0 {
		t.Fatalf("phase 1 rerun = %+v", res)
	}
	if again := e.get(t, d.ID); !again.UpdateTime.Equal(before) {
		t.Fatal("a rerun inside the grace wrote")
	}

	if res := e.sweep(t, sweepNow.Add(OrphanGrace), 10); res.Due != 1 || res.Deleted != 1 {
		t.Fatalf("phase 2 = %+v", res)
	}
	if e.get(t, d.ID) != nil || e.objectsLeft(t, d) != 0 {
		t.Fatalf("after phase 2: doc=%+v objects=%d, want both gone", e.get(t, d.ID), e.objectsLeft(t, d))
	}
	// Redelivery of phase 2.
	if res := e.sweep(t, sweepNow.Add(OrphanGrace+time.Hour), 10); res.Due != 0 {
		t.Fatalf("phase 2 rerun = %+v", res)
	}
}

// TestIntegration_OrphanSweepNeverTouchesAnAttachedImage: FinalizeUpload sets orphanCheckAt on READY (real repo) and the
// CreatePost attach removes it, so an attached image is never due, at any later time.
func TestIntegration_OrphanSweepNeverTouchesAnAttachedImage(t *testing.T) {
	ie := newIntEnv(t, envOpts{})
	tg := ie.upload(t, uidA, PurposePost, "att")
	if _, err := ie.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}}); err != nil {
		t.Fatal(err)
	}
	docs, err := ie.real.GetMany(context.Background(), []string{tg.MediaID})
	if err != nil {
		t.Fatal(err)
	}
	if d := docs[tg.MediaID]; d.Status != string(StatusReady) || !timeIs(d.OrphanCheckAt, testNow.Add(OrphanAfter)) {
		t.Fatalf("READY doc orphanCheckAt = %v, want %v", d.OrphanCheckAt, testNow.Add(OrphanAfter))
	}
	oe := &orphanIntEnv{client: ie.client, repo: ie.real, lib: ie.lib}
	if err := oe.attachInTx(context.Background(), uidA, tg.MediaID, "0000000000000000777"); err != nil {
		t.Fatal(err)
	}
	docs, _ = ie.real.GetMany(context.Background(), []string{tg.MediaID})
	if d := docs[tg.MediaID]; d.PostID != "0000000000000000777" || d.OrphanCheckAt != nil {
		t.Fatalf("attached doc = postId %q orphanCheckAt %v, want the post and no check", d.PostID, d.OrphanCheckAt)
	}
	due, err := ie.real.DueOrphans(context.Background(), testNow.Add(10*OrphanAfter), 10)
	if err != nil || len(due.Docs) != 0 {
		t.Fatalf("due = %+v, %v: an attached image is never a candidate", due, err)
	}
}

// TestIntegration_OrphanSweepAttachWins: CreatePost's transaction commits between the due query and the mark; the mark
// loses its precondition and the image stays attached with its objects.
func TestIntegration_OrphanSweepAttachWins(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	d := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.hooked.before = func(id string) {
		e.hooked.before = nil
		if err := e.attachInTx(context.Background(), uidA, id, "0000000000000000555"); err != nil {
			t.Errorf("attach: %v", err)
		}
	}
	if res := e.sweep(t, sweepNow, 10); res.Conflicts != 1 || res.Marked != 0 {
		t.Fatalf("res = %+v, want the mark to lose", res)
	}
	got := e.get(t, d.ID)
	if got.PostID != "0000000000000000555" || got.OrphanedAt != nil || got.OrphanCheckAt != nil || e.objectsLeft(t, d) != 4 {
		t.Fatalf("doc = %+v objects=%d", got, e.objectsLeft(t, d))
	}
	if res := e.sweep(t, sweepNow.Add(OrphanGrace), 10); res.Due != 0 {
		t.Fatalf("later run = %+v", res)
	}
}

// TestIntegration_OrphanSweepMarkWins: once marked, the attaching transaction, the avatar resolver and the
// article cover preview all refuse the image, so nothing new can attach it before the delete.
func TestIntegration_OrphanSweepMarkWins(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireAll)
	post := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	avatar := e.seed(t, uidA, PurposeAvatar, sweepNow.Add(-time.Minute))
	ctx := context.Background()
	// Before the mark every one of them is usable.
	if _, err := e.lib.ResolvePostCover(ctx, uidA, post.ID); err != nil {
		t.Fatalf("cover before the mark: %v", err)
	}
	if _, err := e.lib.ResolveAvatar(ctx, uidA, avatar.ID); err != nil {
		t.Fatalf("avatar before the mark: %v", err)
	}
	if res := e.sweep(t, sweepNow, 10); res.Marked != 2 {
		t.Fatalf("res = %+v, want 2 marked", res)
	}
	if err := e.attachInTx(ctx, uidA, post.ID, "0000000000000000556"); !IsNotReady(err) {
		t.Fatalf("attach after the mark = %v, want ErrNotReady", err)
	}
	if _, err := e.lib.ResolvePostCover(ctx, uidA, post.ID); !IsNotReady(err) {
		t.Fatalf("cover after the mark = %v", err)
	}
	if _, err := e.lib.ResolveAvatar(ctx, uidA, avatar.ID); !IsNotReady(err) {
		t.Fatalf("avatar after the mark = %v", err)
	}
	if got := e.get(t, post.ID); got.PostID != "" {
		t.Fatal("the refused attach wrote")
	}
}

// TestIntegration_OrphanSweepHolderAppearsBeforeTheDelete: a schedule (or an avatar set) that read the image before the
// mark is seen by phase 2, which removes the mark instead of deleting.
func TestIntegration_OrphanSweepHolderAppearsBeforeTheDelete(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireAll)
	post := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	avatar := e.seed(t, uidB, PurposeAvatar, sweepNow.Add(-time.Minute))
	if res := e.sweep(t, sweepNow, 10); res.Marked != 2 {
		t.Fatalf("phase 1 = %+v", res)
	}
	e.drafts.held[uidA] = map[string]bool{post.ID: true}
	e.profiles.urls[uidB] = []string{"https://cdn.test/media/" + avatar.PublicPath, "https://cdn.test/media/" + avatar.ThumbPath}
	res := e.sweep(t, sweepNow.Add(OrphanGrace), 10)
	if res.Restored != 1 || res.Attached != 1 || res.Deleted != 0 {
		t.Fatalf("phase 2 = %+v, want one restored and one attached", res)
	}
	if got := e.get(t, post.ID); got.OrphanedAt != nil || !timeIs(got.OrphanCheckAt, sweepNow.Add(OrphanGrace).Add(OrphanAfter)) || e.objectsLeft(t, post) != 4 {
		t.Fatalf("held post image = %+v", got)
	}
	if got := e.get(t, avatar.ID); got.OrphanedAt != nil || got.OrphanCheckAt != nil || e.objectsLeft(t, avatar) != 4 {
		t.Fatalf("shown avatar = %+v", got)
	}
	// And the restored image can be attached again.
	if err := e.attachInTx(context.Background(), uidA, post.ID, "0000000000000000557"); err != nil {
		t.Fatalf("attach after the restore: %v", err)
	}
}

// TestIntegration_OrphanSweepRespectsTheLimit: the due query reads at most limit documents, oldest first.
func TestIntegration_OrphanSweepRespectsTheLimit(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	var docs []*Doc
	for i := range 5 {
		docs = append(docs, e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Duration(5-i)*time.Hour)))
	}
	res := e.sweep(t, sweepNow, 2)
	if res.Due != 2 || res.Marked != 2 || !res.More {
		t.Fatalf("res = %+v", res)
	}
	for i, d := range docs {
		if marked := e.get(t, d.ID).OrphanedAt != nil; marked != (i < 2) {
			t.Errorf("doc %d marked = %v, want only the two oldest", i, marked)
		}
	}
}

// TestIntegration_OrphanRepoPreconditions: the repo's own contract: stale writes and deletes are ErrConflict, a missing
// document deletes as success, and nothing is ever recreated.
func TestIntegration_OrphanRepoPreconditions(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	d := e.seed(t, uidA, PurposePost, sweepNow)
	ctx := context.Background()
	cur := e.get(t, d.ID)
	ut, err := e.repo.SetOrphanState(ctx, d.ID, cur.UpdateTime, OrphanState{CheckAt: sweepNow.Add(time.Hour), OrphanedAt: sweepNow})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.SetOrphanState(ctx, d.ID, cur.UpdateTime, OrphanState{}); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale set = %v", err)
	}
	if err := e.repo.DeleteOrphan(ctx, d.ID, cur.UpdateTime); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale delete = %v", err)
	}
	// Clearing both fields removes them.
	ut, err = e.repo.SetOrphanState(ctx, d.ID, ut, OrphanState{})
	if err != nil {
		t.Fatal(err)
	}
	if got := e.get(t, d.ID); got.OrphanCheckAt != nil || got.OrphanedAt != nil {
		t.Fatalf("cleared doc = %+v", got)
	}
	if err := e.repo.DeleteOrphan(ctx, d.ID, ut); err != nil {
		t.Fatal(err)
	}
	if err := e.repo.DeleteOrphan(ctx, d.ID, ut); err != nil && !errors.Is(err, ErrConflict) {
		t.Fatalf("delete of a gone document = %v", err)
	}
	if _, err := e.repo.SetOrphanState(ctx, d.ID, ut, OrphanState{CheckAt: sweepNow}); !errors.Is(err, ErrConflict) {
		t.Fatalf("set on a gone document = %v, want ErrConflict", err)
	}
	if e.get(t, d.ID) != nil {
		t.Fatal("a sweep write recreated a deleted document")
	}
}

// TestIntegration_BackfillOrphanChecks: only published, unattached, unretired documents without the fields get it; a dry
// run writes nothing; a rerun writes nothing; pages resume after the checkpoint.
func TestIntegration_BackfillOrphanChecks(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	ctx := context.Background()
	free := e.seed(t, uidA, PurposePost, time.Time{})
	avatar := e.seed(t, uidA, PurposeAvatar, time.Time{})
	attached := e.seed(t, uidA, PurposePost, time.Time{})
	retired := e.seed(t, uidA, PurposeAvatar, time.Time{})
	rejected := e.seed(t, uidA, PurposePost, time.Time{})
	already := e.seed(t, uidA, PurposePost, sweepNow)
	for id, ups := range map[string][]firestore.Update{
		attached.ID: {{Path: "postId", Value: "0000000000000000999"}},
		retired.ID:  {{Path: "retiredAt", Value: sweepNow}},
		rejected.ID: {{Path: "status", Value: string(StatusRejected)}},
	} {
		if _, err := e.client.Collection(mediaCollection).Doc(id).Update(ctx, ups); err != nil {
			t.Fatal(err)
		}
	}
	checkAt := sweepNow.Add(OrphanAfter)

	dry, err := e.repo.BackfillOrphanChecks(ctx, "", 100, checkAt, true)
	if err != nil || dry.Scanned != 6 || dry.Eligible != 2 || dry.Set != 0 {
		t.Fatalf("dry run = %+v, %v", dry, err)
	}
	if e.get(t, free.ID).OrphanCheckAt != nil {
		t.Fatal("the dry run wrote")
	}

	// Two pages of 3, the second resuming after the first's checkpoint.
	var set, scanned int
	after := ""
	for {
		p, err := e.repo.BackfillOrphanChecks(ctx, after, 3, checkAt, false)
		if err != nil {
			t.Fatal(err)
		}
		set, scanned = set+p.Set, scanned+p.Scanned
		if p.Scanned < 3 {
			break
		}
		after = p.Last
	}
	if scanned != 6 || set != 2 {
		t.Fatalf("scanned=%d set=%d, want 6 and 2", scanned, set)
	}
	for _, d := range []*Doc{free, avatar} {
		if got := e.get(t, d.ID); !timeIs(got.OrphanCheckAt, checkAt) {
			t.Errorf("%s orphanCheckAt = %v, want %v", d.Purpose, got.OrphanCheckAt, checkAt)
		}
	}
	for _, d := range []*Doc{attached, retired, rejected} {
		if got := e.get(t, d.ID); got.OrphanCheckAt != nil {
			t.Errorf("an ineligible doc got the field: %+v", got)
		}
	}
	if got := e.get(t, already.ID); !timeIs(got.OrphanCheckAt, sweepNow) {
		t.Errorf("an existing check was overwritten: %v", got.OrphanCheckAt)
	}
	if again, err := e.repo.BackfillOrphanChecks(ctx, "", 100, checkAt, false); err != nil || again.Set != 0 || again.Eligible != 0 {
		t.Fatalf("rerun = %+v, %v", again, err)
	}
}
