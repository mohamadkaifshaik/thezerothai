package beacons

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/location"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The test catalogue: one city-only entry and a city with three chained neighbourhoods and one retired one.
const (
	areaCityOnly = "in.oth"
	areaCity     = "in.tst"
	areaAlpha    = "in.tst.alpha" // neighbour: beta
	areaBeta     = "in.tst.beta"  // neighbours: alpha, gamma
	areaGamma    = "in.tst.gamma" // neighbour: beta
	areaRetired  = "in.tst.old"
)

const testCatalogJSON = `{"version": 1, "areas": [
{"id": "in.oth", "name": "Otherpur", "kind": "CITY", "city": "in.oth", "aliases": [], "neighbours": [], "retired": false},
{"id": "in.tst", "name": "Testpur", "kind": "CITY", "city": "in.tst", "aliases": [], "neighbours": [], "retired": false},
{"id": "in.tst.alpha", "name": "Alpha", "kind": "AREA", "city": "in.tst", "aliases": [], "neighbours": ["in.tst.beta"], "retired": false},
{"id": "in.tst.beta", "name": "Beta", "kind": "AREA", "city": "in.tst", "aliases": [], "neighbours": ["in.tst.alpha", "in.tst.gamma"], "retired": false},
{"id": "in.tst.gamma", "name": "Gamma", "kind": "AREA", "city": "in.tst", "aliases": [], "neighbours": ["in.tst.beta"], "retired": false},
{"id": "in.tst.old", "name": "Old Town", "kind": "AREA", "city": "in.tst", "aliases": [], "neighbours": [], "retired": true}
]}`

