//go:build integration

package lists

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// The budgets below are the service's own reads on top of the account-status interceptor's one profile read (the interceptor is
// not part of this harness): ADR-0030 "Cost impact" lists CreateList 4 / UpdateList 3 / DeleteList 3 including it.

type listsEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	svc    *service
	node   *snowflake.Node
}

func newListsEnv(t *testing.T, created time.Time) *listsEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := NewFirestoreRepo(client, quota.New(client), idempotency.New(client))
	dir := fakeDirectory{profiles: map[string]identity.Profile{
		"owner":    {UserID: "owner", Handle: "owner", CreatedAt: created},
		"stranger": {UserID: "stranger", Handle: "stranger", CreatedAt: created},
	}}
	svc := New(Deps{
		Repo: repo, Directory: dir, IDs: node,
		Limits: Limits{MaxPerUser: 20, CreatesPerDay: 10, NewAccountCreatesPerDay: 3, NewAccountWindow: 24 * time.Hour, CacheEntries: 100},
	}).(*service)
	return &listsEnv{client: client, repo: repo, svc: svc, node: node}
}

// measured runs fn with a fresh counter and asserts the budget (a ceiling), returning the counter for exact checks.
func measured(t *testing.T, name string, b budgettest.Budget, fn func(ctx context.Context)) *budget.Counter {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	fn(ctx)
	budgettest.Assert(t, name, c, b)
	return c
}

func key(n int) string { return fmt.Sprintf("integration-key-%04d", n) }

func (e *listsEnv) doc(t *testing.T, id string) (map[string]any, bool) {
	t.Helper()
	snap, err := e.client.Collection("lists").Doc(id).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), true
}

func (e *listsEnv) quotaCount(t *testing.T, uid, field string) int64 {
	t.Helper()
	snap, err := e.client.Collection("quotas").Doc(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	v, _ := snap.DataAt(field)
	n, _ := v.(int64)
	return n
}

// seedLists writes n lists owned by owner with the given members (BulkWriter: no budget counted).
func (e *listsEnv) seedLists(t *testing.T, owner string, n int, members []string) []string {
	t.Helper()
	ctx := context.Background()
	bw := e.client.BulkWriter(ctx)
	ids := make([]string, n)
	var jobs []*firestore.BulkWriterJob
	for i := range ids {
		ids[i] = e.node.Generate()
		j, err := bw.Create(e.client.Collection("lists").Doc(ids[i]), listDoc{
			OwnerID: owner, Name: fmt.Sprintf("seed %d", i), MemberIDs: append([]string{}, members...), CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC(),
		})
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, j)
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	return ids
}

func create(t *testing.T, e *listsEnv, uid string, n int, name string, private *bool) (View, error) {
	t.Helper()
	return e.svc.CreateList(context.Background(), uid, CreateInput{Key: key(n), Name: name, IsPrivate: private})
}

// CreateList: 3 reads and 3 writes in the service (4 and 3 with the interceptor), private by default, and the stored document
// has the ADR-0030 D2 shape with memberIds as an empty array.
func TestCreateList_Integration_Budget(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	var view View
	c := measured(t, "CreateList", budgettest.Budget{Reads: 3, Writes: 3}, func(ctx context.Context) {
		v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "  Cricket ", Description: "ODI"})
		if err != nil {
			t.Fatal(err)
		}
		view = v
	})
	if c.Reads() != 3 || c.Writes() != 3 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want exactly 3/3/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if len(view.Header.ID) != 19 || view.Header.Name != "Cricket" || !view.Header.IsPrivate || view.Header.MemberCount != 0 || view.Owner.Handle != "owner" {
		t.Errorf("view = %+v", view)
	}
	d, ok := e.doc(t, view.Header.ID)
	if !ok {
		t.Fatal("the list document was not written")
	}
	members, _ := d["memberIds"].([]any)
	if d["ownerId"] != "owner" || d["isPrivate"] != true || d["name"] != "Cricket" || d["description"] != "ODI" || members == nil || len(members) != 0 {
		t.Errorf("document = %v", d)
	}
	if _, has := d["hidden"]; has {
		t.Error("hidden is written when false (absent = false)")
	}
	if n := e.quotaCount(t, "owner", "listCreates"); n != 1 {
		t.Errorf("quotas.listCreates = %d, want 1", n)
	}
	// is_private=false is honoured.
	pub := false
	v2, err := create(t, e, "owner", 2, "Public", &pub)
	if err != nil || v2.Header.IsPrivate {
		t.Fatalf("public create: %+v %v", v2, err)
	}
}

