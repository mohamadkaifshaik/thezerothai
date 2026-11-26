//go:build integration

package notifications

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// DropPushRegistrations on the emulator (lane D PR 5): every device of the account and the token entries that still name
// it are deleted, a token another account took over is kept, the push preferences and other accounts are untouched, a
// second call is 0, and more devices than one page are all dropped.
func TestIntegration_DropPushRegistrations(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()

	register(t, repo, "alice", "device-alice-000001", "tok-a1", t0)
	register(t, repo, "alice", "device-alice-000002", "tok-a2", t0)
	register(t, repo, "alice", "device-alice-000003", "tok-ax", t0)
	register(t, repo, "bob", "device-bob-00000001", "tok-b1", t0)
	// tok-ax's entry now names bob (a takeover the device document has not caught up with): it is bob's and stays.
	if _, err := client.Doc("deviceTokens/"+TokenKey("tok-ax")).Set(ctx, tokenIndexDoc{UID: "bob", DeviceID: "device-bob-00000002", UpdatedAt: t0}); err != nil {
		t.Fatal(err)
	}
	prefs := Prefs{Plans: false, MentionsReplies: true, LikesReposts: false, Followers: true, Messages: true}
	if _, err := repo.SetPrefs(ctx, "alice", prefs, t0); err != nil {
		t.Fatal(err)
	}

	n, err := repo.DropPushRegistrations(ctx, "alice")
	if err != nil || n != 3 {
		t.Fatalf("drop = %d, %v; want 3, nil", n, err)
	}
	if got := countDocs(t, client, "users/alice/devices"); got != 0 {
		t.Errorf("alice has %d devices left, want 0", got)
	}
	for _, tok := range []string{"tok-a1", "tok-a2"} {
		if docExists(t, client, "deviceTokens/"+TokenKey(tok)) {
			t.Errorf("alice's token entry %s is still there", tok)
		}
	}
	if !docExists(t, client, "deviceTokens/"+TokenKey("tok-ax")) {
		t.Error("the entry another account took over was deleted")
	}
	if !docExists(t, client, "users/bob/devices/device-bob-00000001") || !docExists(t, client, "deviceTokens/"+TokenKey("tok-b1")) {
		t.Error("bob's registration was touched")
	}
	if got, err := repo.GetPrefs(ctx, "alice"); err != nil || got != prefs {
		t.Errorf("prefs = %+v, %v; want them kept", got, err)
	}

	// Idempotent: nothing left is 0, nil.
	if n, err := repo.DropPushRegistrations(ctx, "alice"); err != nil || n != 0 {
		t.Fatalf("second drop = %d, %v; want 0, nil", n, err)
	}

	// More than one page (only possible from data written outside RegisterDevice's cap): every page is dropped.
	const many = dropPage + 7
	b := client.BulkWriter(ctx)
	for i := range many {
		if _, err := b.Set(client.Doc(fmt.Sprintf("users/carol/devices/device-carol-%06d", i)), deviceDoc{Platform: "android", CreatedAt: t0, UpdatedAt: t0.Add(time.Duration(i))}); err != nil {
			t.Fatal(err)
		}
	}
	b.End()
	if n, err := repo.DropPushRegistrations(ctx, "carol"); err != nil || n != many {
		t.Fatalf("paged drop = %d, %v; want %d", n, err, many)
	}
	if got := countDocs(t, client, "users/carol/devices"); got != 0 {
		t.Errorf("carol has %d devices left, want 0", got)
	}
}
