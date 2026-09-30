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
)

// requireVerifiedEmailForPassword enforces H1 (2026-09-27 security audit): a password-provider account
// must have a verified email before creating a profile (ADR-0006 §1). Unscripted signups otherwise let an
// attacker mint Firebase email/password accounts by the thousand per hour per IP and squat handles / burn
// the Firestore write quota (docs/reviews/security-audit-v0.1.0.md). Google/Apple sign-in are never blocked
// here. The predicate is authn.Claims.UnverifiedPassword, which authn.VerifiedIdentityInterceptor (ADR-0010
// D5 A2) applies earlier at 0 reads; this check stays as defence in depth for a chain without the gate.
func requireVerifiedEmailForPassword(ctx context.Context) error {
	claims, _ := authn.ClaimsFromContext(ctx)
	if !claims.UnverifiedPassword() {
		return nil
	}
	return apierr.New(
		connect.CodeFailedPrecondition,
		commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED,
		"please verify your email before creating a profile",
	)
}

// Server adapts Service to identityv1connect.IdentityServiceHandler.
type Server struct {
	svc Service
}

// NewServer builds the Connect handler. Use with identityv1connect.NewIdentityServiceHandler.
func NewServer(svc Service) *Server {
	return &Server{svc: svc}
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
	if err := requireVerifiedEmailForPassword(ctx); err != nil {
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

// DeleteAccount, RequestAccountExport and GetAccountExport need the resumable delete/export jobs from
// ADR-0003 ("Deletes & privacy"), which fan out across graph/posts/engagement/media/notifications —
// none of which exist in this Phase 0 bootstrap. Stubbed Unimplemented; tracked for Phase 1.

func (s *Server) DeleteAccount(context.Context, *connect.Request[identityv1.DeleteAccountRequest]) (*connect.Response[identityv1.DeleteAccountResponse], error) {
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

func (s *Server) RequestAccountExport(context.Context, *connect.Request[identityv1.RequestAccountExportRequest]) (*connect.Response[identityv1.RequestAccountExportResponse], error) {
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

func (s *Server) GetAccountExport(context.Context, *connect.Request[identityv1.GetAccountExportRequest]) (*connect.Response[identityv1.GetAccountExportResponse], error) {
	return nil, connect.NewError(connect.CodeUnimplemented, errUnimplementedPhase1)
}

// errUnimplementedPhase1's message is deliberately generic (L10, 2026-09-27 security audit): it is sent
// verbatim to the client by connect.NewError. The real reason — these need the resumable delete/export
// jobs from ADR-0003 "Deletes & privacy", which fan out across graph/posts/engagement/media/notifications,
// none of which exist in this Phase 0 bootstrap (see the doc comment above) — must stay in source comments,
// not on the wire, so a caller can't map our internal module roadmap from error text.
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
