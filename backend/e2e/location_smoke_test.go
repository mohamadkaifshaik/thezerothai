//go:build integration

package e2e

// Location + Nearby E2E smoke (docs/plans/location-p1-p2-design-2026-11-15.md, PR 7). Two modes, like
// beacons_smoke_test.go:
//
//   - Emulator mode (default, `make test-int` style, emulators up): boots the real handler via newTestServerCfg with
//     FEATURE_LOCATION and FEATURE_BEACONS forced on in the config (no env needed), mints two Auth emulator users and
//     creates their profiles. Skips when FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST are not set.
//   - Remote mode (a running API, e.g. `go run ./cmd/api` on 8081, or a dev URL): set E2E_LOCATION_BASE_URL plus
//     E2E_LOCATION_ID_TOKEN_A and E2E_LOCATION_ID_TOKEN_B (two accounts that already have profiles). That API needs
//     FEATURE_LOCATION=on and FEATURE_BEACONS=on (or both allowlisted for the two accounts). When either is off for
//     the caller the test skips with a message; it never fails on a flag it cannot set.
//
// The loop: A lists the areas and stores an area with consent (GetLocationSettings shows the area and
// current_copy_version); B creates a public plan in A's area and one in a neighbouring area; A's Nearby (AREA scope)
// finds both with SAME_AREA / NEIGHBOURING and the area label on each plan; CITY scope finds both too; A clears the
// area and Nearby answers FAILED_PRECONDITION reason area_not_set. B's plans are cancelled on cleanup. Shared
// emulators keep other runs' plans, so assertions look for this run's plan ids, never for exact counts.

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"slices"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1/locationv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	// Catalogue ids (internal/location/areas/areas.json): Vastrapur lists Bodakdev as a neighbour.
	smokeAreaID      = "in.amd.vastrapur"
	smokeNeighbourID = "in.amd.bodakdev"
	smokeCityID      = "in.amd"
)

type locationSmokeEnv struct {
	location locationv1connect.LocationServiceClient
	beacons  beaconsv1connect.BeaconServiceClient
	tokenA   string
	tokenB   string
}

// resolveLocationSmokeMode follows beacons: a URL without both tokens is an error, never a silent emulator fall back.
func resolveLocationSmokeMode(getenv func(string) string) (baseURL, tokenA, tokenB string, err error) {
	baseURL = getenv("E2E_LOCATION_BASE_URL")
	if baseURL == "" {
		return "", "", "", nil
	}
	tokenA, tokenB = getenv("E2E_LOCATION_ID_TOKEN_A"), getenv("E2E_LOCATION_ID_TOKEN_B")
	if tokenA == "" || tokenB == "" {
		return "", "", "", errors.New("E2E_LOCATION_BASE_URL is set but E2E_LOCATION_ID_TOKEN_A / E2E_LOCATION_ID_TOKEN_B are not")
	}
	return baseURL, tokenA, tokenB, nil
}

func TestE2E_LocationSmoke_RemoteNeedsTokens(t *testing.T) {
	t.Parallel()
	for name, env := range map[string]map[string]string{
		"no tokens": {"E2E_LOCATION_BASE_URL": "https://api.example"},
		"only A":    {"E2E_LOCATION_BASE_URL": "https://api.example", "E2E_LOCATION_ID_TOKEN_A": "a"},
		"only B":    {"E2E_LOCATION_BASE_URL": "https://api.example", "E2E_LOCATION_ID_TOKEN_B": "b"},
	} {
		if _, _, _, err := resolveLocationSmokeMode(func(k string) string { return env[k] }); err == nil {
			t.Errorf("%s: want an error, got none", name)
		}
	}
	if u, _, _, err := resolveLocationSmokeMode(func(string) string { return "" }); err != nil || u != "" {
		t.Fatalf("nothing set: want emulator mode, got %q, %v", u, err)
	}
}

