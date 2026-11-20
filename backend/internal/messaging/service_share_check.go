// service_share_check.go is CheckPostShare (plan 2026-11-20): SendMessage's shared_post_id rules as a question, without a
// recipient or a conversation, for an encrypted share whose post id travels inside the ciphertext. It runs the very
// functions a send runs (guardPostShare, checkPostShare over Deps.PostShare); no rule is copied here.
package messaging

import (
	"context"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ShareCheckFlagName is the wire name of FEATURE_DM_SHARE_CHECK: CheckPostShare needs it on for the caller, after
// "messaging" and before the verified email.
const ShareCheckFlagName = "dm_share_check"

// kindShareCheck is the request-line kind (and the failure op) of CheckPostShare.
const kindShareCheck = "share_check"

// CheckPostShare implements Service.CheckPostShare. In this order, every gate before any lookup: "messaging" on for the
// caller (as Send), "dm_share_check" on for the caller, the verified email (Send's bytes), then Send's shared_post_id gate
// (posts, dm_post_share, the id shape with VALIDATION "post_id") and Send's check (checkPostShare: NOT_FOUND "post not
// found", PROTECTED_ACCOUNT, or the check's own apierr such as UNAVAILABLE, all passed through). Any other failure is a
// redacted INTERNAL. That includes a raw read failure (a timeout or contention reading the post or the directory): it is
// INTERNAL here, whereas SendMessage answers UNAVAILABLE "busy, please retry" (deliberate: read-path timeouts stay
// INTERNAL, and the client auto-retries NO_SIDE_EFFECTS calls on UNAVAILABLE). Every other answer is byte-identical. Writes nothing and never records a share. The per-minute bucket and the daily call cap run in the
// rate-limit interceptor. The request line carries kind=share_check and shared_post=true, never the post id.
func (s *service) CheckPostShare(ctx context.Context, uid string, req *messagingv1.CheckPostShareRequest) (*messagingv1.CheckPostShareResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindShareCheck)
	if err := s.guardShareCheck(ctx, uid); err != nil {
		return nil, err
	}
	// The same action text as Send: the refusal is byte-identical to a send's.
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "sending messages"); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldSharedPost, true)
	postID := req.GetPostId()
	if err := s.guardPostShare(ctx, uid, postID, fieldPostID); err != nil {
		return nil, err
	}
	sp, err := s.checkPostShare(ctx, uid, postID)
	if err != nil {
		return nil, s.failure(ctx, kindShareCheck, uid, "", err, postID)
	}
	return &messagingv1.CheckPostShareResponse{SharedPostId: sp.ID}, nil
}

// guardShareCheck is the caller's FEATURE_DM_SHARE_CHECK gate: FAILED_PRECONDITION + FEATURE_DISABLED with
// metadata["feature"] = "dm_share_check", before any lookup (the shape of guard). A nil checker is off.
func (s *service) guardShareCheck(ctx context.Context, uid string) error {
	return s.guardFlag(ctx, uid, ShareCheckFlagName)
}
