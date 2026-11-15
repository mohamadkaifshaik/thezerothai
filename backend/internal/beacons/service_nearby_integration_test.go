//go:build integration

package beacons

import (
	"context"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/location"
)

// Location P2 on the emulator, over the real catalogue (internal/location/areas/areas.json): Indiranagar's curated
// neighbours are Domlur and Koramangala; Whitefield has none; in.blr is the city.
const (
	itIndiranagar = "in.blr.indiranagar"
	itDomlur      = "in.blr.domlur"
	itWhitefield  = "in.blr.whitefield"
	itBengaluru   = "in.blr"
	itKoramangala = "in.blr.koramangala"
)

type nearbyEnv struct {
	*repoEnv
	svc   Service
	graph *fakeGraph
	my    *fakeMyArea
	cat   *location.StaticCatalog
}

// newNearbyEnv is the real service over the real repository with FEATURE_BEACONS, FEATURE_COMMUNITIES and
// FEATURE_LOCATION on, the real catalogue, every uid an ACTIVE profile and each organiser a JOINED member of itCommunity.
func newNearbyEnv(t *testing.T, uids ...string) *nearbyEnv {
	t.Helper()
	e := newRepoEnv(t)
	cat, err := location.DefaultCatalog()
	if err != nil {
		t.Fatal(err)
	}
	profiles := map[string]identity.Profile{}
	roles := map[string]communities.Role{}
	for _, u := range uids {
		profiles[u] = activeProfile(u)
		roles[itCommunity+"|"+u] = communities.RoleMember
	}
	fl := fakeFlags{on: map[string]bool{FlagName: true, communities.FlagName: true, location.FlagName: true}, off: map[string]bool{}}
	g := &fakeGraph{snaps: map[string]graph.Snapshot{}}
	my := &fakeMyArea{areas: map[string]string{}}
	svc := New(Deps{
		Repo: e.repo, Directory: &fakeDirectory{profiles: profiles}, Graph: g,
		Communities: &fakeCommunities{roles: roles}, CommunityFlags: fl, Flags: fl, Events: &fakeEvents{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Areas: cat, MyArea: my, IDs: e.node,
		Limits: Limits{MaxOpenPerUser: 10, MaxPendingRequests: 10, MaxOpenSpots: 20, NearbyKMin: 5},
		Now:    func() time.Time { return e.now },
	})
	return &nearbyEnv{repoEnv: e, svc: svc, graph: g, my: my, cat: cat}
}

// plan writes a beacon of org at now + hours with the catalogue area areaID ("" = none) through the repository.
func (e *nearbyEnv) plan(t *testing.T, org, communityID, areaID string, hours float64) Beacon {
	t.Helper()
	b := e.beaconAt(org, communityID, e.now.Add(time.Duration(hours*float64(time.Hour))))
	if areaID != "" {
		a, ok := e.cat.Lookup(areaID)
		if !ok {
			t.Fatalf("no catalogue area %s", areaID)
		}
		b.Area = denormalise(a)
	}
	return e.create(t, org, fmt.Sprintf("integration-key-%s-%d", org, int(hours*100)), b).Beacon
}

func (e *nearbyEnv) nearby(t *testing.T, viewer string, in NearbyInput) NearbyPage {
	t.Helper()
	p, err := e.svc.ListNearby(context.Background(), viewer, in)
	if err != nil {
		t.Fatalf("ListNearby(%+v): %v", in, err)
	}
	return p
}

func nearbyIDs(p NearbyPage) []string {
	out := make([]string, 0, len(p.Items))
	for _, it := range p.Items {
		out = append(out, it.View.Beacon.ID)
	}
	return out
}

func (e *nearbyEnv) rawField(t *testing.T, id, field string) (any, bool) {
	t.Helper()
	snap, err := e.client.Collection(beaconsCollection).Doc(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v, err := snap.DataAt(field)
	if err != nil {
		return nil, false
	}
	return v, true
}

// TestIntegrationNearby_AreaFieldsOnCreateUpdateAndClear: CreateBeacon stores areaId, cityId and nearAreaIds; an
// UpdateBeacon to another area rewrites them; "" removes all three; the opsctl lever clears them once.
func TestIntegrationNearby_AreaFieldsOnCreateUpdateAndClear(t *testing.T) {
	const org = "it-nb-org"
	e := newNearbyEnv(t, org)
	ctx := context.Background()
	in := validCreate()
	in.StartAt, in.AreaID = e.now.Add(time.Hour), itIndiranagar
	v, err := e.svc.CreateBeacon(ctx, org, in)
	if err != nil {
		t.Fatal(err)
	}
	id := v.Beacon.ID
	check := func(step, area, city string, near []string) {
		t.Helper()
		gotArea, okA := e.rawField(t, id, "areaId")
		gotCity, okC := e.rawField(t, id, "cityId")
		gotNear, okN := e.rawField(t, id, "nearAreaIds")
		if area == "" {
			if okA || okC || okN {
				t.Errorf("%s: area fields remain: %v %v %v", step, gotArea, gotCity, gotNear)
			}
			return
		}
		if gotArea != area || gotCity != city || fmt.Sprint(gotNear) != fmt.Sprint(near) {
			t.Errorf("%s: stored %v %v %v, want %s %s %v", step, gotArea, gotCity, gotNear, area, city, near)
		}
	}
	check("create", itIndiranagar, itBengaluru, []string{itIndiranagar, itDomlur, itKoramangala})
	if rows, err := e.repo.ExportBeaconsPage(ctx, org, "", 10); err != nil || len(rows) != 1 || rows[0].AreaID != itIndiranagar {
		t.Errorf("export = %+v, %v", rows, err)
	}
	if v.Area == nil || v.Area.ID != itIndiranagar {
		t.Errorf("create view area = %+v", v.Area)
	}

	upd := func(key string, area *string) View {
		t.Helper()
		v, err := e.svc.UpdateBeacon(ctx, org, UpdateInput{Key: key, BeaconID: id, AreaID: area})
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	white, none := itWhitefield, ""
	if v := upd("integration-key-upd1", &white); v.Area == nil || v.Area.ID != itWhitefield {
		t.Errorf("update view area = %+v", v.Area)
	}
	check("update", itWhitefield, itBengaluru, []string{itWhitefield})
	if v := upd("integration-key-upd2", &none); v.Area != nil {
		t.Errorf("removed area still labelled: %+v", v.Area)
	}
	check("remove", "", "", nil)

	ind := itIndiranagar
	upd("integration-key-upd3", &ind)
	changed, err := e.repo.ClearArea(ctx, id, e.now)
	if err != nil || !changed {
		t.Fatalf("ClearArea = %v, %v", changed, err)
	}
	check("clear-area", "", "", nil)
	if changed, err := e.repo.ClearArea(ctx, id, e.now); err != nil || changed {
		t.Errorf("second ClearArea = %v, %v, want no write", changed, err)
	}
	if _, err := e.repo.ClearArea(ctx, "0000000000000000001", e.now); err != ErrNotFound {
		t.Errorf("missing beacon: %v, want ErrNotFound", err)
	}
}

// TestIntegrationNearby_ScopesOrderPagingAndFilters: AREA scope is the area plus its neighbours, soonest first, paged;
// CITY scope is every public live plan of the city; hidden, community and other-city plans are out; the count is
// exact from the filtered rows when the result fits the probe.
func TestIntegrationNearby_ScopesOrderPagingAndFilters(t *testing.T) {
	const org, viewer = "it-nb-org", "it-nb-viewer"
	e := newNearbyEnv(t, org, viewer)
	ind1 := e.plan(t, org, "", itIndiranagar, 1)
	dom := e.plan(t, org, "", itDomlur, 2)
	ind3 := e.plan(t, org, "", itIndiranagar, 3)
	white := e.plan(t, org, "", itWhitefield, 4)
	city := e.plan(t, org, "", itBengaluru, 5)
	comm := e.plan(t, org, itCommunity, itIndiranagar, 6)
	hidden := e.plan(t, org, "", itKoramangala, 2.5)
	e.setField(t, hidden.ID, firestore.Update{Path: "hidden", Value: true})
	e.plan(t, org, "", "in.mum.bandra", 1.5) // another city
	e.plan(t, org, "", "", 1.2)              // no area
	cancelled := e.plan(t, org, "", itIndiranagar, 1.7)
	e.setField(t, cancelled.ID, firestore.Update{Path: "status", Value: string(StatusCancelled)})

	p1 := e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Limit: 2})
	if got := nearbyIDs(p1); fmt.Sprint(got) != fmt.Sprint([]string{ind1.ID, dom.ID}) || p1.NextPageToken == "" {
		t.Fatalf("AREA page 1 = %v token %q", got, p1.NextPageToken)
	}
	if p1.Items[0].Proximity != ProximitySameArea || p1.Items[1].Proximity != ProximityNeighbouring {
		t.Errorf("proximity = %s, %s", p1.Items[0].Proximity, p1.Items[1].Proximity)
	}
	if p1.Count == nil || *p1.Count != (NearbyCount{Few: true}) {
		t.Errorf("AREA count = %+v, want few (3 visible; hidden not counted)", p1.Count)
	}
	p2 := e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Limit: 2, PageToken: p1.NextPageToken})
	if got := nearbyIDs(p2); fmt.Sprint(got) != fmt.Sprint([]string{ind3.ID}) || p2.NextPageToken != "" || p2.Count != nil {
		t.Errorf("AREA page 2 = %v token %q count %+v", got, p2.NextPageToken, p2.Count)
	}

	c := e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Scope: NearbyScopeCity})
	if got := nearbyIDs(c); fmt.Sprint(got) != fmt.Sprint([]string{ind1.ID, dom.ID, ind3.ID, white.ID, city.ID}) {
		t.Errorf("CITY = %v", got)
	}
	if c.Count == nil || *c.Count != (NearbyCount{Plans: 5}) {
		t.Errorf("CITY count = %+v, want 5", c.Count)
	}
	if c.Items[3].Proximity != ProximitySameCity || c.Items[4].Proximity != ProximitySameCity {
		t.Errorf("city proximity = %s, %s", c.Items[3].Proximity, c.Items[4].Proximity)
	}

	// The city itself as the area: CITY scope is forced; the city-tagged plan is SAME_AREA.
	cc := e.nearby(t, viewer, NearbyInput{AreaID: itBengaluru})
	if len(cc.Items) != 5 || cc.Items[4].View.Beacon.ID != city.ID || cc.Items[4].Proximity != ProximitySameArea {
		t.Errorf("city area = %v", nearbyIDs(cc))
	}

	// The organiser sees their own hidden plan, as in ListBeacons (Koramangala's neighbours: Indiranagar, Domlur, ...).
	own := e.nearby(t, org, NearbyInput{AreaID: itKoramangala})
	if got := nearbyIDs(own); fmt.Sprint(got) != fmt.Sprint([]string{ind1.ID, dom.ID, hidden.ID, ind3.ID}) {
		t.Errorf("organiser in Koramangala = %v", got)
	}

	// A community plan joins Nearby once widened (F28b).
	if containsID(nearbyIDs(e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Limit: 50})), comm.ID) {
		t.Fatal("a community plan is listed")
	}
	if _, err := e.svc.UpdateBeacon(context.Background(), org, UpdateInput{Key: "integration-key-widen", BeaconID: comm.ID, Audience: &AudienceInput{Public: true}}); err != nil {
		t.Fatal(err)
	}
	if !containsID(nearbyIDs(e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Limit: 50})), comm.ID) {
		t.Error("a widened plan is not listed")
	}
}

