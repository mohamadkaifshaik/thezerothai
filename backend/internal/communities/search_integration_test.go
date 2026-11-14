//go:build integration

package communities

import (
	"context"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

func (e *env) createNamed(t *testing.T, uid, key, name string) string {
	t.Helper()
	v, err := e.svc.CreateCommunity(context.Background(), uid, CreateInput{Key: key, Name: name})
	if err != nil {
		t.Fatalf("create %q: %v", name, err)
	}
	return v.Community.ID
}

// seedNamedStatus writes a community with a status Create cannot produce, with its nameLower.
func (e *env) seedNamedStatus(t *testing.T, cid, name string, st Status) {
	t.Helper()
	e.seedCommunity(t, Community{ID: cid, Name: name, OwnerID: "owner", MemberCount: 1, Status: st}, nil)
	if _, err := e.repo.ref(cid).Update(context.Background(), []firestore.Update{{Path: namekey.Field, Value: namekey.Fold(name)}}); err != nil {
		t.Fatal(err)
	}
}

// TestSearchByName_StatusBoundsAndRename: Create writes nameLower; only ACTIVE communities match, in folded-name order, within
// the prefix range (an emoji right after the prefix included); a rename moves the key.
func TestSearchByName_StatusBoundsAndRename(t *testing.T) {
	e := newListEnv(t)
	ctx := context.Background()
	a := e.createNamed(t, "owner", "search-integration-key-0001", "Go Devs")
	b := e.createNamed(t, "owner", "search-integration-key-0002", "go\U0001F3C3 club")
	e.createNamed(t, "stranger", "search-integration-key-0003", "Gp")
	e.seedNamedStatus(t, "0000000000000000901", "Go suspended", StatusSuspended)
	e.seedNamedStatus(t, "0000000000000000902", "Go archived", StatusArchived)

	got, err := e.repo.SearchByName(ctx, "go", nil, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != a || got[1].ID != b {
		t.Fatalf("got %v", got)
	}
	page, err := e.svc.SearchCommunities(ctx, "member", "go", 1, "")
	if err != nil || len(page.Views) != 1 || page.Views[0].Community.ID != a || page.NextPageToken == "" {
		t.Fatalf("page 1 = %+v, %v", page, err)
	}
	next, err := e.svc.SearchCommunities(ctx, "member", "go", 1, page.NextPageToken)
	if err != nil || len(next.Views) != 1 || next.Views[0].Community.ID != b {
		t.Fatalf("page 2 = %+v, %v", next, err)
	}

	renamed := "Rust Devs"
	if _, err := e.svc.UpdateCommunity(ctx, "owner", UpdateInput{Key: "search-integration-key-0004", CommunityID: a, Name: &renamed}); err != nil {
		t.Fatal(err)
	}
	if got, _ := e.repo.SearchByName(ctx, "go d", nil, 20); len(got) != 0 {
		t.Fatalf("old prefix still matches: %v", got)
	}
	if got, _ := e.repo.SearchByName(ctx, "rust", nil, 20); len(got) != 1 || got[0].ID != a {
		t.Fatalf("new prefix = %v", got)
	}
}