func testCatalog(t *testing.T) *location.StaticCatalog {
	t.Helper()
	c, err := location.ParseCatalog([]byte(testCatalogJSON))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// fakeMyArea is location.Reader over one stored area per uid.
type fakeMyArea struct {
	areas map[string]string
	err   error
	calls int
}

func (f *fakeMyArea) MyArea(_ context.Context, uid string) (string, bool, error) {
	f.calls++
	if f.err != nil {
		return "", false, f.err
	}
	a, ok := f.areas[uid]
	return a, ok, nil
}

// newAreaEnv is newEnv with FEATURE_BEACONS and FEATURE_LOCATION on for everyone, the test catalogue and a stored-area
// reader (empty).
func newAreaEnv(t *testing.T) (*env, *fakeMyArea) {
	t.Helper()
	e := newEnv()
	e.flags.on[FlagName], e.flags.on[location.FlagName] = true, true
	my := &fakeMyArea{areas: map[string]string{}}
	e.deps.Areas, e.deps.MyArea = testCatalog(t), my
	e.svc = New(e.deps)
	return e, my
}

func lookupArea(t *testing.T, id string) location.Area {
	t.Helper()
	a, ok := testCatalog(t).Lookup(id)
	if !ok {
		t.Fatalf("no test area %s", id)
	}
	return a
}

func TestDenormalise(t *testing.T) {
	t.Parallel()
	got := denormalise(lookupArea(t, areaBeta))
	if got.AreaID != areaBeta || got.CityID != areaCity || fmt.Sprint(got.NearAreaIDs) != fmt.Sprint([]string{areaBeta, areaAlpha, areaGamma}) {
		t.Errorf("beta = %+v", got)
	}
	city := denormalise(lookupArea(t, areaCity))
	if city.AreaID != areaCity || city.CityID != areaCity || fmt.Sprint(city.NearAreaIDs) != fmt.Sprint([]string{areaCity}) {
		t.Errorf("city = %+v, want just itself", city)
	}
}

func TestProximity(t *testing.T) {
	t.Parallel()
	alpha, city := lookupArea(t, areaAlpha), lookupArea(t, areaCity)
	for _, tc := range []struct {
		plan string
		req  location.Area
		want Proximity
	}{
		{areaAlpha, alpha, ProximitySameArea},
		{areaBeta, alpha, ProximityNeighbouring},
		{areaGamma, alpha, ProximitySameCity}, // a neighbour's neighbour is not a neighbour
		{areaCity, alpha, ProximitySameCity},  // a city-tagged plan, seen from a neighbourhood (CITY scope)
		{areaCity, city, ProximitySameArea},
		{areaAlpha, city, ProximitySameCity},
	} {
		if got := proximity(tc.plan, tc.req); got != tc.want {
			t.Errorf("proximity(%s, %s) = %s, want %s", tc.plan, tc.req.ID, got, tc.want)
		}
	}
}

func TestKAnon(t *testing.T) {
	t.Parallel()
	for n, want := range map[int]NearbyCount{0: {}, 1: {Few: true}, 4: {Few: true}, 5: {Plans: 5}, 30: {Plans: 30}} {
		if got := kAnon(n, 5); got != want {
			t.Errorf("kAnon(%d) = %+v, want %+v", n, got, want)
		}
	}
}

func TestCreateBeacon_Area(t *testing.T) {
	t.Parallel()
	t.Run("a pickable area is denormalised and changes the request hash", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		in := validCreate()
		in.AreaID = areaAlpha
		v, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
		if err != nil {
			t.Fatal(err)
		}
		p := e.repo.createdBy[0]
		if p.Beacon.Area.AreaID != areaAlpha || p.Beacon.Area.CityID != areaCity || len(p.Beacon.Area.NearAreaIDs) != 2 {
			t.Errorf("stored area = %+v", p.Beacon.Area)
		}
		plain := p.Beacon
		plain.Area = AreaFields{}
		if p.RequestHash == createHash(plain) {
			t.Error("the area is not part of the request hash")
		}
		if v.Area == nil || v.Area.ID != areaAlpha {
			t.Errorf("view area = %+v", v.Area)
		}
		if got := toView(v).GetBeacon().GetArea(); got.GetAreaId() != areaAlpha || got.GetCityName() != "Testpur" {
			t.Errorf("wire area = %v", got)
		}
	})
	t.Run("no area keeps the pre-P2 hash", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		if _, err := e.svc.CreateBeacon(context.Background(), testOrganiser, validCreate()); err != nil {
			t.Fatal(err)
		}
		b := e.repo.createdBy[0].Beacon
		legacy := idempotency.HashRequest(fmt.Sprintf("community=%s|activity=%s|title=%q|details=%q|venue=%q|start=%d|duration=%d|spots=%d|cost=%s|chat=%s",
			b.CommunityID, b.Activity, b.Title, b.Details, b.Venue, b.StartAt.UnixMicro(), b.DurationMin, b.OpenSpots, b.Cost, b.ChatPref))
		if e.repo.createdBy[0].RequestHash != legacy {
			t.Error("a create without an area no longer hashes as before P2")
		}
	})
	for _, tc := range []struct {
		name, id string
	}{{"malformed", "Indiranagar"}, {"unknown", "in.tst.nowhere"}, {"retired", areaRetired}} {
		t.Run(tc.name+" is VALIDATION area_id before any write", func(t *testing.T) {
			t.Parallel()
			e, _ := newAreaEnv(t)
			in := validCreate()
			in.AreaID = tc.id
			_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
			assertValidation(t, err, "area_id")
			if strings.Contains(err.Error(), tc.id) {
				t.Errorf("the error echoes the value: %v", err)
			}
			if e.repo.calls() != 0 {
				t.Error("the repo was called")
			}
		})
	}
	t.Run("FEATURE_LOCATION off for the caller refuses an area, allows none", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.flags.on[location.FlagName] = false
		in := validCreate()
		in.AreaID = areaAlpha
		_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
		assertDisabled(t, err, location.FlagName)
		if e.repo.calls() != 0 {
			t.Error("the repo was called")
		}
		if _, err := e.svc.CreateBeacon(context.Background(), testOrganiser, validCreate()); err != nil {
			t.Fatalf("no area with the flag off: %v", err)
		}
	})
}

