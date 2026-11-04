//go:build integration

package identity_test

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func lifecycleRepo(t *testing.T) (*identity.FirestoreRepo, *firestore.Client) {
	t.Helper()
	client := newTestClient(t)
	return identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client)), client
}

func seedProfile(t *testing.T, repo *identity.FirestoreRepo, uid, handle string) {
	t.Helper()
	if _, _, err := repo.CreateProfile(context.Background(), uid, handle, lower(handle), "Name "+uid, time.Now().UTC(), nil); err != nil {
		t.Fatalf("seed %s: %v", uid, err)
	}
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// TestBeginDeletion_Integration: DeleteAccount's sync part marks the account DELETING; a replay
// changes nothing; SUSPENDED may delete; and the deletion state survives UpdateProfile's whole-document write.
func TestBeginDeletion_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	svc := identity.New(repo, identity.NewCache(time.Minute), time.Hour)
	seedProfile(t, repo, "u1", "Alice")
	seedProfile(t, repo, "u2", "Bobby")
	now := time.Now().UTC().Truncate(time.Millisecond)

	ctx := context.Background()
	start, err := repo.BeginDeletion(ctx, "u1", now)
	if err != nil || start.Replay {
		t.Fatalf("BeginDeletion = %+v, %v", start, err)
	}
	p, ut, err := repo.GetJobState(context.Background(), "u1")
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != identity.AccountStatusDeleting || !p.DeletionRequestedAt.Equal(now) || p.DeletionJob == nil || p.DeletionJob.Seq != 0 || ut.IsZero() {
		t.Errorf("stored state = %+v updateTime %v", p, ut)
	}

	ctx = context.Background()
	again, err := repo.BeginDeletion(ctx, "u1", now.Add(time.Hour))
	if err != nil || !again.Replay || !again.Profile.DeletionRequestedAt.Equal(now) {
		t.Fatalf("replay = %+v, %v", again, err)
	}

	// SUSPENDED may delete.
	if _, err := client.Collection("users").Doc("u2").Update(context.Background(), []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	if s, err := repo.BeginDeletion(context.Background(), "u2", now); err != nil || s.Replay || s.Profile.Status != identity.AccountStatusDeleting {
		t.Errorf("SUSPENDED BeginDeletion = %+v, %v", s, err)
	}

	if _, err := repo.BeginDeletion(context.Background(), "ghost", now); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("unknown user: err = %v", err)
	}

	// A whole-document rewrite by another instance (UpdateProfile on a stale ACTIVE cache) must not drop the job state.
	if _, err := svc.UpdateProfile(context.Background(), "u1", identity.UpdateProfileParams{IdempotencyKey: "0123456789abcdef", DisplayName: strPtr("Renamed")}); err != nil {
		t.Fatal(err)
	}
	p, _, _ = repo.GetJobState(context.Background(), "u1")
	if p.DeletionJob == nil || !p.DeletionRequestedAt.Equal(now) || p.Status != identity.AccountStatusDeleting {
		t.Errorf("UpdateProfile dropped the deletion state: %+v", p)
	}
}

func strPtr(s string) *string { return &s }

