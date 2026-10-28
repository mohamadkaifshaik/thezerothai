//go:build integration

package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

func newTestClient(t *testing.T) *firestore.Client {
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

// counted returns a context whose Firestore operations are counted (one counter per call under test).
func counted() (context.Context, *budget.Counter) {
	return budget.WithCounter(context.Background())
}

func row(id string, ty Type, actor string, at time.Time) Notification {
	return Notification{ID: id, Type: ty, ActorIDs: []string{actor}, PostID: postA, CreatedAt: at,
		Actor: Actor{UserID: actor, Handle: "h_" + actor, DisplayName: "N " + actor}}
}

func docExists(t *testing.T, c *firestore.Client, path string) bool {
	t.Helper()
	snap, err := c.Doc(path).Get(context.Background())
	if err != nil {
		return false
	}
	return snap.Exists()
}

func countDocs(t *testing.T, c *firestore.Client, path string) int {
	t.Helper()
	it := c.Collection(path).Documents(context.Background())
	defer it.Stop()
	n := 0
	for {
		_, err := it.Next()
		if err == iterator.Done {
			return n
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
}

func TestIntegration_CreateIsIdempotentAndBudgeted(t *testing.T) {
	repo := NewFirestoreRepo(newTestClient(t))
	ctx, c := counted()
	created, err := repo.Create(ctx, "bob", row("follow_alice", TypeFollow, "alice", t0))
	mustNoErr(t, err)
	if !created {
		t.Fatal("first create must report created")
	}
	budgettest.Assert(t, "Create", c, budgettest.Budget{Writes: 1})

	ctx, c = counted()
	created, err = repo.Create(ctx, "bob", row("follow_alice", TypeFollow, "alice", t0.Add(time.Hour)))
	mustNoErr(t, err)
	if created {
		t.Fatal("a redelivery must not report created (it would send a second push)")
	}
	budgettest.Assert(t, "Create replay", c, budgettest.Budget{Reads: 1})
	if c.Writes() != 0 {
		t.Errorf("replay writes = %d", c.Writes())
	}
	// The original row (and its expireAt) is untouched by the replay.
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 10})
	mustNoErr(t, err)
	if len(rows) != 1 || !rows[0].CreatedAt.Equal(t0) {
		t.Fatalf("rows = %+v", rows)
	}
}

func TestIntegration_CreateSetsExpireAtForTheTTLPolicy(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	_, err := repo.Create(context.Background(), "bob", row("follow_alice", TypeFollow, "alice", t0))
	mustNoErr(t, err)
	snap, err := client.Doc("users/bob/notifications/follow_alice").Get(context.Background())
	mustNoErr(t, err)
	exp, err := snap.DataAt("expireAt")
	mustNoErr(t, err)
	if got := exp.(time.Time); !got.Equal(t0.Add(TTL)) {
		t.Errorf("expireAt = %v, want createdAt + 90 d", got)
	}
}

func TestIntegration_AddActorFoldsAndMovesCreatedAt(t *testing.T) {
	repo := NewFirestoreRepo(newTestClient(t))
	_, err := repo.Create(context.Background(), "bob", row("like_x", TypeLike, "alice", t0))
	mustNoErr(t, err)
	ctx, c := counted()
	mustNoErr(t, repo.AddActor(ctx, "bob", "like_x", Actor{UserID: "carol", Handle: "h_carol"}, t0.Add(time.Minute)))
	budgettest.Assert(t, "AddActor", c, budgettest.Budget{Reads: 1, Writes: 1})
	// The same actor again (a redelivery) is write-free: 1 read, 0 writes, createdAt untouched.
	ctx, c = counted()
	mustNoErr(t, repo.AddActor(ctx, "bob", "like_x", Actor{UserID: "carol", Handle: "h_carol"}, t0.Add(2*time.Minute)))
	budgettest.Assert(t, "AddActor replay", c, budgettest.Budget{Reads: 1})
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 5})
	mustNoErr(t, err)
	if len(rows) != 1 || len(rows[0].ActorIDs) != 2 || rows[0].ActorCount != 2 || rows[0].Actor.UserID != "carol" || !rows[0].CreatedAt.Equal(t0.Add(time.Minute)) {
		t.Fatalf("rows = %+v", rows)
	}
	// A row that expired in between is not an error.
	mustNoErr(t, repo.AddActor(context.Background(), "bob", "gone", Actor{UserID: "carol"}, t0))
}