func setupLocationSmoke(t *testing.T) locationSmokeEnv {
	t.Helper()
	base, tokA, tokB, err := resolveLocationSmokeMode(os.Getenv)
	if err != nil {
		t.Fatal(err)
	}
	if base != "" {
		return locationSmokeEnv{
			location: locationv1connect.NewLocationServiceClient(http.DefaultClient, base),
			beacons:  beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, base),
			tokenA:   tokA,
			tokenB:   tokB,
		}
	}
	skipIfNoEmulators(t)
	_, baseURL := newTestServerCfg(t, func(c *config.Config) {
		c.FeatureBeacons = flags.Spec{Name: "beacons", Mode: flags.On}
		c.FeatureLocation = flags.Spec{Name: "location", Mode: flags.On}
	})
	ident := identityv1connect.NewIdentityServiceClient(http.DefaultClient, baseURL)
	create := func(label string) string {
		token, _ := newAnonymousIDToken(t)
		_, err := ident.CreateProfile(context.Background(), authedRequest(token, &identityv1.CreateProfileRequest{
			IdempotencyKey: fmt.Sprintf("e2e-location-create-%s-%d", label, rand.Int63()),
			Handle:         uniqueHandle("l7" + label),
			DisplayName:    "Location Smoke " + label,
		}))
		if err != nil {
			t.Fatalf("CreateProfile(%s): %v", label, err)
		}
		return token
	}
	return locationSmokeEnv{
		location: locationv1connect.NewLocationServiceClient(http.DefaultClient, baseURL),
		beacons:  beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, baseURL),
		tokenA:   create("a"),
		tokenB:   create("b"),
	}
}

func locKey(op string) string { return fmt.Sprintf("e2e-location-%s-%d", op, rand.Int63()) }

// skipIfFlagsOff probes with one read per feature and skips with the reason when either is off for the caller.
func (e locationSmokeEnv) skipIfFlagsOff(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	_, err := e.location.GetLocationSettings(ctx, authedRequest(e.tokenA, &locationv1.GetLocationSettingsRequest{}))
	if connect.CodeOf(err) == connect.CodeFailedPrecondition {
		t.Skipf("FEATURE_LOCATION is off for the caller (%v); start the API with FEATURE_LOCATION=on FEATURE_BEACONS=on", err)
	}
	_, err = e.beacons.ListBeacons(ctx, authedRequest(e.tokenA, &beaconsv1.ListBeaconsRequest{
		Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Limit: 1,
	}))
	if connect.CodeOf(err) == connect.CodeFailedPrecondition {
		t.Skipf("FEATURE_BEACONS is off for the caller (%v); start the API with FEATURE_LOCATION=on FEATURE_BEACONS=on", err)
	}
}

