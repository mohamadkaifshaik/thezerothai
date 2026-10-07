// server.go is the thin Connect handler: extract the caller's uid, do proto<->domain conversion, call
// Service, convert the result back. No business logic and no Firestore here (CLAUDE.md: handlers stay
// thin; errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping, the outermost-but-one
// interceptor — handlers just return the service error as-is).
package identity

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// AccountLifecycleFlag is the wire name of FEATURE_ACCOUNT_LIFECYCLE (P8 T4), the flag guarding DeleteAccount,
// RequestAccountExport and GetAccountExport.
const AccountLifecycleFlag = "account_lifecycle"

// FlagChecker is the minimal seam identity's server needs from pkg/platform/flags.Registry (ADR-0002). It is
// separate from FeatureFlags (api.go, used by the service for GetMe.enabled_features): the handler guards RPCs
// before the service is called, and each consumer-side interface stays one method wide. *flags.Registry
// satisfies both.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// Server adapts Service to identityv1connect.IdentityServiceHandler.
type Server struct {
	svc            Service
	allowAnonymous bool
	flags          FlagChecker
}

// WithFlagChecker wires the account_lifecycle flag check. Without it (nil) the flag is off for everyone.
func WithFlagChecker(fc FlagChecker) ServerOption {
	return func(s *Server) { s.flags = fc }
}

// ServerOption configures NewServer.
type ServerOption func(*Server)

// WithAllowAnonymous lets anonymous sign-ins create a profile. Wire it from config.AuthEmulator only (ADR-0010
// D5 A10): the e2e helpers mint anonymous users against the Auth emulator.
func WithAllowAnonymous(allow bool) ServerOption {
	return func(s *Server) { s.allowAnonymous = allow }
}

// NewServer builds the Connect handler. Use with identityv1connect.NewIdentityServiceHandler.
func NewServer(svc Service, opts ...ServerOption) *Server {
	s := &Server{svc: svc}
	for _, o := range opts {
		o(s)
	}
	return s
}

var _ identityv1connect.IdentityServiceHandler = (*Server)(nil)

func callerUID(ctx context.Context) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		// Should be unreachable: authn.IDTokenInterceptor runs before every handler.
		return "", apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	return uid, nil
}

func (s *Server) CreateProfile(ctx context.Context, req *connect.Request[identityv1.CreateProfileRequest]) (*connect.Response[identityv1.CreateProfileResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.allowAnonymous, "creating a profile"); err != nil {
		return nil, err
	}
	profile, err := s.svc.CreateProfile(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetHandle(), req.Msg.GetDisplayName())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.CreateProfileResponse{Profile: toProtoProfile(profile)}), nil
}

func (s *Server) CheckHandleAvailability(ctx context.Context, req *connect.Request[identityv1.CheckHandleAvailabilityRequest]) (*connect.Response[identityv1.CheckHandleAvailabilityResponse], error) {
	available, reason, err := s.svc.CheckHandleAvailability(ctx, req.Msg.GetHandle())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.CheckHandleAvailabilityResponse{Available: available, Reason: reason}), nil
}

func (s *Server) GetMe(ctx context.Context, _ *connect.Request[identityv1.GetMeRequest]) (*connect.Response[identityv1.GetMeResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	claims, _ := authn.ClaimsFromContext(ctx)
	result, err := s.svc.GetMe(ctx, uid)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.GetMeResponse{
		Profile:                 toProtoProfile(result.Profile),
		Status:                  toProtoStatus(result.Profile.Status),
		EmailVerified:           claims.EmailVerified,
		UnreadNotificationCount: result.UnreadNotificationCount,
		EnabledFeatures:         result.EnabledFeatures,
	}), nil
}

func (s *Server) GetProfile(ctx context.Context, req *connect.Request[identityv1.GetProfileRequest]) (*connect.Response[identityv1.GetProfileResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	target := ProfileTarget{UserID: req.Msg.GetUserId(), Handle: req.Msg.GetHandle()}
	profile, err := s.svc.GetProfile(ctx, uid, target)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.GetProfileResponse{Profile: toProtoProfile(profile)}), nil
}

