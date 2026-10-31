package identity

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

func tabsProfile(tabs ...HomeTab) Profile {
	return Profile{UserID: "u", Handle: "u", HandleLower: "u", Status: AccountStatusActive, HomeTabsEnc: encodeHomeTabs(tabs)}
}

func TestHomeTabs_EncodeRoundTripAndComparable(t *testing.T) {
	t.Parallel()
	in := []HomeTab{{Kind: HomeTabKindList, ID: "0000000000000000101", Title: "Mine"}, {Kind: HomeTabKindList, ID: "0000000000000000102"}}
	p := tabsProfile(in...)
	if got := p.HomeTabs(); !slices.Equal(got, in) {
		t.Fatalf("round trip = %+v, want %+v", got, in)
	}
	if q := tabsProfile(in...); p != q {
		t.Fatal("equal tabs must give equal profiles (UpdateProfile detects a no-op with ==)")
	}
	if tabsProfile().HomeTabsEnc != "" || tabsProfile().HomeTabs() != nil {
		t.Fatal("no tabs must encode to the empty string")
	}
	if (Profile{HomeTabsEnc: "{not json"}).HomeTabs() != nil {
		t.Fatal("a corrupt value must decode to no tabs, not panic")
	}
}

// GetMe returns home_tabs from the profile it already read (0 extra reads) and omits a tab whose kind's flag is off for the
// caller; a dangling tab is kept (the client learns it from GetListTimeline).
func TestGetMe_HomeTabsAndFlags(t *testing.T) {
	t.Parallel()
	a := HomeTab{Kind: HomeTabKindList, ID: "0000000000000000101", Title: "A"}
	b := HomeTab{Kind: HomeTabKindList, ID: "0000000000000000102"}
	c := HomeTab{Kind: HomeTabKindCommunity, ID: "0000000000000000103"}
	tests := []struct {
		name    string
		enabled []string
		stored  []HomeTab
		want    []HomeTab
	}{
		{"lists on keeps order", []string{"graph", ListsFlag}, []HomeTab{b, a}, []HomeTab{b, a}},
		{"lists off omits LIST tabs", []string{"graph"}, []HomeTab{b, a}, nil},
		{"no flags at all", nil, []HomeTab{a}, nil},
		{"community is omitted until its flag exists", []string{ListsFlag}, []HomeTab{a, c}, []HomeTab{a}},
		{"unknown kind is dropped", []string{ListsFlag}, []HomeTab{{Kind: "X", ID: "1"}, a}, []HomeTab{a}},
		{"none stored", []string{ListsFlag}, nil, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			repo.profiles["u"] = tabsProfile(tt.stored...)
			svc := New(repo, NewCache(time.Minute), time.Hour, WithFeatureFlags(&fakeFeatureFlags{enabled: tt.enabled})).(*service)
			got, err := svc.GetMe(context.Background(), "u")
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got.HomeTabs, tt.want) {
				t.Fatalf("home tabs = %+v, want %+v", got.HomeTabs, tt.want)
			}
		})
	}
}

func TestToProtoHomeTabs(t *testing.T) {
	t.Parallel()
	got := toProtoHomeTabs([]HomeTab{{Kind: HomeTabKindList, ID: "7", Title: "T"}, {Kind: "X", ID: "8"}})
	if len(got) != 1 || got[0].GetKind() != commonv1.HomeTabKind_HOME_TAB_KIND_LIST || got[0].GetId() != "7" || got[0].GetTitle() != "T" {
		t.Fatalf("proto tabs = %+v", got)
	}
	if toProtoHomeTabs(nil) != nil {
		t.Fatal("no tabs must stay nil")
	}
}

// The export's profile section carries the owner's stored tabs (all kinds, flag-independent: it is the owner's data), omitted
// when there are none (ADR-0030 D8).
func TestProfileSection_HomeTabs(t *testing.T) {
	t.Parallel()
	raw, err := json.Marshal(profileSection(tabsProfile(HomeTab{Kind: HomeTabKindList, ID: "0000000000000000101", Title: "Mine"}, HomeTab{Kind: HomeTabKindList, ID: "0000000000000000102"})))
	if err != nil {
		t.Fatal(err)
	}
	want := `"homeTabs":[{"kind":"LIST","id":"0000000000000000101","title":"Mine"},{"kind":"LIST","id":"0000000000000000102"}]`
	if !strings.Contains(string(raw), want) {
		t.Fatalf("export = %s, want it to contain %s", raw, want)
	}
	raw, _ = json.Marshal(profileSection(Profile{UserID: "u1"}))
	if strings.Contains(string(raw), "homeTabs") {
		t.Fatalf("absent tabs exported: %s", raw)
	}
}
