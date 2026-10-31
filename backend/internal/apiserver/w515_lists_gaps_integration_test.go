//go:build integration

package apiserver

// W5-15: the gaps the W5-4 to W5-9 tests left against the ticket, over the real Build chain on the emulators (so the account
// status interceptor, the flag guards, the wire errors and the request-line budgets are the production ones):
//   - SetHomeTabs is gated by FEATURE_LISTS at 1 read (the interceptor's) and 0 writes;
//   - a pinned list that later turns private, is deleted or is hidden dangles: GetMe still returns the tab at +0 reads, the list
//     answers the one NOT_FOUND, and the tab can still be moved or removed but never pinned afresh;
//   - GetListTimeline page size (0 -> 20, 500 -> 50), the opaque cursor walk, and a list made private between two pages;
//   - the block matrix with real accounts (the viewer blocks a member, a member blocks the viewer);
//   - the quota names list_creates and list_adds on the wire at the daily cap.

import (
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const rpcSetHomeTabs = timelinev1connect.TimelineServiceSetHomeTabsProcedure

func (e *ltChain) setTabs(u ltUser, label string, ids ...string) (*timelinev1.SetHomeTabsResponse, error) {
	req := &timelinev1.SetHomeTabsRequest{IdempotencyKey: "w515-" + label + "-0123456789"}
	for _, id := range ids {
		req.Tabs = append(req.Tabs, &commonv1.HomeTab{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: id})
	}
	r, err := e.timeline.SetHomeTabs(context.Background(), authed(u.token, req))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *ltChain) tabs(t *testing.T, u ltUser) []string {
	t.Helper()
	r, err := e.identity.GetMe(context.Background(), authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	var out []string
	for _, tab := range r.Msg.GetHomeTabs() {
		out = append(out, tab.GetId()+":"+tab.GetTitle())
	}
	return out
}

// createList makes a real list through the RPC (the instance cache is filled from the write).
func (e *ltChain) createList(t *testing.T, u ltUser, name string, private bool) string {
	t.Helper()
	r, err := e.lists.CreateList(context.Background(), authed(u.token, &listsv1.CreateListRequest{IdempotencyKey: contractKey("w515-create"), Name: name, IsPrivate: &private}))
	if err != nil {
		t.Fatalf("CreateList %s: %v", name, err)
	}
	return r.Msg.GetList().GetListId()
}

// errSig is what a client sees of an error: code, message, reason and the marshalled detail.
func errSig(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		t.Fatal("want an error")
	}
	var ce *connect.Error
	if !asConnectErr(err, &ce) {
		t.Fatalf("not a connect error: %v", err)
	}
	d := wireError(t, err, ce.Code())
	return fmt.Sprintf("%v|%s|%v|%s", ce.Code(), ce.Message(), d.GetReason(), marshalDet(t, d))
}

func missingListID() string { return fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1) }

// SetHomeTabs with a LIST tab while lists is off, or the caller is not on the allowlist, is FEATURE_DISABLED feature=lists
// after only the interceptor's read: no idempotency, users or lists read, nothing written.
func TestW515_SetHomeTabsIsGatedByTheListsFlag(t *testing.T) {
	setup := newLTChain(t, nil)
	owner, viewer := setup.user(t), setup.user(t)
	list := setup.createList(t, owner, "Gate", false)
	cases := []struct {
		name   string
		mutate func(*config.Config)
	}{
		{"off", func(c *config.Config) { c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Off} }},
		{"allowlist without the caller", func(c *config.Config) {
			c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Allowlist, Allowlist: map[string]struct{}{owner.uid: {}}}
		}},
		{"percent 0", func(c *config.Config) { c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Percent, Percent: 0} }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newLTChain(t, tc.mutate)
			_, err := c.setTabs(viewer, "gate", list)
			d := wireError(t, err, connect.CodeFailedPrecondition)
			if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "lists" {
				t.Fatalf("detail = %v", d)
			}
			budgettest.Assert(t, "SetHomeTabs refused", c.lineBudget(t, rpcSetHomeTabs), budgettest.Budget{Reads: 1, Writes: 0})
			// And the request left nothing behind: with lists on the same caller has no tabs.
			on := newLTChain(t, nil)
			if got := on.tabs(t, viewer); len(got) != 0 {
				t.Fatalf("tabs after a refused call = %v", got)
			}
		})
	}
}