func TestUpdateBeacon_Area(t *testing.T) {
	t.Parallel()
	str := func(s string) *string { return &s }
	cases := []struct {
		name     string
		id       *string
		on, off  bool // FEATURE_LOCATION on for the caller / globally off
		wantArea *AreaFields
		wantErr  string // "" | "disabled" | "validation"
	}{
		{name: "unset is unchanged", id: nil, on: true, wantArea: nil},
		{name: "an id sets the denormalised area", id: str(areaGamma), on: true, wantArea: &AreaFields{AreaID: areaGamma, CityID: areaCity, NearAreaIDs: []string{areaGamma, areaBeta}}},
		{name: "empty removes", id: str(""), on: true, wantArea: &AreaFields{}},
		{name: "empty removes outside the allowlist", id: str(""), on: false, wantArea: &AreaFields{}},
		{name: "empty is refused by the kill switch", id: str(""), off: true, wantErr: "disabled"},
		{name: "an id outside the allowlist is refused", id: str(areaGamma), on: false, wantErr: "disabled"},
		{name: "a retired id is refused", id: str(areaRetired), on: true, wantErr: "validation"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e, _ := newAreaEnv(t)
			e.flags.on[location.FlagName], e.flags.off[location.FlagName] = tc.on, tc.off
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.update = UpdateResult{Outcome: Written, Beacon: e.openBeacon()}
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, AreaID: tc.id})
			switch tc.wantErr {
			case "disabled":
				assertDisabled(t, err, location.FlagName)
			case "validation":
				assertValidation(t, err, "area_id")
			}
			if tc.wantErr != "" {
				if len(e.repo.updatedBy) != 0 {
					t.Error("the repo was called")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			p := e.repo.updatedBy[0]
			if fmt.Sprint(p.Area) != fmt.Sprint(tc.wantArea) {
				t.Errorf("params area = %+v, want %+v", p.Area, tc.wantArea)
			}
			if p.RequestHash != updateHash(testBeaconID, nil, nil, nil, nil, schedule{}, nil, tc.id) {
				t.Error("request hash does not carry the area as sent")
			}
			if len(e.events.updated) != 0 {
				t.Error("an area change notified participants")
			}
		})
	}
	t.Run("unset, empty and an id hash apart", func(t *testing.T) {
		t.Parallel()
		hashes := map[string]bool{}
		for _, a := range []*string{nil, str(""), str(areaAlpha)} {
			hashes[updateHash("b", nil, nil, nil, nil, schedule{}, nil, a)] = true
		}
		if len(hashes) != 3 {
			t.Error("two area forms share a request hash")
		}
	})
}

func TestAreaLabel_HiddenByTheKillSwitchOnly(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name    string
		on, off bool
		want    bool
	}{{"on", true, false, true}, {"allowlist out keeps labels", false, false, true}, {"globally off hides", false, true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e, _ := newAreaEnv(t)
			e.flags.on[location.FlagName], e.flags.off[location.FlagName] = tc.on, tc.off
			b := e.openBeacon()
			b.Area = denormalise(lookupArea(t, areaRetired)) // a retired area still resolves its label
			e.repo.docs[b.ID] = b
			v, err := e.svc.GetBeacon(context.Background(), testViewer, b.ID)
			if err != nil {
				t.Fatal(err)
			}
			if got := toView(v).GetBeacon().GetArea() != nil; got != tc.want {
				t.Errorf("label present = %v, want %v", got, tc.want)
			}
		})
	}
}

