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
	budgettest.Assert(t, "AddActor", c, budgettest.Budget{Writes: 1})
	mustNoErr(t, repo.AddActor(context.Background(), "bob", "like_x", Actor{UserID: "carol", Handle: "h_carol"}, t0.Add(2*time.Minute)))
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 5})
	mustNoErr(t, err)
	if len(rows) != 1 || len(rows[0].ActorIDs) != 2 || rows[0].Actor.UserID != "carol" || !rows[0].CreatedAt.Equal(t0.Add(2*time.Minute)) {
		t.Fatalf("rows = %+v", rows)
	}
	// A row that expired in between is not an error.
	mustNoErr(t, repo.AddActor(context.Background(), "bob", "gone", Actor{UserID: "carol"}, t0))
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
	budgettest.Assert(t, "RegisterDevice sixth", c, budgettest.Budget{Reads: 8, Writes: 2, Deletes: 3})
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
	repo := NewFirestoreRepo(client)
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
		budgettest.Assert(t, fmt.Sprintf("PurgeUser step %d", steps), c, budgettest.Budget{Reads: 600, Writes: 0, Deletes: 600})
	}
	if countDocs(t, client, "users/alice/devices") != 0 || countDocs(t, client, "users/alice/notifications") != 0 {
		t.Error("alice's own data remains")
	}
	for _, p := range []string{"deviceTokens/" + TokenKey("tok-a1"), "deviceTokens/" + TokenKey("tok-a2"), "users/bob/notifications/follow_alice", "users/carol/notifications/like_x"} {
		if docExists(t, client, p) {
			t.Errorf("%s survived the purge", p)
		}
	}
	for _, p := range []string{"deviceTokens/" + TokenKey("tok-b"), "users/bob/devices/device-bbbbbbbbbbbb", "users/bob/notifications/follow_dave"} {
		if !docExists(t, client, p) {
			t.Errorf("%s was deleted by alice's purge", p)
		}
	}
	if cp.Deleted != 2+3+2 {
		t.Errorf("deleted = %d, want 7", cp.Deleted)
	}
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
	if out.UserID != "alice" || len(out.Devices) != 1 || len(out.Notifications) != 2 || out.Notifications[0]["id"] != "mention_"+postA {
		t.Errorf("export = %+v", out)
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
	budgettest.Assert(t, "fan-out follow", c, budgettest.Budget{Reads: 2, Writes: 1})

	ctx, c = counted()
	out, err = rig.f.Deliver(ctx, ev)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Pushed != 0 || len(rig.sender.sent) != 2 {
		t.Fatalf("redelivery outcome = %+v, pushes = %d", out, len(rig.sender.sent))
	}
	budgettest.Assert(t, "fan-out redelivery", c, budgettest.Budget{Reads: 1})
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
	budgettest.Assert(t, "fan-out first like", lc, budgettest.Budget{Reads: 2, Writes: 1})
	if o.Created != 1 {
		t.Fatalf("first like = %+v", o)
	}
	before := len(rig.sender.sent)
	lc, o = like("carol")
	budgettest.Assert(t, "fan-out collapsed like", lc, budgettest.Budget{Reads: 1, Writes: 1})
	if o.Duplicate != 1 || len(rig.sender.sent) != before {
		t.Fatalf("collapsed like = %+v, pushes %d -> %d", o, before, len(rig.sender.sent))
	}
	rows, err := repo.List(context.Background(), "bob", ListQuery{Limit: 10})
	mustNoErr(t, err)
	for _, n := range rows {
		if n.Type == TypeLike && len(n.ActorIDs) != 2 {
			t.Errorf("like row actors = %v", n.ActorIDs)
		}
	}
}
