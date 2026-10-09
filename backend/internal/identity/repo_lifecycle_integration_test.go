//go:build integration

package identity_test

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
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

// TestBeginDeletion_Integration: DeleteAccount's sync part is 1 read and 1 write (ADR-0011 budget table); a replay
// is 1 read and 0 writes; SUSPENDED may delete; and the deletion state survives UpdateProfile's whole-document write.
func TestBeginDeletion_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	svc := identity.New(repo, identity.NewCache(time.Minute), time.Hour)
	seedProfile(t, repo, "u1", "Alice")
	seedProfile(t, repo, "u2", "Bobby")
	now := time.Now().UTC().Truncate(time.Millisecond)

	ctx, c := budget.WithCounter(context.Background())
	start, err := repo.BeginDeletion(ctx, "u1", now)
	if err != nil || start.Replay {
		t.Fatalf("BeginDeletion = %+v, %v", start, err)
	}
	budgettest.Assert(t, "BeginDeletion", c, budgettest.Budget{Reads: 1, Writes: 1})
	if c.Writes() != 1 {
		t.Errorf("writes = %d, want exactly 1", c.Writes())
	}
	p, ut, err := repo.GetJobState(context.Background(), "u1")
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != identity.AccountStatusDeleting || !p.DeletionRequestedAt.Equal(now) || p.DeletionJob == nil || p.DeletionJob.Seq != 0 || ut.IsZero() {
		t.Errorf("stored state = %+v updateTime %v", p, ut)
	}

	ctx, c = budget.WithCounter(context.Background())
	again, err := repo.BeginDeletion(ctx, "u1", now.Add(time.Hour))
	if err != nil || !again.Replay || !again.Profile.DeletionRequestedAt.Equal(now) {
		t.Fatalf("replay = %+v, %v", again, err)
	}
	budgettest.Assert(t, "BeginDeletion replay", c, budgettest.Budget{Reads: 1, Writes: 0})

	// SUSPENDED may delete (ADR-0011 Q3).
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

// TestSaveJobState_Integration: the save is 1 write, carries the UpdateTime precondition, and an unrelated counter
// increment between the read and the save is a conflict (the orchestrator re-reads and retries).
func TestSaveJobState_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	seedProfile(t, repo, "u1", "Alice")
	now := time.Now().UTC()
	if _, err := repo.BeginDeletion(context.Background(), "u1", now); err != nil {
		t.Fatal(err)
	}
	_, ut, _ := repo.GetJobState(context.Background(), "u1")

	ctx, c := budget.WithCounter(context.Background())
	job := identity.DeletionJob{Seq: 1, Step: "graph", Checkpoint: []byte(`{"Step":2}`), ProgressAt: now}
	if err := repo.SaveJobState(ctx, "u1", ut, job); err != nil {
		t.Fatalf("SaveJobState: %v", err)
	}
	budgettest.Assert(t, "SaveJobState", c, budgettest.Budget{Writes: 1})
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

// TestCreateExport_Integration: first request 1 read and 2 writes; a replay 2 reads and 0 writes (also with quota left
// and the next IST day, via the AlreadyExists rollback); the quota is
// enforced across keys; the export doc carries the TTL field.
func TestCreateExport_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	p := identity.CreateExportParams{ID: "export-id-1", UID: "u1", ObjectPath: "export-id-1.json", Now: now, Retention: 7 * 24 * time.Hour, ExportsPerDay: 1}

	ctx, c := budget.WithCounter(context.Background())
	doc, replay, err := repo.CreateExport(ctx, p)
	if err != nil || replay || doc.Status != identity.ExportPending || !doc.ExpireAt.Equal(now.Add(7*24*time.Hour)) {
		t.Fatalf("CreateExport = %+v, %v, %v", doc, replay, err)
	}
	budgettest.Assert(t, "CreateExport", c, budgettest.Budget{Reads: 1, Writes: 2})

	ctx, c = budget.WithCounter(context.Background())
	again, replay, err := repo.CreateExport(ctx, p)
	if err != nil || !replay || again.ID != "export-id-1" {
		t.Fatalf("replay = %+v, %v, %v", again, replay, err)
	}
	budgettest.Assert(t, "CreateExport replay", c, budgettest.Budget{Reads: 2, Writes: 0})

	p2 := p
	p2.ID = "export-id-2"
	_, _, err = repo.CreateExport(context.Background(), p2)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeResourceExhausted || ae.Metadata["quota"] != "exports" {
		t.Errorf("second export today: err = %v, want RESOURCE_EXHAUSTED exports", err)
	}
	if _, err := client.Collection("exports").Doc("export-id-2").Get(context.Background()); err == nil {
		t.Error("a rejected export left a doc")
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
	pend, err := repo.ListPendingExports(context.Background(), time.Now().Add(time.Hour), identity.BackstopCursor{}, 50)
	if err != nil || len(pend) != 0 {
		t.Errorf("pending after READY = %v, %v", pend, err)
	}
}