// A replay returns the stored header with 1 read (2 with the interceptor) and 0 writes, and creates no second list. The same
// key with another body is IDEMPOTENCY_KEY_REUSED with 0 writes.
func TestCreateList_Integration_Replay(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	first, err := create(t, e, "owner", 1, "Cricket", nil)
	if err != nil {
		t.Fatal(err)
	}
	var replay View
	c := measured(t, "CreateList replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket"})
		if err != nil {
			t.Fatal(err)
		}
		replay = v
	})
	if c.Writes() != 0 || c.Reads() != 1 {
		t.Errorf("replay reads/writes = %d/%d, want 1/0", c.Reads(), c.Writes())
	}
	if replay.Header != first.Header {
		t.Errorf("replay header = %+v, want %+v", replay.Header, first.Header)
	}
	if n := e.quotaCount(t, "owner", "listCreates"); n != 1 {
		t.Errorf("a replay spent quota: listCreates = %d", n)
	}

	c = measured(t, "CreateList key reused", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		_, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Another name"})
		wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	})
	if c.Writes() != 0 {
		t.Errorf("key reuse wrote %d", c.Writes())
	}
	// is_private unset vs explicit true are different bodies for the same key.
	yes := true
	_, err = e.svc.CreateList(context.Background(), "owner", CreateInput{Key: key(1), Name: "Cricket", IsPrivate: &yes})
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
}

// Four requests race with one key. The contract (service.mapErr, the same as messaging's "busy") lets a racer that loses the
// transaction and exhausts its re-runs answer a retryable UNAVAILABLE; what must never happen is a second list or a second
// quota charge. W5-15: this used to demand that all four succeed inside the 5 s transaction timeout, but a contended call
// takes 2 to 3.4 s on the emulator (the SDK's own backoff on the losers), so a slower runner pushed a loser over the
// timeout and failed the test with a correct product answer. Now: at least one succeeds, every success is the same list,
// a busy racer's retry with the same key replays that list, and there is exactly one list and one quota charge.
func TestCreateList_Integration_ConcurrentSameKey(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	const n = 4
	views := make([]View, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			views[i], errs[i] = e.svc.CreateList(context.Background(), "owner", CreateInput{Key: key(7), Name: "Racing"})
		}()
	}
	wg.Wait()
	winner := ""
	for i := range n {
		if errs[i] != nil {
			wantAPI(t, errs[i], connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil) // a lost race: retryable, nothing written
			continue
		}
		if winner == "" {
			winner = views[i].Header.ID
		}
		if views[i].Header.ID != winner {
			t.Errorf("request %d got list %s, want %s", i, views[i].Header.ID, winner)
		}
	}
	if winner == "" {
		t.Fatalf("no racer succeeded: %v", errs)
	}
	for i := range n {
		if errs[i] == nil {
			continue
		}
		again, err := e.svc.CreateList(context.Background(), "owner", CreateInput{Key: key(7), Name: "Racing"})
		if err != nil || again.Header.ID != winner {
			t.Errorf("retry of busy request %d: id=%s err=%v, want the replayed list %s", i, again.Header.ID, err, winner)
		}
	}
	docs, err := e.client.Collection("lists").Where("ownerId", "==", "owner").Limit(10).Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1 {
		t.Errorf("lists = %d (err %v), want exactly 1", len(docs), err)
	}
	if q := e.quotaCount(t, "owner", "listCreates"); q != 1 {
		t.Errorf("listCreates = %d, want 1", q)
	}
}

