package location

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1/locationv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one location call (<= 10 s); the transaction itself has 5 s.
const rpcDeadline = 8 * time.Second

// gateClass is a handler's FEATURE_LOCATION class (location.proto header).
type gateClass int

const (
	// gateNone: GetLocationSettings and ClearArea work in every flag mode, the kill switch included, so a user can always
	// see and withdraw (DPDP).
	gateNone gateClass = iota
	// gateNotOff: ListAreas needs the flag not globally off.
	gateNotOff
	// gateOn: SetArea needs the flag on for the caller.
	gateOn
)

// Server is the LocationService handler. It mounts every route so the interceptor chain (App Check, ID token, account
// status, rate limits, degraded mode) covers them, then runs auth, the flag class of the RPC, and the service (which
// validates before any lookup). A Server built without a service answers Unimplemented.
type Server struct {
	locationv1connect.UnimplementedLocationServiceHandler
	flags FlagChecker
	svc   Service
}

// NewServer builds the handler. Use with locationv1connect.NewLocationServiceHandler.
func NewServer(fc FlagChecker, svc Service) *Server { return &Server{flags: fc, svc: svc} }

var _ locationv1connect.LocationServiceHandler = (*Server)(nil)

// entry is the shared front of every handler: the caller, the flag class, the wiring check and the RPC deadline.
func (s *Server) entry(ctx context.Context, rpc string, class gateClass) (context.Context, context.CancelFunc, string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, nil, "", connect.NewError(connect.CodeUnauthenticated, nil)
	}
	var err error
	switch class {
	case gateOn:
		err = Guard(ctx, s.flags, uid)
	case gateNotOff:
		err = GuardNotOff(ctx, s.flags, uid)
	}
	if err != nil {
		return nil, nil, "", err
	}
	if s.svc == nil {
		return nil, nil, "", connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not wired", rpc))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	return ctx, cancel, uid, nil
}

// settingsAction is the shared body of the three handlers that answer LocationSettings.
func (s *Server) settingsAction(ctx context.Context, rpc string, class gateClass, call func(ctx context.Context, uid string) (Settings, error)) (*locationv1.LocationSettings, error) {
	ctx, cancel, uid, err := s.entry(ctx, rpc, class)
	if err != nil {
		return nil, err
	}
	defer cancel()
	st, err := call(ctx, uid)
	if err != nil {
		return nil, err
	}
	return toSettings(st), nil
}

// GetLocationSettings works in every flag mode.
func (s *Server) GetLocationSettings(ctx context.Context, _ *connect.Request[locationv1.GetLocationSettingsRequest]) (*connect.Response[locationv1.GetLocationSettingsResponse], error) {
	st, err := s.settingsAction(ctx, "GetLocationSettings", gateNone, s.svcGet)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&locationv1.GetLocationSettingsResponse{Settings: st}), nil
}

func (s *Server) svcGet(ctx context.Context, uid string) (Settings, error) {
	return s.svc.GetSettings(ctx, uid)
}

