package lists

import (
	"context"
	"reflect"
	"strconv"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func itemUIDs(items []graph.ListItem) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.User.UserID)
	}
	return out
}

func listIDs(vs []View) []string {
	out := make([]string, 0, len(vs))
	for _, v := range vs {
		out = append(out, v.Header.ID)
	}
	return out
}

// ---- ListUserLists ----

func TestListUserLists_Visibility(t *testing.T) {
	t.Parallel()
	pub, priv, hid := listN(1, testUID, "a", "b"), listN(2, testUID), listN(3, testUID)
	priv.IsPrivate, hid.Hidden = true, true
	pub2 := listN(4, testUID, "c")
	all := []List{pub, priv, hid, pub2}
	profiles := map[string]identity.Profile{"gone": {UserID: "gone", Status: identity.AccountStatusSuspended}}
	tests := []struct {
		name    string
		viewer  string
		in      UserListsInput
		snaps   map[string]graph.Snapshot
		want    []string
		wantErr bool
	}{
		{"own: all, private and hidden included", testUID, UserListsInput{}, nil, []string{pub.ID, priv.ID, hid.ID, pub2.ID}, false},
		{"own by explicit id", testUID, UserListsInput{OwnerID: testUID}, nil, []string{pub.ID, priv.ID, hid.ID, pub2.ID}, false},
		{"other: public, not hidden only", viewerUID, UserListsInput{OwnerID: testUID}, nil, []string{pub.ID, pub2.ID}, false},
		{"other blocks the viewer", viewerUID, UserListsInput{OwnerID: testUID}, map[string]graph.Snapshot{testUID: {Blocked: set(viewerUID)}}, nil, true},
		{"viewer's blockedBy names the owner", viewerUID, UserListsInput{OwnerID: testUID}, map[string]graph.Snapshot{viewerUID: {BlockedBy: set(testUID)}}, nil, true},
		{"owner blockedBy overflowed: no lists, no error", viewerUID, UserListsInput{OwnerID: testUID}, map[string]graph.Snapshot{testUID: {BlockedByOverflow: true}}, nil, false},
		{"owner not ACTIVE", viewerUID, UserListsInput{OwnerID: "gone"}, nil, nil, true},
		{"owner unknown", viewerUID, UserListsInput{OwnerID: "nobody"}, nil, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newReadEnv(profiles, tt.snaps, all...)
			got, err := e.svc.ListUserLists(context.Background(), tt.viewer, tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatal("want NOT_FOUND")
				}
				sameError(t, err, identity.ProfileNotFoundError()) // GetProfile's bytes
				if e.repo.readCalls() != 0 {
					t.Error("a refused owner must not reach the list query")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Lists)+len(tt.want) > 0 && !reflect.DeepEqual(listIDs(got.Lists), tt.want) {
				t.Errorf("lists = %v, want %v", listIDs(got.Lists), tt.want)
			}
			if got.NextPageToken != "" {
				t.Errorf("next token %q with 4 lists at the default page", got.NextPageToken)
			}
		})
	}
}

func TestListUserLists_Contains(t *testing.T) {
	t.Parallel()
	a, b := listN(1, testUID, "u1", "u2"), listN(2, testUID, "u3")
	b.IsPrivate = true
	e := newReadEnv(nil, nil, a, b)
	got, err := e.svc.ListUserLists(context.Background(), testUID, UserListsInput{ContainsUserID: "u3"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.ContainingIDs, []string{b.ID}) {
		t.Errorf("containing = %v, want [%s]", got.ContainingIDs, b.ID)
	}
	// empty when contains_user_id is ""
	if got, _ = e.svc.ListUserLists(context.Background(), testUID, UserListsInput{}); len(got.ContainingIDs) != 0 {
		t.Errorf("containing = %v without contains_user_id", got.ContainingIDs)
	}
	// another owner's lists: a membership oracle, refused before any read
	e2 := newReadEnv(nil, nil, a)
	for _, in := range []UserListsInput{{OwnerID: testUID, ContainsUserID: "u1"}, {ContainsUserID: "bad_uid"}, {OwnerID: "bad_uid"}} {
		_, err := e2.svc.ListUserLists(context.Background(), viewerUID, in)
		if codeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("%+v: err = %v, want INVALID_ARGUMENT", in, err)
		}
	}
	if e2.repo.readCalls() != 0 || len(e2.g.asked) != 0 {
		t.Error("validation must read nothing")
	}
}

