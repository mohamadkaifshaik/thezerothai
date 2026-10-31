//go:build integration

package lists

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// The platform hide (plan W5-44, security review W5-17 M-4) against the emulator: SetHidden is the write, the existing read
// paths are the effect. A non-owner needs a FRESH service after the write (a cold doc cache): a warm instance serves its cached
// copy for at most cacheTTL (60 s), which is the documented bound and not what these tests measure.

func hideEnv(t *testing.T) *membersEnv {
	t.Helper()
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	e.profiles["viewer"] = active("viewer", false)
	return e
}

// viewerSvc is a fresh service for any caller: cold doc cache, the real graph repository, the same charging directory.
func (e *membersEnv) viewerSvc() *service {
	return New(Deps{
		Repo: e.repo, Directory: chargingDirectory{profiles: e.profiles}, IDs: e.node, Graph: graphFromRepo{graph.NewFirestoreRepo(e.client)},
		CursorKey: readKey, Limits: Limits{MaxPerUser: 20, CacheEntries: 100, MaxMembers: 150, AddsPerDay: 300, NewAccountAddsPerDay: 50},
	}).(*service)
}

func TestHideLever_Integration_SetHiddenCostAndShape(t *testing.T) {
	e := hideEnv(t)
	ctx := context.Background()
	v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket", Description: "ODI", IsPrivate: new(false)})
	if err != nil {
		t.Fatal(err)
	}
	id := v.Header.ID
	if _, err := e.svc.AddMember(ctx, "owner", key(2), id, "u1"); err != nil {
		t.Fatal(err)
	}
	before, _ := e.doc(t, id)
	at := time.Now().UTC().Truncate(time.Millisecond).Add(time.Hour)

	hide := func(hidden bool) (bool, *budget.Counter) {
		cctx, c := budget.WithCounter(ctx)
		changed, err := e.repo.SetHidden(cctx, id, hidden, at)
		if err != nil {
			t.Fatalf("SetHidden(%v): %v", hidden, err)
		}
		return changed, c
	}

	changed, c := hide(true)
	if !changed || c.Reads() != 1 || c.Writes() != 1 {
		t.Fatalf("hide: changed=%v reads=%d writes=%d, want true 1 1", changed, c.Reads(), c.Writes())
	}
	after, _ := e.doc(t, id)
	if after["hidden"] != true || !after["updatedAt"].(time.Time).Equal(at) {
		t.Fatalf("doc after hide = %#v", after)
	}
	// Field-level: nothing but hidden and updatedAt moved.
	for _, f := range []string{"ownerId", "name", "description", "isPrivate", "memberIds", "createdAt"} {
		if !reflect.DeepEqual(before[f], after[f]) {
			t.Errorf("hide changed %s: %#v -> %#v", f, before[f], after[f])
		}
	}

	if changed, c = hide(true); changed || c.Reads() != 1 || c.Writes() != 0 {
		t.Fatalf("hide again: changed=%v reads=%d writes=%d, want false 1 0", changed, c.Reads(), c.Writes())
	}

	if changed, c = hide(false); !changed || c.Reads() != 1 || c.Writes() != 1 {
		t.Fatalf("restore: changed=%v reads=%d writes=%d, want true 1 1", changed, c.Reads(), c.Writes())
	}
	restored, _ := e.doc(t, id)
	if _, present := restored["hidden"]; present {
		t.Errorf("restore left hidden=%v in the document; storage keeps absent = false", restored["hidden"])
	}
	if changed, c = hide(false); changed || c.Reads() != 1 || c.Writes() != 0 {
		t.Fatalf("restore again: changed=%v reads=%d writes=%d, want false 1 0", changed, c.Reads(), c.Writes())
	}
}

// A missing list is refused and, being a field-level Update inside a read, is never created.
func TestHideLever_Integration_MissingListIsRefused(t *testing.T) {
	e := hideEnv(t)
	ctx, c := budget.WithCounter(context.Background())
	changed, err := e.repo.SetHidden(ctx, "0000000000000009999", true, time.Now())
	if !errors.Is(err, ErrNotFound) || changed {
		t.Fatalf("changed=%v err=%v, want ErrNotFound", changed, err)
	}
	if c.Writes() != 0 || c.Reads() != 1 {
		t.Errorf("reads=%d writes=%d, want 1 0", c.Reads(), c.Writes())
	}
	if _, ok := e.doc(t, "0000000000000009999"); ok {
		t.Error("the hide created a document")
	}
}