// TestIntegration_AddActorCapsTheHotDoc: a viral post's collapsed row keeps the last MaxActorIDs actors and a
// running count (ADR-0017 D4 amendment), so the document does not grow without bound.
func TestIntegration_AddActorCapsTheHotDoc(t *testing.T) {
	repo := NewFirestoreRepo(newTestClient(t))
	_, err := repo.Create(context.Background(), "bob", row("like_hot", TypeLike, "a000", t0))
	mustNoErr(t, err)
	total := MaxActorIDs + 10
	for i := 1; i < total; i++ {
		u := fmt.Sprintf("a%03d", i)
		ctx, c := counted()
		mustNoErr(t, repo.AddActor(ctx, "bob", "like_hot", Actor{UserID: u, Handle: "h_" + u}, t0.Add(time.Duration(i)*time.Second)))
		budgettest.Assert(t, "AddActor "+u, c, budgettest.Budget{Reads: 1, Writes: 1})
	}
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 5})
	mustNoErr(t, err)
	if len(rows) != 1 {
		t.Fatalf("rows = %+v", rows)
	}
	r := rows[0]
	if len(r.ActorIDs) != MaxActorIDs || r.ActorCount != total {
		t.Fatalf("actorIds = %d (want %d), actorCount = %d (want %d)", len(r.ActorIDs), MaxActorIDs, r.ActorCount, total)
	}
	if want := fmt.Sprintf("a%03d", total-1); r.ActorIDs[len(r.ActorIDs)-1] != want || r.Actor.UserID != want {
		t.Errorf("newest actor = %q / %q, want %q", r.ActorIDs[len(r.ActorIDs)-1], r.Actor.UserID, want)
	}
	if r.ActorIDs[0] != fmt.Sprintf("a%03d", total-MaxActorIDs) {
		t.Errorf("oldest kept actor = %q", r.ActorIDs[0])
	}
}

func TestIntegration_ListOrderBoundsAndBudget(t *testing.T) {
	repo := NewFirestoreRepo(newTestClient(t))
	for i := 0; i < 5; i++ {
		_, err := repo.Create(context.Background(), "bob", row(fmt.Sprintf("follow_u%d", i), TypeFollow, fmt.Sprintf("u%d", i), t0.Add(time.Duration(i)*time.Minute)))
		mustNoErr(t, err)
	}
	ctx, c := counted()
	page, err := repo.List(ctx, "bob", ListQuery{Limit: 2})
	mustNoErr(t, err)
	budgettest.Assert(t, "List page of 2", c, budgettest.Budget{Reads: 2})
	if got := idsOf(page); strings.Join(got, ",") != "follow_u4,follow_u3" {
		t.Fatalf("page = %v", got)
	}
	before := cursor.Cursor{CreatedAt: page[1].CreatedAt, DocID: page[1].ID}
	ctx, c = counted()
	older, err := repo.List(ctx, "bob", ListQuery{Limit: 10, Before: &before})
	mustNoErr(t, err)
	budgettest.Assert(t, "List older", c, budgettest.Budget{Reads: 3})
	if got := idsOf(older); strings.Join(got, ",") != "follow_u2,follow_u1,follow_u0" {
		t.Fatalf("older = %v", got)
	}
	after := cursor.Cursor{CreatedAt: t0.Add(2 * time.Minute), DocID: "follow_u2"}
	ctx, c = counted()
	newer, err := repo.List(ctx, "bob", ListQuery{Limit: 10, After: &after})
	mustNoErr(t, err)
	budgettest.Assert(t, "List since", c, budgettest.Budget{Reads: 2})
	if got := idsOf(newer); strings.Join(got, ",") != "follow_u4,follow_u3" {
		t.Fatalf("newer = %v", got)
	}
	// A window (gap fill): strictly between.
	ctx, c = counted()
	win, err := repo.List(ctx, "bob", ListQuery{Limit: 10, After: &after, Before: &cursor.Cursor{CreatedAt: t0.Add(4 * time.Minute), DocID: "follow_u4"}})
	mustNoErr(t, err)
	if got := idsOf(win); strings.Join(got, ",") != "follow_u3" {
		t.Fatalf("window = %v", got)
	}
	// An empty result still bills one read.
	ctx, c = counted()
	none, err := repo.List(ctx, "nobody", ListQuery{Limit: 20})
	mustNoErr(t, err)
	if len(none) != 0 || c.Reads() != 1 {
		t.Errorf("empty list: %d rows, %d reads", len(none), c.Reads())
	}
	_ = ctx
}

