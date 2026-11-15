//go:build integration

package apiserver

// Location over the real Build chain (Firestore, Auth, Pub/Sub and Storage emulators): the FEATURE_LOCATION classes
// through the interceptor chain (SetArea needs the flag on; GetLocationSettings and ClearArea work under the kill switch),
// then the `location` export section and the `location` erasure step through the production jobs handler: after deletion
// no area doc and no consent record remain (the residue sweep in account_lifecycle_sweep_integration_test.go covers both
// collections through their guard rows).

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1/locationv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func locationMode(mode flags.Mode) func(*config.Config) {
	return func(c *config.Config) { c.FeatureLocation = flags.Spec{Name: "location", Mode: mode} }
}

func setAreaReq(key, area string, consent bool) *locationv1.SetAreaRequest {
	r := &locationv1.SetAreaRequest{IdempotencyKey: key, AreaId: area}
	if consent {
		r.Consent = &locationv1.ConsentGrant{CopyVersion: 1, AdultConfirmed: true}
	}
	return r
}

func TestLocationChain_KillSwitchKeepsSeeAndWithdraw(t *testing.T) {
	e := newChainWith(t, locationMode(flags.Off), nil)
	tok, _ := mintToken(t, "")
	e.createProfile(t, tok)
	loc := locationv1connect.NewLocationServiceClient(http.DefaultClient, e.url)
	ctx := context.Background()
	_, err := loc.SetArea(ctx, authed(tok, setAreaReq("loc-chain-key-off-01", "in.blr.indiranagar", true)))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "location")
	_, err = loc.ListAreas(ctx, authed(tok, &locationv1.ListAreasRequest{}))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "location")
	if _, err := loc.GetLocationSettings(ctx, authed(tok, &locationv1.GetLocationSettingsRequest{})); err != nil {
		t.Fatalf("GetLocationSettings under the kill switch: %v", err)
	}
	if _, err := loc.ClearArea(ctx, authed(tok, &locationv1.ClearAreaRequest{IdempotencyKey: "loc-chain-key-off-02"})); err != nil {
		t.Fatalf("ClearArea under the kill switch: %v", err)
	}
}

func TestLocationChain_ExportAndErase(t *testing.T) {
	le := newLifecycleEnvCfg(t, nil, locationMode(flags.On))
	u := le.newUser(t)
	loc := locationv1connect.NewLocationServiceClient(http.DefaultClient, le.url)
	ctx := context.Background()
	for _, step := range []func() error{
		func() error {
			_, err := loc.SetArea(ctx, authed(u.token, setAreaReq("loc-chain-key-000001", "in.blr.indiranagar", true)))
			return err
		},
		func() error {
			_, err := loc.ClearArea(ctx, authed(u.token, &locationv1.ClearAreaRequest{IdempotencyKey: "loc-chain-key-000002"}))
			return err
		},
		func() error {
			_, err := loc.SetArea(ctx, authed(u.token, setAreaReq("loc-chain-key-000003", "in.mum.bandra", true)))
			return err
		},
	} {
		if err := step(); err != nil {
			t.Fatal(err)
		}
	}
	got, err := loc.GetLocationSettings(ctx, authed(u.token, &locationv1.GetLocationSettingsRequest{}))
	if err != nil || got.Msg.GetSettings().GetArea().GetAreaId() != "in.mum.bandra" {
		t.Fatalf("settings: %v, %v", got, err)
	}

	_, raw := le.exportOf(t, u, "loc-chain-export-0001")
	var env struct {
		Location struct {
			Area *struct {
				AreaID   string `json:"areaId"`
				Name     string `json:"name"`
				CityName string `json:"cityName"`
				SetAt    string `json:"setAt"`
			} `json:"area"`
			Consents []struct {
				ID     string `json:"id"`
				Action string `json:"action"`
			} `json:"consents"`
		} `json:"location"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatalf("export is not JSON: %v", err)
	}
	l := env.Location
	if l.Area == nil || l.Area.AreaID != "in.mum.bandra" || l.Area.Name != "Bandra" || l.Area.CityName != "Mumbai" || l.Area.SetAt == "" {
		t.Fatalf("export area = %+v", l.Area)
	}
	if len(l.Consents) != 3 || l.Consents[0].Action != "granted" || l.Consents[1].Action != "withdrawn" || l.Consents[2].Action != "granted" ||
		l.Consents[0].ID >= l.Consents[1].ID || l.Consents[1].ID >= l.Consents[2].ID {
		t.Fatalf("export consents = %+v", l.Consents)
	}

	le.runDeletion(t, u, "loc-chain-delete-0001")
	user := le.fs.Collection("users").Doc(u.uid)
	if snap, err := user.Collection("locationArea").Doc("current").Get(ctx); err == nil && snap.Exists() {
		t.Fatal("the area doc survived the deletion")
	}
	if docs, err := user.Collection("locationConsents").Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Fatalf("consent records survived the deletion: %d, %v", len(docs), err)
	}
}
