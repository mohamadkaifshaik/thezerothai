// server.go is the thin Connect handler for ModerationService: caller uid, the FEATURE_REPORTS flag, enum
// conversion, Service. No business logic and no Firestore here (CLAUDE.md: handlers stay thin).
package moderation

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagChecker is the minimal seam the handler needs from pkg/platform/flags.Registry.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// reportDeadline bounds one ReportContent call (<= 10 s, go-service skill).
const reportDeadline = 8 * time.Second

// Server adapts Service to moderationv1connect.ModerationServiceHandler.
type Server struct {
	moderationv1connect.UnimplementedModerationServiceHandler
	svc   Service
	flags FlagChecker
}

// NewServer builds the Connect handler. Use with moderationv1connect.NewModerationServiceHandler.
func NewServer(svc Service, fc FlagChecker) *Server { return &Server{svc: svc, flags: fc} }

var _ moderationv1connect.ModerationServiceHandler = (*Server)(nil)

// ReportContent is behind FEATURE_REPORTS (FAILED_PRECONDITION + FEATURE_DISABLED, 0 reads, when off). A MESSAGE report
// also needs FEATURE_MESSAGING not globally off (guardMessaging, feature=messaging). Worst case reads and writes per
// target are on Service.Report: MESSAGE 6 reads cold / 3 warm (interceptor included), 3 writes (report, quotas, and the evidence child holding the message text, W7-36).
func (s *Server) ReportContent(ctx context.Context, req *connect.Request[moderationv1.ReportContentRequest]) (*connect.Response[moderationv1.ReportContentResponse], error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	var enabled func(string, string) bool
	if s.flags != nil {
		enabled = s.flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, FlagName); err != nil {
		return nil, err
	}
	m := req.Msg
	targetType := targetTypeFromProto(m.GetTargetType())
	if targetType == TargetMessage {
		// Before any work, so the exhausted-quota fast path (1 read) never runs for a switched-off feature.
		if err := s.guardMessaging(ctx, uid); err != nil {
			return nil, err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, reportDeadline)
	defer cancel()
	res, err := s.svc.Report(ctx, uid, ReportInput{
		IdempotencyKey: m.GetIdempotencyKey(),
		TargetType:     targetType,
		TargetID:       m.GetTargetId(),
		Reason:         reasonFromProto(m.GetReason()),
		Note:           m.GetNote(),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&moderationv1.ReportContentResponse{ReportId: res.ReportID, AlreadyReported: res.AlreadyReported}), nil
}

// guardMessaging is the second flag gate of a MESSAGE report (ADR-0027 D6, F6): FEATURE_MESSAGING only has to be not
// globally off, so a user dropped from the allowlist or percent bucket can still report what they received. A checker
// without GloballyOff (posts.GloballyOffChecker) gets the stricter per-caller answer. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=messaging, 0 reads.
func (s *Server) guardMessaging(ctx context.Context, uid string) error {
	on := s.flags != nil && s.flags.Enabled(uid, MessagingFlagName)
	if g, ok := s.flags.(posts.GloballyOffChecker); ok {
		on = !g.GloballyOff(MessagingFlagName)
	}
	if on {
		return nil
	}
	logger.SetRequestField(ctx, "feature_disabled", true)
	logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
	logger.SetRequestField(ctx, "feature", MessagingFlagName)
	return flags.DisabledError().WithMeta("feature", MessagingFlagName)
}

func targetTypeFromProto(t moderationv1.ReportTargetType) TargetType {
	switch t {
	case moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST:
		return TargetPost
	case moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT:
		return TargetAccount
	case moderationv1.ReportTargetType_REPORT_TARGET_TYPE_MESSAGE:
		return TargetMessage
	}
	return ""
}

func reasonFromProto(r moderationv1.ReportReason) Reason {
	switch r {
	case moderationv1.ReportReason_REPORT_REASON_SPAM:
		return ReasonSpam
	case moderationv1.ReportReason_REPORT_REASON_HARASSMENT:
		return ReasonHarassment
	case moderationv1.ReportReason_REPORT_REASON_HATE:
		return ReasonHate
	case moderationv1.ReportReason_REPORT_REASON_VIOLENCE:
		return ReasonViolence
	case moderationv1.ReportReason_REPORT_REASON_SEXUAL:
		return ReasonSexual
	case moderationv1.ReportReason_REPORT_REASON_SELF_HARM:
		return ReasonSelfHarm
	case moderationv1.ReportReason_REPORT_REASON_ILLEGAL:
		return ReasonIllegal
	case moderationv1.ReportReason_REPORT_REASON_IMPERSONATION:
		return ReasonImpersonation
	case moderationv1.ReportReason_REPORT_REASON_OTHER:
		return ReasonOther
	}
	return ""
}