// TestCreateExport_Integration_ReplayWithQuotaLeft: the same id replayed while the daily quota is not used up (so
// the Create runs) fails with AlreadyExists, which rolls the commit back: the doc is returned, nothing is written
// and the quota counter is not incremented a second time.
func TestCreateExport_Integration_ReplayWithQuotaLeft(t *testing.T) {
	repo, client := lifecycleRepo(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	p := identity.CreateExportParams{ID: "export-id-1", UID: "u1", ObjectPath: "export-id-1.json", Now: now, Retention: time.Hour, ExportsPerDay: 5}
	if _, _, err := repo.CreateExport(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	ctx, c := budget.WithCounter(context.Background())
	doc, replay, err := repo.CreateExport(ctx, p)
	if err != nil || !replay || doc.ID != "export-id-1" || doc.UID != "u1" {
		t.Fatalf("replay = %+v, %v, %v", doc, replay, err)
	}
	budgettest.Assert(t, "CreateExport replay with quota left", c, budgettest.Budget{Reads: 2, Writes: 0})
	if c.Writes() != 0 {
		t.Errorf("writes = %d, want 0", c.Writes())
	}
	snap, err := client.Collection("quotas").Doc("u1").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := snap.DataAt("exports"); n != int64(1) {
		t.Errorf("exports quota counter = %v after a replay, want 1", n)
	}
}

// TestIdentityStepOps_Integration: the identity-step repo operations on real documents, with their read/delete costs.
func TestIdentityStepOps_Integration(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	seedProfile(t, repo, "u1", "Alice")
	seedProfile(t, repo, "u2", "Bobby")
	now := time.Now().UTC()
	for _, id := range []string{"e1", "e2"} {
		if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: id, UID: "u1", ObjectPath: id + ".json", Now: now, Retention: time.Hour, ExportsPerDay: 5}); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: "other", UID: "u2", ObjectPath: "other.json", Now: now, Retention: time.Hour, ExportsPerDay: 5}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b", "c"} {
		if _, err := client.Collection("users").Doc("u1").Collection("private").Doc(id).Set(ctx, map[string]any{"x": 1}); err != nil {
			t.Fatal(err)
		}
	}

	c1, cnt := budget.WithCounter(ctx)
	docs, err := repo.ListExports(c1, "u1", 50)
	if err != nil || len(docs) != 2 {
		t.Fatalf("ListExports = %v, %v (u2's export must not be listed)", docs, err)
	}
	budgettest.Assert(t, "ListExports", cnt, budgettest.Budget{Reads: 2})
	if err := repo.DeleteExportDocs(ctx, []string{"e1", "e2", "already-gone"}); err != nil {
		t.Fatalf("DeleteExportDocs: %v", err)
	}
	if left, _ := repo.ListExports(ctx, "u1", 50); len(left) != 0 {
		t.Errorf("exports left: %v", left)
	}

	c2, cnt := budget.WithCounter(ctx)
	if n, err := repo.DeletePrivate(c2, "u1", 2); err != nil || n != 2 {
		t.Fatalf("DeletePrivate = %d, %v (limit 2)", n, err)
	}
	budgettest.Assert(t, "DeletePrivate", cnt, budgettest.Budget{Reads: 2, Deletes: 2})
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
	c3, cnt := budget.WithCounter(ctx)
	if out, err := repo.DeleteHandleIfOwned(c3, "alice", "u1"); err != nil || out != identity.HandleDeleted {
		t.Errorf("own handle: %v, %v", out, err)
	}
	budgettest.Assert(t, "DeleteHandleIfOwned", cnt, budgettest.Budget{Reads: 1, Deletes: 1})
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
	// The final delete is conditional (ADR-0011 m8): an ACTIVE doc, or a DELETING one at another seq, survives.
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
	c4, cnt := budget.WithCounter(ctx)
	if err := repo.DeleteUserDoc(c4, "u1", 0); err != nil {
		t.Errorf("DeleteUserDoc: %v", err)
	}
	budgettest.Assert(t, "DeleteUserDoc", cnt, budgettest.Budget{Reads: 1, Deletes: 1})
	if err := repo.DeleteUserDoc(ctx, "u1", 0); err != nil {
		t.Errorf("DeleteUserDoc repeat: %v", err)
	}
	if _, err := repo.GetProfile(ctx, "u1"); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("profile after delete: %v", err)
	}
}

