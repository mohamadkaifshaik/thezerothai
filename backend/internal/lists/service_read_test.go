package lists

import (
	"context"
	"errors"
	"maps"
	"reflect"
	"strconv"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const viewerUID = "viewer-1"

var readKey = []byte("0123456789abcdef0123456789abcdef")

type readEnv struct {
	svc  *service
	repo *fakeRepo
	g    *fakeGraph
	dir  fakeDirectory
}

// newReadEnv builds a service over fakes. The owner (testUID) and the viewer are ACTIVE unless profiles says otherwise.
// profiles is copied, never written: parallel subtests share the caller's map (a write here was a data race under -race).
func newReadEnv(in map[string]identity.Profile, snaps map[string]graph.Snapshot, ls ...List) readEnv {
	profiles := maps.Clone(in)
	if profiles == nil {
		profiles = map[string]identity.Profile{}
	}
	for _, u := range []string{testUID, viewerUID} {
		if _, ok := profiles[u]; !ok {
			profiles[u] = active(u, false)
		}
	}
	repo := &fakeRepo{}
	repo.seed(ls...)
	g := &fakeGraph{snaps: snaps}
	dir := fakeDirectory{profiles: profiles}
	s := New(Deps{
		Repo: repo, Directory: dir, IDs: fixedIDs{}, Graph: g, CursorKey: readKey, Now: func() time.Time { return testNow },
		Limits: Limits{MaxPerUser: 20, CacheEntries: 50, MaxMembers: 150},
	}).(*service)
	return readEnv{svc: s, repo: repo, g: g, dir: dir}
}

func pubList(members ...string) List {
	return List{ID: testListID, OwnerID: testUID, Name: "Cricket", Description: "ODI", MemberIDs: members}
}

// sameError reports whether two errors are byte-identical to a client: the same Connect code, reason, message and metadata.
func sameError(t *testing.T, got, want error) {
	t.Helper()
	var a, b *apierr.Error
	if !errors.As(got, &a) || !errors.As(want, &b) {
		t.Fatalf("not apierr errors: got %v, want %v", got, want)
	}
	if a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message || !reflect.DeepEqual(a.Metadata, b.Metadata) {
		t.Fatalf("error differs: got %+v, want %+v", a, b)
	}
}

// missingErr is what a list id that never existed answers: the reference for byte-identity.
func missingErr(t *testing.T) error {
	t.Helper()
	e := newReadEnv(nil, nil)
	_, err := e.svc.GetList(context.Background(), viewerUID, testListID)
	if codeOf(err) != connect.CodeNotFound {
		t.Fatalf("missing list = %v, want NOT_FOUND", err)
	}
	return err
}

// ADR-0030 D3: one byte-identical NOT_FOUND for every cause, and the owner always sees the list.
func TestGetList_D3Matrix(t *testing.T) {
	t.Parallel()
	want := missingErr(t)
	tests := []struct {
		name     string
		list     List
		profiles map[string]identity.Profile
		snaps    map[string]graph.Snapshot
		viewer   string
		visible  bool
		graphs   int // snapshots read
	}{
		{"owner sees a private list", List{ID: testListID, OwnerID: testUID, IsPrivate: true}, nil, nil, testUID, true, 0},
		{"owner sees a hidden list", List{ID: testListID, OwnerID: testUID, Hidden: true}, nil, nil, testUID, true, 0},
		{"public list", pubList(), nil, nil, viewerUID, true, 2},
		{"private list, other viewer", List{ID: testListID, OwnerID: testUID, IsPrivate: true}, nil, nil, viewerUID, false, 0},
		{"hidden list, other viewer", List{ID: testListID, OwnerID: testUID, Hidden: true}, nil, nil, viewerUID, false, 0},
		{"viewer's blockedBy names the owner", pubList(), nil, map[string]graph.Snapshot{viewerUID: {BlockedBy: set(testUID)}}, viewerUID, false, 1},
		{"owner blocks the viewer (viewer blockedBy overflowed)", pubList(), nil,
			map[string]graph.Snapshot{testUID: {Blocked: set(viewerUID)}}, viewerUID, false, 2},
		{"owner not ACTIVE", pubList(), map[string]identity.Profile{testUID: {UserID: testUID, Status: identity.AccountStatusSuspended}}, nil, viewerUID, false, 1},
		{"owner has no profile", pubList(), map[string]identity.Profile{testUID: {}}, nil, viewerUID, false, 1},
		{"owner blockedBy overflowed", pubList(), nil, map[string]graph.Snapshot{testUID: {BlockedByOverflow: true}}, viewerUID, false, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newReadEnv(tt.profiles, tt.snaps, tt.list)
			if tt.name == "owner has no profile" {
				delete(e.dir.profiles, testUID) // absent from the directory
			}
			v, err := e.svc.GetList(context.Background(), tt.viewer, testListID)
			if len(e.g.asked) != tt.graphs {
				t.Errorf("graph snapshots read = %v, want %d", e.g.asked, tt.graphs)
			}
			if tt.visible {
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				if v.Header.ID != testListID || v.Owner.UserID != testUID {
					t.Errorf("view = %+v", v)
				}
				return
			}
			if err == nil {
				t.Fatalf("visible, want NOT_FOUND")
			}
			sameError(t, err, want)
		})
	}
}