// At 20 lists CreateList is LIMIT_REACHED limit=lists with 0 writes; the count is charged (3 reads in the service).
func TestCreateList_Integration_Cap(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	e.seedLists(t, "owner", 20, nil)
	e.seedLists(t, "stranger", 3, nil) // another owner's lists do not count
	c := measured(t, "CreateList at the cap", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
		_, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "21st"})
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "lists"})
	})
	if c.Writes() != 0 {
		t.Errorf("the cap wrote %d documents, want 0", c.Writes())
	}
	if n := e.quotaCount(t, "owner", "listCreates"); n != 0 {
		t.Errorf("the cap spent quota: %d", n)
	}
	// 19 is below the cap.
	e2 := newListsEnv(t, time.Now().Add(-72*time.Hour))
	e2.seedLists(t, "owner", 19, nil)
	if _, err := create(t, e2, "owner", 1, "20th", nil); err != nil {
		t.Fatalf("the 20th list: %v", err)
	}
	if _, err := create(t, e2, "owner", 2, "21st", nil); err == nil {
		t.Fatal("the 21st list was created")
	}
}

// Quota tiers: 10 a day, 3 for an account younger than 24 h; the refusal is QUOTA_EXCEEDED list_creates with 0 writes.
func TestCreateList_Integration_QuotaTiers(t *testing.T) {
	tests := []struct {
		name    string
		created time.Time
		allowed int
	}{
		{"new account", time.Now().Add(-time.Hour), 3},
		{"established account", time.Now().Add(-72 * time.Hour), 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newListsEnv(t, tt.created)
			for i := 1; i <= tt.allowed; i++ {
				if _, err := create(t, e, "owner", i, fmt.Sprintf("List %d", i), nil); err != nil {
					t.Fatalf("create %d: %v", i, err)
				}
			}
			c := measured(t, "over the quota", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
				_, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(99), Name: "Over"})
				wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, map[string]string{"quota": "list_creates"})
			})
			if c.Writes() != 0 {
				t.Errorf("the quota refusal wrote %d", c.Writes())
			}
			if n := e.quotaCount(t, "owner", "listCreates"); n != int64(tt.allowed) {
				t.Errorf("listCreates = %d, want %d", n, tt.allowed)
			}
			// A replay of an earlier create still succeeds at the limit and is not charged.
			if _, err := create(t, e, "owner", 1, "List 1", nil); err != nil {
				t.Errorf("replay at the quota limit: %v", err)
			}
		})
	}
}

// UpdateList: 2 reads and 2 writes in the service (3 and 2 with the interceptor); nothing changed = 1 write; replay 1 read, 0
// writes; field-level (members and createdAt survive); a rename and a visibility change are visible in the document.
func TestUpdateList_Integration(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	ids := e.seedLists(t, "owner", 1, []string{"m1", "m2"})
	id := ids[0]
	before, _ := e.doc(t, id)

	var v View
	c := measured(t, "UpdateList", budgettest.Budget{Reads: 2, Writes: 2}, func(ctx context.Context) {
		var err error
		v, err = e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(1), ListID: id, Name: ptr(" New name "), IsPrivate: ptr(true)})
		if err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 2 || c.Writes() != 2 {
		t.Errorf("reads/writes = %d/%d, want 2/2", c.Reads(), c.Writes())
	}
	if v.Header.Name != "New name" || !v.Header.IsPrivate || v.Header.MemberCount != 2 {
		t.Errorf("view = %+v", v.Header)
	}
	after, _ := e.doc(t, id)
	if after["name"] != "New name" || after["isPrivate"] != true || fmt.Sprint(after["memberIds"]) != "[m1 m2]" || after["ownerId"] != "owner" || !after["createdAt"].(time.Time).Equal(before["createdAt"].(time.Time)) {
		t.Errorf("document = %v (members, owner and createdAt must survive a field-level update)", after)
	}

	// Nothing differs from what is stored: only the idempotency document is written.
	c = measured(t, "UpdateList unchanged", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if _, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(2), ListID: id, Name: ptr("New name")}); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 1 {
		t.Errorf("unchanged update wrote %d, want 1 (the idempotency document)", c.Writes())
	}

	// Replay: stored header, 1 read, 0 writes, even though the list changed since.
	if _, err := e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(3), ListID: id, Name: ptr("Third")}); err != nil {
		t.Fatal(err)
	}
	c = measured(t, "UpdateList replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		rv, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(1), ListID: id, Name: ptr(" New name "), IsPrivate: ptr(true)})
		if err != nil || rv.Header.Name != "New name" {
			t.Errorf("replay = %+v, %v, want the stored outcome", rv.Header, err)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("replay wrote %d", c.Writes())
	}
	if d, _ := e.doc(t, id); d["name"] != "Third" {
		t.Errorf("a replay changed the list: %v", d["name"])
	}

	// Same key, different body.
	_, err := e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(1), ListID: id, Name: ptr("Other")})
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	// An unset description and an empty description are different bodies for one key.
	if _, err := e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(4), ListID: id, Description: ptr("")}); err != nil {
		t.Fatal(err)
	}
	_, err = e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(4), ListID: id})
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
}

