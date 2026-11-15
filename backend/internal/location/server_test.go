package location

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func callerCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

// rpcCall runs one RPC on srv for uid; each call uses a fresh idempotency key.
type rpcCall struct {
	name string
	run  func(ctx context.Context, srv *Server, n int) error
}

var allRPCs = []rpcCall{
	{"GetLocationSettings", func(ctx context.Context, srv *Server, _ int) error {
		_, err := srv.GetLocationSettings(ctx, connect.NewRequest(&locationv1.GetLocationSettingsRequest{}))
		return err
	}},
	{"SetArea", func(ctx context.Context, srv *Server, n int) error {
		_, err := srv.SetArea(ctx, connect.NewRequest(&locationv1.SetAreaRequest{
			IdempotencyKey: key(fmt.Sprintf("set%d", n)), AreaId: areaIndi, Consent: &locationv1.ConsentGrant{CopyVersion: 1, AdultConfirmed: true},
		}))
		return err
	}},
	{"ClearArea", func(ctx context.Context, srv *Server, n int) error {
		_, err := srv.ClearArea(ctx, connect.NewRequest(&locationv1.ClearAreaRequest{IdempotencyKey: key(fmt.Sprintf("clr%d", n))}))
		return err
	}},
	{"ListAreas", func(ctx context.Context, srv *Server, _ int) error {
		_, err := srv.ListAreas(ctx, connect.NewRequest(&locationv1.ListAreasRequest{Limit: 3}))
		return err
	}},
}

// TestServer_FlagClasses: every RPC in every flag mode. SetArea needs the flag on for the caller; ListAreas needs it not
// globally off; GetLocationSettings and ClearArea work in every mode, the kill switch included (DPDP: always see and
// withdraw). A disabled answer is FEATURE_DISABLED with feature=location and touches no storage.
func TestServer_FlagClasses(t *testing.T) {
	modes := []struct {
		name  string
		flags FlagChecker
		// allowed per RPC name
		allowed map[string]bool
	}{
		{"kill switch", fakeFlags{off: true}, map[string]bool{"GetLocationSettings": true, "ClearArea": true}},
		{"allowlist, caller outside", fakeFlags{on: map[string]bool{uidB: true}}, map[string]bool{"GetLocationSettings": true, "ClearArea": true, "ListAreas": true}},
		{"allowlist, caller inside", fakeFlags{on: map[string]bool{uidA: true}}, map[string]bool{"GetLocationSettings": true, "ClearArea": true, "ListAreas": true, "SetArea": true}},
		{"nil checker", nil, map[string]bool{"GetLocationSettings": true, "ClearArea": true}},
	}
	for _, m := range modes {
		for i, rpc := range allRPCs {
			t.Run(m.name+"/"+rpc.name, func(t *testing.T) {
				e := newEnv(t, Limits{})
				srv := NewServer(m.flags, e.svc)
				err := rpc.run(callerCtx(uidA), srv, i)
				if m.allowed[rpc.name] {
					if err != nil {
						t.Fatalf("want success, got %v", err)
					}
					return
				}
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagName {
					t.Fatalf("want FEATURE_DISABLED feature=location, got %v", err)
				}
				if e.repo.reads != 0 || len(e.repo.idem) != 0 {
					t.Fatalf("a disabled call touched storage")
				}
			})
		}
	}
}

// TestServer_Unauthenticated and unwired: no uid is UNAUTHENTICATED; a server without a service is UNIMPLEMENTED.
func TestServer_UnauthenticatedAndUnwired(t *testing.T) {
	on := fakeFlags{on: map[string]bool{uidA: true}}
	for i, rpc := range allRPCs {
		if err := rpc.run(context.Background(), NewServer(on, newEnv(t, Limits{}).svc), i); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Errorf("%s without a uid: %v", rpc.name, err)
		}
		if err := rpc.run(callerCtx(uidA), NewServer(on, nil), i); connect.CodeOf(err) != connect.CodeUnimplemented {
			t.Errorf("%s unwired: %v", rpc.name, err)
		}
	}
}

