// server_shares.go holds the Connect handler of RecordPostShare: the flag gate, then the share through the PostShares
// seam. No business logic here.
package engagement

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// WithPostShares supplies the service behind RecordPostShare, overriding the default: NewServer already uses svc when it
// implements PostShares (the Module does). Without either, RecordPostShare answers Unimplemented after the flag gate.
func WithPostShares(p PostShares) ServerOption { return func(s *Server) { s.shares = p } }

// guardShare is the flag gate of RecordPostShare, run before any Firestore access: FEATURE_POSTS first (the posts guard),
// then FEATURE_SHARE_COUNT on for the caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata feature=share_count). It
// does not need FEATURE_ENGAGEMENT: a share is not a like. It returns the caller's uid.
func (s *Server) guardShare(ctx context.Context) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if err := flags.Guard(ctx, s.flags.Enabled, uid, ShareFlagName); err != nil {
		logger.SetRequestField(ctx, "feature", ShareFlagName)
		return "", flags.DisabledError().WithMeta("feature", ShareFlagName)
	}
	return uid, nil
}

// shareChannel is the request-log value of ShareChannel; "" for UNSPECIFIED or an unknown value (VALIDATION channel).
func shareChannel(c engagementv1.ShareChannel) string {
	switch c {
	case engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK:
		return "copy_link"
	case engagementv1.ShareChannel_SHARE_CHANNEL_SHARE_SHEET:
		return "share_sheet"
	}
	return ""
}

// RecordPostShare implements the RPC; the rules are PostShares.RecordShare (engagement.proto). A flag, shape or rate-bucket
// refusal does no Firestore access; a protected author's post, the caller's own post and a repeat share answer success
// with counted = false and nothing written.
func (s *Server) RecordPostShare(ctx context.Context, req *connect.Request[engagementv1.RecordPostShareRequest]) (*connect.Response[engagementv1.RecordPostShareResponse], error) {
	uid, err := s.guardShare(ctx)
	if err != nil {
		return nil, err
	}
	if s.shares == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("RecordPostShare is not wired"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	r, err := s.shares.RecordShare(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId(), shareChannel(req.Msg.GetChannel()))
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.RecordPostShareResponse{Engagement: toProto(r.Result), Counted: r.Counted}), nil
}