// SetArea needs FEATURE_LOCATION on for the caller.
func (s *Server) SetArea(ctx context.Context, req *connect.Request[locationv1.SetAreaRequest]) (*connect.Response[locationv1.SetAreaResponse], error) {
	m := req.Msg
	in := SetAreaInput{Key: m.GetIdempotencyKey(), AreaID: m.GetAreaId()}
	if c := m.GetConsent(); c != nil {
		in.Consent = &Grant{CopyVersion: int(c.GetCopyVersion()), AdultConfirmed: c.GetAdultConfirmed()}
	}
	st, err := s.settingsAction(ctx, "SetArea", gateOn, func(ctx context.Context, uid string) (Settings, error) {
		return s.svc.SetArea(ctx, uid, in)
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&locationv1.SetAreaResponse{Settings: st}), nil
}

// ClearArea works in every flag mode.
func (s *Server) ClearArea(ctx context.Context, req *connect.Request[locationv1.ClearAreaRequest]) (*connect.Response[locationv1.ClearAreaResponse], error) {
	key := req.Msg.GetIdempotencyKey()
	st, err := s.settingsAction(ctx, "ClearArea", gateNone, func(ctx context.Context, uid string) (Settings, error) {
		return s.svc.ClearArea(ctx, uid, key)
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&locationv1.ClearAreaResponse{Settings: st}), nil
}

// ListAreas needs FEATURE_LOCATION not globally off.
func (s *Server) ListAreas(ctx context.Context, req *connect.Request[locationv1.ListAreasRequest]) (*connect.Response[locationv1.ListAreasResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListAreas", gateNotOff)
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	page, err := s.svc.ListAreas(ctx, uid, ListAreasInput{Limit: int(m.GetLimit()), PageToken: m.GetPageToken(), KnownVersion: m.GetKnownVersion()})
	if err != nil {
		return nil, err
	}
	out := &locationv1.ListAreasResponse{
		Areas: make([]*locationv1.Area, 0, len(page.Areas)), NextPageToken: page.Next, Version: page.Version, NotModified: page.NotModified,
	}
	for _, a := range page.Areas {
		out.Areas = append(out.Areas, toArea(a))
	}
	return connect.NewResponse(out), nil
}

func toKind(k Kind) locationv1.AreaKind {
	switch k {
	case KindArea:
		return locationv1.AreaKind_AREA_KIND_AREA
	case KindCity:
		return locationv1.AreaKind_AREA_KIND_CITY
	}
	return locationv1.AreaKind_AREA_KIND_UNSPECIFIED
}

func toArea(a Area) *locationv1.Area {
	return &locationv1.Area{
		AreaId: a.ID, Name: a.Name, Kind: toKind(a.Kind), CityId: a.CityID, CityName: a.CityName,
		Aliases: a.Aliases, NeighbourIds: a.Neighbours, Retired: a.Retired,
	}
}

// ToSummary is the small form other packages embed (beacons, P2).
func ToSummary(a Area) *locationv1.AreaSummary {
	return &locationv1.AreaSummary{AreaId: a.ID, Name: a.Name, Kind: toKind(a.Kind), CityId: a.CityID, CityName: a.CityName}
}

func toAction(a string) locationv1.LocationConsentAction {
	switch a {
	case ActionGranted:
		return locationv1.LocationConsentAction_LOCATION_CONSENT_ACTION_GRANTED
	case ActionWithdrawn:
		return locationv1.LocationConsentAction_LOCATION_CONSENT_ACTION_WITHDRAWN
	}
	return locationv1.LocationConsentAction_LOCATION_CONSENT_ACTION_UNSPECIFIED
}

func toPurpose(p string) locationv1.LocationPurpose {
	if p == PurposePlansNearby {
		return locationv1.LocationPurpose_LOCATION_PURPOSE_PLANS_NEARBY
	}
	return locationv1.LocationPurpose_LOCATION_PURPOSE_UNSPECIFIED
}

func ts(t time.Time) *timestamppb.Timestamp {
	if t.IsZero() {
		return nil
	}
	return timestamppb.New(t)
}

func toSettings(s Settings) *locationv1.LocationSettings {
	out := &locationv1.LocationSettings{
		Consent: &locationv1.ConsentState{
			Action: toAction(s.Consent.Action), Purpose: toPurpose(s.Consent.Purpose), CopyVersion: int32(min(s.Consent.CopyVersion, 1<<30)), // #nosec G115 -- bounded above
			At: ts(s.Consent.At), AdultConfirmedAt: ts(s.Consent.AdultConfirmedAt),
		},
		RequiredCopyVersion: int32(min(s.RequiredCopyVersion, 1<<30)), // #nosec G115 -- bounded above
	}
	if s.Area != nil {
		out.Area = ToSummary(*s.Area)
	}
	return out
}