func containsID(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// TestIntegrationNearby_BlocksBothWaysAndStoredArea: a plan across a block in either direction is absent and uncounted;
// no area_id reads the stored area; none is area_not_set.
func TestIntegrationNearby_BlocksBothWaysAndStoredArea(t *testing.T) {
	const org, other, viewer = "it-nb-org", "it-nb-other", "it-nb-viewer"
	e := newNearbyEnv(t, org, other, viewer)
	mine := e.plan(t, org, "", itIndiranagar, 1)
	theirs := e.plan(t, other, "", itIndiranagar, 2)

	_, err := e.svc.ListNearby(context.Background(), viewer, NearbyInput{})
	assertPrecondition(t, err, "area_not_set")
	e.my.areas[viewer] = itDomlur // Indiranagar is Domlur's neighbour
	all := e.nearby(t, viewer, NearbyInput{})
	if fmt.Sprint(nearbyIDs(all)) != fmt.Sprint([]string{mine.ID, theirs.ID}) || all.Area.ID != itDomlur {
		t.Fatalf("stored area = %v (%s)", nearbyIDs(all), all.Area.ID)
	}
	for name, snap := range map[string]graph.Snapshot{
		"viewer blocks":  {Blocked: map[string]bool{other: true}},
		"viewer blocked": {BlockedBy: map[string]bool{other: true}},
	} {
		e.graph.mu.Lock()
		e.graph.snaps[viewer] = snap
		e.graph.mu.Unlock()
		p := e.nearby(t, viewer, NearbyInput{})
		if fmt.Sprint(nearbyIDs(p)) != fmt.Sprint([]string{mine.ID}) || *p.Count != (NearbyCount{Few: true}) {
			t.Errorf("%s: %v count %+v", name, nearbyIDs(p), p.Count)
		}
	}
}

// TestIntegrationNearby_ErasedOrganiserLeaves: the eraser deletes an organiser's area plan, so it leaves Nearby.
func TestIntegrationNearby_ErasedOrganiserLeaves(t *testing.T) {
	const org, viewer = "it-nb-doomed", "it-nb-viewer"
	e := newNearbyEnv(t, org, viewer)
	e.plan(t, org, "", itIndiranagar, 1)
	if len(e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar}).Items) != 1 {
		t.Fatal("seed not listed")
	}
	er := NewEraser(e.repo)
	var cp Checkpoint
	for i, done := 0, false; !done; i++ {
		var err error
		if cp, done, err = er.PurgeUser(context.Background(), org, cp); err != nil {
			t.Fatal(err)
		}
		if i > 10 {
			t.Fatal("eraser did not finish")
		}
	}
	p := e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar})
	if len(p.Items) != 0 || *p.Count != (NearbyCount{}) {
		t.Errorf("after erasure: %v count %+v", nearbyIDs(p), p.Count)
	}
}

// TestIntegrationNearby_MultiPageCountAggregates: a result past the first-page probe is counted by the aggregation over
// the same filter (before the viewer filters), capped by the query limit.
func TestIntegrationNearby_MultiPageCountAggregates(t *testing.T) {
	const org, viewer = "it-nb-org", "it-nb-viewer"
	e := newNearbyEnv(t, org, viewer)
	for i := range 7 {
		e.plan(t, org, "", itIndiranagar, float64(i+1))
	}
	e.plan(t, org, "", itWhitefield, 9)
	p := e.nearby(t, viewer, NearbyInput{AreaID: itIndiranagar, Limit: 2})
	if len(p.Items) != 2 || p.NextPageToken == "" || p.Count == nil || *p.Count != (NearbyCount{Plans: 7}) {
		t.Fatalf("items %d token %q count %+v", len(p.Items), p.NextPageToken, p.Count)
	}
	n, err := e.repo.CountNearby(context.Background(), NearbyQuery{CityID: itBengaluru, From: e.now, Limit: 3})
	if err != nil || n != 3 {
		t.Errorf("capped city count = %d, %v, want 3", n, err)
	}
}