// ADR-0030 D6: a tab already stored is kept without a re-read, so a pin that became unreadable can still be reordered or
// removed; it is returned by GetMe at +0 reads; the list answers the one NOT_FOUND; a fresh pin of it is VALIDATION `tabs`.
func TestW515_PinnedListsThatStopBeingReadable(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer := c.user(t), c.user(t)
	toPrivate := c.createList(t, owner, "ToPrivate", false)
	toDelete := c.createList(t, owner, "ToDelete", false)
	toRename := c.createList(t, owner, "ToRename", false)
	if _, err := c.setTabs(viewer, "pin", toPrivate, toDelete, toRename); err != nil {
		t.Fatalf("SetHomeTabs: %v", err)
	}
	want := []string{toPrivate + ":", toDelete + ":", toRename + ":"} // a foreign list is never titled on the viewer's doc (D6)
	if got := c.tabs(t, viewer); !slices.Equal(got, want) {
		t.Fatalf("tabs = %v, want %v", got, want)
	}
	// The cold GetMe of an account with no tabs is the baseline: a dangling tab must add nothing to it.
	bare := c.user(t)
	b0 := newLTChain(t, nil)
	b0.tabs(t, bare)
	baseline := b0.lineBudget(t, rpcGetMe).Reads()

	private := true
	if _, err := c.lists.UpdateList(context.Background(), authed(owner.token, &listsv1.UpdateListRequest{IdempotencyKey: contractKey("w515-priv"), ListId: toPrivate, IsPrivate: &private})); err != nil {
		t.Fatalf("UpdateList private: %v", err)
	}
	if _, err := c.lists.DeleteList(context.Background(), authed(owner.token, &listsv1.DeleteListRequest{IdempotencyKey: contractKey("w515-del"), ListId: toDelete})); err != nil {
		t.Fatalf("DeleteList: %v", err)
	}
	renamed := "Renamed"
	if _, err := c.lists.UpdateList(context.Background(), authed(owner.token, &listsv1.UpdateListRequest{IdempotencyKey: contractKey("w515-ren"), ListId: toRename, Name: &renamed})); err != nil {
		t.Fatalf("UpdateList rename: %v", err)
	}

	// GetMe: all three are still returned, titles untouched, and the read count did not move (+0).
	cold := newLTChain(t, nil) // a cold instance reads the user document fresh, like the baseline
	if got := cold.tabs(t, viewer); !slices.Equal(got, want) {
		t.Fatalf("tabs after the owner's changes = %v, want %v (dangling tabs stay until the next SetHomeTabs)", got, want)
	}
	if r := cold.lineBudget(t, rpcGetMe).Reads(); r != baseline {
		t.Errorf("GetMe reads = %d, want %d (+0 for dangling tabs)", r, baseline)
	}

	// The unreadable ones answer exactly like a list that never existed, on both RPCs; the renamed one still works.
	missing := missingListID()
	_, err := c.listTimeline(viewer, missing, 20, "", "")
	wantSig := errSig(t, err)
	for name, id := range map[string]string{"made private": toPrivate, "deleted": toDelete} {
		_, terr := c.listTimeline(viewer, id, 20, "", "")
		if got := errSig(t, terr); got != wantSig {
			t.Errorf("%s: GetListTimeline %q differs from a missing id %q", name, got, wantSig)
		}
		_, gerr := c.lists.GetList(context.Background(), authed(viewer.token, &listsv1.GetListRequest{ListId: id}))
		if got := errSig(t, gerr); got != wantSig {
			t.Errorf("%s: GetList %q differs from a missing id %q", name, got, wantSig)
		}
	}
	if r, err := c.listTimeline(viewer, toRename, 20, "", ""); err != nil || r.GetList().GetName() != "Renamed" {
		t.Fatalf("renamed list: err=%v resp=%v", err, r)
	}
	if _, err := c.listTimeline(owner, toPrivate, 20, "", ""); err != nil {
		t.Fatalf("the owner still reads a list made private: %v", err)
	}

	// Moving and removing stored tabs needs no read of the dangling lists: interceptor + idempotency + users, 2 writes.
	moved, err := c.setTabs(viewer, "reorder", toRename, toDelete, toPrivate)
	if err != nil {
		t.Fatalf("reorder with dangling tabs: %v", err)
	}
	if len(moved.GetTabs()) != 3 || moved.GetTabs()[0].GetId() != toRename || moved.GetTabs()[2].GetId() != toPrivate {
		t.Fatalf("reordered = %v", moved.GetTabs())
	}
	budgettest.Assert(t, "SetHomeTabs reorder of stored tabs", c.lineBudget(t, rpcSetHomeTabs), budgettest.Budget{Reads: 3, Writes: 2}) // interceptor, idempotency, users: a re-read of a dangling list would make it 5
	if _, err := c.setTabs(viewer, "drop", toRename); err != nil {
		t.Fatalf("removing dangling tabs: %v", err)
	}
	if got := c.tabs(t, viewer); !slices.Equal(got, []string{toRename + ":"}) {
		t.Fatalf("tabs after removal = %v", got)
	}

	// A fresh pin of either is VALIDATION `tabs`, the same answer as a list that does not exist.
	_, merr := c.setTabs(viewer, "missing", missing)
	wantVal := errSig(t, merr)
	for name, id := range map[string]string{"private": toPrivate, "deleted": toDelete} {
		_, err := c.setTabs(viewer, "repin"+name, toRename, id)
		w320Reason(t, name, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "tabs")
		if got := errSig(t, err); got != wantVal {
			t.Errorf("%s: %q differs from a missing list %q", name, got, wantVal)
		}
	}
}

