//go:build integration

package lists

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// The `lists_member_of` part against the emulator. Reads are one per list that names the user (the array-contains query,
// 100 per page); the owners' profiles and the user's graph come from caches and are not Firestore reads of this module.
func TestExporter_Integration_MemberOf(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	now := time.Now().UTC()
	put := func(id, owner, name string, private, hidden bool, members ...string) {
		doc := map[string]any{"ownerId": owner, "name": name, "description": "d", "isPrivate": private, "memberIds": members, "createdAt": now, "updatedAt": now}
		if hidden {
			doc["hidden"] = true
		}
		if _, err := e.client.Collection("lists").Doc(id).Set(context.Background(), doc); err != nil {
			t.Fatal(err)
		}
	}
	put("0000000000000000701", "alice", "Public A", false, false, "me", "other-member")
	put("0000000000000000702", "alice", "PRIVATE-NAME", true, false, "me", "other-member")
	put("0000000000000000703", "bob", "HIDDEN-NAME", false, true, "me", "other-member2")
	put("0000000000000000704", "me", "Mine", false, false, "me", "x") // owned and self-listed: not repeated here
	put("0000000000000000705", "alice", "Not me", false, false, "someone")
	handles := &fakeHandles{profs: map[string]identity.Profile{
		"alice": {UserID: "alice", Handle: "alice", Status: identity.AccountStatusActive},
		"bob":   {UserID: "bob", Handle: "bob", Status: identity.AccountStatusActive},
	}}
	buf := &bytesBuffer{}
	// 4 lists name "me" (701-704); the own list 704 is exported in the lists part and not repeated in member-of.
	x := NewExporter(e.repo).WithMembership(e.repo, handles, &fakeSocial{snap: graph.Snapshot{}})
	if err := x.ExportUser(context.Background(), "me", buf); err != nil {
		t.Fatal(err)
	}
	out := strings.ReplaceAll(string(buf.b), "\n", "")
	want := `"lists_member_of":{"public":[{"listId":"0000000000000000701","ownerHandle":"alice","name":"Public A"}],"redactedCount":2}`
	if !strings.Contains(out, want) {
		t.Errorf("member-of part missing or wrong:\n%s", out)
	}
	for _, leak := range []string{"other-member", "PRIVATE-NAME", "HIDDEN-NAME", "0000000000000000702", "0000000000000000703", "bob"} {
		if strings.Contains(out, leak) {
			t.Errorf("export leaks %q: %s", leak, out)
		}
	}
	if n := countSub(out, `"listId":"0000000000000000704"`); n != 1 {
		t.Errorf("own list appears %d times, want once (in lists, not repeated): %s", n, out)
	}
}

// A user on more than one page of lists: 101 memberships read as 100 + 1 (pages of 100), none lost at the page boundary.
func TestExporter_Integration_MemberOfPages(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds 101 lists")
	}
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	now := time.Now().UTC()
	profs := map[string]identity.Profile{}
	for i := range 101 {
		owner := fmt.Sprintf("own%03d", i)
		profs[owner] = identity.Profile{UserID: owner, Handle: owner, Status: identity.AccountStatusActive}
		if _, err := e.client.Collection("lists").Doc(fmt.Sprintf("%019d", 8000+i)).Set(context.Background(), map[string]any{
			"ownerId": owner, "name": "n", "description": "", "isPrivate": false, "memberIds": []string{"me"}, "createdAt": now, "updatedAt": now,
		}); err != nil {
			t.Fatal(err)
		}
	}
	buf := &bytesBuffer{}
	if err := NewExporter(e.repo).WithMembership(e.repo, &fakeHandles{profs: profs}, &fakeSocial{}).ExportUser(context.Background(), "me", buf); err != nil {
		t.Fatal(err)
	}
	// 100 on the first page, 1 on the second; the second page is short, so no third query.
	if n := countSub(string(buf.b), `"ownerHandle"`); n != 101 {
		t.Errorf("exported %d memberships, want 101 (none lost at the page boundary)", n)
	}
}
