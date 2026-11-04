package timeline

// SetHomeTabs with COMMUNITY tabs.

import (
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	commTabCID  = "1000000000000000099"
	commTabCID2 = "1000000000000000097"
)

type tab struct {
	kind commonv1.HomeTabKind
	id   string
}

func commTab(id string) tab { return tab{commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY, id} }
func listTab(id string) tab { return tab{commonv1.HomeTabKind_HOME_TAB_KIND_LIST, id} }

func sendKinded(s *Server, uid string, tabs ...tab) (*timelinev1.SetHomeTabsResponse, error) {
	req := &timelinev1.SetHomeTabsRequest{IdempotencyKey: idemK}
	for _, t := range tabs {
		req.Tabs = append(req.Tabs, &commonv1.HomeTab{Kind: t.kind, Id: t.id, Title: "ignored on input"})
	}
	ctx := ctxFor(uid)
	resp, err := s.SetHomeTabs(ctx, connect.NewRequest(req))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
}

func tabRegistry(listsMode, communitiesMode flags.Mode) lists.FlagChecker {
	return flags.NewRegistry(flags.Spec{Name: lists.FlagName, Mode: listsMode}, flags.Spec{Name: communities.FlagName, Mode: communitiesMode})
}

func commTabsServer(fl lists.FlagChecker, st HomeTabsStore, rd lists.Reader, fc communities.Reader) *Server {
	return NewServer(Deps{}, WithHomeTabs(HomeTabsDeps{Store: st, Lists: rd, Communities: fc, Flags: fl, Max: 5}))
}

func newTabCommunities() *fakeCommunities {
	return &fakeCommunities{
		c:     communities.Community{ID: commTabCID, Name: "Go", Status: communities.StatusActive, OwnerID: "someone"},
		roles: map[string]communities.Role{},
	}
}