// A platform-hidden list (W5-29) dangles the same way: pinned while public, then hidden in Firestore, read by a fresh instance.
func TestW515_PinnedListThatBecameHidden(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer := c.user(t), c.user(t)
	list, _ := seedList(t, c.fs, owner.uid, false, memberNames(2))
	if _, err := c.setTabs(viewer, "pinhid", list); err != nil {
		t.Fatalf("pin: %v", err)
	}
	if _, err := c.fs.Collection("lists").Doc(list).Update(context.Background(), []firestore.Update{{Path: "hidden", Value: true}}); err != nil {
		t.Fatal(err)
	}
	fresh := newLTChain(t, nil) // another instance, cold list cache: the 60 s bound of D11 does not apply to it
	if got := fresh.tabs(t, viewer); !slices.Equal(got, []string{list + ":"}) {
		t.Fatalf("GetMe tabs = %v, want the hidden list still returned", got)
	}
	_, err := fresh.listTimeline(viewer, list, 20, "", "")
	_, merr := fresh.listTimeline(viewer, missingListID(), 20, "", "")
	if errSig(t, err) != errSig(t, merr) {
		t.Errorf("hidden list %q differs from a missing id %q", errSig(t, err), errSig(t, merr))
	}
	if _, err := fresh.listTimeline(owner, list, 20, "", ""); err != nil {
		t.Fatalf("the owner reads a hidden list: %v", err)
	}
	hid2, _ := seedList(t, c.fs, owner.uid, false, memberNames(1))
	if _, err := c.fs.Collection("lists").Doc(hid2).Update(context.Background(), []firestore.Update{{Path: "hidden", Value: true}}); err != nil {
		t.Fatal(err)
	}
	_, err = fresh.setTabs(viewer, "pinhid2", list, hid2)
	w320Reason(t, "pin a hidden list", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "tabs")
}