func TestListUserLists_PagingAndTokens(t *testing.T) {
	t.Parallel()
	var ls []List
	for i := 1; i <= 5; i++ {
		ls = append(ls, listN(i, testUID))
	}
	e := newReadEnv(nil, nil, ls...)
	ctx := context.Background()
	var seen []string
	token := ""
	for pages := 0; pages < 10; pages++ {
		got, err := e.svc.ListUserLists(ctx, testUID, UserListsInput{PageSize: 2, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, listIDs(got.Lists)...)
		if token = got.NextPageToken; token == "" {
			break
		}
	}
	want := []string{ls[0].ID, ls[1].ID, ls[2].ID, ls[3].ID, ls[4].ID}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("paged = %v, want %v", seen, want)
	}
	// the look-ahead row is read but never returned: page 2 of size 2 asked for 3
	if q := e.repo.queries[0]; q.limit != 3 {
		t.Errorf("first query limit = %d, want page+1", q.limit)
	}

	first, _ := e.svc.ListUserLists(ctx, testUID, UserListsInput{PageSize: 2})
	before := e.repo.readCalls()
	bad := map[string]struct {
		viewer string
		in     UserListsInput
	}{
		"tampered":      {testUID, UserListsInput{PageToken: first.NextPageToken[:len(first.NextPageToken)-2] + "AA"}},
		"garbage":       {testUID, UserListsInput{PageToken: "not-a-token"}},
		"foreign owner": {testUID, UserListsInput{OwnerID: testUID, PageToken: "x"}},
	}
	for name, c := range bad {
		if _, err := e.svc.ListUserLists(ctx, c.viewer, c.in); codeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("%s: err = %v, want VALIDATION", name, err)
		}
	}
	// a token minted for the owner's own lists does not open for another viewer
	e2 := newReadEnv(nil, nil, ls...)
	if _, err := e2.svc.ListUserLists(ctx, viewerUID, UserListsInput{OwnerID: testUID, PageToken: first.NextPageToken}); codeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("foreign token: err = %v, want VALIDATION", err)
	}
	if e.repo.readCalls() != before || e2.repo.readCalls() != 0 {
		t.Error("a bad token must cost 0 repo reads")
	}
}

func TestListUserLists_MemberCountNetOfOwnerBlockers(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, map[string]graph.Snapshot{testUID: {BlockedBy: set("b")}}, listN(1, testUID, "a", "b"))
	got, err := e.svc.ListUserLists(context.Background(), viewerUID, UserListsInput{OwnerID: testUID})
	if err != nil {
		t.Fatal(err)
	}
	if got.Lists[0].Header.MemberCount != 1 {
		t.Errorf("count = %d, want 1", got.Lists[0].Header.MemberCount)
	}
	if own, _ := e.svc.ListUserLists(context.Background(), testUID, UserListsInput{}); own.Lists[0].Header.MemberCount != 2 {
		t.Errorf("owner count = %d, want the stored 2", own.Lists[0].Header.MemberCount)
	}
}

// ---- ListListMembers ----

func memberList(n int) List {
	m := make([]string, n)
	for i := range m {
		m[i] = "m" + strconv.Itoa(i+1) // m1 oldest ... mn newest
	}
	return pubList(m...)
}

func TestListListMembers_OrderAndRelationship(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{viewerUID: {Following: set("m3"), Requested: set("m2")}}
	e := newReadEnv(nil, snaps, memberList(3))
	for _, m := range []string{"m1", "m2", "m3"} {
		e.dir.profiles[m] = active(m, m == "m2")
	}
	got, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(itemUIDs(got.Items), []string{"m3", "m2", "m1"}) {
		t.Fatalf("order = %v, want newest added first", itemUIDs(got.Items))
	}
	if got.Items[0].Relationship.FollowState != graph.FollowStateFollowing || got.Items[1].Relationship.FollowState != graph.FollowStateRequested ||
		got.Items[2].Relationship.FollowState != graph.FollowStateNone {
		t.Errorf("relationships = %+v", got.Items)
	}
	if got.NextPageToken != "" {
		t.Errorf("next = %q", got.NextPageToken)
	}
}

