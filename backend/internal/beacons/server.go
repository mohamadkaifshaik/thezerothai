package beacons

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one beacon call (<= 10 s); the transaction itself has 5 s.
const rpcDeadline = 8 * time.Second

// Server is the BeaconService handler. It mounts every route so the interceptor chain (App Check, ID token, account
// status, rate limits, degraded mode) covers them, and runs the flag gate (FEATURE_BEACONS) before anything else, by
// class: CreateBeacon, UpdateBeacon, RequestToJoin and RespondToJoinRequest need the flag on for the caller (Guard); the
// other eight only need it not globally off (GuardNotOff), so a caller dropped from an allowlist can still read, leave,
// withdraw and cancel. Past the gate every RPC calls the Service; a Server built without one answers Unimplemented.
type Server struct {
	beaconsv1connect.UnimplementedBeaconServiceHandler
	flags FlagChecker
	svc   Service
}

// NewServer builds the handler. svc may be nil (a wiring without the service): every gated RPC then answers
// Unimplemented. Use with beaconsv1connect.NewBeaconServiceHandler.
func NewServer(fc FlagChecker, svc Service) *Server { return &Server{flags: fc, svc: svc} }

var _ beaconsv1connect.BeaconServiceHandler = (*Server)(nil)

// gate runs the flag check of the class for the authenticated caller. A request that reaches a handler without a uid is
// a wiring bug (the authn interceptor runs first); it is treated as unauthenticated.
func (s *Server) gate(ctx context.Context, write bool) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return "", connect.NewError(connect.CodeUnauthenticated, nil)
	}
	if write {
		return uid, Guard(ctx, s.flags, uid)
	}
	return uid, GuardNotOff(ctx, s.flags, uid)
}