// The worst SetHomeTabs shape of the ADR table: 5 lists of 5 distinct owners on a cold instance (19 reads: interceptor,
// idempotency, users, 5 lists, caller graph, 5 owner profiles and 5 owner graphs), 2 writes.
func TestW515_SetHomeTabsWorstCase(t *testing.T) {
	setup := newLTChain(t, nil)
	viewer := setup.user(t)
	var ids []string
	for range 5 {
		o := setup.user(t)
		ids = append(ids, setup.createList(t, o, "Five", false))
	}
	cold := newLTChain(t, nil)
	if _, err := cold.setTabs(viewer, "worst", ids...); err != nil {
		t.Fatalf("SetHomeTabs: %v", err)
	}
	budgettest.Assert(t, "SetHomeTabs, 5 foreign lists, cold", cold.lineBudget(t, rpcSetHomeTabs), budgettest.Budget{Reads: 19, Writes: 2})
	if got := cold.tabs(t, viewer); len(got) != 5 {
		t.Fatalf("tabs = %v", got)
	}
	// The sixth is LIMIT_REACHED limit=home_tabs after only the interceptor's read.
	_, err := cold.setTabs(viewer, "sixth", append(slices.Clone(ids), missingListID())...)
	d := wireError(t, err, connect.CodeFailedPrecondition)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED || d.GetMetadata()["limit"] != "home_tabs" {
		t.Fatalf("detail = %v", d)
	}
	budgettest.Assert(t, "SetHomeTabs sixth tab", cold.lineBudget(t, rpcSetHomeTabs), budgettest.Budget{Reads: 1, Writes: 0})
}