// nearbyRows are n public beacons in areaAlpha, organised by testOrganiser, a minute apart.
func (e *env) nearbyRows(n int) []Beacon {
	out := make([]Beacon, 0, n)
	for i := range n {
		b := e.openBeacon()
		b.ID = fmt.Sprintf("%019d", 1000+i)
		b.StartAt = b.StartAt.Add(time.Duration(i) * time.Minute)
		b.EndAt = b.StartAt.Add(25 * time.Minute)
		b.Area = AreaFields{AreaID: areaAlpha, CityID: areaCity, NearAreaIDs: []string{areaAlpha, areaBeta}}
		out = append(out, b)
	}
	return out
}

func TestListNearby_Gates(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	t.Run("FEATURE_LOCATION off for the caller", func(t *testing.T) {
		t.Parallel()
		e, my := newAreaEnv(t)
		e.flags.on[location.FlagName] = false
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		assertDisabled(t, err, location.FlagName)
		if len(e.repo.nqueries) != 0 || my.calls != 0 {
			t.Error("a read ran")
		}
	})
	t.Run("FEATURE_LOCATION globally off", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.flags.on[location.FlagName], e.flags.off[location.FlagName] = false, true
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		assertDisabled(t, err, location.FlagName)
	})
	t.Run("FEATURE_BEACONS globally off (handler)", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.flags.off[FlagName] = true
		srv := NewServer(e.flags, e.svc)
		_, err := srv.ListNearbyBeacons(authn.WithClaims(ctx, authn.Claims{UID: testViewer}), connect.NewRequest(&beaconsv1.ListNearbyBeaconsRequest{AreaId: areaAlpha}))
		assertDisabled(t, err, FlagName)
		if len(e.repo.nqueries) != 0 {
			t.Error("a read ran")
		}
	})
	t.Run("FEATURE_BEACONS outside the allowlist still reads", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.flags.on[FlagName] = false
		srv := NewServer(e.flags, e.svc)
		if _, err := srv.ListNearbyBeacons(authn.WithClaims(ctx, authn.Claims{UID: testViewer}), connect.NewRequest(&beaconsv1.ListNearbyBeaconsRequest{AreaId: areaAlpha})); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("FEATURE_LOCATION off wins over a bad scope (handler)", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.flags.on[location.FlagName] = false
		srv := NewServer(e.flags, e.svc)
		_, err := srv.ListNearbyBeacons(authn.WithClaims(ctx, authn.Claims{UID: testViewer}), connect.NewRequest(&beaconsv1.ListNearbyBeaconsRequest{AreaId: areaAlpha, Scope: beaconsv1.NearbyScope(9)}))
		assertDisabled(t, err, location.FlagName)
	})
	t.Run("an unknown scope is VALIDATION scope (handler)", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		srv := NewServer(e.flags, e.svc)
		_, err := srv.ListNearbyBeacons(authn.WithClaims(ctx, authn.Claims{UID: testViewer}), connect.NewRequest(&beaconsv1.ListNearbyBeaconsRequest{AreaId: areaAlpha, Scope: beaconsv1.NearbyScope(9)}))
		assertValidation(t, err, "scope")
	})
	// Through the handler, the two answers PR 6 branches on are the bare *apierr.Error (no wrapper) with their metadata.
	for _, tc := range []struct {
		name, areaID, key, want string
		code                    connect.Code
	}{
		{"unknown area_id", "in.tst.nowhere", "field", "area_id", connect.CodeInvalidArgument},
		{"no stored area", "", "reason", "area_not_set", connect.CodeFailedPrecondition},
	} {
		t.Run(tc.name+" on the wire (handler)", func(t *testing.T) {
			t.Parallel()
			e, _ := newAreaEnv(t)
			srv := NewServer(e.flags, e.svc)
			_, err := srv.ListNearbyBeacons(authn.WithClaims(ctx, authn.Claims{UID: testViewer}), connect.NewRequest(&beaconsv1.ListNearbyBeaconsRequest{AreaId: tc.areaID}))
			ae, ok := err.(*apierr.Error) //nolint:errorlint // the handler must answer the shaped error itself, not a wrapper
			if !ok {
				t.Fatalf("err = %T %v, want a bare *apierr.Error", err, err)
			}
			if ae.Code != tc.code || ae.Metadata[tc.key] != tc.want {
				t.Errorf("code %v meta %v, want %v %s=%s", ae.Code, ae.Metadata, tc.code, tc.key, tc.want)
			}
		})
	}
	for _, id := range []string{"nowhere", "in.tst.nowhere"} {
		t.Run("area_id "+id+" is VALIDATION area_id", func(t *testing.T) {
			t.Parallel()
			e, my := newAreaEnv(t)
			_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: id})
			assertValidation(t, err, "area_id")
			if len(e.repo.nqueries) != 0 || my.calls != 0 {
				t.Error("a read ran")
			}
		})
	}
	t.Run("no area_id and no stored area is area_not_set", func(t *testing.T) {
		t.Parallel()
		e, my := newAreaEnv(t)
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{})
		assertPrecondition(t, err, "area_not_set")
		if my.calls != 1 || len(e.repo.nqueries) != 0 {
			t.Errorf("reads: my area %d, queries %d", my.calls, len(e.repo.nqueries))
		}
	})
	t.Run("a retired area may be browsed", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		if _, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaRetired}); err != nil {
			t.Fatal(err)
		}
	})
}

