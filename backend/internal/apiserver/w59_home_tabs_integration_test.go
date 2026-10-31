//go:build integration

package apiserver

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W5-9 (ADR-0030 D6) through the production wiring: SetHomeTabs, GetMe.home_tabs, GetList.pinned_by_viewer, UpdateList's retitle
// and DeleteList's unpin, and the flag modes. Request-line budgets include the account-status interceptor's read.

func tabsListsOn(c *config.Config) {
	w320AllW3On(c)
	c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.On}
}

type tabsHarness struct {
	*w320Chain
	lists listsv1connect.ListServiceClient
	tl    timelinev1connect.TimelineServiceClient
}

func newTabsHarness(t *testing.T, mutate func(*config.Config)) *tabsHarness {
	t.Helper()
	w := newW320Chain(t, mutate)
	return &tabsHarness{w320Chain: w, lists: listsv1connect.NewListServiceClient(http.DefaultClient, w.url), tl: timelinev1connect.NewTimelineServiceClient(http.DefaultClient, w.url)}
}

func (h *tabsHarness) createList(t *testing.T, u bmUser, name string, private bool) string {
	t.Helper()
	r, err := h.lists.CreateList(context.Background(), authed(u.token, &listsv1.CreateListRequest{
		IdempotencyKey: tabsKey("list-" + name), Name: name, IsPrivate: &private,
	}))
	if err != nil {
		t.Fatalf("CreateList %s: %v", name, err)
	}
	return r.Msg.GetList().GetListId()
}

func (h *tabsHarness) setTabs(u bmUser, k string, ids ...string) (*timelinev1.SetHomeTabsResponse, error) {
	req := &timelinev1.SetHomeTabsRequest{IdempotencyKey: tabsKey(k)}
	for _, id := range ids {
		req.Tabs = append(req.Tabs, &commonv1.HomeTab{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: id})
	}
	r, err := h.tl.SetHomeTabs(context.Background(), authed(u.token, req))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func tabPairs(tabs []*commonv1.HomeTab) []string {
	var out []string
	for _, t := range tabs {
		out = append(out, t.GetId()+":"+t.GetTitle())
	}
	return out
}

func TestW59_HomeTabsLifecycle(t *testing.T) {
	h := newTabsHarness(t, tabsListsOn)
	me, other := h.user(t), h.user(t)
	mine := h.createList(t, me, "Mine", true)
	theirsPublic := h.createList(t, other, "Theirs", false)
	theirsPrivate := h.createList(t, other, "Hidden", true)
	rpc := timelinev1connect.TimelineServiceSetHomeTabsProcedure

	// A private foreign list and a missing list are the same VALIDATION answer.
	_, err := h.setTabs(me, "bad1", mine, theirsPrivate)
	w320Reason(t, "foreign private list", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "tabs")
	_, err = h.setTabs(me, "bad2", "0000000000000000999")
	w320Reason(t, "missing list", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "tabs")

	got, err := h.setTabs(me, "set1", theirsPublic, mine)
	if err != nil {
		t.Fatalf("SetHomeTabs: %v", err)
	}
	if want := []string{theirsPublic + ":", mine + ":Mine"}; !slices.Equal(tabPairs(got.GetTabs()), want) {
		t.Fatalf("response tabs = %v, want %v (own list titled, foreign list not)", tabPairs(got.GetTabs()), want)
	}
	// ADR-0030 table: <= 19 reads, 2 writes (users field-level, idempotency).
	budgettest.Assert(t, "SetHomeTabs, 2 tabs", h.lineBudget(t, rpc), budgettest.Budget{Reads: 19, Writes: 2})

	// The same order under a new key writes only the idempotency record; a replay writes nothing.
	if _, err := h.setTabs(me, "set2", theirsPublic, mine); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SetHomeTabs, same order", h.lineBudget(t, rpc), budgettest.Budget{Reads: 19, Writes: 1})
	if _, err := h.setTabs(me, "set1", theirsPublic, mine); err != nil {
		t.Fatalf("replay: %v", err)
	}
	budgettest.Assert(t, "SetHomeTabs, replay", h.lineBudget(t, rpc), budgettest.Budget{Reads: 3})
	_, err = h.setTabs(me, "set1", mine)
	w320Reason(t, "reused key", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, "")

	// GetMe returns the tabs with no extra read.
	m := h.w326bGetMe(t, me)
	if want := []string{theirsPublic + ":", mine + ":Mine"}; !slices.Equal(tabPairs(m.GetHomeTabs()), want) {
		t.Fatalf("GetMe home_tabs = %v, want %v", tabPairs(m.GetHomeTabs()), want)
	}
	if !slices.Contains(m.GetEnabledFeatures(), "lists") {
		t.Fatalf("enabled_features = %v, want lists", m.GetEnabledFeatures())
	}
	budgettest.Assert(t, "GetMe with tabs", h.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 2})

	// pinned_by_viewer follows the viewer's own tabs.
	gl, err := h.lists.GetList(context.Background(), authed(me.token, &listsv1.GetListRequest{ListId: theirsPublic}))
	if err != nil || !gl.Msg.GetList().GetPinnedByViewer() {
		t.Fatalf("GetList pinned = %v, %v; want true for the viewer who pinned it", gl.Msg.GetList().GetPinnedByViewer(), err)
	}
	gl, err = h.lists.GetList(context.Background(), authed(other.token, &listsv1.GetListRequest{ListId: theirsPublic}))
	if err != nil || gl.Msg.GetList().GetPinnedByViewer() {
		t.Fatalf("GetList pinned for another viewer = %v, %v; want false", gl.Msg.GetList().GetPinnedByViewer(), err)
	}

	// Renaming the pinned list refreshes the stored title; GetMe on the same instance shows it at once.
	newName := "Renamed"
	if _, err := h.lists.UpdateList(context.Background(), authed(me.token, &listsv1.UpdateListRequest{IdempotencyKey: tabsKey("upd"), ListId: mine, Name: &newName})); err != nil {
		t.Fatalf("UpdateList: %v", err)
	}
	if want := []string{theirsPublic + ":", mine + ":Renamed"}; !slices.Equal(tabPairs(h.w326bGetMe(t, me).GetHomeTabs()), want) {
		t.Fatalf("after rename: %v, want %v", tabPairs(h.w326bGetMe(t, me).GetHomeTabs()), want)
	}

	// Deleting the pinned list unpins it in the same call; the other user's pin of a deleted list would dangle instead.
	if _, err := h.lists.DeleteList(context.Background(), authed(me.token, &listsv1.DeleteListRequest{IdempotencyKey: tabsKey("del"), ListId: mine})); err != nil {
		t.Fatalf("DeleteList: %v", err)
	}
	if want := []string{theirsPublic + ":"}; !slices.Equal(tabPairs(h.w326bGetMe(t, me).GetHomeTabs()), want) {
		t.Fatalf("after delete: %v, want %v", tabPairs(h.w326bGetMe(t, me).GetHomeTabs()), want)
	}
	// The sixth tab is LIMIT_REACHED before any read.
	var six []string
	for range 6 {
		six = append(six, theirsPublic+"x")
	}
	_, err = h.setTabs(me, "six", mine, theirsPublic, "0000000000000000201", "0000000000000000202", "0000000000000000203", "0000000000000000204")
	w320Reason(t, "six tabs", err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "")
	_ = six
}

