// server.go is the thin Connect handler for MessagingService: caller uid, deadline, Service, error mapping. The flag
// check lives in the service layer (service.go), so a later split of the module keeps it; no business logic and no
// Firestore here.
package messaging

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
)

// rpcDeadline bounds one messaging call (<= 10 s).
const rpcDeadline = 8 * time.Second

// Server adapts Service to messagingv1connect.MessagingServiceHandler. It embeds no Unimplemented handler: every
// procedure of the service is implemented here, and a new one fails the build until it is.
type Server struct {
	svc   Service
	floor ClientFloor
}

// ServerOption configures NewServer.
type ServerOption func(*Server)

// WithClientFloor wires the app version floor (plan 6 section 3.1): a build below it gets FEATURE_DISABLED
// feature=messaging update_required=true from every RPC, before the flag check and any read. Nil, or floors of 0, change
// nothing.
func WithClientFloor(f ClientFloor) ServerOption { return func(s *Server) { s.floor = f } }

// NewServer builds the Connect handler. Use with messagingv1connect.NewMessagingServiceHandler.
func NewServer(svc Service, opts ...ServerOption) *Server {
	s := &Server{svc: svc}
	for _, o := range opts {
		o(s)
	}
	return s
}

var _ messagingv1connect.MessagingServiceHandler = (*Server)(nil)

// call is the shared RPC shell: caller uid, the app version floor, deadline, the service method.
func call[Req, Resp any](ctx context.Context, floor ClientFloor, req *connect.Request[Req], fn func(context.Context, string, *Req) (*Resp, error)) (*connect.Response[Resp], error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	if floor != nil && floor.BelowFloor(ctx) {
		return nil, clientinfo.UpdateRequired(ctx, clientinfo.FeatureMessaging)
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := fn(ctx, uid, req.Msg)
	if err != nil {
		return nil, err // apierr errors (FEATURE_DISABLED, NOT_FOUND, VALIDATION, ...) are converted by the error middleware
	}
	return connect.NewResponse(resp), nil
}

// SendMessage implements the RPC; the rules are Service.Send.
func (s *Server) SendMessage(ctx context.Context, req *connect.Request[messagingv1.SendMessageRequest]) (*connect.Response[messagingv1.SendMessageResponse], error) {
	return call(ctx, s.floor, req, s.svc.Send)
}

// CheckPostShare implements the RPC; the rules are Service.CheckPostShare.
func (s *Server) CheckPostShare(ctx context.Context, req *connect.Request[messagingv1.CheckPostShareRequest]) (*connect.Response[messagingv1.CheckPostShareResponse], error) {
	return call(ctx, s.floor, req, s.svc.CheckPostShare)
}

// ListConversations implements the RPC; the rules are Service.ListConversations.
func (s *Server) ListConversations(ctx context.Context, req *connect.Request[messagingv1.ListConversationsRequest]) (*connect.Response[messagingv1.ListConversationsResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListConversations)
}

// ListMessages implements the RPC; the rules are Service.ListMessages.
func (s *Server) ListMessages(ctx context.Context, req *connect.Request[messagingv1.ListMessagesRequest]) (*connect.Response[messagingv1.ListMessagesResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListMessages)
}

// MarkConversationRead implements the RPC; the rules are Service.MarkRead.
func (s *Server) MarkConversationRead(ctx context.Context, req *connect.Request[messagingv1.MarkConversationReadRequest]) (*connect.Response[messagingv1.MarkConversationReadResponse], error) {
	return call(ctx, s.floor, req, s.svc.MarkRead)
}

// AcceptMessageRequest implements the RPC; the rules are Service.Accept.
func (s *Server) AcceptMessageRequest(ctx context.Context, req *connect.Request[messagingv1.AcceptMessageRequestRequest]) (*connect.Response[messagingv1.AcceptMessageRequestResponse], error) {
	return call(ctx, s.floor, req, s.svc.Accept)
}

// DeleteConversation implements the RPC; the rules are Service.Delete.
func (s *Server) DeleteConversation(ctx context.Context, req *connect.Request[messagingv1.DeleteConversationRequest]) (*connect.Response[messagingv1.DeleteConversationResponse], error) {
	return call(ctx, s.floor, req, s.svc.Delete)
}

// ListMessageSuggestions implements the RPC; the rules are Service.ListSuggestions.
func (s *Server) ListMessageSuggestions(ctx context.Context, req *connect.Request[messagingv1.ListMessageSuggestionsRequest]) (*connect.Response[messagingv1.ListMessageSuggestionsResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListSuggestions)
}

// CommitConversation implements the RPC; the rules (flag per caller, verified email, the reset cap) are Service.Commit.
func (s *Server) CommitConversation(ctx context.Context, req *connect.Request[messagingv1.CommitConversationRequest]) (*connect.Response[messagingv1.CommitConversationResponse], error) {
	return call(ctx, s.floor, req, s.svc.Commit)
}

// ListConversationCommits implements the RPC; the rules are Service.ListCommits.
func (s *Server) ListConversationCommits(ctx context.Context, req *connect.Request[messagingv1.ListConversationCommitsRequest]) (*connect.Response[messagingv1.ListConversationCommitsResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListCommits)
}

// ListEpochMessages implements the RPC; the rules are Service.ListEpochMessages.
func (s *Server) ListEpochMessages(ctx context.Context, req *connect.Request[messagingv1.ListEpochMessagesRequest]) (*connect.Response[messagingv1.ListEpochMessagesResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListEpochMessages)
}

// ListWelcomes implements the RPC; the rules are Service.ListWelcomes.
func (s *Server) ListWelcomes(ctx context.Context, req *connect.Request[messagingv1.ListWelcomesRequest]) (*connect.Response[messagingv1.ListWelcomesResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListWelcomes)
}

// AckWelcomes implements the RPC; the rules are Service.AckWelcomes.
func (s *Server) AckWelcomes(ctx context.Context, req *connect.Request[messagingv1.AckWelcomesRequest]) (*connect.Response[messagingv1.AckWelcomesResponse], error) {
	return call(ctx, s.floor, req, s.svc.AckWelcomes)
}

// ListMessageTombstones implements the RPC; the rules are Service.ListMessageTombstones.
func (s *Server) ListMessageTombstones(ctx context.Context, req *connect.Request[messagingv1.ListMessageTombstonesRequest]) (*connect.Response[messagingv1.ListMessageTombstonesResponse], error) {
	return call(ctx, s.floor, req, s.svc.ListMessageTombstones)
}