func register(t *testing.T, repo *FirestoreRepo, uid, deviceID, token string, now time.Time) *budget.Counter {
	t.Helper()
	ctx, c := counted()
	mustNoErr(t, repo.RegisterDevice(ctx, uid, Device{ID: deviceID, Token: token, Platform: PlatformAndroid}, now))
	return c
}

func TestIntegration_RegisterDevice_BudgetsRefreshAndTokenRotation(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)

	// New device: device doc + token index, 3 reads (device, index, the cap list), 2 writes.
	c := register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-1", t0)
	budgettest.Assert(t, "RegisterDevice new", c, budgettest.Budget{Reads: 3, Writes: 2})
	if !docExists(t, client, "users/alice/devices/device-aaaaaaaaaaaa") || !docExists(t, client, "deviceTokens/"+TokenKey("tok-1")) {
		t.Fatal("device or token index missing")
	}

	// The same registration inside the refresh interval writes nothing.
	c = register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-1", t0.Add(time.Hour))
	budgettest.Assert(t, "RegisterDevice fresh", c, budgettest.Budget{Reads: 2})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("fresh registration wrote: %d writes %d deletes", c.Writes(), c.Deletes())
	}

	// After the interval it refreshes updatedAt (2 writes) and keeps createdAt.
	c = register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-1", t0.Add(25*time.Hour))
	budgettest.Assert(t, "RegisterDevice refresh", c, budgettest.Budget{Reads: 2, Writes: 2})
	devs, err := repo.Devices(context.Background(), "alice", 5)
	mustNoErr(t, err)
	if len(devs) != 1 || !devs[0].CreatedAt.Equal(t0) || !devs[0].UpdatedAt.Equal(t0.Add(25*time.Hour)) {
		t.Fatalf("devices = %+v", devs)
	}

	// Token rotation: the old index doc is deleted, the new one written.
	c = register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-2", t0.Add(26*time.Hour))
	budgettest.Assert(t, "RegisterDevice rotate", c, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})
	if docExists(t, client, "deviceTokens/"+TokenKey("tok-1")) || !docExists(t, client, "deviceTokens/"+TokenKey("tok-2")) {
		t.Error("token index not rotated")
	}
	if countDocs(t, client, "deviceTokens") != 1 {
		t.Errorf("deviceTokens = %d", countDocs(t, client, "deviceTokens"))
	}
}

func TestIntegration_RegisterDevice_CapEvictsLeastRecentlyUpdated(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	for i := 0; i < MaxDevicesPerUser; i++ {
		register(t, repo, "alice", fmt.Sprintf("device-%012d", i), fmt.Sprintf("tok-%d", i), t0.Add(time.Duration(i)*time.Minute))
	}
	if n := countDocs(t, client, "users/alice/devices"); n != MaxDevicesPerUser {
		t.Fatalf("devices = %d", n)
	}
	// device-0 refreshes: it is now the most recently updated, so device-1 is the one evicted.
	register(t, repo, "alice", "device-000000000000", "tok-0", t0.Add(30*time.Hour))
	c := register(t, repo, "alice", "device-new000000000", "tok-new", t0.Add(31*time.Hour))
	budgettest.Assert(t, "RegisterDevice sixth", c, budgettest.Budget{Reads: 9, Writes: 2, Deletes: 3})
	if n := countDocs(t, client, "users/alice/devices"); n != MaxDevicesPerUser {
		t.Fatalf("devices after the sixth = %d, want %d", n, MaxDevicesPerUser)
	}
	if docExists(t, client, "users/alice/devices/device-000000000001") || docExists(t, client, "deviceTokens/"+TokenKey("tok-1")) {
		t.Error("the least recently updated device (and its token index) must be evicted")
	}
	for _, id := range []string{"device-000000000000", "device-new000000000"} {
		if !docExists(t, client, "users/alice/devices/"+id) {
			t.Errorf("%s was evicted", id)
		}
	}
}