// Another user's list and a list that never existed are the same NOT_FOUND, byte for byte, with 0 writes; a deleted list is
// not recreated by an Update.
func TestUpdateList_Integration_NotFoundIsOneAnswer(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	foreign := e.seedLists(t, "stranger", 1, nil)[0]
	missing := e.node.Generate()
	mine := e.seedLists(t, "owner", 1, nil)[0]

	answer := func(id string, n int) (code connect.Code, msg string, reason commonv1.ErrorReason, meta map[string]string) {
		var out *apierr.Error
		c := measured(t, "UpdateList not found", budgettest.Budget{Reads: 2}, func(ctx context.Context) {
			_, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(n), ListID: id, Name: ptr("Hijack")})
			var ae *apierr.Error
			if !asAPI(err, &ae) {
				t.Fatalf("err = %v", err)
			}
			out = ae
		})
		if c.Writes() != 0 {
			t.Errorf("a not-found update wrote %d", c.Writes())
		}
		return out.Code, out.Message, out.Reason, out.Metadata
	}
	c1, m1, r1, md1 := answer(foreign, 1)
	c2, m2, r2, md2 := answer(missing, 2)
	if c1 != connect.CodeNotFound || c1 != c2 || m1 != m2 || r1 != r2 || fmt.Sprint(md1) != fmt.Sprint(md2) {
		t.Errorf("foreign: %v %q %v %v; missing: %v %q %v %v: not byte-identical", c1, m1, r1, md1, c2, m2, r2, md2)
	}
	if d, _ := e.doc(t, foreign); d["name"] == "Hijack" {
		t.Error("another user's list was changed")
	}

	if err := e.svc.DeleteList(context.Background(), "owner", key(3), mine); err != nil {
		t.Fatal(err)
	}
	c3, m3, _, _ := answer(mine, 4)
	if c3 != connect.CodeNotFound || m3 != m1 {
		t.Errorf("deleted list: %v %q, want the same NOT_FOUND", c3, m3)
	}
	if _, ok := e.doc(t, mine); ok {
		t.Error("an Update recreated a deleted list")
	}
}

func asAPI(err error, target **apierr.Error) bool {
	for err != nil {
		if ae, ok := err.(*apierr.Error); ok {
			*target = ae
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// DeleteList: 2 reads, 1 write (idempotency), 1 delete in the service (3, 1, 1 with the interceptor). A list that is not the
// caller's, or is gone, is success with 1 write and no delete; a replay is 1 read, 0 writes.
func TestDeleteList_Integration(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	mine := e.seedLists(t, "owner", 1, []string{"m1"})[0]
	foreign := e.seedLists(t, "stranger", 1, nil)[0]

	c := measured(t, "DeleteList", budgettest.Budget{Reads: 2, Writes: 1, Deletes: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(1), mine); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 2 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 2/1/1", c.Reads(), c.Writes(), c.Deletes())
	}
	if _, ok := e.doc(t, mine); ok {
		t.Error("the list survived")
	}

	c = measured(t, "DeleteList foreign", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(2), foreign); err != nil {
			t.Fatalf("foreign list: %v", err)
		}
	})
	if c.Deletes() != 0 {
		t.Errorf("deleted somebody else's list: deletes = %d", c.Deletes())
	}
	if _, ok := e.doc(t, foreign); !ok {
		t.Error("another user's list was deleted")
	}

	missing := e.node.Generate()
	c = measured(t, "DeleteList missing", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(3), missing); err != nil {
			t.Fatalf("missing list: %v", err)
		}
	})
	if c.Deletes() != 0 || c.Writes() != 1 {
		t.Errorf("missing: writes/deletes = %d/%d, want 1/0", c.Writes(), c.Deletes())
	}

	c = measured(t, "DeleteList replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(1), mine); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("replay wrote %d / deleted %d", c.Writes(), c.Deletes())
	}
	// The same key for another list is a reused key.
	err := e.svc.DeleteList(context.Background(), "owner", key(1), foreign)
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
}