// Page size 0 -> 20 and 500 -> 50 on a 60-member list; the opaque cursor walks the rest with no repeat; a list made private
// through the real UpdateList between two pages answers the next page with the one NOT_FOUND.
func TestW515_ListTimelinePagingAndPrivateBetweenPages(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer := c.user(t), c.user(t)
	list, all := seedList(t, c.fs, owner.uid, false, memberNames(60))

	for _, tc := range []struct {
		size int32
		want int
	}{{0, 20}, {-5, 20}, {51, 50}, {500, 50}} {
		r, err := c.listTimeline(viewer, list, tc.size, "", "")
		if err != nil || len(r.GetPosts()) != tc.want {
			t.Fatalf("page_size %d: %d posts (err %v), want %d", tc.size, len(r.GetPosts()), err, tc.want)
		}
		if r.GetNextPageToken() == "" {
			t.Errorf("page_size %d: 60 posts and a page of %d must carry a next_page_token", tc.size, tc.want)
		}
	}
	first, err := c.listTimeline(viewer, list, 50, "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.listTimeline(viewer, list, 50, "", first.GetNextPageToken())
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	walked := append(idsOf(first), idsOf(second)...)
	if second.GetNextPageToken() != "" || len(walked) != 60 || !slices.Equal(walked, all) {
		t.Fatalf("walk: %d posts, next=%q; want the 60 seeded posts newest first and no more pages", len(walked), second.GetNextPageToken())
	}

	// Private between pages.
	p1, err := c.listTimeline(viewer, list, 20, "", "")
	if err != nil || p1.GetNextPageToken() == "" {
		t.Fatalf("page 1: %v", err)
	}
	private := true
	if _, err := c.lists.UpdateList(context.Background(), authed(owner.token, &listsv1.UpdateListRequest{IdempotencyKey: contractKey("w515-mid"), ListId: list, IsPrivate: &private})); err != nil {
		t.Fatalf("UpdateList: %v", err)
	}
	_, perr := c.listTimeline(viewer, list, 20, "", p1.GetNextPageToken())
	_, merr := c.listTimeline(viewer, missingListID(), 20, "", "")
	if errSig(t, perr) != errSig(t, merr) {
		t.Errorf("page 2 of a list made private: %q, want the missing-id answer %q", errSig(t, perr), errSig(t, merr))
	}
	// A refresh with the since token is refused the same way.
	_, serr := c.listTimeline(viewer, list, 20, p1.GetSinceToken(), "")
	if errSig(t, serr) != errSig(t, merr) {
		t.Errorf("refresh of a list made private: %q, want %q", errSig(t, serr), errSig(t, merr))
	}
}

// With real accounts and the real graph: a member the viewer blocks and a member who blocks the viewer are both absent from
// that viewer's timeline and member page, present for an unaffected viewer and for the owner.
func TestW515_ListTimelineAndMembersDropBlockedBothWays(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer, bystander := c.user(t), c.user(t), c.user(t)
	m1, m2, m3 := c.user(t), c.user(t), c.user(t) // m1: the viewer blocks; m2 blocks the viewer; m3: untouched
	list, ids := seedList(t, c.fs, owner.uid, false, []string{m1.uid, m2.uid, m3.uid})
	if _, err := c.graph.Block(context.Background(), authed(viewer.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w515-b1"), UserId: m1.uid})); err != nil {
		t.Fatalf("viewer blocks m1: %v", err)
	}
	if _, err := c.graph.Block(context.Background(), authed(m2.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w515-b2"), UserId: viewer.uid})); err != nil {
		t.Fatalf("m2 blocks viewer: %v", err)
	}
	fresh := newLTChain(t, nil) // cold graph caches

	members := func(u ltUser) []string {
		t.Helper()
		r, err := fresh.lists.ListListMembers(context.Background(), authed(u.token, &listsv1.ListListMembersRequest{ListId: list}))
		if err != nil {
			t.Fatalf("ListListMembers: %v", err)
		}
		var out []string
		for _, it := range r.Msg.GetUsers() {
			out = append(out, it.GetUser().GetUserId())
		}
		slices.Sort(out)
		return out
	}
	posts := func(u ltUser) []string {
		t.Helper()
		r, err := fresh.listTimeline(u, list, 20, "", "")
		if err != nil {
			t.Fatalf("GetListTimeline: %v", err)
		}
		return idsOf(r)
	}
	if got := posts(viewer); !slices.Equal(got, []string{ids[2]}) {
		t.Errorf("viewer's list timeline = %v, want only m3's post %s", got, ids[2])
	}
	if got := members(viewer); !slices.Equal(got, []string{m3.uid}) {
		t.Errorf("viewer's member page = %v, want only %s", got, m3.uid)
	}
	for name, u := range map[string]ltUser{"bystander": bystander, "owner": owner} {
		if got := posts(u); !slices.Equal(got, ids) {
			t.Errorf("%s's list timeline = %v, want all three %v", name, got, ids)
		}
		want := []string{m1.uid, m2.uid, m3.uid}
		slices.Sort(want)
		if got := members(u); !slices.Equal(got, want) {
			t.Errorf("%s's member page = %v, want %v", name, got, want)
		}
	}
}

// The quota names on the wire: QUOTA_EXCEEDED carries the snake_case names the proto documents, at exactly the daily caps
// (10 creates; 300 adds), with nothing written by the refusal.
func TestW515_QuotaNamesAtTheDailyCaps(t *testing.T) {
	c := newLTChain(t, nil)
	u, target := c.user(t), c.user(t)
	var last string
	for i := range 10 {
		last = c.createList(t, u, fmt.Sprintf("List %d", i), true)
	}
	private := true
	_, err := c.lists.CreateList(context.Background(), authed(u.token, &listsv1.CreateListRequest{IdempotencyKey: contractKey("w515-over"), Name: "Eleventh", IsPrivate: &private}))
	d := wireError(t, err, connect.CodeResourceExhausted)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || d.GetMetadata()["quota"] != "list_creates" {
		t.Fatalf("11th create: %v", d)
	}
	budgettest.Assert(t, "CreateList over quota", c.lineBudget(t, "/dzeroth.lists.v1.ListService/CreateList"), budgettest.Budget{Reads: 4, Writes: 0})

	// 300 adds recorded today: the 301st is refused; seeding the counter avoids 300 RPCs.
	if _, err := c.fs.Collection("quotas").Doc(u.uid).Set(context.Background(), quota.Record{Day: quota.Today(), ListCreates: 10, ListAdds: 300}); err != nil {
		t.Fatal(err)
	}
	fresh := newLTChain(t, nil)
	_, err = fresh.lists.AddListMember(context.Background(), authed(u.token, &listsv1.AddListMemberRequest{IdempotencyKey: contractKey("w515-add"), ListId: last, UserId: target.uid}))
	d = wireError(t, err, connect.CodeResourceExhausted)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || d.GetMetadata()["quota"] != "list_adds" {
		t.Fatalf("301st add: %v", d)
	}
	budgettest.Assert(t, "AddListMember over quota", fresh.lineBudget(t, "/dzeroth.lists.v1.ListService/AddListMember"), budgettest.Budget{Reads: 6, Writes: 0})
}

// DEGRADED_MODE=readonly (W5-4 acceptance, the interceptor derives "mutating" from each RPC's idempotency level): the five list
// writes and SetHomeTabs are refused with UNAVAILABLE before any read; the four read RPCs and GetMe still answer, write-free.
func TestW515_ReadonlyDegradedModeRefusesWritesAndKeepsReads(t *testing.T) {
	setup := newLTChain(t, nil)
	owner, viewer := setup.user(t), setup.user(t)
	list, _ := seedList(t, setup.fs, owner.uid, false, memberNames(2))
	ro := newLTChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })
	ctx := context.Background()
	name := "x"
	writes := map[string]func() error{
		"CreateList": func() error {
			_, err := ro.lists.CreateList(ctx, authed(owner.token, &listsv1.CreateListRequest{IdempotencyKey: contractKey("ro1"), Name: "RO"}))
			return err
		},
		"UpdateList": func() error {
			_, err := ro.lists.UpdateList(ctx, authed(owner.token, &listsv1.UpdateListRequest{IdempotencyKey: contractKey("ro2"), ListId: list, Name: &name}))
			return err
		},
		"DeleteList": func() error {
			_, err := ro.lists.DeleteList(ctx, authed(owner.token, &listsv1.DeleteListRequest{IdempotencyKey: contractKey("ro3"), ListId: list}))
			return err
		},
		"AddListMember": func() error {
			_, err := ro.lists.AddListMember(ctx, authed(owner.token, &listsv1.AddListMemberRequest{IdempotencyKey: contractKey("ro4"), ListId: list, UserId: viewer.uid}))
			return err
		},
		"RemoveListMember": func() error {
			_, err := ro.lists.RemoveListMember(ctx, authed(owner.token, &listsv1.RemoveListMemberRequest{IdempotencyKey: contractKey("ro5"), ListId: list, UserId: viewer.uid}))
			return err
		},
		"SetHomeTabs": func() error { _, err := ro.setTabs(viewer, "ro6", list); return err },
	}
	for rpc, call := range writes {
		if err := call(); connect.CodeOf(err) != connect.CodeUnavailable {
			t.Errorf("%s under readonly: %v, want UNAVAILABLE", rpc, err)
		}
	}
	reads := map[string]func() error{
		"GetList": func() error {
			_, err := ro.lists.GetList(ctx, authed(viewer.token, &listsv1.GetListRequest{ListId: list}))
			return err
		},
		"ListUserLists": func() error {
			_, err := ro.lists.ListUserLists(ctx, authed(viewer.token, &listsv1.ListUserListsRequest{OwnerId: owner.uid}))
			return err
		},
		"ListListMembers": func() error {
			_, err := ro.lists.ListListMembers(ctx, authed(viewer.token, &listsv1.ListListMembersRequest{ListId: list}))
			return err
		},
		"GetListTimeline": func() error { _, err := ro.listTimeline(viewer, list, 20, "", ""); return err },
	}
	for rpc, call := range reads {
		if err := call(); err != nil {
			t.Errorf("%s under readonly: %v, want success", rpc, err)
			continue
		}
		proc := "/dzeroth.lists.v1.ListService/" + rpc
		if rpc == "GetListTimeline" {
			proc = rpcGetListTimeline
		}
		if w := ro.lineBudget(t, proc).Writes(); w != 0 {
			t.Errorf("%s wrote %d documents under readonly", rpc, w)
		}
	}
}

// Token binding through the chain (ADR-0030 D5): a UserTimeline token and another viewer's list token are VALIDATION at the
// interceptor's read only; the request never reaches the list or the posts.
func TestW515_ListTokenBindingAcrossFeedsAndViewers(t *testing.T) {
	c := newLTChain(t, nil)
	owner, a, b, m := c.user(t), c.user(t), c.user(t), c.user(t)
	list, _ := seedList(t, c.fs, owner.uid, false, []string{m.uid})
	for range 25 { // a second page on the member's own timeline
		seedPostBy(t, c.fs, m.uid)
	}
	ut, err := c.timeline.GetUserTimeline(context.Background(), authed(a.token, &timelinev1.GetUserTimelineRequest{UserId: m.uid, PageSize: 5}))
	if err != nil || ut.Msg.GetSinceToken() == "" || ut.Msg.GetNextPageToken() == "" {
		t.Fatalf("user timeline setup: %v", err)
	}
	mine, err := c.listTimeline(a, list, 1, "", "")
	if err != nil || mine.GetSinceToken() == "" {
		t.Fatalf("list setup: %v", err)
	}
	cases := []struct {
		name         string
		who          ltUser
		since, page  string
		wantFieldKey string
	}{
		{"user timeline since token", a, ut.Msg.GetSinceToken(), "", "since_token"},
		{"user timeline page token", a, "", ut.Msg.GetNextPageToken(), "page_token"},
		{"another viewer's list since token", b, mine.GetSinceToken(), "", "since_token"},
	}
	for _, tc := range cases {
		_, err := c.listTimeline(tc.who, list, 20, tc.since, tc.page)
		d := wireError(t, err, connect.CodeInvalidArgument)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != tc.wantFieldKey {
			t.Errorf("%s: detail = %v", tc.name, d)
		}
		budgettest.Assert(t, tc.name, c.lineBudget(t, rpcGetListTimeline), budgettest.Budget{Reads: 1})
	}
}

// ADR-0030 D3 names "the owner blocks the caller" but not the reverse. This pins what the code does for a caller who blocks the
// list's owner (GetList and GetListTimeline must agree) and is reported to the architect as a question, not a defect.
func TestW515_CallerWhoBlocksTheOwnerSeesTheList(t *testing.T) {
	c := newLTChain(t, nil)
	owner, viewer := c.user(t), c.user(t)
	list, _ := seedList(t, c.fs, owner.uid, false, memberNames(2))
	if _, err := c.graph.Block(context.Background(), authed(viewer.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w515-bo"), UserId: owner.uid})); err != nil {
		t.Fatal(err)
	}
	fresh := newLTChain(t, nil)
	_, gerr := fresh.lists.GetList(context.Background(), authed(viewer.token, &listsv1.GetListRequest{ListId: list}))
	_, terr := fresh.listTimeline(viewer, list, 20, "", "")
	if (gerr == nil) != (terr == nil) {
		t.Fatalf("GetList err=%v but GetListTimeline err=%v: the two reads disagree about a list whose owner the caller blocked", gerr, terr)
	}
	t.Logf("caller blocks the owner: GetList err=%v, GetListTimeline err=%v", gerr, terr)
	// A pinned or opened list from an owner you blocked is a product question (D3 is silent); this test fixes the observed answer.
	if gerr != nil {
		wireError(t, gerr, connect.CodeNotFound)
	}
}

// seedPostBy writes one public root post by uid in the shape seedList uses, 30 s or more old so the settle window has passed.
func seedPostBy(t *testing.T, fs *firestore.Client, uid string) {
	t.Helper()
	pid := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := fs.Collection("posts").Doc(pid).Set(context.Background(), map[string]any{
		"authorId": uid, "author": map[string]any{"userId": uid, "handle": "h" + uid},
		"kind": "POST", "isReply": false, "text": "own", "conversationId": pid, "hashtags": []string{},
		"mentions": []map[string]any{}, "likeCount": int64(0), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
		"visibility": "PUBLIC", "createdAt": now.Add(-time.Duration(rand.IntN(3000)+60) * time.Second), "hasMedia": false,
	}); err != nil {
		t.Fatalf("seed post: %v", err)
	}
}
