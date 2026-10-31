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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// List reads (W5-7). As in the member-write tests, what is measured is the service's own Firestore operations on a cold path:
// the real graph repository (one real read per snapshot, no instance cache), the real lists repository, and a directory that
// charges one read for every profile except the caller's own (the account-status interceptor loaded it). The interceptor's one
// read is not in this harness: add 1 to compare with lists.proto and ADR-0030 (GetList 5 / 2, ListUserLists 24 / 21,
// ListListMembers 25 / 55). The ADR counts the owner's profile inside the page's GetMany; here it is a separate (also charged)
// read, so the totals are the ADR's minus 1.

// readDirectory serves profiles and charges one read per uid returned other than free (the caller).
type readDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
	free     string
}

func (d readDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	out := map[string]identity.Profile{}
	for _, u := range uids {
		p, ok := d.profiles[u]
		if !ok {
			continue
		}
		out[u] = p
		if u != d.free {
			budget.FromContext(ctx).AddReads(1)
		}
	}
	return out, nil
}

type readIntEnv struct {
	*listsEnv
	profiles map[string]identity.Profile
}

// svcFor builds a FRESH service for caller (a cold doc cache and no graph cache): every cold assertion needs one.
func (e *readIntEnv) svcFor(caller string) *service {
	return New(Deps{
		Repo: e.repo, Directory: readDirectory{profiles: e.profiles, free: caller}, IDs: e.node,
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

// exact asserts the measured reads equal want (a regression in either direction is a finding) and the call wrote nothing.
func exact(t *testing.T, name string, c *budget.Counter, wantReads int64) {
	t.Helper()
	budgettest.Assert(t, name, c, budgettest.Budget{Reads: wantReads})
	if c.Reads() != wantReads {
		t.Errorf("%s: reads = %d, want exactly %d (update the doc comment and the ADR table if this is intended)", name, c.Reads(), wantReads)
	}
}

func TestGetList_Integration_Budget(t *testing.T) {
	e := newReadIntEnv(t, 0)
	e.putList(t, lid(1), "owner", false, false, []string{"m1"})
	e.putList(t, lid(2), "owner", true, false, nil)
	hiddenID := lid(3)
	e.putList(t, hiddenID, "owner", false, true, nil)
	ctx := context.Background()

	// owner: the list doc only (ADR 2 with the interceptor)
	own := e.svcFor("owner")
	c := budgetCall(func(ctx context.Context) {
		if v, err := own.GetList(ctx, "owner", lid(1)); err != nil || v.Header.ID != lid(1) {
			t.Fatalf("owner: %+v, %v", v, err)
		}
	})
	exact(t, "GetList owner cold", c, 1)
	c = budgetCall(func(ctx context.Context) { _, _ = own.GetList(ctx, "owner", lid(1)) })
	exact(t, "GetList owner warm", c, 0)

	// a private list the owner never shared: the owner still reads it
	if _, err := own.GetList(ctx, "owner", lid(2)); err != nil {
		t.Fatal(err)
	}

	// non-owner, public: list + caller graph + owner profile + owner graph (ADR 5 with the interceptor)
	other := e.svcFor("viewer")
	c = budgetCall(func(ctx context.Context) {
		if _, err := other.GetList(ctx, "viewer", lid(1)); err != nil {
			t.Fatal(err)
		}
	})
	exact(t, "GetList non-owner cold", c, 4)

	// private and hidden (stored hidden:true) and a missing id are one answer; the first two stop after the doc read
	want := missingErr(t)
	for name, id := range map[string]string{"private": lid(2), "hidden": hiddenID, "missing": lid(9)} {
		other = e.svcFor("viewer")
		c = budgetCall(func(ctx context.Context) {
			_, err := other.GetList(ctx, "viewer", id)
			if err == nil {
				t.Fatalf("%s: visible to a non-owner", name)
			}
			sameError(t, err, want)
		})
		exact(t, "GetList refused "+name, c, 1)
	}

	// owner blocks the viewer, and an overflowed owner: refused after the owner's graph (4 reads), the same bytes
	e.seedGraph(t, "owner", nil, true)
	other = e.svcFor("viewer")
	c = budgetCall(func(ctx context.Context) {
		_, err := other.GetList(ctx, "viewer", lid(1))
		sameError(t, err, want)
	})
	exact(t, "GetList owner overflow", c, 4)
}

func budgetCall(fn func(ctx context.Context)) *budget.Counter {
	ctx, c := budget.WithCounter(context.Background())
	fn(ctx)
	return c
}

func TestListUserLists_Integration_Budget(t *testing.T) {
	e := newReadIntEnv(t, 0)
	for i := 1; i <= 20; i++ {
		e.putList(t, lid(i), "owner", i%2 == 0, i == 3, []string{"u1"})
	}
	e.putList(t, "0000000000000009901", "stranger", false, false, nil) // another owner's list is never returned

	for _, size := range []int32{20, 50} {
		// the caller's own lists: all 20 (ADR 21 with the interceptor)
		own := e.svcFor("owner")
		c := budgetCall(func(ctx context.Context) {
			got, err := own.ListUserLists(ctx, "owner", UserListsInput{PageSize: size, ContainsUserID: "u1"})
			if err != nil || len(got.Lists) != 20 || len(got.ContainingIDs) != 20 || got.NextPageToken != "" {
				t.Fatalf("own page %d: %d lists, %d containing, token %q, %v", size, len(got.Lists), len(got.ContainingIDs), got.NextPageToken, err)
			}
		})
		exact(t, fmt.Sprintf("ListUserLists own, page %d", size), c, 20)

		// another owner's: caller graph + owner profile + owner graph + 20 docs read, 9 public and not hidden returned
		other := e.svcFor("viewer")
		c = budgetCall(func(ctx context.Context) {
			got, err := other.ListUserLists(ctx, "viewer", UserListsInput{OwnerID: "owner", PageSize: size})
			if err != nil {
				t.Fatal(err)
			}
			want := []string{lid(1), lid(5), lid(7), lid(9), lid(11), lid(13), lid(15), lid(17), lid(19)}
			if !reflect.DeepEqual(listIDs(got.Lists), want) {
				t.Fatalf("page %d = %v, want %v", size, listIDs(got.Lists), want)
			}
		})
		exact(t, fmt.Sprintf("ListUserLists other, page %d", size), c, 23)
	}

	// an owner with no lists: the empty query bills 1 (ADR 5 with the interceptor)
	other := e.svcFor("viewer")
	e.profiles["empty"] = active("empty", false)
	c := budgetCall(func(ctx context.Context) {
		got, err := other.ListUserLists(ctx, "viewer", UserListsInput{OwnerID: "empty"})
		if err != nil || len(got.Lists) != 0 {
			t.Fatalf("%v %v", got, err)
		}
	})
	exact(t, "ListUserLists other, none", c, 4)

	// a refused owner reads the graphs and the profile, never the list query
	e.seedGraph(t, "owner", nil, true)
	other = e.svcFor("viewer")
	c = budgetCall(func(ctx context.Context) {
		got, err := other.ListUserLists(ctx, "viewer", UserListsInput{OwnerID: "owner"})
		if err != nil || len(got.Lists) != 0 {
			t.Fatalf("overflow owner: %v %v", got, err)
		}
	})
	exact(t, "ListUserLists overflowed owner", c, 3)
}

func TestListUserLists_Integration_Paging(t *testing.T) {
	e := newReadIntEnv(t, 0)
	for i := 1; i <= 7; i++ {
		e.putList(t, lid(i), "owner", false, false, nil)
	}
	svc := e.svcFor("owner")
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

func TestListListMembers_Integration_Budget(t *testing.T) {
	e := newReadIntEnv(t, 60)
	members := manyMembers(60) // m000 oldest ... m059 newest
	e.putList(t, lid(1), "owner", false, false, members)
	e.seedGraph(t, "owner", []string{"m059"}, false) // the newest member blocks the owner: dropped for everyone
	e.seedGraph(t, "viewer", nil, false)

	for _, size := range []int32{20, 50} {
		// non-owner: list + caller graph + owner profile + owner graph + one profile per kept member of the page
		viewer := e.svcFor("viewer")
		var page MembersPage
		c := budgetCall(func(ctx context.Context) {
			var err error
			if page, err = viewer.ListListMembers(ctx, "viewer", lid(1), size, ""); err != nil {
				t.Fatal(err)
			}
		})
		kept := int64(size) - 1 // the dropped newest member costs no profile read
		exact(t, fmt.Sprintf("ListListMembers non-owner, page %d", size), c, 4+kept)
		if int64(len(page.Items)) != kept || page.Items[0].User.UserID != "m058" || page.NextPageToken == "" {
			t.Fatalf("page %d = %d rows first %v token %q", size, len(page.Items), page.Items[0].User.UserID, page.NextPageToken)
		}

		// owner: list + own graph + the page's profiles
		own := e.svcFor("owner")
		c = budgetCall(func(ctx context.Context) {
			if _, err := own.ListListMembers(ctx, "owner", lid(1), size, ""); err != nil {
				t.Fatal(err)
			}
		})
		exact(t, fmt.Sprintf("ListListMembers owner, page %d", size), c, 2+kept)
	}
}

func TestListListMembers_Integration_PagesAreComplete(t *testing.T) {
	e := newReadIntEnv(t, 45)
	members := manyMembers(45)
	e.putList(t, lid(1), "owner", false, false, members)
	e.seedGraph(t, "owner", []string{"m010"}, false)
	e.seedGraph(t, "viewer", nil, false)
	svc := e.svcFor("viewer")
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
		svc := e.svcFor("viewer")
		_, err := svc.ListListMembers(context.Background(), "viewer", id, 20, "")
		sameError(t, err, want)
	}
	if _, err := e.svcFor("owner").ListListMembers(context.Background(), "owner", lid(2), 20, ""); err != nil {
		t.Fatalf("the owner reads a hidden list: %v", err)
	}
}

func TestRepoGet_Integration_MissingBillsOne(t *testing.T) {
	e := newReadIntEnv(t, 0)
	ctx, c := budget.WithCounter(context.Background())
	if _, err := e.repo.Get(ctx, lid(9)); err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	exact(t, "Repo.Get missing", c, 1)
	if got, err := e.repo.ListByOwner(ctx, "nobody", "", 5); err != nil || len(got) != 0 {
		t.Fatalf("%v %v", got, err)
	}
	if c.Reads() != 2 {
		t.Errorf("an empty query must bill 1: reads = %d", c.Reads())
	}
}