// TestIntegration_RegisterDevice_EvictionKeepsATokenIndexAnotherAccountOwns: the evicted device's index entry is
// deleted only when it still names that device.
func TestIntegration_RegisterDevice_EvictionKeepsATokenIndexAnotherAccountOwns(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	for i := 0; i < MaxDevicesPerUser; i++ {
		register(t, repo, "alice", fmt.Sprintf("device-%012d", i), fmt.Sprintf("tok-%d", i), t0.Add(time.Duration(i)*time.Minute))
	}
	// device-0 is the eviction candidate; its token index now belongs to bob's device.
	_, err := client.Doc("deviceTokens/"+TokenKey("tok-0")).Set(context.Background(), map[string]any{"uid": "bob", "deviceId": "device-bbbbbbbbbbbb", "updatedAt": t0})
	mustNoErr(t, err)
	register(t, repo, "alice", "device-new000000000", "tok-new", t0.Add(time.Hour))
	if docExists(t, client, "users/alice/devices/device-000000000000") {
		t.Fatal("the least recently updated device must still be evicted")
	}
	snap, err := client.Doc("deviceTokens/" + TokenKey("tok-0")).Get(context.Background())
	mustNoErr(t, err)
	if uid, _ := snap.DataAt("uid"); uid != "bob" {
		t.Errorf("bob's token index was deleted or rewritten by alice's eviction (uid = %v)", uid)
	}
}

func TestIntegration_RegisterDevice_TokenMovesToTheNewAccount(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "shared-handset-token", t0)
	c := register(t, repo, "bob", "device-bbbbbbbbbbbb", "shared-handset-token", t0.Add(time.Hour))
	budgettest.Assert(t, "RegisterDevice takeover", c, budgettest.Budget{Reads: 8, Writes: 2, Deletes: 3})
	if docExists(t, client, "users/alice/devices/device-aaaaaaaaaaaa") {
		t.Fatal("alice keeps receiving bob's pushes: her device doc must be removed")
	}
	snap, err := client.Doc("deviceTokens/" + TokenKey("shared-handset-token")).Get(context.Background())
	mustNoErr(t, err)
	if uid, _ := snap.DataAt("uid"); uid != "bob" {
		t.Errorf("token index uid = %v", uid)
	}
	devs, err := repo.Devices(context.Background(), "alice", 5)
	mustNoErr(t, err)
	if len(devs) != 0 {
		t.Errorf("alice devices = %+v", devs)
	}
}

func TestIntegration_RemoveDevice(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-a", t0)

	// A prune racing a token refresh must keep the refreshed device.
	ctx, c := counted()
	mustNoErr(t, repo.RemoveDevice(ctx, "alice", "device-aaaaaaaaaaaa", "stale-token"))
	budgettest.Assert(t, "RemoveDevice stale", c, budgettest.Budget{Reads: 1})
	if !docExists(t, client, "users/alice/devices/device-aaaaaaaaaaaa") {
		t.Fatal("a device with a different token was removed")
	}

	ctx, c = counted()
	mustNoErr(t, repo.RemoveDevice(ctx, "alice", "device-aaaaaaaaaaaa", ""))
	budgettest.Assert(t, "RemoveDevice", c, budgettest.Budget{Reads: 2, Deletes: 2})
	if docExists(t, client, "users/alice/devices/device-aaaaaaaaaaaa") || docExists(t, client, "deviceTokens/"+TokenKey("tok-a")) {
		t.Error("device or token index still present")
	}

	ctx, c = counted()
	mustNoErr(t, repo.RemoveDevice(ctx, "alice", "device-aaaaaaaaaaaa", ""))
	budgettest.Assert(t, "RemoveDevice unknown", c, budgettest.Budget{Reads: 1})
}