func TestGetList_ValidationReadsNothing(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, nil, pubList())
	for _, id := range []string{"", "42", "000000000000000004x", "00000000000000000420"} {
		_, err := e.svc.GetList(context.Background(), viewerUID, id)
		if codeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("id %q: err = %v, want INVALID_ARGUMENT", id, err)
		}
	}
	if e.repo.readCalls() != 0 || len(e.g.asked) != 0 {
		t.Errorf("reads = %d repo, %v graph; want none", e.repo.readCalls(), e.g.asked)
	}
}

// The doc cache also holds private lists (Create always puts): a hit must never widen who may see the list, and a hit costs no
// repository read.
func TestGetList_CacheNeverWidensVisibility(t *testing.T) {
	t.Parallel()
	want := missingErr(t)
	e := newReadEnv(nil, nil)
	e.svc.cache.put(List{ID: testListID, OwnerID: testUID, IsPrivate: true, MemberIDs: []string{"a"}})
	if _, err := e.svc.GetList(context.Background(), viewerUID, testListID); err == nil {
		t.Fatal("private cached list served to a non-owner")
	} else {
		sameError(t, err, want)
	}
	if _, err := e.svc.GetList(context.Background(), testUID, testListID); err != nil {
		t.Fatalf("owner: %v", err)
	}
	if e.repo.readCalls() != 0 {
		t.Errorf("repo reads = %d, want 0 (cache hits)", e.repo.readCalls())
	}
	// a miss fills the cache; the second call reads nothing
	e2 := newReadEnv(nil, nil, pubList("a"))
	for range 2 {
		if _, err := e2.svc.GetList(context.Background(), viewerUID, testListID); err != nil {
			t.Fatal(err)
		}
	}
	if len(e2.repo.gets) != 1 {
		t.Errorf("repo gets = %d, want 1", len(e2.repo.gets))
	}
}

// A cached copy is a copy: a caller can not change the stored member slice through what a read returned.
func TestMembers_ReturnsACopy(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, nil, pubList("a", "b"))
	m, err := e.svc.Members(context.Background(), viewerUID, testListID)
	if err != nil {
		t.Fatal(err)
	}
	m.MemberIDs[0] = "zzz"
	l, _ := e.svc.cache.get(testListID)
	if l.MemberIDs[0] != "a" {
		t.Fatalf("cache changed through the returned slice: %v", l.MemberIDs)
	}
}

func TestGetList_MemberCount(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{testUID: {BlockedBy: set("b")}}
	e := newReadEnv(nil, snaps, pubList("a", "b", "c"))
	v, err := e.svc.GetList(context.Background(), viewerUID, testListID)
	if err != nil {
		t.Fatal(err)
	}
	if v.Header.MemberCount != 2 {
		t.Errorf("non-owner count = %d, want 2 (net of the member who blocks the owner)", v.Header.MemberCount)
	}
	o, err := e.svc.GetList(context.Background(), testUID, testListID)
	if err != nil {
		t.Fatal(err)
	}
	if o.Header.MemberCount != 3 || o.PinnedByViewer {
		t.Errorf("owner view = %+v, want stored count 3 and pinned_by_viewer false (W5-9 seam)", o)
	}
}

// Reader.Members: members who block the owner are gone for everyone, the owner included; the other drops are the caller's.
func TestMembers_OwnerLevelDrop(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{
		testUID:   {BlockedBy: set("blocker")},
		viewerUID: {Blocked: set("viewer-blocked")}, // per-viewer drops are NOT applied by Members
	}
	for _, viewer := range []string{viewerUID, testUID} {
		e := newReadEnv(nil, snaps, pubList("a", "blocker", "viewer-blocked"))
		m, err := e.svc.Members(context.Background(), viewer, testListID)
		if err != nil {
			t.Fatalf("%s: %v", viewer, err)
		}
		if !reflect.DeepEqual(m.MemberIDs, []string{"a", "viewer-blocked"}) || m.Header.MemberCount != 2 || m.Owner.UserID != testUID {
			t.Errorf("%s: members = %+v", viewer, m)
		}
	}
	// a private list is NOT_FOUND to the timeline of anyone else
	e := newReadEnv(nil, nil, List{ID: testListID, OwnerID: testUID, IsPrivate: true, MemberIDs: []string{"a"}})
	if _, err := e.svc.Members(context.Background(), viewerUID, testListID); !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want ErrNotFound", err)
	}
}

func TestOwnedBy_UsesTheCap(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, nil, pubList())
	got, err := e.svc.OwnedBy(context.Background(), testUID)
	if err != nil || len(got) != 1 {
		t.Fatalf("OwnedBy = %v, %v", got, err)
	}
	if q := e.repo.queries[0]; q.owner != testUID || q.limit != 20 || q.after != "" {
		t.Errorf("query = %+v, want owner, limit 20 (LISTS_MAX_PER_USER)", q)
	}
}

func listN(i int, owner string, members ...string) List {
	return List{ID: "00000000000000001" + strconv.Itoa(10+i), OwnerID: owner, Name: "L" + strconv.Itoa(i), MemberIDs: members}
}

// codeOf is the Connect code the handler boundary will send for a service error.
func codeOf(err error) connect.Code {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.Code
	}
	return connect.CodeUnknown
}
