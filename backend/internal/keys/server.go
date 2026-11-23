package keys

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// rpcDeadline bounds one KeyService call (<= 10 s, as location); a claim's retries and the repository transactions
// have their own, shorter budgets inside it.
const rpcDeadline = 8 * time.Second

// gateClass is an RPC's FEATURE_E2EE_DM class (keys.proto header).
type gateClass int

const (
	// gateOn: RegisterKeyDevice, UploadKeyPackages and ClaimKeyPackages need the flag on for the caller.
	gateOn gateClass = iota
	// gateNotOff: ListMyKeyDevices, RemoveKeyDevice and GetKeyDevices need it only not globally off, so a user dropped
	// from an allowlist can still see and remove their devices and look up a peer they share an encrypted
	// conversation with.
	gateNotOff
)

// Server is the KeyService handler. Every route is mounted so the interceptor chain (App Check, ID token, account
// status, rate limits, degraded mode) covers it; each handler then runs auth, the RPC's flag class, the wiring check,
// the idempotency_key format (the four mutating RPCs) and the service, converting only between wire and service types.
// A Server built without a service answers Unimplemented. Nothing here logs an id, a key or a key package.
type Server struct {
	keysv1connect.UnimplementedKeyServiceHandler
	flags FlagChecker
	svc   Service
}

// NewServer builds the handler. Use with keysv1connect.NewKeyServiceHandler.
func NewServer(fc FlagChecker, svc Service) *Server { return &Server{flags: fc, svc: svc} }

var _ keysv1connect.KeyServiceHandler = (*Server)(nil)

// entry is the shared front of every handler, in this order: the caller (UNAUTHENTICATED), the flag class
// (FEATURE_DISABLED feature=e2ee_dm, before any lookup), the wiring (UNIMPLEMENTED), the idempotency_key format of a
// mutating RPC (key non-nil; VALIDATION idempotency_key; the key is not stored: Register, Remove and Upload are naturally
// idempotent and Claim is not replayable), then the RPC deadline. A read RPC passes a nil key.
func (s *Server) entry(ctx context.Context, rpc string, class gateClass, key *string) (context.Context, context.CancelFunc, string, error) {
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
	if key != nil && !idempotency.KeyFormatValid(*key) {
		return nil, nil, "", invalid(ctx, "idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	return ctx, cancel, uid, nil
}

// RegisterKeyDevice needs the flag on for the caller.
func (s *Server) RegisterKeyDevice(ctx context.Context, req *connect.Request[keysv1.RegisterKeyDeviceRequest]) (*connect.Response[keysv1.RegisterKeyDeviceResponse], error) {
	m := req.Msg
	key := m.GetIdempotencyKey()
	ctx, cancel, uid, err := s.entry(ctx, "RegisterKeyDevice", gateOn, &key)
	if err != nil {
		return nil, err
	}
	defer cancel()
	d, err := s.svc.Register(ctx, uid, m.GetDeviceId(), m.GetSignaturePublicKey())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&keysv1.RegisterKeyDeviceResponse{Device: toKeyDevice(d)}), nil
}

// ListMyKeyDevices needs the flag only not globally off.
func (s *Server) ListMyKeyDevices(ctx context.Context, _ *connect.Request[keysv1.ListMyKeyDevicesRequest]) (*connect.Response[keysv1.ListMyKeyDevicesResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListMyKeyDevices", gateNotOff, nil)
	if err != nil {
		return nil, err
	}
	defer cancel()
	ds, err := s.svc.ListMine(ctx, uid)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&keysv1.ListMyKeyDevicesResponse{Devices: toKeyDevices(ds)}), nil
}

// RemoveKeyDevice needs the flag only not globally off. The wire reason becomes the service's: UNSPECIFIED (builds before
// the field) and SIGN_OUT are RemoveSignOut, REMOTE is RemoveRemote; a value this server does not know is VALIDATION
// "reason" before the service (never silently a removal that remembers nothing).
func (s *Server) RemoveKeyDevice(ctx context.Context, req *connect.Request[keysv1.RemoveKeyDeviceRequest]) (*connect.Response[keysv1.RemoveKeyDeviceResponse], error) {
	m := req.Msg
	key := m.GetIdempotencyKey()
	ctx, cancel, uid, err := s.entry(ctx, "RemoveKeyDevice", gateNotOff, &key)
	if err != nil {
		return nil, err
	}
	defer cancel()
	var reason RemoveReason
	switch m.GetReason() {
	case keysv1.RemoveReason_REMOVE_REASON_UNSPECIFIED, keysv1.RemoveReason_REMOVE_REASON_SIGN_OUT:
		reason = RemoveSignOut
	case keysv1.RemoveReason_REMOVE_REASON_REMOTE:
		reason = RemoveRemote
	default:
		return nil, invalid(ctx, "reason", "reason must be a known RemoveReason")
	}
	res, err := s.svc.RemoveDevice(ctx, uid, m.GetDeviceId(), reason)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&keysv1.RemoveKeyDeviceResponse{OtherSessionsEnded: res.OtherSessionsEnded}), nil
}