// TestSaveJobState_Integration: the save carries the UpdateTime precondition, and an unrelated counter
// increment between the read and the save is a conflict (the orchestrator re-reads and retries).
func TestSaveJobState_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	seedProfile(t, repo, "u1", "Alice")
	now := time.Now().UTC()
	if _, err := repo.BeginDeletion(context.Background(), "u1", now); err != nil {
		t.Fatal(err)
	}
	_, ut, _ := repo.GetJobState(context.Background(), "u1")

	ctx := context.Background()
	job := identity.DeletionJob{Seq: 1, Step: "graph", Checkpoint: []byte(`{"Step":2}`), ProgressAt: now}
	if err := repo.SaveJobState(ctx, "u1", ut, job); err != nil {
		t.Fatalf("SaveJobState: %v", err)
	}
	p, ut2, _ := repo.GetJobState(context.Background(), "u1")
	if p.DeletionJob.Seq != 1 || p.DeletionJob.Step != "graph" || string(p.DeletionJob.Checkpoint) != `{"Step":2}` {
		t.Errorf("job = %+v", p.DeletionJob)
	}
	if !p.DeletionRequestedAt.Equal(now.Truncate(time.Microsecond)) && p.DeletionRequestedAt.Sub(now).Abs() > time.Millisecond {
		t.Errorf("a checkpoint write moved deletionRequestedAt: %v vs %v", p.DeletionRequestedAt, now)
	}
	if p.UpdatedAt.Sub(now).Abs() > time.Millisecond {
		t.Errorf("a checkpoint write moved updatedAt to %v", p.UpdatedAt)
	}

	// A stale update time loses.
	if err := repo.SaveJobState(context.Background(), "u1", ut, job); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("stale save err = %v, want ErrJobConflict", err)
	}
	// An unrelated counter write (another account's purge decrementing followersCount) also changes the UpdateTime.
	if _, err := client.Collection("users").Doc("u1").Update(context.Background(), []firestore.Update{{Path: "followersCount", Value: firestore.Increment(-1)}}); err != nil {
		t.Fatal(err)
	}
	if err := repo.SaveJobState(context.Background(), "u1", ut2, job); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("save after an unrelated write: err = %v, want ErrJobConflict", err)
	}
	// Firestore reports a missing document under a LastUpdateTime precondition as a failed precondition.
	if err := repo.SaveJobState(context.Background(), "ghost", ut2, job); !errors.Is(err, identity.ErrJobConflict) && !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("missing doc err = %v, want ErrJobConflict or ErrNotFound", err)
	}
}

// raceCreateExport runs n concurrent CreateExport calls, id(i) naming each call's export, then retries each one in turn
// with its own id, as a client would. The race may end with nothing written: the emulator's locks can time out every racer,
// which is a retryable answer and no harm done. It must never store a second export, and once retried every call must get
// the one export.
func raceCreateExport(t *testing.T, repo *identity.FirestoreRepo, client *firestore.Client, uid string, n int, id func(int) string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	create := func(i int) (identity.ExportDoc, bool, error) {
		return repo.CreateExport(ctx, identity.CreateExportParams{ID: id(i), UID: uid, ObjectPath: id(i) + ".json", Now: now, Retention: time.Hour, GiveUpBefore: now.Add(-time.Hour)})
	}
	storedExports := func() []*firestore.DocumentSnapshot {
		t.Helper()
		stored, err := client.Collection("exports").Where("uid", "==", uid).Limit(n + 1).Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		return stored
	}

	docs := make([]identity.ExportDoc, n)
	replays := make([]bool, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			docs[i], replays[i], errs[i] = create(i)
		}()
	}
	wg.Wait()

	stored := storedExports()
	if len(stored) > 1 {
		t.Fatalf("exports = %d after racing requests, want at most 1 (errs %v)", len(stored), errs)
	}
	created, failed := 0, 0
	for i := range n {
		switch {
		case errs[i] != nil:
			failed++
			// The same answers RequestAccountExport turns into a retryable UNAVAILABLE.
			if !store.IsContention(errs[i]) && !errors.Is(errs[i], context.DeadlineExceeded) && status.Code(errs[i]) != codes.DeadlineExceeded {
				t.Errorf("request %d err = %v, want only a retryable contention error", i, errs[i])
			}
		case len(stored) != 1 || docs[i].ID != stored[0].Ref.ID:
			t.Errorf("request %d got %s, want the one stored export (%d stored)", i, docs[i].ID, len(stored))
		case !replays[i]:
			created++
		}
	}

	for i := range n {
		doc, replay, err := create(i)
		if err != nil {
			t.Fatalf("retry of request %d: %v", i, err)
		}
		if !replay {
			created++
		}
		docs[i] = doc
	}
	stored = storedExports()
	if len(stored) != 1 {
		t.Fatalf("exports = %d after retries, want 1", len(stored))
	}
	for i := range n {
		if docs[i].ID != stored[0].Ref.ID {
			t.Errorf("retry of request %d got %s, want the one export %s", i, docs[i].ID, stored[0].Ref.ID)
		}
	}
	// That flag decides the publish. A racer whose commit landed after its deadline reports an error and its retry a replay,
	// so 0 is possible only when a racer failed; the replay republish recovers that export.
	if created > 1 || (created == 0 && failed == 0) {
		t.Errorf("%d requests reported creating the export, want 1 (%d racers failed: %v)", created, failed, errs)
	}
}