// TestBackstopQueries_Integration (L-6): the backstop scans are ordered by progress timestamp with the age filter in
// the query, so fresh jobs cost nothing and cannot hide a stuck one, and a cursor walks the rest. The emulator does
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

	c, cnt := budget.WithCounter(ctx)
	page, err := repo.ListDeleting(c, threshold, identity.BackstopCursor{}, 50)
	if err != nil || len(page) != 5 {
		t.Fatalf("ListDeleting = %d accounts, %v; want only the 5 stuck ones among 56 DELETING", len(page), err)
	}
	budgettest.Assert(t, "ListDeleting", cnt, budgettest.Budget{Reads: 5})
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
		if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: e.id, UID: "u-" + e.id, ObjectPath: e.id + ".json", Now: now.Add(-e.ago), Retention: 7 * 24 * time.Hour, ExportsPerDay: 1}); err != nil {
			t.Fatal(err)
		}
	}
	doc, _ := repo.GetExport(ctx, "p-mid")
	if _, err := repo.ClaimExport(ctx, "p-mid", doc.UpdateTime, now.Add(-time.Hour)); err != nil { // a crashed run: lease long expired
		t.Fatal(err)
	}
	c, cnt = budget.WithCounter(ctx)
	pend, err := repo.ListPendingExports(c, threshold, identity.BackstopCursor{}, 50)
	if err != nil || len(pend) != 2 || pend[0].ID != "p-old" || pend[1].ID != "p-mid" {
		t.Fatalf("ListPendingExports = %v, %v; want [p-old p-mid] (oldest first, the fresh one filtered, the expired lease included)", pend, err)
	}
	budgettest.Assert(t, "ListPendingExports", cnt, budgettest.Budget{Reads: 2})
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
	if _, _, err := repo.CreateExport(ctx, identity.CreateExportParams{ID: "x1", UID: "u1", ObjectPath: "x1.json", Now: now, Retention: time.Hour, ExportsPerDay: 5}); err != nil {
		t.Fatal(err)
	}
	doc, err := repo.GetExport(ctx, "x1")
	if err != nil || !doc.LeaseUntil.IsZero() {
		t.Fatalf("fresh doc = %+v, %v; want no lease", doc, err)
	}
	lease := now.Add(35 * time.Second)

	c, cnt := budget.WithCounter(ctx)
	ut, err := repo.ClaimExport(c, "x1", doc.UpdateTime, lease)
	if err != nil || !ut.After(doc.UpdateTime) {
		t.Fatalf("ClaimExport = %v, %v", ut, err)
	}
	budgettest.Assert(t, "ClaimExport", cnt, budgettest.Budget{Writes: 1})
	if cnt.Writes() != 1 {
		t.Errorf("writes = %d, want exactly 1", cnt.Writes())
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