func TestListNearby_ScopeAndQuery(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	for _, tc := range []struct {
		name           string
		stored, param  string
		scope          NearbyScope
		wantArea, city string
	}{
		{"the stored area, AREA scope", areaAlpha, "", "", areaAlpha, ""},
		{"a named area, CITY scope", "", areaBeta, NearbyScopeCity, "", areaCity},
		{"a CITY area forces CITY scope", "", areaCityOnly, NearbyScopeArea, "", areaCityOnly},
		{"a stored CITY area forces CITY scope", areaCity, "", "", "", areaCity},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e, my := newAreaEnv(t)
			if tc.stored != "" {
				my.areas[testViewer] = tc.stored
			}
			page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: tc.param, Scope: tc.scope})
			if err != nil {
				t.Fatal(err)
			}
			q := e.repo.nqueries[0]
			if q.AreaID != tc.wantArea || q.CityID != tc.city || !q.From.Equal(e.now) {
				t.Errorf("query = %+v", q)
			}
			if want := tc.stored + tc.param; page.Area.ID != want {
				t.Errorf("resolved area = %s, want %s", page.Area.ID, want)
			}
		})
	}
}

func TestListNearby_CountAndPaging(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	for _, n := range []int{0, 1, 4, 5} {
		t.Run(fmt.Sprintf("%d plans on one page", n), func(t *testing.T) {
			t.Parallel()
			e, _ := newAreaEnv(t)
			e.repo.nearby = e.nearbyRows(n)
			page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
			if err != nil {
				t.Fatal(err)
			}
			if *page.Count != kAnon(n, 5) || len(page.Items) != n || page.NextPageToken != "" || len(e.repo.cqueries) != 0 {
				t.Errorf("count %+v items %d token %q aggregations %d", *page.Count, len(page.Items), page.NextPageToken, len(e.repo.cqueries))
			}
		})
	}
	t.Run("a blocked organiser's lone plan gives no few", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.repo.nearby = e.nearbyRows(1)
		e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		if err != nil {
			t.Fatal(err)
		}
		if *page.Count != (NearbyCount{}) || len(page.Items) != 0 {
			t.Errorf("count %+v items %d", *page.Count, len(page.Items))
		}
	})
	t.Run("a hidden plan is not counted", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		rows := e.nearbyRows(5)
		rows[2].Hidden = true
		e.repo.nearby = rows
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		if err != nil {
			t.Fatal(err)
		}
		if *page.Count != (NearbyCount{Few: true}) || len(page.Items) != 4 {
			t.Errorf("count %+v items %d", *page.Count, len(page.Items))
		}
	})
	t.Run("limit 1 cannot turn a filtered thin area into a number", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		rows := e.nearbyRows(5)
		rows[4].OrganiserID = "blocked-org"
		e.dir.profiles["blocked-org"] = activeProfile("blocked-org")
		e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{"blocked-org": true}}
		e.repo.nearby = rows
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha, Limit: 1})
		if err != nil {
			t.Fatal(err)
		}
		if *page.Count != (NearbyCount{Few: true}) || len(e.repo.cqueries) != 0 {
			t.Errorf("count %+v aggregations %d: the blocked plan moved the count", *page.Count, len(e.repo.cqueries))
		}
		if len(page.Items) != 1 || page.NextPageToken == "" || e.repo.nqueries[0].Limit != 6 {
			t.Errorf("items %d token %q probe %d", len(page.Items), page.NextPageToken, e.repo.nqueries[0].Limit)
		}
	})
	t.Run("more than one page uses the aggregation, later pages carry no count", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		e.repo.nearby = e.nearbyRows(30)
		e.repo.countN = 30
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha, Limit: 10})
		if err != nil {
			t.Fatal(err)
		}
		if *page.Count != (NearbyCount{Plans: 30}) || len(page.Items) != 10 || page.NextPageToken == "" {
			t.Fatalf("count %+v items %d token %q", *page.Count, len(page.Items), page.NextPageToken)
		}
		if c := e.repo.cqueries[0]; c.AfterID != "" || c.Limit != nearbyCountCap || c.AreaID != areaAlpha {
			t.Errorf("count query = %+v", c)
		}
		next, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha, Limit: 10, PageToken: page.NextPageToken})
		if err != nil {
			t.Fatal(err)
		}
		if next.Count != nil || len(e.repo.cqueries) != 1 {
			t.Error("a later page counted")
		}
		if q := e.repo.nqueries[1]; q.AfterID != page.Items[9].View.Beacon.ID || q.Limit != 11 {
			t.Errorf("second query = %+v", q)
		}
		// The token is bound to the area and the scope.
		_, err = e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaBeta, Limit: 10, PageToken: page.NextPageToken})
		assertValidation(t, err, "page_token")
		_, err = e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha, Scope: NearbyScopeCity, Limit: 10, PageToken: page.NextPageToken})
		assertValidation(t, err, "page_token")
	})
	t.Run("proximity per row", func(t *testing.T) {
		t.Parallel()
		e, _ := newAreaEnv(t)
		rows := e.nearbyRows(3)
		rows[1].Area = denormalise(lookupArea(t, areaGamma))
		rows[2].Area = denormalise(lookupArea(t, areaCity))
		e.repo.nearby = rows
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaBeta, Scope: NearbyScopeCity})
		if err != nil {
			t.Fatal(err)
		}
		got := []Proximity{page.Items[0].Proximity, page.Items[1].Proximity, page.Items[2].Proximity}
		if fmt.Sprint(got) != fmt.Sprint([]Proximity{ProximityNeighbouring, ProximityNeighbouring, ProximitySameCity}) {
			t.Errorf("proximity = %v", got)
		}
		resp := toNearbyResponse(page)
		if resp.GetArea().GetAreaId() != areaBeta || resp.GetItems()[2].GetProximity() != beaconsv1.AreaProximity_AREA_PROXIMITY_SAME_CITY || resp.GetCount() == nil {
			t.Errorf("wire = %v", resp)
		}
	})
}

