//go:build integration

package lists

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

func boolp(b bool) *bool { return &b }

// seedNamed creates a list through the real write path (so nameLower is the one Create writes) and returns its id.
func (e *listsEnv) seedNamed(t *testing.T, n int, owner, name string, private bool) string {
	t.Helper()
	v, err := e.svc.CreateList(context.Background(), owner, CreateInput{Key: key(n), Name: name, IsPrivate: boolp(private)})
	if err != nil {
		t.Fatalf("create %q: %v", name, err)
	}
	return v.Header.ID
}

func names(ls []List) []string {
	out := make([]string, len(ls))
	for i, l := range ls {
		out[i] = l.Name
	}
	return out
}

// TestSearchByName_PrefixBoundsAndPrivacy: Create writes nameLower; the range holds every name with the prefix (an astral-plane
// character right after it included) and nothing past it; private lists are never returned; the order is nameLower then id;
// the anchor resumes strictly after.
func TestSearchByName_PrefixBoundsAndPrivacy(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-48*time.Hour))
	ctx := context.Background()
	e.seedNamed(t, 1, "owner", "Go Devs", false)
	e.seedNamed(t, 2, "owner", "go\U0001F3C3 runners", false)
	e.seedNamed(t, 3, "owner", "Gopher", false)
	e.seedNamed(t, 4, "owner", "Go private", true)
	e.seedNamed(t, 5, "owner", "Gp", false)
	e.seedNamed(t, 6, "owner", "G", false)
	e.seedNamed(t, 7, "owner", "Learn Go", false)

	id := e.seedNamed(t, 8, "owner", "Golf", false)
	if d, _ := e.doc(t, id); d[namekey.Field] != "golf" {
		t.Fatalf("Create wrote nameLower = %v", d[namekey.Field])
	}

	got, err := e.repo.SearchByName(ctx, "go", nil, 20)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Go Devs", "Golf", "Gopher", "go\U0001F3C3 runners"}
	if gn := names(got); len(gn) != len(want) {
		t.Fatalf("got %q, want %q", gn, want)
	} else {
		for i := range gn {
			if gn[i] != want[i] {
				t.Fatalf("got %q, want %q", gn, want)
			}
		}
	}
	page, err := e.repo.SearchByName(ctx, "go", nil, 2)
	if err != nil || len(page) != 2 {
		t.Fatalf("page = %v, %v", names(page), err)
	}
	rest, err := e.repo.SearchByName(ctx, "go", &NameAnchor{NameLower: page[1].NameLower, ListID: page[1].ID}, 20)
	if err != nil || len(rest) != 2 || rest[0].Name != "Gopher" {
		t.Fatalf("rest = %v, %v", names(rest), err)
	}
	if none, err := e.repo.SearchByName(ctx, "zz", nil, 20); err != nil || len(none) != 0 {
		t.Fatalf("zz = %v, %v", names(none), err)
	}
}

// TestSearchByName_RenameAndPrivacyFlip: a rename rewrites nameLower (the old prefix stops matching), and a list turned private
// leaves the results at once.
func TestSearchByName_RenameAndPrivacyFlip(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-48*time.Hour))
	ctx := context.Background()
	id := e.seedNamed(t, 1, "owner", "Cricket", false)
	newName := "Football"
	if _, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(2), ListID: id, Name: &newName}); err != nil {
		t.Fatal(err)
	}
	if old, _ := e.repo.SearchByName(ctx, "cri", nil, 20); len(old) != 0 {
		t.Fatalf("old prefix still matches: %v", names(old))
	}
	if now, _ := e.repo.SearchByName(ctx, "foot", nil, 20); len(now) != 1 || now[0].ID != id {
		t.Fatalf("new prefix = %v", names(now))
	}
	if _, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(3), ListID: id, IsPrivate: boolp(true)}); err != nil {
		t.Fatal(err)
	}
	if got, _ := e.repo.SearchByName(ctx, "foot", nil, 20); len(got) != 0 {
		t.Fatalf("a private list is returned: %v", names(got))
	}
}

// TestSearchLists_HiddenAndBlocksThroughFirestore: the service over the real query drops a platform-hidden list and an owner who
// blocks the viewer, and keeps the rest.
func TestSearchLists_HiddenAndBlocksThroughFirestore(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-48*time.Hour))
	ctx := context.Background()
	keep := e.seedNamed(t, 1, "owner", "Chess club", false)
	hidden := e.seedNamed(t, 2, "owner", "Chess hidden", false)
	if _, err := e.client.Collection("lists").Doc(hidden).Update(ctx, []firestore.Update{{Path: "hidden", Value: true}}); err != nil {
		t.Fatal(err)
	}
	e.svc.d.Directory = fakeDirectory{profiles: map[string]identity.Profile{
		"owner":    {UserID: "owner", Handle: "owner", Status: identity.AccountStatusActive},
		"blocker":  {UserID: "blocker", Handle: "blocker", Status: identity.AccountStatusActive},
		"stranger": {UserID: "stranger", Handle: "stranger", Status: identity.AccountStatusActive},
	}}
	e.svc.d.Graph = &fakeGraph{snaps: map[string]graph.Snapshot{"blocker": {Blocked: set("stranger")}}}
	e.svc.d.CursorKey = []byte("0123456789abcdef0123456789abcdef")
	e.seedNamed(t, 3, "blocker", "Chess blocked", false)
	page, err := e.svc.SearchLists(ctx, "stranger", "chess", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Views) != 1 || page.Views[0].Header.ID != keep {
		t.Fatalf("got %v", page.Views)
	}
}