// The block and status matrix of one page: every drop is silent, and each lands in its own counter.
func TestListListMembers_DropMatrix(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{
		testUID:   {BlockedBy: set("blocks-owner")},
		viewerUID: {BlockedBy: set("blocks-viewer"), Blocked: set("viewer-blocks"), Muted: set("viewer-mutes")},
	}
	members := []string{"keep", "blocks-owner", "blocks-viewer", "viewer-blocks", "viewer-mutes", "suspended", "no-profile"}
	for _, viewer := range []string{viewerUID, testUID} {
		sn := snaps
		if viewer == testUID { // the owner is the viewer: one graph, theirs
			sn = map[string]graph.Snapshot{testUID: {
				BlockedBy: set("blocks-owner", "blocks-viewer"), Blocked: set("viewer-blocks"), Muted: set("viewer-mutes"),
			}}
		}
		profs := map[string]identity.Profile{
			"suspended": {UserID: "suspended", Status: identity.AccountStatusSuspended},
		}
		for _, m := range members[:5] {
			profs[m] = active(m, false)
		}
		e := newReadEnv(profs, sn, pubList(members...))
		got, err := e.svc.ListListMembers(context.Background(), viewer, testListID, 50, "")
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(itemUIDs(got.Items), []string{"keep"}) {
			t.Errorf("%s: kept %v, want only keep", viewer, itemUIDs(got.Items))
		}
	}
}

// ADR-0030 D4: a member who blocks the owner is absent for everyone; one who blocks only the viewer is absent for that viewer only.
func TestListListMembers_BlockAcceptance(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{testUID: {BlockedBy: set("b-owner")}, viewerUID: {BlockedBy: set("b-viewer")}, "other": {}}
	profs := map[string]identity.Profile{"other": active("other", false)}
	for _, m := range []string{"b-owner", "b-viewer", "ok"} {
		profs[m] = active(m, false)
	}
	e := newReadEnv(profs, snaps, pubList("b-owner", "b-viewer", "ok"))
	for viewer, want := range map[string][]string{viewerUID: {"ok"}, "other": {"ok", "b-viewer"}, testUID: {"ok", "b-viewer"}} {
		got, err := e.svc.ListListMembers(context.Background(), viewer, testListID, 0, "")
		if err != nil {
			t.Fatalf("%s: %v", viewer, err)
		}
		if !reflect.DeepEqual(itemUIDs(got.Items), want) {
			t.Errorf("%s sees %v, want %v", viewer, itemUIDs(got.Items), want)
		}
	}
}

// A viewer whose own blockedBy overflowed can not rule a blocker out: only members they follow stay (the W4 fail-closed rule).
func TestListListMembers_ViewerOverflowKeepsFollowed(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{viewerUID: {BlockedByOverflow: true, Following: set("f")}}
	profs := map[string]identity.Profile{"f": active("f", false), "s": active("s", false)}
	e := newReadEnv(profs, snaps, pubList("s", "f"))
	got, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(itemUIDs(got.Items), []string{"f"}) {
		t.Errorf("kept %v, want [f]", itemUIDs(got.Items))
	}
}