// A caller outside FEATURE_LISTS: LIST tabs are refused with FEATURE_DISABLED, an empty request is accepted, and a LIST tab stored
// while the flag was on is kept but not returned by GetMe (it comes back with the flag).
func TestW59_HomeTabsFlagOff(t *testing.T) {
	on := newTabsHarness(t, tabsListsOn)
	u := on.user(t)
	id := on.createList(t, u, "Mine", true)
	if _, err := on.setTabs(u, "set", id); err != nil {
		t.Fatal(err)
	}

	off := newTabsHarness(t, func(c *config.Config) {
		w320AllW3On(c)
		c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Off}
	})
	_, err := off.setTabs(u, "off1", id)
	w320Reason(t, "lists off", err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "")
	if me := off.w326bGetMe(t, u); len(me.GetHomeTabs()) != 0 || slices.Contains(me.GetEnabledFeatures(), "lists") {
		t.Fatalf("flag off GetMe = tabs %v features %v", me.GetHomeTabs(), me.GetEnabledFeatures())
	}
	if r, err := off.setTabs(u, "off2"); err != nil || len(r.GetTabs()) != 0 {
		t.Fatalf("empty request with lists off = %v, %v", r, err)
	}
	// The stored LIST tab was kept: with the flag on again it is back.
	if got := tabPairs(on.w326bGetMe(t, u).GetHomeTabs()); !slices.Equal(got, []string{id + ":Mine"}) {
		t.Fatalf("flag back on: %v", got)
	}
}

var _ = identityv1.GetMeRequest{}

// tabsKey makes a valid idempotency key (16 to 64 characters) from a label; keys are scoped per uid, so reuse across users is fine.
func tabsKey(label string) string { return "w59-" + label + "-0123456789" }