func (s *Server) UpdateProfile(ctx context.Context, req *connect.Request[identityv1.UpdateProfileRequest]) (*connect.Response[identityv1.UpdateProfileResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	params := UpdateProfileParams{
		IdempotencyKey: req.Msg.GetIdempotencyKey(),
		DisplayName:    req.Msg.DisplayName,
		Bio:            req.Msg.Bio,
		AvatarMediaID:  req.Msg.AvatarMediaId,
		IsPrivate:      req.Msg.IsPrivate,
	}
	profile, err := s.svc.UpdateProfile(ctx, uid, params)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.UpdateProfileResponse{Profile: toProtoProfile(profile)}), nil
}

func (s *Server) ChangeHandle(ctx context.Context, req *connect.Request[identityv1.ChangeHandleRequest]) (*connect.Response[identityv1.ChangeHandleResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	profile, err := s.svc.ChangeHandle(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetNewHandle())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.ChangeHandleResponse{Profile: toProtoProfile(profile)}), nil
}

// DeleteAccount, RequestAccountExport and GetAccountExport sit behind FEATURE_ACCOUNT_LIFECYCLE (P8 T4). Flag
// off for the caller: FAILED_PRECONDITION + FEATURE_DISABLED before any Firestore access (0 reads). Flag on:
// Unimplemented until T5/T9 land the real bodies. The three stay in the charge-only set and account_ops_daily
// (apiserver/ratelimit_config.go), so a rejected call still counts against the daily cap.

// guardAccountLifecycle returns the flag rejection, or nil when the flag is on for the caller.
func (s *Server) guardAccountLifecycle(ctx context.Context) error {
	uid, err := callerUID(ctx)
	if err != nil {
		return err
	}
	if s.flags == nil {
		return flags.Guard(ctx, nil, uid, AccountLifecycleFlag)
	}
	return flags.Guard(ctx, s.flags.Enabled, uid, AccountLifecycleFlag)
}

func (s *Server) DeleteAccount(ctx context.Context, _ *connect.Request[identityv1.DeleteAccountRequest]) (*connect.Response[identityv1.DeleteAccountResponse], error) {
	if err := s.guardAccountLifecycle(ctx); err != nil {
		return nil, err
	}
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

func (s *Server) RequestAccountExport(ctx context.Context, _ *connect.Request[identityv1.RequestAccountExportRequest]) (*connect.Response[identityv1.RequestAccountExportResponse], error) {
	if err := s.guardAccountLifecycle(ctx); err != nil {
		return nil, err
	}
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

func (s *Server) GetAccountExport(ctx context.Context, _ *connect.Request[identityv1.GetAccountExportRequest]) (*connect.Response[identityv1.GetAccountExportResponse], error) {
	if err := s.guardAccountLifecycle(ctx); err != nil {
		return nil, err
	}
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

// errUnimplementedPhase1's message is deliberately generic (L10, 2026-09-27 security audit): it is sent
// verbatim to the client by connect.NewError, so the module roadmap must not appear in it. The real reason is
// that the resumable delete/export jobs (ADR-0003 "Deletes & privacy") are not built yet; it stays in source
// comments, not on the wire.
var errUnimplementedPhase1 = errors.New("not available yet")

func toProtoStatus(s AccountStatus) identityv1.AccountStatus {
	switch s {
	case AccountStatusActive:
		return identityv1.AccountStatus_ACCOUNT_STATUS_ACTIVE
	case AccountStatusSuspended:
		return identityv1.AccountStatus_ACCOUNT_STATUS_SUSPENDED
	case AccountStatusDeleting:
		return identityv1.AccountStatus_ACCOUNT_STATUS_DELETING
	default:
		return identityv1.AccountStatus_ACCOUNT_STATUS_UNSPECIFIED
	}
}

func toProtoProfile(p Profile) *identityv1.Profile {
	return &identityv1.Profile{
		UserId:         p.UserID,
		Handle:         p.Handle,
		DisplayName:    p.DisplayName,
		Bio:            p.Bio,
		AvatarUrl:      p.AvatarURL,
		AvatarThumbUrl: p.AvatarThumbURL,
		IsPrivate:      p.IsPrivate,
		Verified:       p.Verified,
		FollowersCount: p.FollowersCount,
		FollowingCount: p.FollowingCount,
		PostsCount:     p.PostsCount,
		CreatedAt:      timestamppb.New(p.CreatedAt),
	}
}