func TestListListMembers_VisibilityAndTokenFailuresReadNothing(t *testing.T) {
	t.Parallel()
	want := missingErr(t)
	e := newReadEnv(nil, nil, List{ID: testListID, OwnerID: testUID, IsPrivate: true, MemberIDs: []string{"a"}})
	_, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, 0, "")
	sameError(t, err, want)

	pub := newReadEnv(nil, nil, memberList(5))
	pub.dir.profiles["m5"] = active("m5", false)
	first, err := pub.svc.ListListMembers(context.Background(), viewerUID, testListID, 1, "")
	if err != nil || first.NextPageToken == "" {
		t.Fatalf("first = %+v, %v", first, err)
	}
	fresh := newReadEnv(nil, nil, memberList(5))
	for name, c := range map[string]struct{ viewer, list, token string }{
		"tampered":     {viewerUID, testListID, first.NextPageToken[:len(first.NextPageToken)-2] + "AA"},
		"other viewer": {"other", testListID, first.NextPageToken},
		"other list":   {viewerUID, "0000000000000000043", first.NextPageToken},
		"garbage":      {viewerUID, testListID, "x"},
	} {
		if _, err := fresh.svc.ListListMembers(context.Background(), c.viewer, c.list, 1, c.token); codeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("%s: err = %v, want VALIDATION", name, err)
		}
	}
	if fresh.repo.readCalls() != 0 || len(fresh.g.asked) != 0 {
		t.Error("a bad token must read nothing")
	}
}

// Paging is by position from the newest end, resumed across an add and a remove between two pages without a skip or a repeat.
func TestListListMembers_PagingAcrossChanges(t *testing.T) {
	t.Parallel()
	setup := func() readEnv {
		e := newReadEnv(nil, nil, memberList(6)) // m6 newest
		for i := 1; i <= 8; i++ {
			e.dir.profiles["m"+strconv.Itoa(i)] = active("m"+strconv.Itoa(i), false)
		}
		return e
	}
	page := func(e readEnv, tok string) MembersPage {
		t.Helper()
		e.svc.cache = newDocCache(50) // a fresh read each page: the repository holds the truth
		p, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, 2, tok)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	mutate := func(e readEnv, fn func(*List)) {
		e.repo.mu.Lock()
		defer e.repo.mu.Unlock()
		l := e.repo.docs[testListID]
		fn(&l)
		e.repo.docs[testListID] = l
	}
	tests := []struct {
		name   string
		change func(*List)
		want   [][]string
	}{
		{"unchanged", func(*List) {}, [][]string{{"m6", "m5"}, {"m4", "m3"}, {"m2", "m1"}}},
		{"a new member lands above: no repeat", func(l *List) { l.MemberIDs = append(l.MemberIDs, "m7") }, [][]string{{"m6", "m5"}, {"m4", "m3"}, {"m2", "m1"}}},
		{"the next member is removed: nothing skipped", func(l *List) { l.MemberIDs = []string{"m1", "m2", "m3", "m5", "m6"} }, [][]string{{"m6", "m5"}, {"m3", "m2"}, {"m1"}}},
		{"the last shown member is removed", func(l *List) { l.MemberIDs = []string{"m1", "m2", "m3", "m4", "m6"} }, [][]string{{"m6", "m5"}, {"m4", "m3"}, {"m2", "m1"}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := setup()
			p1 := page(e, "")
			tt.change(&List{})
			mutate(e, tt.change)
			var got [][]string
			got = append(got, itemUIDs(p1.Items))
			tok := p1.NextPageToken
			for tok != "" && len(got) < 6 {
				p := page(e, tok)
				got = append(got, itemUIDs(p.Items))
				tok = p.NextPageToken
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("pages = %v, want %v", got, tt.want)
			}
		})
	}
}

// A page that loses rows to drops can be short while the token is set: the client keeps following it.
func TestListListMembers_ShortPageKeepsToken(t *testing.T) {
	t.Parallel()
	snaps := map[string]graph.Snapshot{testUID: {BlockedBy: set("m5", "m4")}}
	e := newReadEnv(nil, snaps, memberList(5))
	for i := 1; i <= 3; i++ {
		e.dir.profiles["m"+strconv.Itoa(i)] = active("m"+strconv.Itoa(i), false)
	}
	p, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, 2, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Items) != 0 || p.NextPageToken == "" {
		t.Fatalf("page = %+v, want empty with a token", p)
	}
	p, err = e.svc.ListListMembers(context.Background(), viewerUID, testListID, 2, p.NextPageToken)
	if err != nil || !reflect.DeepEqual(itemUIDs(p.Items), []string{"m3", "m2"}) {
		t.Fatalf("second = %v, %v", itemUIDs(p.Items), err)
	}
}
