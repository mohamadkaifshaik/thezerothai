// server.go is the thin Connect handler: extract the caller's uid, do proto<->domain conversion, call
// Service, convert the result back. No business logic and no Firestore here (CLAUDE.md: handlers stay
// thin; errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping, the outermost-but-one
// interceptor — handlers just return the service error as-is).
package identity

import (
	"context"
	"errors"
	"time"

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
	lifecycle      AccountLifecycle
	reauthMaxAge   time.Duration
	now            func() time.Time
}

// WithLifecycle wires the account-lifecycle service behind DeleteAccount, RequestAccountExport and
// GetAccountExport. Without it (nil), a caller the flag is on for gets Unimplemented.
func WithLifecycle(l AccountLifecycle) ServerOption {
	return func(s *Server) { s.lifecycle = l }
}

// WithReauthMaxAge sets how recent the caller's sign-in (the ID token's auth_time) must be for DeleteAccount:
// config.AccountDeleteReauthMaxAge, ACCOUNT_DELETE_REAUTH_MAX_AGE. It is deliberately not defaulted here: left
// zero, authn.RequireRecentSignIn rejects every token, so a wiring mistake fails closed.
func WithReauthMaxAge(d time.Duration) ServerOption {
	return func(s *Server) { s.reauthMaxAge = d }
}

// WithClock replaces time.Now for the recent-sign-in check (tests).
func WithClock(now func() time.Time) ServerOption {
	return func(s *Server) { s.now = now }
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
	s := &Server{svc: svc, now: time.Now}
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

// CreateProfile: worst case Firestore reads 2, writes 3; replay reads 1, writes 0 and no Auth call. One Firebase Auth
// users.get of the token's own uid, only on a real sign-up (ADR-0011 amendment M2: a deleted or disabled Auth user is
// refused with PERMISSION_DENIED, an Auth outage with UNAVAILABLE; nothing is written).
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

// DeleteAccount, RequestAccountExport and GetAccountExport sit behind FEATURE_ACCOUNT_LIFECYCLE (P8, ADR-0011).
// Flag off for the caller: FAILED_PRECONDITION + FEATURE_DISABLED before any Firestore access (0 reads). They stay
// in the charge-only set and account_ops_daily (apiserver/ratelimit_config.go), so a rejected call still counts
// against the daily cap. The job handlers behind them are never gated (Q9).

// guardAccountLifecycle returns the flag rejection (and the caller uid), or nil when the flag is on for the caller.
func (s *Server) guardAccountLifecycle(ctx context.Context) (string, error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return "", err
	}
	if s.flags == nil {
		return uid, flags.Guard(ctx, nil, uid, AccountLifecycleFlag)
	}
	return uid, flags.Guard(ctx, s.flags.Enabled, uid, AccountLifecycleFlag)
}

func (s *Server) DeleteAccount(ctx context.Context, req *connect.Request[identityv1.DeleteAccountRequest]) (*connect.Response[identityv1.DeleteAccountResponse], error) {
	uid, err := s.guardAccountLifecycle(ctx)
	if err != nil {
		return nil, err
	}
	if s.lifecycle == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
	}
	// Destructive and irreversible: the token's own sign-in must be recent (also on a replay). The uid is the
	// token's; DeleteAccountRequest has no uid field and must never get one (ADR-0011 IAM control C1).
	if err := authn.RequireRecentSignIn(ctx, s.reauthMaxAge, s.now()); err != nil {
		return nil, err
	}
	at, err := s.lifecycle.DeleteAccount(ctx, uid, req.Msg.GetIdempotencyKey())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.DeleteAccountResponse{DeletionRequestedAt: timestamppb.New(at)}), nil
}

func (s *Server) RequestAccountExport(ctx context.Context, req *connect.Request[identityv1.RequestAccountExportRequest]) (*connect.Response[identityv1.RequestAccountExportResponse], error) {
	uid, err := s.guardAccountLifecycle(ctx)
	if err != nil {
		return nil, err
	}
	if s.lifecycle == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
	}
	view, err := s.lifecycle.RequestAccountExport(ctx, uid, req.Msg.GetIdempotencyKey())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&identityv1.RequestAccountExportResponse{ExportId: view.ID, Status: toProtoExportStatus(view.Status)}), nil
}

func (s *Server) GetAccountExport(ctx context.Context, req *connect.Request[identityv1.GetAccountExportRequest]) (*connect.Response[identityv1.GetAccountExportResponse], error) {
	uid, err := s.guardAccountLifecycle(ctx)
	if err != nil {
		return nil, err
	}
	if s.lifecycle == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
	}
	view, err := s.lifecycle.GetAccountExport(ctx, uid, req.Msg.GetExportId())
	if err != nil {
		return nil, err
	}
	resp := &identityv1.GetAccountExportResponse{
		ExportId:    view.ID,
		Status:      toProtoExportStatus(view.Status),
		DownloadUrl: view.DownloadURL,
		ExpiresAt:   timestamppb.New(view.ExpiresAt),
	}
	if !view.URLExpiresAt.IsZero() {
		resp.DownloadUrlExpiresAt = timestamppb.New(view.URLExpiresAt)
	}
	return connect.NewResponse(resp), nil
}

func toProtoExportStatus(s ExportStatus) identityv1.ExportStatus {
	switch s {
	case ExportPending:
		return identityv1.ExportStatus_EXPORT_STATUS_PENDING
	case ExportReady:
		return identityv1.ExportStatus_EXPORT_STATUS_READY
	case ExportFailed:
		return identityv1.ExportStatus_EXPORT_STATUS_FAILED
	default:
		return identityv1.ExportStatus_EXPORT_STATUS_UNSPECIFIED
	}
}

// errUnimplementedPhase1's message is deliberately generic (L10, 2026-09-27 security audit): it is sent
// verbatim to the client by connect.NewError, so the module roadmap must not appear in it. The real reason is
// that no lifecycle service is wired (apiserver.Build always wires one); it stays in source comments, not on the
// wire.
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