// After the hide: GetList, ListUserLists, ListListMembers and the Reader (which GetListTimeline calls) answer the one NOT_FOUND
// to a non-owner; the owner still reads all of them. After the restore the non-owner sees the list again.
func TestHideLever_Integration_NonOwnersGetNotFoundOwnerSees(t *testing.T) {
	e := hideEnv(t)
	ctx := context.Background()
	v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket", IsPrivate: new(false)})
	if err != nil {
		t.Fatal(err)
	}
	id := v.Header.ID
	if _, err := e.svc.AddMember(ctx, "owner", key(2), id, "u1"); err != nil {
		t.Fatal(err)
	}
	want := missingErr(t)

	visible := func(viewer string) (get, lists, members, reader error) {
		s := e.viewerSvc()
		_, get = s.GetList(ctx, viewer, id)
		var ul UserLists
		ul, lists = s.ListUserLists(ctx, viewer, UserListsInput{OwnerID: "owner", PageSize: 20})
		if lists == nil && len(ul.Lists) == 0 {
			lists = errors.New("no lists returned")
		}
		_, members = s.ListListMembers(ctx, viewer, id, 20, "")
		_, reader = s.Members(ctx, viewer, id)
		return
	}
	if g, l, m, r := visible("viewer"); g != nil || l != nil || m != nil || r != nil {
		t.Fatalf("before the hide a non-owner sees: get=%v lists=%v members=%v reader=%v", g, l, m, r)
	}

	if _, err := e.repo.SetHidden(ctx, id, true, time.Now()); err != nil {
		t.Fatal(err)
	}

	s := e.viewerSvc()
	if _, err := s.GetList(ctx, "viewer", id); err == nil {
		t.Fatal("GetList: visible to a non-owner")
	} else {
		sameError(t, err, want)
	}
	if _, err := s.ListListMembers(ctx, "viewer", id, 20, ""); err == nil {
		t.Fatal("ListListMembers: visible to a non-owner")
	} else {
		sameError(t, err, want)
	}
	if _, err := s.Members(ctx, "viewer", id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Reader.Members (GetListTimeline's source) = %v, want ErrNotFound", err)
	}
	ul, err := s.ListUserLists(ctx, "viewer", UserListsInput{OwnerID: "owner", PageSize: 20})
	if err != nil || len(ul.Lists) != 0 {
		t.Fatalf("ListUserLists (not an error: the hidden list is simply absent): %d lists, err %v", len(ul.Lists), err)
	}
	if _, err := s.ReportableList(ctx, "viewer", id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ReportableList of a hidden list = %v, want ErrNotFound", err)
	}

	// The owner (ADR-0030 D3) still sees and edits it.
	o := e.viewerSvc()
	if g, err := o.GetList(ctx, "owner", id); err != nil || g.Header.ID != id {
		t.Fatalf("owner GetList: %+v %v", g, err)
	}
	if ul, err := o.ListUserLists(ctx, "owner", UserListsInput{OwnerID: "owner", PageSize: 20}); err != nil || len(ul.Lists) != 1 {
		t.Fatalf("owner ListUserLists: %d %v", len(ul.Lists), err)
	}
	if m, err := o.ListListMembers(ctx, "owner", id, 20, ""); err != nil || len(m.Items) != 1 {
		t.Fatalf("owner ListListMembers: %+v %v", m, err)
	}
	if _, err := o.Members(ctx, "owner", id); err != nil {
		t.Fatalf("owner Reader.Members: %v", err)
	}

	if _, err := e.repo.SetHidden(ctx, id, false, time.Now()); err != nil {
		t.Fatal(err)
	}
	if g, l, m, r := visible("viewer"); g != nil || l != nil || m != nil || r != nil {
		t.Fatalf("after the restore a non-owner sees: get=%v lists=%v members=%v reader=%v", g, l, m, r)
	}
}

// An owner's own writes never revert the hide: UpdateList (rename, privacy), AddMember and RemoveMember are field-level
// Updates that do not touch `hidden`.
func TestHideLever_Integration_OwnerWritesKeepItHidden(t *testing.T) {
	e := hideEnv(t)
	ctx := context.Background()
	v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket", IsPrivate: new(false)})
	if err != nil {
		t.Fatal(err)
	}
	id := v.Header.ID
	if _, err := e.repo.SetHidden(ctx, id, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	name := "Renamed"
	private := false
	if _, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(2), ListID: id, Name: &name, IsPrivate: &private}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.AddMember(ctx, "owner", key(3), id, "u2"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.RemoveMember(ctx, "owner", key(4), id, "u2"); err != nil {
		t.Fatal(err)
	}
	d, _ := e.doc(t, id)
	if d["hidden"] != true || d["name"] != "Renamed" {
		t.Fatalf("doc = %#v, want hidden=true and the rename", d)
	}
	if _, err := e.viewerSvc().GetList(ctx, "viewer", id); codeOf(err) != connect.CodeNotFound {
		t.Fatalf("a non-owner after the owner's writes: %v, want NOT_FOUND", err)
	}
}

// A report of a visible list returns the evidence; the owner's own list is ErrOwnList; reads: list 1, caller graph 1, owner
// profile 1, owner graph 1 on a cold instance.
func TestHideLever_Integration_ReportableListBudget(t *testing.T) {
	e := hideEnv(t)
	ctx := context.Background()
	v, err := e.svc.CreateList(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket", Description: "ODI", IsPrivate: new(false)})
	if err != nil {
		t.Fatal(err)
	}
	// A directory that charges the owner's profile too (chargingDirectory treats the owner as the free caller): free is the viewer.
	cold := e.viewerSvc()
	cold.d.Directory = readDirectory{profiles: e.profiles, free: "viewer"}
	cctx, c := budget.WithCounter(ctx)
	got, err := cold.ReportableList(cctx, "viewer", v.Header.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.OwnerUID != "owner" || got.OwnerHandle != "owner" || got.Name != "Cricket" || got.Description != "ODI" {
		t.Errorf("evidence = %+v", got)
	}
	if c.Reads() != 4 || c.Writes() != 0 {
		t.Errorf("reads=%d writes=%d, want 4 0", c.Reads(), c.Writes())
	}
	if _, err := e.viewerSvc().ReportableList(ctx, "owner", v.Header.ID); !errors.Is(err, ErrOwnList) {
		t.Errorf("own list = %v, want ErrOwnList", err)
	}
}