func TestIntegration_RemoveDevice_DoesNotDeleteAnotherOwnersIndex(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-a", t0)
	// Simulate a stale device doc whose token index now belongs to bob.
	_, err := client.Doc("deviceTokens/"+TokenKey("tok-a")).Set(context.Background(), map[string]any{"uid": "bob", "deviceId": "device-bbbbbbbbbbbb", "updatedAt": t0})
	mustNoErr(t, err)
	mustNoErr(t, repo.RemoveDevice(context.Background(), "alice", "device-aaaaaaaaaaaa", ""))
	if !docExists(t, client, "deviceTokens/"+TokenKey("tok-a")) {
		t.Error("alice's removal deleted bob's token index")
	}
}

func TestIntegration_PurgeUserIsResumableAndLeavesOthersAlone(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client).WithDirectory(newDirectory("dave"))
	ctx := context.Background()
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-a1", t0)
	register(t, repo, "alice", "device-aaaaaaaaaaab", "tok-a2", t0)
	register(t, repo, "bob", "device-bbbbbbbbbbbb", "tok-b", t0)
	for i := 0; i < 3; i++ { // alice's own notifications
		_, err := repo.Create(ctx, "alice", row(fmt.Sprintf("follow_u%d", i), TypeFollow, fmt.Sprintf("u%d", i), t0))
		mustNoErr(t, err)
	}
	// Rows in bob's and carol's lists about alice (follow, and a like collapsed with another actor), plus one not about her.
	_, err := repo.Create(ctx, "bob", row("follow_alice", TypeFollow, "alice", t0))
	mustNoErr(t, err)
	_, err = repo.Create(ctx, "carol", row("like_x", TypeLike, "dave", t0))
	mustNoErr(t, err)
	mustNoErr(t, repo.AddActor(ctx, "carol", "like_x", Actor{UserID: "alice"}, t0))
	_, err = repo.Create(ctx, "bob", row("follow_dave", TypeFollow, "dave", t0))
	mustNoErr(t, err)

	var cp Checkpoint
	var steps int
	for done := false; !done; steps++ {
		if steps > 10 {
			t.Fatal("purge did not finish")
		}
		pctx, c := counted()
		cp, done, err = repo.PurgeUser(pctx, "alice", cp)
		mustNoErr(t, err)
		budgettest.Assert(t, fmt.Sprintf("PurgeUser step %d", steps), c, budgettest.Budget{Reads: 600, Writes: 1, Deletes: 600})
	}
	if countDocs(t, client, "users/alice/devices") != 0 || countDocs(t, client, "users/alice/notifications") != 0 {
		t.Error("alice's own data remains")
	}
	for _, p := range []string{"deviceTokens/" + TokenKey("tok-a1"), "deviceTokens/" + TokenKey("tok-a2"), "users/bob/notifications/follow_alice"} {
		if docExists(t, client, p) {
			t.Errorf("%s survived the purge", p)
		}
	}
	// carol's collapsed like row also named dave: alice is removed from it and the row is repointed at dave.
	like, err := client.Doc("users/carol/notifications/like_x").Get(ctx)
	mustNoErr(t, err)
	var ld notificationDoc
	mustNoErr(t, like.DataTo(&ld))
	if len(ld.ActorIDs) != 1 || ld.ActorIDs[0] != "dave" || ld.Actor.UserID != "dave" || ld.Actor.Handle != "h_dave" || ld.ActorCount != 1 {
		t.Errorf("carol's like row after the purge = %+v", ld)
	}
	for _, p := range []string{"deviceTokens/" + TokenKey("tok-b"), "users/bob/devices/device-bbbbbbbbbbbb", "users/bob/notifications/follow_dave"} {
		if !docExists(t, client, p) {
			t.Errorf("%s was deleted by alice's purge", p)
		}
	}
	if cp.Deleted != 2+3+2 {
		t.Errorf("deleted = %d, want 7", cp.Deleted)
	}
	// A second purge must have nothing left to do (alice is in no actorIds, so the step-2 query is empty).
	// Running it again is a clean no-op.
	_, done, err := repo.PurgeUser(ctx, "alice", Checkpoint{})
	mustNoErr(t, err)
	_ = done
}