// The late-retry hazard ADR-0030 D7 closes: a delete of a missing list stores its key, so the retry replays instead of acting on
// state that appeared since. (Snowflake ids are never reused, so here the stored key is checked, not a recreated list.)
func TestDeleteList_Integration_NoOpStoresTheKey(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	id := e.node.Generate()
	if err := e.svc.DeleteList(context.Background(), "owner", key(1), id); err != nil {
		t.Fatal(err)
	}
	snap, err := e.client.Collection("idempotency").Doc(idempotency.Key("owner", rpcDeleteList, key(1))).Get(context.Background())
	if err != nil {
		t.Fatalf("the no-op delete stored no idempotency document: %v", err)
	}
	if exp, _ := snap.DataAt("expireAt"); exp == nil {
		t.Error("the idempotency document has no expireAt (TTL)")
	}
}

// Eraser: a user who owns 2 lists and is a member of 3 others (and a 4th they own and are in). After the step their 2 lists
// are gone, the 3 lists no longer name them but keep every other member, and a rerun writes nothing.
func TestEraser_Integration(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	ctx := context.Background()
	own := e.seedLists(t, "doomed", 2, []string{"doomed", "friend"})
	others := e.seedLists(t, "friend", 3, []string{"doomed", "friend2"})
	untouched := e.seedLists(t, "friend", 1, []string{"friend2"})[0]
	before, _ := e.doc(t, others[0])

	eraser := NewEraser(e.repo)
	var cp Checkpoint
	// Phase 1: 2 reads + 2 deletes. Phase 2: 3 reads + 3 writes.
	{
		ctx1, c := budget.WithCounter(ctx)
		next, done, err := eraser.PurgeUser(ctx1, "doomed", cp)
		if err != nil || done {
			t.Fatalf("own phase: done %v err %v", done, err)
		}
		cp = next
		if c.Reads() != 2 || c.Deletes() != 2 || c.Writes() != 0 {
			t.Errorf("own phase reads/deletes/writes = %d/%d/%d, want 2/2/0", c.Reads(), c.Deletes(), c.Writes())
		}
	}
	// Resume from a serialised checkpoint, as a redelivered job would.
	raw, err := json.Marshal(cp)
	if err != nil {
		t.Fatal(err)
	}
	cp = Checkpoint{}
	if err := json.Unmarshal(raw, &cp); err != nil {
		t.Fatal(err)
	}
	for _, id := range own {
		if _, ok := e.doc(t, id); ok {
			t.Fatalf("own list %s survived phase 1", id)
		}
	}
	{
		ctx2, c := budget.WithCounter(ctx)
		next, done, err := eraser.PurgeUser(ctx2, "doomed", cp)
		if err != nil || !done {
			t.Fatalf("member phase: done %v err %v", done, err)
		}
		cp = next
		if c.Reads() != 3 || c.Writes() != 3 || c.Deletes() != 0 {
			t.Errorf("member phase reads/writes/deletes = %d/%d/%d, want 3/3/0", c.Reads(), c.Writes(), c.Deletes())
		}
	}
	for _, id := range others {
		d, ok := e.doc(t, id)
		if !ok {
			t.Fatalf("list %s of another owner was deleted", id)
		}
		if fmt.Sprint(d["memberIds"]) != "[friend2]" || d["ownerId"] != "friend" {
			t.Errorf("list %s = %v, want memberIds [friend2] only", id, d)
		}
	}
	if d, _ := e.doc(t, others[0]); !d["updatedAt"].(time.Time).After(before["updatedAt"].(time.Time)) {
		t.Error("updatedAt did not move")
	}
	if d, ok := e.doc(t, untouched); !ok || fmt.Sprint(d["memberIds"]) != "[friend2]" {
		t.Errorf("an unrelated list changed: %v", d)
	}

	// A rerun from the start is two empty pages: 1 read each, 0 writes, 0 deletes.
	var rerun Checkpoint
	for i := range 2 {
		rctx, c := budget.WithCounter(ctx)
		next, done, err := eraser.PurgeUser(rctx, "doomed", rerun)
		if err != nil {
			t.Fatal(err)
		}
		rerun = next
		if c.Reads() != 1 || c.Writes() != 0 || c.Deletes() != 0 || done != (i == 1) {
			t.Errorf("rerun page %d reads/writes/deletes = %d/%d/%d done %v, want 1/0/0 %v", i, c.Reads(), c.Writes(), c.Deletes(), done, i == 1)
		}
	}
}

