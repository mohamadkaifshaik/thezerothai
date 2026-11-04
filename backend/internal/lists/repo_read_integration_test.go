//go:build integration

package lists

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// List reads run against the real graph repository (no instance cache), the real lists repository and a directory that serves the
// profiles of a map.

// readDirectory serves the profiles it holds.
type readDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
}

func (d readDirectory) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	out := map[string]identity.Profile{}
	for _, u := range uids {
		p, ok := d.profiles[u]
		if !ok {
			continue
		}
		out[u] = p
	}
	return out, nil
}

type readIntEnv struct {
	*listsEnv
	profiles map[string]identity.Profile
}

// svcFor builds a FRESH service (a cold doc cache and no graph cache).
func (e *readIntEnv) svcFor() *service {
	return New(Deps{
		Repo: e.repo, Directory: readDirectory{profiles: e.profiles}, IDs: e.node,
		Graph: graphFromRepo{graph.NewFirestoreRepo(e.client)}, CursorKey: readKey,
		Limits: Limits{MaxPerUser: 20, CacheEntries: 100, MaxMembers: 150},
	}).(*service)
}

func newReadIntEnv(t *testing.T, memberCount int) *readIntEnv {
	t.Helper()
	base := newListsEnv(t, time.Now().Add(-72*time.Hour))
	profiles := map[string]identity.Profile{"owner": active("owner", false), "viewer": active("viewer", false)}
	for _, m := range manyMembers(memberCount) {
		profiles[m] = active(m, false)
	}
	return &readIntEnv{listsEnv: base, profiles: profiles}
}