func TestIntegration_ExportCarriesNoTokens(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "SECRET-FCM-TOKEN", t0)
	_, err := repo.Create(ctx, "alice", row("follow_bob", TypeFollow, "bob", t0))
	mustNoErr(t, err)
	_, err = repo.Create(ctx, "alice", row("mention_"+postA, TypeMention, "carol", t0.Add(time.Minute)))
	mustNoErr(t, err)

	var buf bytes.Buffer
	ectx, c := counted()
	mustNoErr(t, repo.ExportUser(ectx, "alice", &buf))
	budgettest.Assert(t, "ExportUser", c, budgettest.Budget{Reads: 4})
	if strings.Contains(buf.String(), "SECRET-FCM-TOKEN") || strings.Contains(buf.String(), TokenKey("SECRET-FCM-TOKEN")) {
		t.Fatalf("export leaks a device token: %s", buf.String())
	}
	var out struct {
		UserID        string
		Devices       []map[string]any
		Notifications []map[string]any
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("not valid JSON: %v\n%s", err, buf.String())
	}
	if out.UserID != "alice" || len(out.Devices) != 1 || len(out.Notifications) != 2 {
		t.Errorf("export = %+v", out)
	}
	// N-3: row ids embed other users' uids (follow_{actorUid}); the export carries no id at all.
	for _, n := range out.Notifications {
		if _, has := n["id"]; has {
			t.Errorf("export row carries an id: %v", n)
		}
	}
	if strings.Contains(buf.String(), "follow_bob") {
		t.Errorf("export leaks a notification id: %s", buf.String())
	}
	// Empty account: still valid JSON.
	buf.Reset()
	mustNoErr(t, repo.ExportUser(ctx, "nobody", &buf))
	if !json.Valid(buf.Bytes()) {
		t.Errorf("empty export is not JSON: %s", buf.String())
	}
}

// TestIntegration_FanoutBudgetsAndIdempotency runs the handler's Deliver against the real repo: the per-recipient
// Firestore cost documented in ADR-0017 (1 write per new row, 1 read for a replay, devices <= 5 reads).
func TestIntegration_FanoutBudgetsAndIdempotency(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	rig := newRig(t, nil)
	rig.f.d.Repo = repo
	register(t, repo, "bob", "device-bbbbbbbbbbbb", "tok-b1", t0)
	register(t, repo, "bob", "device-bbbbbbbbbbbc", "tok-b2", t0)
	ev := Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}

	ctx, c := counted()
	out, err := rig.f.Deliver(ctx, ev)
	mustNoErr(t, err)
	if out.Created != 1 || out.Pushed != 2 {
		t.Fatalf("outcome = %+v", out)
	}
	// 2 fresh profile reads (actor, recipient) + 2 device rows.
	budgettest.Assert(t, "fan-out follow", c, budgettest.Budget{Reads: 4, Writes: 1})

	ctx, c = counted()
	out, err = rig.f.Deliver(ctx, ev)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Pushed != 0 || len(rig.sender.sent) != 2 {
		t.Fatalf("redelivery outcome = %+v, pushes = %d", out, len(rig.sender.sent))
	}
	budgettest.Assert(t, "fan-out redelivery", c, budgettest.Budget{Reads: 3})
	if c.Writes() != 0 {
		t.Errorf("redelivery wrote %d docs", c.Writes())
	}

	// Collapsed like: first creates (1 write) and pushes, the next folds in (1 read + 1 write) with no push.
	rig.dir = newDirectory("alice", "bob", "carol")
	rig.f.d.Directory = rig.dir
	like := func(actor string) (*budget.Counter, Outcome) {
		lctx, lc := counted()
		o, err := rig.f.Deliver(lctx, Event{Type: TypeLike, ActorID: actor, RecipientIDs: []string{"bob"}, PostID: postB, At: t0})
		mustNoErr(t, err)
		return lc, o
	}
	lc, o := like("alice")
	budgettest.Assert(t, "fan-out first like", lc, budgettest.Budget{Reads: 4, Writes: 1})
	if o.Created != 1 {
		t.Fatalf("first like = %+v", o)
	}
	before := len(rig.sender.sent)
	lc, o = like("carol")
	// 2 fresh profile reads + failed Create + fold check.
	budgettest.Assert(t, "fan-out collapsed like", lc, budgettest.Budget{Reads: 4, Writes: 1})
	if o.Duplicate != 1 || len(rig.sender.sent) != before {
		t.Fatalf("collapsed like = %+v, pushes %d -> %d", o, before, len(rig.sender.sent))
	}
	// Redelivering carol's like writes nothing: 2 fresh profile reads, 1 for the failed Create, 1 for the fold.
	lc, o = like("carol")
	budgettest.Assert(t, "fan-out like redelivery", lc, budgettest.Budget{Reads: 4})
	if lc.Writes() != 0 || o.Duplicate != 1 {
		t.Errorf("like redelivery wrote %d docs, outcome %+v", lc.Writes(), o)
	}
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 10})
	mustNoErr(t, err)
	for _, n := range rows {
		if n.Type == TypeLike && len(n.ActorIDs) != 2 {
			t.Errorf("like row actors = %v", n.ActorIDs)
		}
	}
}

