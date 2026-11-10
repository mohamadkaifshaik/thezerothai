package beacons

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F29: ListBeacons filters by activity in the query, so a page is never emptied by the filter.

func TestListActivityFromProto(t *testing.T) {
	for _, tc := range []struct {
		name    string
		in      beaconsv1.BeaconActivity
		want    Activity
		wantErr bool
	}{
		{"unspecified is no filter", beaconsv1.BeaconActivity_BEACON_ACTIVITY_UNSPECIFIED, "", false},
		{"coffee", beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, ActivityCoffee, false},
		{"other", beaconsv1.BeaconActivity_BEACON_ACTIVITY_OTHER, ActivityOther, false},
		{"unknown value", beaconsv1.BeaconActivity(99), "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := listActivityFromProto(tc.in)
			if tc.wantErr {
				assertValidation(t, err, "activity")
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
		})
	}
}

func TestListBeacons_ActivityFilterReachesTheQuery(t *testing.T) {
	for _, tc := range []struct {
		name      string
		activity  Activity
		wantViews int
		wantErr   bool
	}{
		{"no filter lists every activity", "", 3, false},
		{"coffee only", ActivityCoffee, 2, false},
		{"meal only", ActivityMeal, 1, false},
		{"no match is an empty page, not an error", ActivityWalk, 0, false},
		{"unknown stored value is VALIDATION before any lookup", Activity("bowling"), 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			rows := e.rowsFrom(3)
			rows[0].Activity, rows[1].Activity, rows[2].Activity = ActivityCoffee, ActivityMeal, ActivityCoffee
			e.repo.rows = rows
			page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Activity: tc.activity})
			if tc.wantErr {
				assertValidation(t, err, "activity")
				if len(e.repo.queries) != 0 {
					t.Fatal("query ran for an invalid activity")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if q := e.repo.queries[0]; q.Activity != tc.activity {
				t.Fatalf("query activity = %q, want %q", q.Activity, tc.activity)
			}
			if len(page.Views) != tc.wantViews {
				t.Fatalf("views = %d, want %d", len(page.Views), tc.wantViews)
			}
			for _, v := range page.Views {
				if tc.activity != "" && v.Beacon.Activity != tc.activity {
					t.Fatalf("view activity = %q, want %q", v.Beacon.Activity, tc.activity)
				}
			}
		})
	}
}

func TestListBeacons_TokenBoundToActivity(t *testing.T) {
	e := newEnv()
	rows := e.rowsFrom(3)
	for i := range rows {
		rows[i].Activity = ActivityCoffee
	}
	e.repo.rows = rows
	ctx := context.Background()
	page, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Activity: ActivityCoffee, Limit: 1})
	if err != nil || page.NextPageToken == "" {
		t.Fatalf("coffee page 1: token %q, %v", page.NextPageToken, err)
	}
	for _, other := range []Activity{"", ActivityMeal} {
		_, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Activity: other, Limit: 1, PageToken: page.NextPageToken})
		assertValidation(t, err, "page_token")
	}
	if _, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Activity: ActivityCoffee, Limit: 1, PageToken: page.NextPageToken}); err != nil {
		t.Fatalf("same filter: %v", err)
	}
	if q := e.repo.queries[len(e.repo.queries)-1]; q.Activity != ActivityCoffee || q.AfterID != rows[0].ID {
		t.Fatalf("resume query = %+v", q)
	}
	// An unfiltered token does not open a filtered list either.
	plain, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Limit: 1})
	if err != nil || plain.NextPageToken == "" {
		t.Fatalf("unfiltered page 1: %v", err)
	}
	_, err = e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Activity: ActivityCoffee, Limit: 1, PageToken: plain.NextPageToken})
	assertValidation(t, err, "page_token")
}