// An account at 501 own lists (more than the cap can produce, but the step must page): two own pages, then the member phase.
func TestEraser_Integration_Paging(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds 501 lists")
	}
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	e.seedLists(t, "doomed", 501, nil)
	eraser := NewEraser(e.repo)
	var cp Checkpoint
	wantReads := []int64{500, 1, 1}
	wantDeletes := []int64{500, 1, 0}
	for i := range wantReads {
		ctx, c := budget.WithCounter(context.Background())
		next, done, err := eraser.PurgeUser(ctx, "doomed", cp)
		if err != nil {
			t.Fatal(err)
		}
		cp = next
		if c.Reads() != wantReads[i] || c.Deletes() != wantDeletes[i] || done != (i == 2) {
			t.Errorf("call %d: reads %d deletes %d done %v, want %d %d %v", i+1, c.Reads(), c.Deletes(), done, wantReads[i], wantDeletes[i], i == 2)
		}
	}
	if docs, _ := e.client.Collection("lists").Where("ownerId", "==", "doomed").Limit(1).Documents(context.Background()).GetAll(); len(docs) != 0 {
		t.Error("lists survived")
	}
}

// Export: own lists only (not the ones the user is a member of), with member ids, 1 read per list.
func TestExporter_Integration(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	e.seedLists(t, "owner", 2, []string{"m1"})
	e.seedLists(t, "stranger", 2, []string{"owner"}) // a member, not the owner: not exported
	var out []byte
	buf := &bytesBuffer{}
	c := measured(t, "export", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
		if err := NewExporter(e.repo).ExportUser(ctx, "owner", buf); err != nil {
			t.Fatal(err)
		}
	})
	out = buf.b
	if c.Reads() != 2 {
		t.Errorf("reads = %d, want 2 (one per own list)", c.Reads())
	}
	if n := countSub(string(out), `"listId"`); n != 2 {
		t.Errorf("exported %d lists, want 2: %s", n, out)
	}
	if countSub(string(out), `"owner"`) != 0 {
		t.Errorf("the export names the owner uid or a foreign list: %s", out)
	}
	// An account with no lists: 1 read (an empty query bills 1).
	buf = &bytesBuffer{}
	c = measured(t, "export empty", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		if err := NewExporter(e.repo).ExportUser(ctx, "nobody", buf); err != nil {
			t.Fatal(err)
		}
	})
	if string(buf.b) != "{\"lists\":[]}\n" || c.Reads() != 1 {
		t.Errorf("empty export = %q reads %d", buf.b, c.Reads())
	}
}

type bytesBuffer struct{ b []byte }

func (w *bytesBuffer) Write(p []byte) (int, error) { w.b = append(w.b, p...); return len(p), nil }

func countSub(s, sub string) int {
	n := 0
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			n++
		}
	}
	return n
}