// racingDirectory runs hook once on the first GetProfiles, which purge step 2 calls between its query and its
// batch commit: a deterministic "concurrent write after the query".
type racingDirectory struct {
	*fakeDirectory
	hook func()
	// every re-arms the hook on each call (a row that keeps changing under the purge).
	every bool
}

func (d *racingDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	if d.hook != nil {
		h := d.hook
		if !d.every {
			d.hook = nil
		}
		h()
	}
	return d.fakeDirectory.GetProfiles(ctx, uids)
}

// TestIntegration_PurgeStep2DoesNotClobberAConcurrentFold: a like folded in between the purge's query and its
// commit must not be overwritten by the stale snapshot (precondition on the update time); the batch fails and the
// inline retry applies cleanly.
func TestIntegration_PurgeStep2DoesNotClobberAConcurrentFold(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	plain := NewFirestoreRepo(client)
	_, err := plain.Create(ctx, "carol", row("like_x", TypeLike, "dave", t0))
	mustNoErr(t, err)
	mustNoErr(t, plain.AddActor(ctx, "carol", "like_x", Actor{UserID: "alice", Handle: "h_alice"}, t0.Add(time.Second)))

	dir := &racingDirectory{fakeDirectory: newDirectory("dave", "erin")}
	dir.hook = func() {
		mustNoErr(t, plain.AddActor(ctx, "carol", "like_x", Actor{UserID: "erin", Handle: "h_erin"}, t0.Add(2*time.Second)))
	}
	repo := NewFirestoreRepo(client).WithDirectory(dir)
	runCtx, counter := budget.WithCounter(ctx)
	_, done, err := repo.PurgeUser(runCtx, "alice", Checkpoint{Step: 2})
	mustNoErr(t, err)
	if !done {
		t.Error("the inline retry must finish the step")
	}
	// Only the retry's batch commits: 1 repointed row, the failed attempt counted nothing.
	if counter.Writes() != 1 || counter.Deletes() != 0 {
		t.Errorf("counted writes=%d deletes=%d, want 1/0 (one repointed row)", counter.Writes(), counter.Deletes())
	}
	snap, err := client.Doc("users/carol/notifications/like_x").Get(ctx)
	mustNoErr(t, err)
	var d notificationDoc
	mustNoErr(t, snap.DataTo(&d))
	if strings.Join(d.ActorIDs, ",") != "dave,erin" || d.Actor.UserID != "erin" || d.ActorCount != 2 {
		t.Errorf("the concurrent fold was clobbered or alice not removed: %+v", d)
	}
}

