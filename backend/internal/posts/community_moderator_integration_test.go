//go:build integration

package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TestCommunityModerator_SetCommunityListing pins the A12 field changes and the found / changed answers: 1 read, 0 or 1 write.
func TestCommunityModerator_SetCommunityListing(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	const cid, other = "0000000000000000801", "0000000000000000802"
	seed := func(id string, d map[string]any) {
		t.Helper()
		d["authorId"], d["kind"], d["createdAt"] = "alice", "POST", time.Now().UTC()
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	seed("0000000000000000901", map[string]any{"communityId": cid, "community": map[string]any{"id": cid, "name": "Go"}})
	seed("0000000000000000902", map[string]any{"text": "plain post"})
	seed("0000000000000000903", map[string]any{"communityId": other, "community": map[string]any{"id": other, "name": "Other"}})
	seed("0000000000000000904", map[string]any{"communityId": cid, "community": map[string]any{"id": cid, "name": "Go"}, "moderation": "TAKEN_DOWN"})
	seed("0000000000000000905", map[string]any{"communityHidden": true, "community": map[string]any{"id": cid, "name": "Go"}, "moderation": "SUSPENDED_AUTHOR"})
	m := NewCommunityModerator(client)

	type res struct{ changed, found bool }
	var gotAuthor string // the authorId the guard saw on the last call
	var guardErr error
	guard := func(a string) error { gotAuthor = a; return guardErr }
	call := func(id, community string, listed bool) (res, int64, int64) {
		t.Helper()
		bctx, c := budget.WithCounter(ctx)
		var out res
		err := client.RunTransaction(ctx, func(_ context.Context, tx *firestore.Transaction) error {
			var err error
			out.changed, out.found, _, err = m.SetCommunityListing(bctx, tx, id, community, listed, guard)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return out, c.Reads(), c.Writes()
	}
	state := func(id string) (listed, hidden bool, label string) {
		t.Helper()
		snap, err := client.Collection("posts").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		d := snap.Data()
		_, listed = d["communityId"]
		hidden, _ = d["communityHidden"].(bool)
		if c, ok := d["community"].(map[string]any); ok {
			label, _ = c["name"].(string)
		}
		return
	}

	// hide: communityId deleted, communityHidden set, the label snapshot kept for the restore; 1 read, 1 write
	if r, reads, writes := call("0000000000000000901", cid, false); r != (res{true, true}) || reads != 1 || writes != 1 {
		t.Errorf("hide = %+v, %d reads, %d writes", r, reads, writes)
	}
	if listed, hidden, label := state("0000000000000000901"); listed || !hidden || label != "Go" {
		t.Errorf("after hide: listed=%v hidden=%v label=%q", listed, hidden, label)
	}
	// A12: the post left the community query but is still an ordinary, visible post (never Hidden()), label snapshot intact
	repo := NewFirestoreRepo(client)
	inQuery := func() bool {
		t.Helper()
		got, err := repo.ByCommunity(ctx, cid, Window{}, 20)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range got {
			if p.ID == "0000000000000000901" {
				return true
			}
		}
		return false
	}
	if inQuery() {
		t.Error("a hidden post is still in the community query")
	}
	posts, err := repo.GetAll(ctx, []string{"0000000000000000901"})
	if p := posts["0000000000000000901"]; err != nil || p == nil || p.CommunityID != "" || p.Community == nil || p.Community.Name != "Go" || p.Hidden() || !p.Visible() {
		t.Errorf("hidden post = %+v, %v, want kept, visible, unlisted, label snapshot kept", p, err)
	}
	// hiding again changes nothing and writes nothing
	if r, reads, writes := call("0000000000000000901", cid, false); r != (res{false, true}) || reads != 1 || writes != 0 {
		t.Errorf("second hide = %+v, %d reads, %d writes", r, reads, writes)
	}
	// restore: communityId back from the label, the flag gone
	if r, _, writes := call("0000000000000000901", cid, true); r != (res{true, true}) || writes != 1 {
		t.Errorf("restore = %+v, %d writes", r, writes)
	}
	if listed, hidden, _ := state("0000000000000000901"); !listed || hidden {
		t.Errorf("after restore: listed=%v hidden=%v", listed, hidden)
	}
	if !inQuery() {
		t.Error("a restored post is not back in the community query")
	}
	if r, _, writes := call("0000000000000000901", cid, true); r != (res{false, true}) || writes != 0 {
		t.Errorf("second restore = %+v, %d writes", r, writes)
	}
	// not found: a missing post, a post without a community, a post of another community; nothing is written
	for _, id := range []string{"0000000000000000999", "0000000000000000902", "0000000000000000903"} {
		if r, reads, writes := call(id, cid, false); r != (res{false, false}) || reads != 1 || writes != 0 {
			t.Errorf("post %s = %+v, %d reads, %d writes, want not found", id, r, reads, writes)
		}
	}
	if listed, _, _ := state("0000000000000000903"); !listed {
		t.Error("a hide in the wrong community changed the post")
	}
	// F16: the guard sees the author before any write and its error stops the write, hide and restore alike, listed or not
	gotAuthor, guardErr = "", errors.New("refused")
	for _, listed := range []bool{false, true} {
		bctx, c := budget.WithCounter(ctx)
		err := client.RunTransaction(ctx, func(_ context.Context, tx *firestore.Transaction) error {
			_, _, _, err := m.SetCommunityListing(bctx, tx, "0000000000000000901", cid, listed, guard)
			return err
		})
		if !errors.Is(err, guardErr) || gotAuthor != "alice" || c.Reads() != 1 || c.Writes() != 0 {
			t.Errorf("guard refusal listed=%v: err=%v author=%q reads=%d writes=%d", listed, err, gotAuthor, c.Reads(), c.Writes())
		}
	}
	if listed, _, _ := state("0000000000000000901"); !listed {
		t.Error("a refused call wrote")
	}
	guardErr = nil
	// L-2: a post with moderation set is not found, hidden or not, and the guard is not even asked
	gotAuthor = ""
	for _, id := range []string{"0000000000000000904", "0000000000000000905"} {
		for _, listed := range []bool{false, true} {
			if r, reads, writes := call(id, cid, listed); r != (res{false, false}) || reads != 1 || writes != 0 || gotAuthor != "" {
				t.Errorf("moderated post %s listed=%v = %+v, %d reads, %d writes, guard saw %q", id, listed, r, reads, writes, gotAuthor)
			}
		}
	}
	if _, _, _, err := NewCommunityModerator(nil).SetCommunityListing(ctx, nil, "x", cid, false, nil); err == nil {
		t.Error("a moderator without a client must fail closed")
	}
}

// A reply qualifies through conversationCommunityId; it has no communityId, so hidden is communityHidden alone
// (plus communityHiddenAt, server time); reply is reported; a REPOST, a foreign conversation and a moderated reply are not found.
func TestCommunityModerator_SetCommunityListing_Replies(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	const cid, other = "0000000000000000811", "0000000000000000812"
	seed := func(id string, d map[string]any) {
		t.Helper()
		d["authorId"], d["createdAt"] = "alice", time.Now().UTC()
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	seed("0000000000000000911", map[string]any{"kind": "REPLY", "isReply": true, "conversationCommunityId": cid})
	seed("0000000000000000912", map[string]any{"kind": "REPLY", "isReply": true, "conversationCommunityId": other})
	seed("0000000000000000913", map[string]any{"kind": "REPLY", "isReply": true})
	seed("0000000000000000914", map[string]any{"kind": "REPLY", "isReply": true, "conversationCommunityId": cid, "moderation": "TAKEN_DOWN"})
	seed("0000000000000000915", map[string]any{"kind": "REPOST", "conversationCommunityId": cid})
	m := NewCommunityModerator(client)

	var sawAuthor string
	guard := func(a string) error { sawAuthor = a; return nil }
	call := func(id string, listed bool) (changed, found, reply bool, reads, writes int64) {
		t.Helper()
		bctx, c := budget.WithCounter(ctx)
		err := client.RunTransaction(ctx, func(_ context.Context, tx *firestore.Transaction) error {
			var err error
			changed, found, reply, err = m.SetCommunityListing(bctx, tx, id, cid, listed, guard)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return changed, found, reply, c.Reads(), c.Writes()
	}
	fields := func(id string) map[string]any {
		t.Helper()
		snap, err := client.Collection("posts").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return snap.Data()
	}
	const rep = "0000000000000000911"

	if ch, f, r, reads, writes := call(rep, false); !ch || !f || !r || reads != 1 || writes != 1 || sawAuthor != "alice" {
		t.Errorf("hide = %v %v %v, %d reads, %d writes, guard saw %q", ch, f, r, reads, writes, sawAuthor)
	}
	d := fields(rep)
	if at, ok := d["communityHiddenAt"].(time.Time); d["communityHidden"] != true || !ok || at.IsZero() {
		t.Errorf("after hide: %v", d)
	}
	if _, ok := d["communityId"]; ok {
		t.Error("a reply hide wrote communityId")
	}
	repo := NewFirestoreRepo(client)
	got, err := repo.GetAll(ctx, []string{rep})
	if p := got[rep]; err != nil || p == nil || !p.CommunityHidden || p.Hidden() || !p.Visible() {
		t.Errorf("hidden reply = %+v, %v, want CommunityHidden and still visible", p, err)
	}
	if ch, f, r, _, writes := call(rep, false); ch || !f || !r || writes != 0 {
		t.Errorf("second hide = %v %v %v, %d writes", ch, f, r, writes)
	}
	if ch, f, r, _, writes := call(rep, true); !ch || !f || !r || writes != 1 {
		t.Errorf("restore = %v %v %v, %d writes", ch, f, r, writes)
	}
	d = fields(rep)
	if _, ok := d["communityHidden"]; ok {
		t.Errorf("after restore: %v", d)
	}
	if _, ok := d["communityHiddenAt"]; ok {
		t.Errorf("after restore: %v", d)
	}
	if ch, f, _, _, writes := call(rep, true); ch || !f || writes != 0 {
		t.Errorf("second restore = %v %v, %d writes", ch, f, writes)
	}
	sawAuthor = ""
	for _, id := range []string{"0000000000000000912", "0000000000000000913", "0000000000000000914", "0000000000000000915"} {
		for _, listed := range []bool{false, true} {
			if ch, f, r, reads, writes := call(id, listed); ch || f || r || reads != 1 || writes != 0 || sawAuthor != "" {
				t.Errorf("post %s listed=%v = %v %v %v, %d reads, %d writes, guard saw %q, want not found", id, listed, ch, f, r, reads, writes, sawAuthor)
			}
		}
	}
	// a root answers reply=false and now writes communityHiddenAt too
	root := "0000000000000000921"
	seed(root, map[string]any{"kind": "POST", "communityId": cid, "community": map[string]any{"id": cid, "name": "Go"}})
	if ch, f, r, _, _ := call(root, false); !ch || !f || r {
		t.Errorf("root hide = %v %v %v", ch, f, r)
	}
	if _, ok := fields(root)["communityHiddenAt"].(time.Time); !ok {
		t.Error("a root hide did not write communityHiddenAt")
	}
	if ch, _, _, _, _ := call(root, true); !ch {
		t.Error("root restore")
	}
	if _, ok := fields(root)["communityHiddenAt"]; ok {
		t.Error("a root restore left communityHiddenAt")
	}
}