// TestListBinding_UnfilteredIsUnchanged: a token minted before the activity field existed must still open after the
// deploy, so the unfiltered binding is the old string byte for byte.
func TestListBinding_UnfilteredIsUnchanged(t *testing.T) {
	for _, tc := range []struct {
		cid      string
		activity Activity
		want     string
	}{
		{"", "", "beacons|list|v|public"},
		{testCommunity, "", "beacons|list|v|c:" + testCommunity},
		{"", ActivityStudy, "beacons|list|v|public|a:study"},
		{testCommunity, ActivityWalk, "beacons|list|v|c:" + testCommunity + "|a:walk"},
	} {
		if got := listBinding("v", tc.cid, tc.activity); got != tc.want {
			t.Errorf("listBinding(%q, %q) = %q, want %q", tc.cid, tc.activity, got, tc.want)
		}
	}
}

func TestListBeacons_CommunityAudienceWithActivity(t *testing.T) {
	e := newEnv()
	e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
	if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{CommunityID: testCommunity, Activity: ActivitySports}); err != nil {
		t.Fatal(err)
	}
	if q := e.repo.queries[0]; q.CommunityID != testCommunity || q.Activity != ActivitySports {
		t.Fatalf("query = %+v", q)
	}
}

// TestServer_ListBeaconsActivity: the handler runs the flag gate first, then converts the filter (an unknown enum value is
// VALIDATION "activity" with no query), and forwards a known one.
func TestServer_ListBeaconsActivity(t *testing.T) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: testViewer})
	off := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}), newEnv().svc)
	_, err := off.ListBeacons(ctx, connect.NewRequest(&beaconsv1.ListBeaconsRequest{Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Activity: beaconsv1.BeaconActivity(99)}))
	assertDisabled(t, err, FlagName)

	e := newEnv()
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), e.svc)
	_, err = s.ListBeacons(ctx, connect.NewRequest(&beaconsv1.ListBeaconsRequest{Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Activity: beaconsv1.BeaconActivity(99)}))
	assertValidation(t, err, "activity")
	if len(e.repo.queries) != 0 {
		t.Fatal("query ran for an unknown activity")
	}
	if _, err := s.ListBeacons(ctx, connect.NewRequest(&beaconsv1.ListBeaconsRequest{Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_MEAL})); err != nil {
		t.Fatal(err)
	}
	if q := e.repo.queries[0]; q.Activity != ActivityMeal {
		t.Fatalf("query activity = %q, want meal", q.Activity)
	}
}

// TestFirestoreIndexesCoverTheBeaconQueries: the emulator does not enforce composite indexes, so this asserts that the
// file firebase deploys declares the indexes ListByAudience needs, with and without the activity filter.
func TestFirestoreIndexesCoverTheBeaconQueries(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "firebase", "firestore.indexes.json"))
	if err != nil {
		t.Fatalf("read firestore.indexes.json: %v", err)
	}
	var file struct {
		Indexes []struct {
			CollectionGroup string `json:"collectionGroup"`
			QueryScope      string `json:"queryScope"`
			Fields          []struct {
				FieldPath string `json:"fieldPath"`
				Order     string `json:"order"`
			} `json:"fields"`
		} `json:"indexes"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, ix := range file.Indexes {
		if ix.CollectionGroup != beaconsCollection || ix.QueryScope != "COLLECTION" {
			continue
		}
		var parts []string
		for _, f := range ix.Fields {
			parts = append(parts, f.FieldPath+":"+f.Order)
		}
		have[fmt.Sprint(parts)] = true
	}
	for name, fields := range map[string][]string{
		"ListByAudience":                {"communityId:ASCENDING", "status:ASCENDING", "startAt:ASCENDING"},
		"ListByAudience with activity":  {"communityId:ASCENDING", "activity:ASCENDING", "status:ASCENDING", "startAt:ASCENDING"},
		"countLive (organiser, status)": {"organiserId:ASCENDING", "status:ASCENDING", "endAt:ASCENDING"},
	} {
		if !have[fmt.Sprint(fields)] {
			t.Errorf("firestore.indexes.json has no beacons index for %s: %v", name, fields)
		}
	}
}