// TestIntegration_PurgeStep2PersistentRaceEndsInAnError: a row that changes between every query and commit must
// not loop forever as a no-progress success; after the one inline retry the step errors so the job's
// step-error budget and backoff apply.
func TestIntegration_PurgeStep2PersistentRaceEndsInAnError(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	plain := NewFirestoreRepo(client)
	_, err := plain.Create(ctx, "carol", row("like_x", TypeLike, "dave", t0))
	mustNoErr(t, err)
	mustNoErr(t, plain.AddActor(ctx, "carol", "like_x", Actor{UserID: "alice", Handle: "h_alice"}, t0.Add(time.Second)))

	calls := 0
	dir := &racingDirectory{fakeDirectory: newDirectory("dave", "erin"), every: true}
	dir.hook = func() {
		calls++
		// Touch the row without changing who is displayed, so every attempt reaches GetProfiles again.
		_, err := client.Doc("users/carol/notifications/like_x").Update(ctx, []firestore.Update{{Path: "bumped", Value: calls}})
		mustNoErr(t, err)
	}
	repo := NewFirestoreRepo(client).WithDirectory(dir)
	cctx, counter := budget.WithCounter(ctx)
	cp, done, err := repo.PurgeUser(cctx, "alice", Checkpoint{Step: 2})
	if err == nil || done {
		t.Fatalf("persistent race: cp=%+v done=%v err=%v, want an error", cp, done, err)
	}
	if calls != 2 {
		t.Errorf("step ran %d times, want exactly 2 (one inline retry)", calls)
	}
	if counter.Writes() != 0 || counter.Deletes() != 0 {
		t.Errorf("failed batches counted writes=%d deletes=%d, want 0/0", counter.Writes(), counter.Deletes())
	}
}

// TestIntegration_FollowRequestTypesBudgetsAndErasure (W3-31, ADR-0025 D10): a request and an accept cost about 2
// reads per recipient and 1 write, a re-request is write-free, a suppressed protected-actor row costs 0 writes, and
// the actorIds query of the ADR-0017 D10 eraser finds the request row when the requester is deleted.
func TestIntegration_FollowRequestTypesBudgetsAndErasure(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client).WithDirectory(newDirectory("dave"))
	rig := newRig(t, nil)
	rig.f.d.Repo = repo
	rig.f.d.Audience = AudienceFunc(func(context.Context, string, string, bool) (bool, error) { return false, nil })
	register(t, repo, "bob", "device-bbbbbbbbbbbb", "tok-b1", t0)

	req := Event{Type: TypeFollowRequest, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}
	ctx, c := counted()
	out, err := rig.f.Deliver(ctx, req)
	mustNoErr(t, err)
	if out.Created != 1 || out.Pushed != 1 {
		t.Fatalf("outcome = %+v", out)
	}
	// 2 fresh profile reads (actor, recipient) + 1 device row; 1 write.
	budgettest.Assert(t, "fan-out follow_request", c, budgettest.Budget{Reads: 3, Writes: 1})

	// A withdraw and a new request inside the TTL: the row is still there, so 0 writes and no second push.
	ctx, c = counted()
	out, err = rig.f.Deliver(ctx, req)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Pushed != 0 || c.Writes() != 0 {
		t.Fatalf("re-request outcome = %+v writes = %d", out, c.Writes())
	}
	budgettest.Assert(t, "fan-out re-request", c, budgettest.Budget{Reads: 3})

	ctx, c = counted()
	_, err = rig.f.Deliver(ctx, Event{Type: TypeFollowAccepted, ActorID: "bob", RecipientIDs: []string{"alice"}, At: t0})
	mustNoErr(t, err)
	// 2 profile reads + the requester's device query (an empty query bills 1); 1 write.
	budgettest.Assert(t, "fan-out follow_accepted", c, budgettest.Budget{Reads: 3, Writes: 1})

	// Suppression: a post-bearing event from an actor the recipient may not see writes nothing.
	ctx, c = counted()
	out, err = rig.f.Deliver(ctx, Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: postA, At: t0})
	mustNoErr(t, err)
	if out.SuppressedProtected != 1 || c.Writes() != 0 {
		t.Fatalf("suppressed outcome = %+v writes = %d", out, c.Writes())
	}
	budgettest.Assert(t, "fan-out suppressed protected", c, budgettest.Budget{Reads: 2})

	// The eraser finds the request row through actorIds when the requester is deleted.
	var cp Checkpoint
	for done := false; !done; {
		cp, done, err = repo.PurgeUser(context.Background(), "alice", cp)
		mustNoErr(t, err)
	}
	if docExists(t, client, "users/bob/notifications/follow_request_alice") {
		t.Error("the follow_request row survived the requester's purge")
	}
	if docExists(t, client, "users/alice/notifications/follow_accepted_bob") {
		t.Error("alice's own follow_accepted row survived her purge")
	}
}