// TestListNearby_IndexNotReadyDegrades is not parallel: its subtests swap the global slog logger (captureLogs).
func TestListNearby_IndexNotReadyDegrades(t *testing.T) {
	ctx := context.Background()
	t.Run("the list", func(t *testing.T) {
		e, _ := newAreaEnv(t)
		logs := captureLogs(t)
		e.repo.nearbyErr = fmt.Errorf("wrapped: %w", ErrNearbyIndex)
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		if err != nil {
			t.Fatalf("err = %v, want an empty page", err)
		}
		if len(page.Items) != 0 || page.Count != nil || page.NextPageToken != "" || page.Area.ID != areaAlpha {
			t.Errorf("page = %+v", page)
		}
		if !strings.Contains(logs.String(), "beacons_nearby_index_not_ready") {
			t.Errorf("no warning: %s", logs)
		}
	})
	t.Run("the count", func(t *testing.T) {
		e, _ := newAreaEnv(t)
		captureLogs(t)
		e.repo.nearby = e.nearbyRows(30)
		e.repo.countErr = ErrNearbyIndex
		page, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		if err != nil {
			t.Fatal(err)
		}
		if page.Count != nil || len(page.Items) != 20 {
			t.Errorf("count %+v items %d", page.Count, len(page.Items))
		}
	})
	t.Run("any other error fails the call", func(t *testing.T) {
		e, _ := newAreaEnv(t)
		e.repo.nearbyErr = errors.New("boom")
		if _, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha}); err == nil {
			t.Fatal("want an error")
		}
	})
}