// TestCreateExport_Integration_SameKeyRace: retries of one request racing each other give one export, not an Internal
// error from the Create that lost (AlreadyExists).
func TestCreateExport_Integration_SameKeyRace(t *testing.T) {
	repo, client := lifecycleRepo(t)
	raceCreateExport(t, repo, client, "racer-same-key", 5, func(int) string { return "racer-same-key-export" })
}

// TestCreateExport_Integration_OnePendingRace: requests racing with different keys start one export and all get it. It
// runs with the lock doc already there today (Touch must still change it) and not there yet. The emulator's locking is
// not production's optimistic mode, so this shows the outcome; what the lock adds is the reasoning in CreateExport.
func TestCreateExport_Integration_OnePendingRace(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	if _, err := client.Collection("quotas").Doc("racer-seeded").Set(ctx, map[string]any{"day": quota.Today()}); err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{"racer-seeded", "racer-fresh"} {
		t.Run(uid, func(t *testing.T) {
			raceCreateExport(t, repo, client, uid, 5, func(i int) string { return fmt.Sprintf("%s-export-%d", uid, i) })
		})
	}
}

// TestCreateExport_Integration: a first request creates the export; a replay writes nothing; a second key while it is
// PENDING gets that export; a second key after it finished is a second export; the export doc carries the TTL field.
func TestCreateExport_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	p := identity.CreateExportParams{ID: "export-id-1", UID: "u1", ObjectPath: "export-id-1.json", Now: now, Retention: 7 * 24 * time.Hour}

	ctx := context.Background()
	doc, replay, err := repo.CreateExport(ctx, p)
	if err != nil || replay || doc.Status != identity.ExportPending || !doc.ExpireAt.Equal(now.Add(7*24*time.Hour)) {
		t.Fatalf("CreateExport = %+v, %v, %v", doc, replay, err)
	}

	ctx = context.Background()
	again, replay, err := repo.CreateExport(ctx, p)
	if err != nil || !replay || again.ID != "export-id-1" {
		t.Fatalf("replay = %+v, %v, %v", again, replay, err)
	}

	p2 := p
	p2.ID = "export-id-2"
	joined, replay, err := repo.CreateExport(context.Background(), p2)
	if err != nil || !replay || joined.ID != "export-id-1" {
		t.Errorf("second key while PENDING = %+v, replay %v, err %v; want export-id-1", joined, replay, err)
	}
	if _, err := repo.GetExport(context.Background(), "export-id-2"); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("second key while PENDING created a doc: GetExport err = %v", err)
	}
	if rec, err := client.Collection("quotas").Doc("u1").Get(context.Background()); err != nil {
		t.Errorf("quotas/u1 read: %v", err)
	} else if reports, _ := rec.DataAt("reports"); reports != int64(0) {
		t.Errorf("quotas/u1 reports = %v; the export lock must count nothing", reports)
	}

	// Status changes carry the precondition.
	got, err := repo.GetExport(context.Background(), "export-id-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.SetExportStatus(context.Background(), "export-id-1", identity.ExportReady, got.UpdateTime); err != nil {
		t.Fatal(err)
	}
	if err := repo.SetExportStatus(context.Background(), "export-id-1", identity.ExportFailed, got.UpdateTime); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("stale SetExportStatus err = %v", err)
	}
	if _, err := repo.GetExport(context.Background(), "nope"); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("GetExport(unknown) err = %v", err)
	}
	if err := repo.SetExportStatus(context.Background(), "nope", identity.ExportReady, now); !errors.Is(err, identity.ErrJobConflict) && !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("SetExportStatus(unknown) err = %v", err)
	}
	if _, replay, err := repo.CreateExport(context.Background(), p2); err != nil || replay {
		t.Errorf("second key after READY = replay %v, err %v; want a new export", replay, err)
	}
	// A PENDING export created exactly at the give-up cut-off no longer holds the slot.
	p3 := p
	p3.ID, p3.GiveUpBefore = "export-id-3", now
	if got, replay, err := repo.CreateExport(context.Background(), p3); err != nil || replay || got.ID != "export-id-3" {
		t.Errorf("past the give-up cut-off = %+v, replay %v, err %v; want a new export", got, replay, err)
	}
	if err := repo.DeleteExportDocs(context.Background(), []string{"export-id-3"}); err != nil {
		t.Fatal(err)
	}
	pend, err := repo.ListPendingExports(context.Background(), time.Now().Add(time.Hour), identity.BackstopCursor{}, 50)
	if err != nil || len(pend) != 1 || pend[0].ID != "export-id-2" {
		t.Errorf("pending after READY = %v, %v; want only the second export (export-id-2)", pend, err)
	}
}