// UploadKeyPackages needs the flag on for the caller.
func (s *Server) UploadKeyPackages(ctx context.Context, req *connect.Request[keysv1.UploadKeyPackagesRequest]) (*connect.Response[keysv1.UploadKeyPackagesResponse], error) {
	m := req.Msg
	key := m.GetIdempotencyKey()
	ctx, cancel, uid, err := s.entry(ctx, "UploadKeyPackages", gateOn, &key)
	if err != nil {
		return nil, err
	}
	defer cancel()
	n, has, err := s.svc.Upload(ctx, uid, m.GetDeviceId(), m.GetKeyPackages(), m.GetLastResortKeyPackage())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&keysv1.UploadKeyPackagesResponse{KeyPackageCount: count32(n), HasLastResort: has}), nil
}

// GetKeyDevices needs the flag only not globally off: a caller whose flag is off gets devices only for a peer they share
// an accepted encrypted conversation with, else an empty success (the service decides). The service answers a map keyed by every
// requested id; the response lists the users in request order, with an entry (possibly empty) for every requested id.
func (s *Server) GetKeyDevices(ctx context.Context, req *connect.Request[keysv1.GetKeyDevicesRequest]) (*connect.Response[keysv1.GetKeyDevicesResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "GetKeyDevices", gateNotOff, nil)
	if err != nil {
		return nil, err
	}
	defer cancel()
	userIDs := req.Msg.GetUserIds()
	byUser, err := s.svc.GetDevices(ctx, uid, userIDs)
	if err != nil {
		return nil, err
	}
	out := &keysv1.GetKeyDevicesResponse{Users: make([]*keysv1.UserKeyDevices, 0, len(userIDs))}
	for _, id := range userIDs {
		out.Users = append(out.Users, &keysv1.UserKeyDevices{UserId: id, Devices: toKeyDevices(byUser[id])})
	}
	return connect.NewResponse(out), nil
}

// ClaimKeyPackages needs the flag on for the caller.
func (s *Server) ClaimKeyPackages(ctx context.Context, req *connect.Request[keysv1.ClaimKeyPackagesRequest]) (*connect.Response[keysv1.ClaimKeyPackagesResponse], error) {
	m := req.Msg
	key := m.GetIdempotencyKey()
	ctx, cancel, uid, err := s.entry(ctx, "ClaimKeyPackages", gateOn, &key)
	if err != nil {
		return nil, err
	}
	defer cancel()
	got, convID, err := s.svc.Claim(ctx, uid, m.GetUserId(), m.GetExcludeDeviceId())
	if err != nil {
		return nil, err
	}
	out := &keysv1.ClaimKeyPackagesResponse{KeyPackages: make([]*keysv1.ClaimedKeyPackage, 0, len(got)), ConversationId: convID}
	for _, c := range got {
		out.KeyPackages = append(out.KeyPackages, &keysv1.ClaimedKeyPackage{
			DeviceId: c.DeviceID, SignaturePublicKey: c.SignatureKey, KeyPackage: c.KeyPackage,
			HasKeyPackage: c.HasKeyPackage, LastResort: c.LastResort,
		})
	}
	return connect.NewResponse(out), nil
}

func toKeyDevices(ds []Device) []*keysv1.KeyDevice {
	out := make([]*keysv1.KeyDevice, 0, len(ds))
	for _, d := range ds {
		out = append(out, toKeyDevice(d))
	}
	return out
}

func toKeyDevice(d Device) *keysv1.KeyDevice {
	return &keysv1.KeyDevice{
		DeviceId: d.ID, SignaturePublicKey: d.SignatureKey, CreatedAt: ts(d.CreatedAt), LastSeenAt: ts(d.LastSeenAt),
		KeyPackageCount: count32(d.PoolCount), HasLastResort: d.HasLastResort, Inactive: d.Inactive,
	}
}

// count32 is a pool count on the wire (at most MaxPoolSize in practice; clamped so the conversion can never wrap).
func count32(n int) int32 {
	return int32(min(max(n, 0), 1<<30)) // #nosec G115 -- bounded above
}

func ts(t time.Time) *timestamppb.Timestamp {
	if t.IsZero() {
		return nil
	}
	return timestamppb.New(t)
}
