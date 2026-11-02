//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TestCommunityModerator_SetCommunityListing pins the A12 field changes and the found / changed answers (ADR-0031 D5): 1 read, 0 or 1 write.
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
	m := NewCommunityModerator(client)

	type res struct{ changed, found bool }
	call := func(id, community string, listed bool) (res, int64, int64) {
		t.Helper()
		bctx, c := budget.WithCounter(ctx)
		var out res
		err := client.RunTransaction(ctx, func(_ context.Context, tx *firestore.Transaction) error {
			var err error
			out.changed, out.found, err = m.SetCommunityListing(bctx, tx, id, community, listed)
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
	if _, _, err := NewCommunityModerator(nil).SetCommunityListing(ctx, nil, "x", cid, false); err == nil {
		t.Error("a moderator without a client must fail closed")
	}
}