func TestSetHomeTabs_CommunityTabs(t *testing.T) {
	t.Parallel()
	on := tabRegistry(flags.On, flags.On)
	t.Run("a community the caller has not joined is accepted, title empty, one community lookup", func(t *testing.T) {
		t.Parallel()
		st, fc := &fakeTabsStore{}, newTabCommunities()
		rd := &fakeReader{}
		resp, err := sendKinded(commTabsServer(on, st, rd, fc), "me", commTab(commTabCID))
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.GetTabs()) != 1 || resp.GetTabs()[0].GetKind() != commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY || resp.GetTabs()[0].GetTitle() != "" {
			t.Fatalf("tabs = %v", resp.GetTabs())
		}
		if st.stored[0].Kind != identity.HomeTabKindCommunity || st.stored[0].Title != "" {
			t.Fatalf("stored = %+v", st.stored)
		}
		if fc.gets != 1 || rd.gets != 0 {
			t.Fatalf("community gets=%d list gets=%d, want 1/0", fc.gets, rd.gets)
		}
	})
	t.Run("an archived community is accepted", func(t *testing.T) {
		t.Parallel()
		fc := newTabCommunities()
		fc.c.Status = communities.StatusArchived
		if _, err := sendKinded(commTabsServer(on, &fakeTabsStore{}, &fakeReader{}, fc), "me", commTab(commTabCID)); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("suspended and missing are the one VALIDATION tabs answer", func(t *testing.T) {
		t.Parallel()
		for name, mut := range map[string]func(*fakeCommunities){
			"suspended": func(f *fakeCommunities) { f.c.Status = communities.StatusSuspended },
			"missing":   func(f *fakeCommunities) { f.missing = true },
			"other id":  func(f *fakeCommunities) { f.c.ID = commTabCID2 },
		} {
			fc := newTabCommunities()
			mut(fc)
			st := &fakeTabsStore{}
			_, err := sendKinded(commTabsServer(on, st, &fakeReader{}, fc), "me", commTab(commTabCID))
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
			if st.writes != 0 {
				t.Fatalf("%s: wrote", name)
			}
		}
	})
	t.Run("communities off for the caller is FEATURE_DISABLED without a community lookup, even with lists on", func(t *testing.T) {
		t.Parallel()
		fc := newTabCommunities()
		_, err := sendKinded(commTabsServer(tabRegistry(flags.On, flags.Off), &fakeTabsStore{}, &fakeReader{}, fc), "me", commTab(commTabCID))
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "communities"})
		if fc.gets != 0 {
			t.Fatalf("community gets = %d, want 0", fc.gets)
		}
	})
	t.Run("a community-only request does not need lists, and a list-only one does not need communities", func(t *testing.T) {
		t.Parallel()
		if _, err := sendKinded(commTabsServer(tabRegistry(flags.Off, flags.On), &fakeTabsStore{}, &fakeReader{}, newTabCommunities()), "me", commTab(commTabCID)); err != nil {
			t.Fatalf("communities only: %v", err)
		}
		rd := &fakeReader{views: map[string]lists.ListView{listA: view(listA, "Mine", "me")}}
		if _, err := sendKinded(commTabsServer(tabRegistry(flags.On, flags.Off), &fakeTabsStore{}, rd, newTabCommunities()), "me", listTab(listA)); err != nil {
			t.Fatalf("lists only: %v", err)
		}
		_, err := sendKinded(commTabsServer(tabRegistry(flags.Off, flags.On), &fakeTabsStore{}, &fakeReader{}, newTabCommunities()), "me", listTab(listA))
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "lists"})
	})
	t.Run("mixed kinds keep the sent order and each kind's title rule", func(t *testing.T) {
		t.Parallel()
		rd := &fakeReader{views: map[string]lists.ListView{listA: view(listA, "Mine", "me")}}
		resp, err := sendKinded(commTabsServer(on, &fakeTabsStore{}, rd, newTabCommunities()), "me", commTab(commTabCID), listTab(listA))
		if err != nil {
			t.Fatal(err)
		}
		if got := tabIDs(resp); !slices.Equal(got, []string{commTabCID, listA}) {
			t.Fatalf("order = %v", got)
		}
		if resp.GetTabs()[0].GetKind() != commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY || resp.GetTabs()[1].GetTitle() != "Mine" {
			t.Fatalf("tabs = %v", resp.GetTabs())
		}
	})
	t.Run("the same id as a list and as a community are different tabs; duplicates of one kind are refused", func(t *testing.T) {
		t.Parallel()
		rd := &fakeReader{views: map[string]lists.ListView{commTabCID: view(commTabCID, "L", "me")}}
		if _, err := sendKinded(commTabsServer(on, &fakeTabsStore{}, rd, newTabCommunities()), "me", commTab(commTabCID), listTab(commTabCID)); err != nil {
			t.Fatal(err)
		}
		_, err := sendKinded(commTabsServer(on, &fakeTabsStore{}, &fakeReader{}, newTabCommunities()), "me", commTab(commTabCID), commTab(commTabCID))
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
	})
	t.Run("a stored community tab is kept without a community lookup, even when the community was suspended since", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{stored: []identity.HomeTab{{Kind: identity.HomeTabKindCommunity, ID: commTabCID}}}
		fc := newTabCommunities()
		fc.c.Status = communities.StatusSuspended
		resp, err := sendKinded(commTabsServer(on, st, &fakeReader{}, fc), "me", commTab(commTabCID))
		if err != nil || len(resp.GetTabs()) != 1 || fc.gets != 0 {
			t.Fatalf("err=%v tabs=%v community gets=%d, want a kept tab and no lookup", err, resp.GetTabs(), fc.gets)
		}
	})
	t.Run("a stored community tab is hidden and kept while communities is off", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{stored: []identity.HomeTab{{Kind: identity.HomeTabKindCommunity, ID: commTabCID}}}
		rd := &fakeReader{views: map[string]lists.ListView{listA: view(listA, "Mine", "me")}}
		resp, err := sendKinded(commTabsServer(tabRegistry(flags.On, flags.Off), st, rd, newTabCommunities()), "me", listTab(listA))
		if err != nil {
			t.Fatal(err)
		}
		if got := tabIDs(resp); !slices.Equal(got, []string{listA}) {
			t.Fatalf("visible = %v, want only the list", got)
		}
		if len(st.stored) != 2 || st.stored[1].Kind != identity.HomeTabKindCommunity {
			t.Fatalf("stored = %+v, want the community tab kept after the sent ones", st.stored)
		}
	})
	t.Run("an empty request with only communities on still runs, and with both off is the no-op", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{stored: []identity.HomeTab{{Kind: identity.HomeTabKindCommunity, ID: commTabCID}}}
		resp, err := sendKinded(commTabsServer(tabRegistry(flags.Off, flags.On), st, &fakeReader{}, newTabCommunities()), "me")
		if err != nil || len(resp.GetTabs()) != 0 || len(st.stored) != 0 {
			t.Fatalf("err=%v tabs=%v stored=%+v, want the community tab unpinned", err, resp.GetTabs(), st.stored)
		}
		st = &fakeTabsStore{stored: []identity.HomeTab{{Kind: identity.HomeTabKindCommunity, ID: commTabCID}}}
		_, err = sendKinded(commTabsServer(tabRegistry(flags.Off, flags.Off), st, &fakeReader{}, newTabCommunities()), "me")
		if err != nil || st.calls != 0 || len(st.stored) != 1 {
			t.Fatalf("err=%v calls=%d: the no-op touched the store", err, st.calls)
		}
	})
	t.Run("without communities wired a COMMUNITY tab is VALIDATION tabs, and SetCommunities wires it", func(t *testing.T) {
		t.Parallel()
		s := commTabsServer(on, &fakeTabsStore{}, &fakeReader{}, nil)
		_, err := sendKinded(s, "me", commTab(commTabCID))
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
		s.SetCommunities(newTabCommunities(), 0)
		if _, err := sendKinded(s, "me", commTab(commTabCID)); err != nil {
			t.Fatalf("after SetCommunities: %v", err)
		}
	})
}