// TestNearbyAndAreas_LogNoAreaID: no catalogue id reaches the request line, a slog record or an error message on the
// area paths (design 5.5), including failures.
func TestNearbyAndAreas_LogNoAreaID(t *testing.T) {
	e, my := newAreaEnv(t)
	logs := captureLogs(t)
	my.areas[testViewer] = areaBeta
	e.repo.nearby = e.nearbyRows(30)
	var fields []string
	var errs []string
	run := func(f func(ctx context.Context) error) {
		ctx, info := logger.WithRequestInfo(context.Background())
		if err := f(ctx); err != nil {
			errs = append(errs, err.Error())
		}
		fields = append(fields, fmt.Sprint(info.Fields()))
	}
	run(func(ctx context.Context) error {
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{})
		return err
	})
	run(func(ctx context.Context) error {
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaGamma, Scope: NearbyScopeCity})
		return err
	})
	run(func(ctx context.Context) error {
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: "in.tst.nowhere"})
		return err
	})
	in := validCreate()
	in.AreaID = areaRetired
	run(func(ctx context.Context) error { _, err := e.svc.CreateBeacon(ctx, testOrganiser, in); return err })
	e.repo.nearbyErr = ErrNearbyIndex
	run(func(ctx context.Context) error {
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{AreaID: areaAlpha})
		return err
	})
	// A failed stored-area read whose text names the stored id (and its city): it must still not reach the error or a log.
	e.repo.nearbyErr, my.err = nil, fmt.Errorf("my area read failed for %s (city %s)", areaBeta, areaCity)
	run(func(ctx context.Context) error {
		_, err := e.svc.ListNearby(ctx, testViewer, NearbyInput{})
		return err
	})
	all := logs.String() + strings.Join(fields, "\n") + strings.Join(errs, "\n")
	if len(errs) != 3 {
		t.Fatalf("errors = %v, want 3 (unknown area, retired area, failed read)", errs)
	}
	if strings.Contains(all, "in.tst") || strings.Contains(all, "in.oth") {
		t.Errorf("an area id reached the logs or errors:\n%s", all)
	}
	if !strings.Contains(all, fieldNearbyScope) || !strings.Contains(all, fieldHasAreaParam) {
		t.Errorf("the request line lacks the nearby fields:\n%s", all)
	}
}

// TestExportedBeacon_AreaID: the export carries the plan's area id and omits the key for a plan without one.
func TestExportedBeacon_AreaID(t *testing.T) {
	t.Parallel()
	with, err := json.Marshal(ExportedBeacon{BeaconID: testBeaconID, AreaID: areaAlpha})
	if err != nil {
		t.Fatal(err)
	}
	without, err := json.Marshal(ExportedBeacon{BeaconID: testBeaconID})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(with), `"areaId":"in.tst.alpha"`) || strings.Contains(string(without), "areaId") {
		t.Errorf("with %s, without %s", with, without)
	}
}
