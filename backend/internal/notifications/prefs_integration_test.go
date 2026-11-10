//go:build integration

package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"
)

// Emulator tests of the F6 push preferences over the real FirestoreRepo.

func TestIntegration_PrefsStoreAndRoundTrip(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()

	if p, err := repo.GetPrefs(ctx, "alice"); err != nil || p != DefaultPrefs() {
		t.Fatalf("no document: %+v, %v, want the defaults", p, err)
	}
	// Defaults over a missing document write nothing.
	if changed, err := repo.SetPrefs(ctx, "alice", DefaultPrefs(), t0); err != nil || changed || docExists(t, client, "users/alice/settings/notifications") {
		t.Fatalf("defaults over nothing: changed=%v err=%v", changed, err)
	}
	want := Prefs{Plans: true, MentionsReplies: false, LikesReposts: false, Followers: true, Messages: true}
	if changed, err := repo.SetPrefs(ctx, "alice", want, t0); err != nil || !changed {
		t.Fatalf("set: changed=%v err=%v", changed, err)
	}
	snap, err := client.Doc("users/alice/settings/notifications").Get(ctx)
	mustNoErr(t, err)
	if off, _ := snap.DataAt("pushOff"); len(off.([]any)) != 2 {
		t.Errorf("stored pushOff = %v, want the two switched-off groups", off)
	}
	if p, err := repo.GetPrefs(ctx, "alice"); err != nil || p != want {
		t.Fatalf("get = %+v, %v", p, err)
	}
	// Replay: equal value writes nothing (updateTime unchanged).
	snap2, _ := client.Doc("users/alice/settings/notifications").Get(ctx)
	if changed, err := repo.SetPrefs(ctx, "alice", want, t0.Add(1)); err != nil || changed {
		t.Fatalf("replay: changed=%v err=%v", changed, err)
	}
	snap3, _ := client.Doc("users/alice/settings/notifications").Get(ctx)
	if !snap3.UpdateTime.Equal(snap2.UpdateTime) {
		t.Error("a replay of the same update wrote the document")
	}
	// Back to defaults is a real change and the group is on again.
	if changed, err := repo.SetPrefs(ctx, "alice", DefaultPrefs(), t0); err != nil || !changed {
		t.Fatalf("reset: %v %v", changed, err)
	}
	if p, _ := repo.GetPrefs(ctx, "alice"); p != DefaultPrefs() {
		t.Errorf("after reset = %+v", p)
	}
	// Another user is unaffected, and an invalid uid never builds a path.
	if p, _ := repo.GetPrefs(ctx, "bob"); p != DefaultPrefs() {
		t.Errorf("bob = %+v", p)
	}
	if _, err := repo.GetPrefs(ctx, "a/b"); err == nil {
		t.Error("an invalid uid reached Firestore")
	}
}

// TestIntegration_PrefsSuppressedPushOnRedelivery: the push is suppressed while the group is off, the row is written, and a
// redelivery after the user turned the group on finds the row and pushes nothing.
func TestIntegration_PrefsSuppressedPushOnRedelivery(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	rig := newRig(t, prefsFlagsOn("alice", "bob", "carol"))
	rig.f.d.Repo = repo
	store := NewPrefsStore(repo, rig.dir)
	rig.f.d.Prefs = store
	register(t, repo, "bob", "device-bbbbbbbbbbbb", "tok-b1", t0)
	_, err := store.UpdatePrefs(ctx, "bob", goodKey, Prefs{Plans: true, MentionsReplies: true, LikesReposts: true, Followers: false, Messages: true})
	mustNoErr(t, err)

	ev := Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}
	out, err := rig.f.Deliver(ctx, ev)
	mustNoErr(t, err)
	if out.Created != 1 || out.Pushed != 0 || out.PrefSuppressed != 1 || len(rig.sender.sent) != 0 {
		t.Fatalf("first delivery = %+v pushes=%d", out, len(rig.sender.sent))
	}
	rows, err := repo.List(ctx, "bob", ListQuery{Limit: 10})
	mustNoErr(t, err)
	if len(rows) != 1 || rows[0].Type != TypeFollow {
		t.Fatalf("rows = %+v, want the follow row written despite the muted push", rows)
	}
	_, err = store.UpdatePrefs(ctx, "bob", goodKey, DefaultPrefs())
	mustNoErr(t, err)
	out, err = rig.f.Deliver(ctx, ev)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Pushed != 0 || len(rig.sender.sent) != 0 {
		t.Errorf("redelivery = %+v pushes=%d, want a duplicate and no push", out, len(rig.sender.sent))
	}
	// A new event of the now-enabled group does push.
	out, err = rig.f.Deliver(ctx, Event{Type: TypeFollow, ActorID: "carol", RecipientIDs: []string{"bob"}, At: t0})
	mustNoErr(t, err)
	if out.Pushed != 1 {
		t.Errorf("after re-enabling: %+v", out)
	}
}

func TestIntegration_PrefsErasedAndExported(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	register(t, repo, "alice", "device-aaaaaaaaaaaa", "tok-a1", t0)
	_, err := repo.SetPrefs(ctx, "alice", Prefs{Plans: false, MentionsReplies: true, LikesReposts: true, Followers: true, Messages: false}, t0)
	mustNoErr(t, err)
	_, err = repo.SetPrefs(ctx, "bob", Prefs{}, t0)
	mustNoErr(t, err)

	var buf bytes.Buffer
	mustNoErr(t, repo.ExportUser(ctx, "alice", &buf))
	var out struct {
		Settings struct {
			PushEnabled map[string]bool `json:"pushEnabled"`
		} `json:"settings"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("not valid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Settings.PushEnabled) != 5 || out.Settings.PushEnabled["plans"] || !out.Settings.PushEnabled["followers"] || out.Settings.PushEnabled["messages"] {
		t.Errorf("exported settings = %v", out.Settings.PushEnabled)
	}
	// A user who never saved anything exports the defaults.
	buf.Reset()
	mustNoErr(t, repo.ExportUser(ctx, "nobody", &buf))
	if !json.Valid(buf.Bytes()) || !bytes.Contains(buf.Bytes(), []byte(`"settings":{"pushEnabled":{`)) {
		t.Errorf("empty export = %s", buf.String())
	}

	var cp Checkpoint
	for done, steps := false, 0; !done; steps++ {
		if steps > 10 {
			t.Fatal("purge did not finish")
		}
		cp, done, err = repo.PurgeUser(ctx, "alice", cp)
		mustNoErr(t, err)
	}
	if docExists(t, client, "users/alice/settings/notifications") {
		t.Error("alice's settings document survived the purge")
	}
	if !docExists(t, client, "users/bob/settings/notifications") {
		t.Error("bob's settings document was deleted by alice's purge")
	}
	// Redelivered purge with nothing left is a clean no-op.
	_, _, err = repo.PurgeUser(ctx, "alice", Checkpoint{})
	mustNoErr(t, err)
}