// TestServer_Rendering: SetArea answers the area summary and the consent state; ListAreas renders kinds and neighbours.
func TestServer_Rendering(t *testing.T) {
	e := newEnv(t, Limits{})
	srv := NewServer(fakeFlags{on: map[string]bool{uidA: true}}, e.svc)
	ctx := callerCtx(uidA)
	res, err := srv.SetArea(ctx, connect.NewRequest(&locationv1.SetAreaRequest{
		IdempotencyKey: key("r1"), AreaId: areaIndi, Consent: &locationv1.ConsentGrant{CopyVersion: 1, AdultConfirmed: true},
	}))
	if err != nil {
		t.Fatal(err)
	}
	s := res.Msg.GetSettings()
	if a := s.GetArea(); a.GetAreaId() != areaIndi || a.GetKind() != locationv1.AreaKind_AREA_KIND_AREA || a.GetCityId() != cityBlr || a.GetCityName() != "Bengaluru" {
		t.Fatalf("area = %v", a)
	}
	if c := s.GetConsent(); c.GetAction() != locationv1.LocationConsentAction_LOCATION_CONSENT_ACTION_GRANTED ||
		c.GetPurpose() != locationv1.LocationPurpose_LOCATION_PURPOSE_PLANS_NEARBY || c.GetCopyVersion() != 1 || c.GetAt() == nil || c.GetAdultConfirmedAt() == nil {
		t.Fatalf("consent = %v", c)
	}
	if s.GetRequiredCopyVersion() != 1 {
		t.Fatalf("required copy = %d", s.GetRequiredCopyVersion())
	}
	g, err := srv.GetLocationSettings(callerCtx(uidB), connect.NewRequest(&locationv1.GetLocationSettingsRequest{}))
	if err != nil || g.Msg.GetSettings().GetArea() != nil || g.Msg.GetSettings().GetConsent().GetAt() != nil {
		t.Fatalf("empty settings = %v, %v", g, err)
	}
	l, err := srv.ListAreas(ctx, connect.NewRequest(&locationv1.ListAreasRequest{Limit: 500}))
	if err != nil {
		t.Fatal(err)
	}
	var sawCity, sawNeighbours bool
	for _, a := range l.Msg.GetAreas() {
		sawCity = sawCity || (a.GetKind() == locationv1.AreaKind_AREA_KIND_CITY && a.GetCityId() == a.GetAreaId())
		sawNeighbours = sawNeighbours || len(a.GetNeighbourIds()) > 0
	}
	if !sawCity || !sawNeighbours || l.Msg.GetVersion() != e.cat.Version() || l.Msg.GetNextPageToken() != "" {
		t.Fatalf("list: city %v neighbours %v version %d next %q", sawCity, sawNeighbours, l.Msg.GetVersion(), l.Msg.GetNextPageToken())
	}
}

// TestLogs_NoAreaID captures slog output and the request-line fields over every service path (grant, change, no-op,
// replay, clear, errors, contention-free internal error) and fails if any catalogue id appears: location logs has_area,
// never an area id (design section 5.5).
func TestLogs_NoAreaID(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(prev) })

	e := newEnv(t, Limits{ConsentChangesPerDay: 2})
	srv := NewServer(fakeFlags{on: map[string]bool{uidA: true}}, e.svc)
	var fields []string
	call := func(f func(ctx context.Context) error) {
		ctx, info := logger.WithRequestInfo(callerCtx(uidA))
		if err := f(ctx); err != nil {
			fields = append(fields, err.Error())
		}
		for _, a := range info.Fields() {
			fields = append(fields, a.String())
		}
	}
	set := func(k, area string, withConsent bool) func(context.Context) error {
		return func(ctx context.Context) error {
			req := &locationv1.SetAreaRequest{IdempotencyKey: key(k), AreaId: area}
			if withConsent {
				req.Consent = &locationv1.ConsentGrant{CopyVersion: 1, AdultConfirmed: true}
			}
			_, err := srv.SetArea(ctx, connect.NewRequest(req))
			return err
		}
	}
	clear := func(k string) func(context.Context) error {
		return func(ctx context.Context) error {
			_, err := srv.ClearArea(ctx, connect.NewRequest(&locationv1.ClearAreaRequest{IdempotencyKey: key(k)}))
			return err
		}
	}
	get := func(ctx context.Context) error {
		_, err := srv.GetLocationSettings(ctx, connect.NewRequest(&locationv1.GetLocationSettingsRequest{}))
		return err
	}
	call(set("a", areaIndi, false))        // consent_required
	call(set("b", areaIndi, true))         // grant
	call(set("b", areaIndi, true))         // replay
	call(set("b", areaDoml, true))         // key reused
	call(set("c", areaDoml, false))        // change
	call(set("d", areaDoml, false))        // no-op
	call(get)                              // area set
	call(clear("e"))                       // withdraw (2 records: the cap)
	call(set("f", areaIndi, true))         // limit reached
	call(set("g", "in.blr.nowhere", true)) // validation
	call(func(ctx context.Context) error {
		_, err := srv.ListAreas(ctx, connect.NewRequest(&locationv1.ListAreasRequest{Limit: 2}))
		return err
	})
	e.repo.err = errors.New("storage down")
	call(get) // internal error
	call(clear("h"))
	e.repo.err = errors.New("storage down for " + areaDoml) // a driver error that names the id: redacted
	call(set("i", areaDoml, true))
	all := buf.String() + "\n" + strings.Join(fields, "\n")
	if len(fields) == 0 {
		t.Fatal("no request fields captured: the scan would prove nothing")
	}
	areas, _ := e.cat.Page("", MaxAreas)
	for _, a := range areas {
		if strings.Contains(all, a.ID) {
			t.Fatalf("area id %s appears in the logs:\n%s", a.ID, all)
		}
	}
	if !strings.Contains(all, fieldHasArea) {
		t.Fatalf("has_area was never logged:\n%s", all)
	}
}