func (e locationSmokeEnv) createPlan(t *testing.T, areaID, title string) string {
	t.Helper()
	ctx := context.Background()
	res, err := e.beacons.CreateBeacon(ctx, authedRequest(e.tokenB, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey:  locKey("create"),
		Audience:        &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity:        beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE,
		Title:           title,
		Venue:           "Food court",
		StartAt:         timestamppb.New(time.Now().Add(time.Hour)),
		DurationMinutes: 30,
		OpenSpots:       2,
		Cost:            beaconsv1.BeaconCost_BEACON_COST_FREE,
		ChatPreference:  beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
		AreaId:          areaID,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon(area %s): %v", areaID, err)
	}
	id := res.Msg.GetView().GetBeacon().GetBeaconId()
	t.Cleanup(func() {
		if _, err := e.beacons.CancelBeacon(ctx, authedRequest(e.tokenB, &beaconsv1.CancelBeaconRequest{IdempotencyKey: locKey("cancel"), BeaconId: id})); err != nil {
			t.Errorf("cleanup CancelBeacon: %v", err)
		}
	})
	if got := res.Msg.GetView().GetBeacon().GetArea().GetAreaId(); got != areaID {
		t.Fatalf("CreateBeacon: beacon.area = %q, want %q", got, areaID)
	}
	return id
}

// findNearby pages Nearby (limit 50, at most 20 pages) until every wanted id is seen, returning the items by id.
func (e locationSmokeEnv) findNearby(t *testing.T, scope beaconsv1.NearbyScope, want ...string) map[string]*beaconsv1.NearbyBeacon {
	t.Helper()
	got := map[string]*beaconsv1.NearbyBeacon{}
	eventually(t, "Nearby lists the new plans", 10*time.Second, 250*time.Millisecond, func() (bool, string) {
		token := ""
		for page := 0; page < 20; page++ {
			res, err := e.beacons.ListNearbyBeacons(context.Background(), authedRequest(e.tokenA, &beaconsv1.ListNearbyBeaconsRequest{
				Scope: scope, Limit: 50, PageToken: token,
			}))
			if err != nil {
				t.Fatalf("ListNearbyBeacons(%v): %v", scope, err)
			}
			for _, it := range res.Msg.GetItems() {
				got[it.GetView().GetBeacon().GetBeaconId()] = it
			}
			if token = res.Msg.GetNextPageToken(); token == "" {
				break
			}
		}
		for _, id := range want {
			if got[id] == nil {
				return false, fmt.Sprintf("plan %s not among %d items", id, len(got))
			}
		}
		return true, ""
	})
	return got
}

func TestE2E_LocationSmoke_SetAreaNearbyClear(t *testing.T) {
	env := setupLocationSmoke(t)
	env.skipIfFlagsOff(t)
	ctx := context.Background()

	// 1. A lists the catalogue: it holds the smoke areas, the neighbour link and the city.
	areas, err := env.location.ListAreas(ctx, authedRequest(env.tokenA, &locationv1.ListAreasRequest{Limit: 500}))
	if err != nil {
		t.Fatalf("ListAreas: %v", err)
	}
	have := map[string]*locationv1.Area{}
	for _, a := range areas.Msg.GetAreas() {
		have[a.GetAreaId()] = a
	}
	for _, id := range []string{smokeAreaID, smokeNeighbourID, smokeCityID} {
		if have[id] == nil {
			t.Fatalf("ListAreas: no %s among %d areas (next_page_token %q)", id, len(have), areas.Msg.GetNextPageToken())
		}
	}
	if !slices.Contains(have[smokeAreaID].GetNeighbourIds(), smokeNeighbourID) {
		t.Fatalf("ListAreas: %s neighbours = %v, want %s", smokeAreaID, have[smokeAreaID].GetNeighbourIds(), smokeNeighbourID)
	}

	// 2. Before any area: Nearby with no area_id is area_not_set.
	_, err = env.beacons.ListNearbyBeacons(ctx, authedRequest(env.tokenA, &beaconsv1.ListNearbyBeaconsRequest{}))
	assertAreaNotSet(t, err)

	// 3. A stores the area with consent; settings show it and the current copy version.
	cur, err := env.location.GetLocationSettings(ctx, authedRequest(env.tokenA, &locationv1.GetLocationSettingsRequest{}))
	if err != nil {
		t.Fatalf("GetLocationSettings (before): %v", err)
	}
	copyV := cur.Msg.GetSettings().GetCurrentCopyVersion()
	if copyV < 1 {
		t.Fatalf("GetLocationSettings: current_copy_version = %d, want >= 1", copyV)
	}
	if _, err := env.location.SetArea(ctx, authedRequest(env.tokenA, &locationv1.SetAreaRequest{
		IdempotencyKey: locKey("set"),
		AreaId:         smokeAreaID,
		Consent:        &locationv1.ConsentGrant{CopyVersion: copyV, AdultConfirmed: true},
	})); err != nil {
		t.Fatalf("SetArea: %v", err)
	}
	got, err := env.location.GetLocationSettings(ctx, authedRequest(env.tokenA, &locationv1.GetLocationSettingsRequest{}))
	if err != nil {
		t.Fatalf("GetLocationSettings (after): %v", err)
	}
	s := got.Msg.GetSettings()
	if s.GetArea().GetAreaId() != smokeAreaID || s.GetCurrentCopyVersion() != copyV ||
		s.GetConsent().GetAction() != locationv1.LocationConsentAction_LOCATION_CONSENT_ACTION_GRANTED {
		t.Fatalf("GetLocationSettings after SetArea = %v, want area %s, copy version %d, GRANTED", s, smokeAreaID, copyV)
	}

	// 4. B creates a public plan in A's area and one in the neighbour.
	same := env.createPlan(t, smokeAreaID, "Smoke same area")
	near := env.createPlan(t, smokeNeighbourID, "Smoke neighbour")

	// 5. A's Nearby, AREA scope on the stored area: both plans, labelled; the first page resolves the area and counts.
	items := env.findNearby(t, beaconsv1.NearbyScope_NEARBY_SCOPE_AREA, same, near)
	if p := items[same].GetProximity(); p != beaconsv1.AreaProximity_AREA_PROXIMITY_SAME_AREA {
		t.Errorf("same-area plan proximity = %v, want SAME_AREA", p)
	}
	if p := items[near].GetProximity(); p != beaconsv1.AreaProximity_AREA_PROXIMITY_NEIGHBOURING {
		t.Errorf("neighbour plan proximity = %v, want NEIGHBOURING", p)
	}
	for id, want := range map[string]string{same: smokeAreaID, near: smokeNeighbourID} {
		if a := items[id].GetView().GetBeacon().GetArea(); a.GetAreaId() != want || a.GetName() != have[want].GetName() {
			t.Errorf("plan %s label = %v, want %s / %q", id, a, want, have[want].GetName())
		}
	}
	first, err := env.beacons.ListNearbyBeacons(ctx, authedRequest(env.tokenA, &beaconsv1.ListNearbyBeaconsRequest{Limit: 50}))
	if err != nil {
		t.Fatalf("ListNearbyBeacons (first page): %v", err)
	}
	if first.Msg.GetArea().GetAreaId() != smokeAreaID || first.Msg.GetCount() == nil {
		t.Fatalf("first page: area = %v count = %v, want the stored area and a count", first.Msg.GetArea(), first.Msg.GetCount())
	}

	// 6. CITY scope finds both plans too.
	env.findNearby(t, beaconsv1.NearbyScope_NEARBY_SCOPE_CITY, same, near)

	// 7. A clears the area; settings carry no area and Nearby is area_not_set again.
	if _, err := env.location.ClearArea(ctx, authedRequest(env.tokenA, &locationv1.ClearAreaRequest{IdempotencyKey: locKey("clear")})); err != nil {
		t.Fatalf("ClearArea: %v", err)
	}
	cleared, err := env.location.GetLocationSettings(ctx, authedRequest(env.tokenA, &locationv1.GetLocationSettingsRequest{}))
	if err != nil {
		t.Fatalf("GetLocationSettings (cleared): %v", err)
	}
	if a := cleared.Msg.GetSettings().GetArea(); a != nil {
		t.Fatalf("GetLocationSettings after ClearArea: area = %v, want none", a)
	}
	_, err = env.beacons.ListNearbyBeacons(ctx, authedRequest(env.tokenA, &beaconsv1.ListNearbyBeaconsRequest{}))
	assertAreaNotSet(t, err)
}

// assertAreaNotSet wants FAILED_PRECONDITION with ErrorDetail.metadata["reason"] == "area_not_set".
func assertAreaNotSet(t *testing.T, err error) {
	t.Helper()
	assertCode(t, err, connect.CodeFailedPrecondition)
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	for _, d := range cerr.Details() {
		msg, derr := d.Value()
		if derr != nil {
			continue
		}
		if detail, ok := msg.(*commonv1.ErrorDetail); ok && detail.GetMetadata()["reason"] == "area_not_set" {
			return
		}
	}
	t.Fatalf("error %v: no ErrorDetail carries metadata reason=area_not_set", err)
}