// TestIdentityStepOps_Integration: the identity-step repo operations on real documents.
func TestIdentityStepOps_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	seedProfile(t, repo, "u1", "Alice")
	seedProfile(t, repo, "u2", "Bobby")
	now := time.Now().UTC()
	for _, id := range []string{"e1", "e2"} {
		// The cut-off is past now so that e1 does not hold the slot: this test needs two export docs for one user.
		if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: id, UID: "u1", ObjectPath: id + ".json", Now: now, Retention: time.Hour, GiveUpBefore: now.Add(time.Second)}); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: "other", UID: "u2", ObjectPath: "other.json", Now: now, Retention: time.Hour}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b", "c"} {
		if _, err := client.Collection("users").Doc("u1").Collection("private").Doc(id).Set(ctx, map[string]any{"x": 1}); err != nil {
			t.Fatal(err)
		}
	}

	docs, err := repo.ListExports(ctx, "u1", 50)
	if err != nil || len(docs) != 2 {
		t.Fatalf("ListExports = %v, %v (u2's export must not be listed)", docs, err)
	}
	if err := repo.DeleteExportDocs(ctx, []string{"e1", "e2", "already-gone"}); err != nil {
		t.Fatalf("DeleteExportDocs: %v", err)
	}
	if left, _ := repo.ListExports(ctx, "u1", 50); len(left) != 0 {
		t.Errorf("exports left: %v", left)
	}

	if n, err := repo.DeletePrivate(ctx, "u1", 2); err != nil || n != 2 {
		t.Fatalf("DeletePrivate = %d, %v (limit 2)", n, err)
	}
	if n, err := repo.DeletePrivate(ctx, "u1", 500); err != nil || n != 1 {
		t.Fatalf("second DeletePrivate = %d, %v", n, err)
	}
	if n, _ := repo.DeletePrivate(ctx, "u1", 500); n != 0 {
		t.Errorf("third DeletePrivate = %d", n)
	}

	// The handle is deleted only when it is theirs.
	if out, err := repo.DeleteHandleIfOwned(ctx, "bobby", "u1"); err != nil || out != identity.HandleOwnerMismatch {
		t.Errorf("another user's handle: %v, %v, want HandleOwnerMismatch", out, err)
	}
	if _, err := client.Collection("handles").Doc("bobby").Get(ctx); err != nil {
		t.Errorf("another user's handle was deleted: %v", err)
	}
	if out, err := repo.DeleteHandleIfOwned(ctx, "alice", "u1"); err != nil || out != identity.HandleDeleted {
		t.Errorf("own handle: %v, %v", out, err)
	}
	if out, err := repo.DeleteHandleIfOwned(ctx, "alice", "u1"); err != nil || out != identity.HandleAbsent {
		t.Errorf("repeat: %v, %v, want HandleAbsent", out, err)
	}
	if out, err := repo.DeleteHandleIfOwned(ctx, "", "u1"); err != nil || out != identity.HandleAbsent {
		t.Errorf("empty handle: %v, %v", out, err)
	}

	if err := repo.DeleteQuotas(ctx, "u1"); err != nil {
		t.Errorf("DeleteQuotas: %v", err)
	}
	if err := repo.DeleteQuotas(ctx, "no-quota-doc"); err != nil {
		t.Errorf("DeleteQuotas(missing): %v", err)
	}
	// The final delete is conditional (m8): an ACTIVE doc, or a DELETING one at another seq, survives.
	if err := repo.DeleteUserDoc(ctx, "u1", 0); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("DeleteUserDoc on an ACTIVE account = %v, want ErrJobConflict", err)
	}
	if _, err := repo.BeginDeletion(ctx, "u1", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := repo.DeleteUserDoc(ctx, "u1", 7); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("DeleteUserDoc at the wrong seq = %v, want ErrJobConflict", err)
	}
	if _, err := repo.GetProfile(ctx, "u1"); err != nil {
		t.Fatalf("a conflicting DeleteUserDoc deleted the document: %v", err)
	}
	if err := repo.DeleteUserDoc(ctx, "u1", 0); err != nil {
		t.Errorf("DeleteUserDoc: %v", err)
	}
	if err := repo.DeleteUserDoc(ctx, "u1", 0); err != nil {
		t.Errorf("DeleteUserDoc repeat: %v", err)
	}
	if _, err := repo.GetProfile(ctx, "u1"); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("profile after delete: %v", err)
	}
}