func (e *readIntEnv) seedGraph(t *testing.T, uid string, blockedBy []string, overflow bool) {
	t.Helper()
	nz := func(s []string) []string {
		if s == nil {
			return []string{}
		}
		return s
	}
	_, err := e.client.Collection("graph").Doc(uid).Set(context.Background(), map[string]any{
		"following": []string{}, "blocked": []string{}, "muted": []string{}, "requested": []string{}, "blockedBy": nz(blockedBy),
		"blockedByOverflow": overflow, "updatedAt": time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
}

// putList stores a list doc as the write path would.
func (e *readIntEnv) putList(t *testing.T, id, owner string, private, hidden bool, members []string) {
	t.Helper()
	now := time.Now().UTC()
	d := listDoc{OwnerID: owner, Name: "L" + id[len(id)-2:], IsPrivate: private, MemberIDs: members, Hidden: hidden, CreatedAt: now, UpdatedAt: now}
	if members == nil {
		d.MemberIDs = []string{}
	}
	if _, err := e.client.Collection("lists").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

func lid(i int) string { return fmt.Sprintf("00000000000000001%02d", 10+i) }

func TestGetList_Integration_Visibility(t *testing.T) {
	e := newReadIntEnv(t, 0)
	e.putList(t, lid(1), "owner", false, false, []string{"m1"})
	e.putList(t, lid(2), "owner", true, false, nil)
	hiddenID := lid(3)
	e.putList(t, hiddenID, "owner", false, true, nil)
	e.putList(t, lid(4), "owner", false, false, nil)
	ctx := context.Background()

	own := e.svcFor()
	if v, err := own.GetList(ctx, "owner", lid(1)); err != nil || v.Header.ID != lid(1) {
		t.Fatalf("owner: %+v, %v", v, err)
	}

	// a private list the owner never shared: the owner still reads it
	if _, err := own.GetList(ctx, "owner", lid(2)); err != nil {
		t.Fatal(err)
	}

	// the owner's second read of a list is served from the instance cache: it still answers with the document gone
	if _, err := own.GetList(ctx, "owner", lid(4)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Collection("lists").Doc(lid(4)).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	if v, err := own.GetList(ctx, "owner", lid(4)); err != nil || v.Header.ID != lid(4) {
		t.Fatalf("warm owner read after the document was deleted: %+v, %v", v, err)
	}

	// non-owner, public
	other := e.svcFor()
	if _, err := other.GetList(ctx, "viewer", lid(1)); err != nil {
		t.Fatal(err)
	}

	// private and hidden (stored hidden:true) and a missing id are one answer
	want := missingErr(t)
	for name, id := range map[string]string{"private": lid(2), "hidden": hiddenID, "missing": lid(9)} {
		_, err := e.svcFor().GetList(ctx, "viewer", id)
		if err == nil {
			t.Fatalf("%s: visible to a non-owner", name)
		}
		sameError(t, err, want)
	}

	// an overflowed owner graph refuses the viewer with the same bytes
	e.seedGraph(t, "owner", nil, true)
	_, err := e.svcFor().GetList(ctx, "viewer", lid(1))
	sameError(t, err, want)
}

func TestListUserLists_Integration_Visibility(t *testing.T) {
	e := newReadIntEnv(t, 0)
	for i := 1; i <= 20; i++ {
		e.putList(t, lid(i), "owner", i%2 == 0, i == 3, []string{"u1"})
	}
	e.putList(t, "0000000000000009901", "stranger", false, false, nil) // another owner's list is never returned

	for _, size := range []int32{20, 50} {
		// the caller's own lists: all 20
		got, err := e.svcFor().ListUserLists(context.Background(), "owner", UserListsInput{PageSize: size, ContainsUserID: "u1"})
		if err != nil || len(got.Lists) != 20 || len(got.ContainingIDs) != 20 || got.NextPageToken != "" {
			t.Fatalf("own page %d: %d lists, %d containing, token %q, %v", size, len(got.Lists), len(got.ContainingIDs), got.NextPageToken, err)
		}

		// another owner's: 9 of the 20 are public and not hidden
		got, err = e.svcFor().ListUserLists(context.Background(), "viewer", UserListsInput{OwnerID: "owner", PageSize: size})
		if err != nil {
			t.Fatal(err)
		}
		want := []string{lid(1), lid(5), lid(7), lid(9), lid(11), lid(13), lid(15), lid(17), lid(19)}
		if !reflect.DeepEqual(listIDs(got.Lists), want) {
			t.Fatalf("page %d = %v, want %v", size, listIDs(got.Lists), want)
		}
	}

	// page_size 1 for another owner: the filtering happens over the one 20-document query, so all 9 public lists come back with no token
	got, err := e.svcFor().ListUserLists(context.Background(), "viewer", UserListsInput{OwnerID: "owner", PageSize: 1})
	if err != nil || len(got.Lists) != 9 || got.NextPageToken != "" {
		t.Fatalf("other page 1: %d lists, token %q, %v", len(got.Lists), got.NextPageToken, err)
	}

	// an owner with no lists
	e.profiles["empty"] = active("empty", false)
	got, err = e.svcFor().ListUserLists(context.Background(), "viewer", UserListsInput{OwnerID: "empty"})
	if err != nil || len(got.Lists) != 0 {
		t.Fatalf("%v %v", got, err)
	}

	// an owner whose blocked-by set overflowed shows nothing to the viewer
	e.seedGraph(t, "owner", nil, true)
	got, err = e.svcFor().ListUserLists(context.Background(), "viewer", UserListsInput{OwnerID: "owner"})
	if err != nil || len(got.Lists) != 0 {
		t.Fatalf("overflow owner: %v %v", got, err)
	}
}

func TestListUserLists_Integration_Paging(t *testing.T) {
	e := newReadIntEnv(t, 0)
	for i := 1; i <= 7; i++ {
		e.putList(t, lid(i), "owner", false, false, nil)
	}
	svc := e.svcFor()
	var seen []string
	tok := ""
	for range 10 {
		got, err := svc.ListUserLists(context.Background(), "owner", UserListsInput{PageSize: 3, PageToken: tok})
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, listIDs(got.Lists)...)
		if tok = got.NextPageToken; tok == "" {
			break
		}
	}
	want := []string{lid(1), lid(2), lid(3), lid(4), lid(5), lid(6), lid(7)}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("paged %v, want %v", seen, want)
	}
}

func TestListListMembers_Integration_Pages(t *testing.T) {
	e := newReadIntEnv(t, 60)
	members := manyMembers(60) // m000 oldest ... m059 newest
	e.putList(t, lid(1), "owner", false, false, members)
	e.seedGraph(t, "owner", []string{"m059"}, false) // the newest member blocks the owner: dropped for everyone
	e.seedGraph(t, "viewer", nil, false)

	for _, size := range []int32{20, 50} {
		// non-owner: the dropped newest member leaves one fewer row on the page
		page, err := e.svcFor().ListListMembers(context.Background(), "viewer", lid(1), size, "")
		if err != nil {
			t.Fatal(err)
		}
		kept := int(size) - 1
		if len(page.Items) != kept || page.Items[0].User.UserID != "m058" || page.NextPageToken == "" {
			t.Fatalf("page %d = %d rows first %v token %q", size, len(page.Items), page.Items[0].User.UserID, page.NextPageToken)
		}

		// owner
		if _, err := e.svcFor().ListListMembers(context.Background(), "owner", lid(1), size, ""); err != nil {
			t.Fatal(err)
		}
	}
}

func TestListListMembers_Integration_PagesAreComplete(t *testing.T) {
	e := newReadIntEnv(t, 45)
	members := manyMembers(45)
	e.putList(t, lid(1), "owner", false, false, members)
	e.seedGraph(t, "owner", []string{"m010"}, false)
	e.seedGraph(t, "viewer", nil, false)
	svc := e.svcFor()
	var seen []string
	tok := ""
	for range 10 {
		p, err := svc.ListListMembers(context.Background(), "viewer", lid(1), 20, tok)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, itemUIDs(p.Items)...)
		if tok = p.NextPageToken; tok == "" {
			break
		}
	}
	var want []string
	for i := len(members) - 1; i >= 0; i-- {
		if members[i] != "m010" {
			want = append(want, members[i])
		}
	}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("paged %d members, want %d newest first without the dropped one", len(seen), len(want))
	}
}

// Private, hidden and absent are one answer through the real repository; a stored hidden:true is honoured and an absent field
// (omitempty) is false.
func TestListListMembers_Integration_RefusalsAreOneAnswer(t *testing.T) {
	e := newReadIntEnv(t, 3)
	e.putList(t, lid(1), "owner", true, false, manyMembers(3))
	e.putList(t, lid(2), "owner", false, true, manyMembers(3))
	want := missingErr(t)
	for _, id := range []string{lid(1), lid(2), lid(9)} {
		svc := e.svcFor()
		_, err := svc.ListListMembers(context.Background(), "viewer", id, 20, "")
		sameError(t, err, want)
	}
	if _, err := e.svcFor().ListListMembers(context.Background(), "owner", lid(2), 20, ""); err != nil {
		t.Fatalf("the owner reads a hidden list: %v", err)
	}
}

func TestRepoGet_Integration_Missing(t *testing.T) {
	e := newReadIntEnv(t, 0)
	ctx := context.Background()
	if _, err := e.repo.Get(ctx, lid(9)); err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	if got, err := e.repo.ListByOwner(ctx, "nobody", "", 5); err != nil || len(got) != 0 {
		t.Fatalf("%v %v", got, err)
	}
}