// entry is the shared front of every handler: the flag gate of the class, the wiring check and the RPC deadline.
func (s *Server) entry(ctx context.Context, rpc string, write bool) (context.Context, context.CancelFunc, string, error) {
	uid, err := s.gate(ctx, write)
	if err != nil {
		return nil, nil, "", err
	}
	if s.svc == nil {
		return nil, nil, "", connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not wired", rpc))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	return ctx, cancel, uid, nil
}

// viewAction is the shared body of the handlers that answer one BeaconView: entry, the service call, the rendering.
func (s *Server) viewAction(ctx context.Context, rpc string, write bool, call func(ctx context.Context, uid string) (View, error)) (*beaconsv1.BeaconView, error) {
	ctx, cancel, uid, err := s.entry(ctx, rpc, write)
	if err != nil {
		return nil, err
	}
	defer cancel()
	v, err := call(ctx, uid)
	if err != nil {
		return nil, err
	}
	return toView(v), nil
}

// emptyAction is the shared body of the handlers that answer nothing: entry and the service call.
func (s *Server) emptyAction(ctx context.Context, rpc string, write bool, call func(ctx context.Context, uid string) error) error {
	ctx, cancel, uid, err := s.entry(ctx, rpc, write)
	if err != nil {
		return err
	}
	defer cancel()
	return call(ctx, uid)
}

func renderViews(views []View) []*beaconsv1.BeaconView {
	out := make([]*beaconsv1.BeaconView, 0, len(views))
	for _, v := range views {
		out = append(out, toView(v))
	}
	return out
}

// CreateBeacon is write class.
func (s *Server) CreateBeacon(ctx context.Context, req *connect.Request[beaconsv1.CreateBeaconRequest]) (*connect.Response[beaconsv1.CreateBeaconResponse], error) {
	view, err := s.viewAction(ctx, "CreateBeacon", true, func(ctx context.Context, uid string) (View, error) {
		in, err := createInputFromProto(req.Msg)
		if err != nil {
			return View{}, err
		}
		return s.svc.CreateBeacon(ctx, uid, in)
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.CreateBeaconResponse{View: view}), nil
}

// UpdateBeacon is write class; only the fields that are set change.
func (s *Server) UpdateBeacon(ctx context.Context, req *connect.Request[beaconsv1.UpdateBeaconRequest]) (*connect.Response[beaconsv1.UpdateBeaconResponse], error) {
	m := req.Msg
	view, err := s.viewAction(ctx, "UpdateBeacon", true, func(ctx context.Context, uid string) (View, error) {
		in := UpdateInput{Key: m.GetIdempotencyKey(), BeaconID: m.GetBeaconId(), Title: m.Title, Details: m.Details, Venue: m.Venue}
		if m.OpenSpots != nil {
			n := int(m.GetOpenSpots())
			in.OpenSpots = &n
		}
		return s.svc.UpdateBeacon(ctx, uid, in)
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.UpdateBeaconResponse{View: view}), nil
}

// CancelBeacon is read class (a caller dropped from the allowlist can still cancel).
//
//nolint:dupl // mirrors WithdrawJoinRequest and LeaveBeacon over distinct generated proto types
func (s *Server) CancelBeacon(ctx context.Context, req *connect.Request[beaconsv1.CancelBeaconRequest]) (*connect.Response[beaconsv1.CancelBeaconResponse], error) {
	err := s.emptyAction(ctx, "CancelBeacon", false, func(ctx context.Context, uid string) error {
		return s.svc.CancelBeacon(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetBeaconId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.CancelBeaconResponse{}), nil
}

// GetBeacon is read class.
func (s *Server) GetBeacon(ctx context.Context, req *connect.Request[beaconsv1.GetBeaconRequest]) (*connect.Response[beaconsv1.GetBeaconResponse], error) {
	view, err := s.viewAction(ctx, "GetBeacon", false, func(ctx context.Context, uid string) (View, error) {
		return s.svc.GetBeacon(ctx, uid, req.Msg.GetBeaconId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.GetBeaconResponse{View: view}), nil
}

// ListBeacons is read class.
func (s *Server) ListBeacons(ctx context.Context, req *connect.Request[beaconsv1.ListBeaconsRequest]) (*connect.Response[beaconsv1.ListBeaconsResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListBeacons", false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	activity, err := listActivityFromProto(m.GetActivity())
	if err != nil {
		return nil, err
	}
	in := ListInput{CommunityID: m.GetCommunityId(), Public: m.GetPublic(), Activity: activity, Limit: m.GetLimit(), PageToken: m.GetPageToken()}
	if m.GetFrom() != nil {
		in.From = m.GetFrom().AsTime()
	}
	page, err := s.svc.ListBeacons(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.ListBeaconsResponse{Views: renderViews(page.Views), NextPageToken: page.NextPageToken}), nil
}

// ListMyBeacons is read class.
func (s *Server) ListMyBeacons(ctx context.Context, req *connect.Request[beaconsv1.ListMyBeaconsRequest]) (*connect.Response[beaconsv1.ListMyBeaconsResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListMyBeacons", false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	page, err := s.svc.ListMyBeacons(ctx, uid, MyBeaconsInput{
		Role: myRoleFromProto(m.GetRole()), Past: m.GetWindow() == beaconsv1.MyBeaconsWindow_MY_BEACONS_WINDOW_PAST,
		Limit: m.GetLimit(), PageToken: m.GetPageToken(),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.ListMyBeaconsResponse{Views: renderViews(page.Views), NextPageToken: page.NextPageToken}), nil
}

// RequestToJoin is write class.
func (s *Server) RequestToJoin(ctx context.Context, req *connect.Request[beaconsv1.RequestToJoinRequest]) (*connect.Response[beaconsv1.RequestToJoinResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "RequestToJoin", true)
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	vs, err := s.svc.RequestToJoin(ctx, uid, m.GetIdempotencyKey(), m.GetBeaconId(), m.GetNote())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.RequestToJoinResponse{Viewer: toViewerState(vs)}), nil
}

// WithdrawJoinRequest is read class (a caller dropped from the allowlist can still withdraw).
//
//nolint:dupl // mirrors CancelBeacon and LeaveBeacon over distinct generated proto types
func (s *Server) WithdrawJoinRequest(ctx context.Context, req *connect.Request[beaconsv1.WithdrawJoinRequestRequest]) (*connect.Response[beaconsv1.WithdrawJoinRequestResponse], error) {
	err := s.emptyAction(ctx, "WithdrawJoinRequest", false, func(ctx context.Context, uid string) error {
		return s.svc.WithdrawJoinRequest(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetBeaconId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.WithdrawJoinRequestResponse{}), nil
}

// RespondToJoinRequest is write class; organiser only. An UNSPECIFIED response is VALIDATION "response".
func (s *Server) RespondToJoinRequest(ctx context.Context, req *connect.Request[beaconsv1.RespondToJoinRequestRequest]) (*connect.Response[beaconsv1.RespondToJoinRequestResponse], error) {
	m := req.Msg
	view, err := s.viewAction(ctx, "RespondToJoinRequest", true, func(ctx context.Context, uid string) (View, error) {
		accept, err := responseFromProto(m.GetResponse())
		if err != nil {
			return View{}, err
		}
		return s.svc.RespondToJoinRequest(ctx, uid, m.GetIdempotencyKey(), m.GetBeaconId(), m.GetUserId(), accept)
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.RespondToJoinRequestResponse{View: view}), nil
}

// LeaveBeacon is read class (always allowed, never needs approval).
//
//nolint:dupl // mirrors CancelBeacon and WithdrawJoinRequest over distinct generated proto types
func (s *Server) LeaveBeacon(ctx context.Context, req *connect.Request[beaconsv1.LeaveBeaconRequest]) (*connect.Response[beaconsv1.LeaveBeaconResponse], error) {
	err := s.emptyAction(ctx, "LeaveBeacon", false, func(ctx context.Context, uid string) error {
		return s.svc.LeaveBeacon(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetBeaconId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.LeaveBeaconResponse{}), nil
}

// RemoveParticipant is read class; organiser only.
func (s *Server) RemoveParticipant(ctx context.Context, req *connect.Request[beaconsv1.RemoveParticipantRequest]) (*connect.Response[beaconsv1.RemoveParticipantResponse], error) {
	m := req.Msg
	view, err := s.viewAction(ctx, "RemoveParticipant", false, func(ctx context.Context, uid string) (View, error) {
		return s.svc.RemoveParticipant(ctx, uid, m.GetIdempotencyKey(), m.GetBeaconId(), m.GetUserId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&beaconsv1.RemoveParticipantResponse{View: view}), nil
}

// ListParticipants is read class.
func (s *Server) ListParticipants(ctx context.Context, req *connect.Request[beaconsv1.ListParticipantsRequest]) (*connect.Response[beaconsv1.ListParticipantsResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListParticipants", false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	page, err := s.svc.ListParticipants(ctx, uid, ListParticipantsInput{
		BeaconID: m.GetBeaconId(), Requested: m.GetFilter() == beaconsv1.ParticipantFilter_PARTICIPANT_FILTER_REQUESTED,
		Limit: m.GetLimit(), PageToken: m.GetPageToken(),
	})
	if err != nil {
		return nil, err
	}
	out := &beaconsv1.ListParticipantsResponse{NextPageToken: page.NextPageToken}
	for _, r := range page.Rows {
		out.Participants = append(out.Participants, toParticipant(r))
	}
	return connect.NewResponse(out), nil
}