// TestBackstopQueries_Integration (L-6): the backstop scans are ordered by progress timestamp with the age filter in
// the query, so fresh jobs cannot hide a stuck one, and a cursor walks the rest. The emulator does
// not enforce composite indexes; firebase/firestore.indexes.json carries users(status, deletionJob.progressAt) and
// exports(status, createdAt) for the deployed database.
func TestBackstopQueries_Integration(t *testing.T) {
	repo, _ := lifecycleRepo(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)

	// More fresh DELETING accounts than one page (the old unordered Limit(50) scan could be filled by these alone),
	// then stuck ones with distinct and equal progress timestamps.
	seedProfile(t, repo, "live", "Live1")
	for i := 0; i < 51; i++ {
		uid := fmt.Sprintf("fresh%02d", i)
		seedProfile(t, repo, uid, fmt.Sprintf("Fresh%02d", i))
		if _, err := repo.BeginDeletion(ctx, uid, now.Add(-time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	stuck := []struct {
		uid string
		ago time.Duration
	}{{"stuck-c", 2 * time.Hour}, {"stuck-a", 5 * time.Hour}, {"stuck-b", 5 * time.Hour}, {"stuck-d", 90 * time.Minute}, {"stuck-e", time.Hour}}
	for i, st := range stuck {
		seedProfile(t, repo, st.uid, fmt.Sprintf("Stuck%d", i))
		if _, err := repo.BeginDeletion(ctx, st.uid, now.Add(-st.ago)); err != nil {
			t.Fatal(err)
		}
	}
	threshold := now.Add(-time.Hour)

	page, err := repo.ListDeleting(ctx, threshold, identity.BackstopCursor{}, 50)
	if err != nil || len(page) != 5 {
		t.Fatalf("ListDeleting = %d accounts, %v; want only the 5 stuck ones among 56 DELETING", len(page), err)
	}
	var order []string
	for _, p := range page {
		order = append(order, p.UserID)
	}
	if want := []string{"stuck-a", "stuck-b", "stuck-c", "stuck-d", "stuck-e"}; !slices.Equal(order, want) {
		t.Errorf("order = %v, want oldest progress first with the uid as tie-break: %v", order, want)
	}

	// A cursor continues after the last document of the previous page: pages of 2 cover all 5 exactly once.
	var walked []string
	cursor := identity.BackstopCursor{}
	for pages := 0; pages < 5; pages++ {
		got, err := repo.ListDeleting(ctx, threshold, cursor, 2)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range got {
			walked = append(walked, p.UserID)
		}
		if len(got) < 2 {
			break
		}
		last := got[len(got)-1]
		cursor = identity.BackstopCursor{At: last.DeletionJob.ProgressAt, ID: last.UserID}
	}
	if !slices.Equal(walked, order) {
		t.Errorf("cursor walk = %v, want %v", walked, order)
	}
	if got, _ := repo.ListDeleting(ctx, now.Add(-10*time.Hour), identity.BackstopCursor{}, 50); len(got) != 0 {
		t.Errorf("nothing is older than 10 h, got %d", len(got))
	}

	// Exports: the same shape on exports(status, createdAt). A leased export is still PENDING and is listed.
	for _, e := range []struct {
		id  string
		ago time.Duration
	}{{"p-new", time.Minute}, {"p-mid", 2 * time.Hour}, {"p-old", 30 * time.Hour}} {
		if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: e.id, UID: "u-" + e.id, ObjectPath: e.id + ".json", Now: now.Add(-e.ago), Retention: 7 * 24 * time.Hour}); err != nil {
			t.Fatal(err)
		}
	}
	doc, _ := repo.GetExport(ctx, "p-mid")
	if _, err := repo.ClaimExport(ctx, "p-mid", doc.UpdateTime, now.Add(-time.Hour)); err != nil { // a crashed run: lease long expired
		t.Fatal(err)
	}
	pend, err := repo.ListPendingExports(ctx, threshold, identity.BackstopCursor{}, 50)
	if err != nil || len(pend) != 2 || pend[0].ID != "p-old" || pend[1].ID != "p-mid" {
		t.Fatalf("ListPendingExports = %v, %v; want [p-old p-mid] (oldest first, the fresh one filtered, the expired lease included)", pend, err)
	}
	next, err := repo.ListPendingExports(ctx, threshold, identity.BackstopCursor{At: pend[0].CreatedAt, ID: pend[0].ID}, 50)
	if err != nil || len(next) != 1 || next[0].ID != "p-mid" {
		t.Errorf("after the first: %v, %v", next, err)
	}
}

// TestClaimExport_Integration (L-4): the claim is one conditional write that leaves the status PENDING, returns the
// update time the final status write needs, and loses to any concurrent change.
func TestClaimExport_Integration(t *testing.T) {
	repo, _ := lifecycleRepo(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: "x1", UID: "u1", ObjectPath: "x1.json", Now: now, Retention: time.Hour}); err != nil {
		t.Fatal(err)
	}
	doc, err := repo.GetExport(ctx, "x1")
	if err != nil || !doc.LeaseUntil.IsZero() {
		t.Fatalf("fresh doc = %+v, %v; want no lease", doc, err)
	}
	lease := now.Add(35 * time.Second)

	ut, err := repo.ClaimExport(ctx, "x1", doc.UpdateTime, lease)
	if err != nil || !ut.After(doc.UpdateTime) {
		t.Fatalf("ClaimExport = %v, %v", ut, err)
	}
	got, _ := repo.GetExport(ctx, "x1")
	if got.Status != identity.ExportPending || !got.LeaseUntil.Equal(lease) || !got.UpdateTime.Equal(ut) {
		t.Errorf("after claim = %+v, want PENDING, lease %v, update time %v", got, lease, ut)
	}
	// The second claimant read the same doc: it loses.
	if _, err := repo.ClaimExport(ctx, "x1", doc.UpdateTime, lease.Add(time.Minute)); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("stale claim err = %v, want ErrJobConflict", err)
	}
	if _, err := repo.ClaimExport(ctx, "nope", doc.UpdateTime, lease); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("claim of a missing doc err = %v, want ErrJobConflict", err)
	}
	// The claimant finishes with the update time the claim returned; the original read's time is stale.
	if err := repo.SetExportStatus(ctx, "x1", identity.ExportReady, doc.UpdateTime); !errors.Is(err, identity.ErrJobConflict) {
		t.Errorf("READY with the pre-claim time err = %v, want ErrJobConflict", err)
	}
	if err := repo.SetExportStatus(ctx, "x1", identity.ExportReady, ut); err != nil {
		t.Errorf("READY with the claim's update time: %v", err)
	}
}
