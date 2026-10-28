// server.go is the thin Connect handler for MessagingService: caller uid, deadline, Service, error mapping. The flag
// check lives in the service layer (service.go), so a later split of the module keeps it; no business logic and no
// Firestore here.
package messaging

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one messaging call (<= 10 s, go-service skill).
const rpcDeadline = 8 * time.Second

// Server adapts Service to messagingv1connect.MessagingServiceHandler.
type Server struct {
	messagingv1connect.UnimplementedMessagingServiceHandler
	svc Service
}

// NewServer builds the Connect handler. Use with messagingv1connect.NewMessagingServiceHandler.
func NewServer(svc Service) *Server { return &Server{svc: svc} }

var _ messagingv1connect.MessagingServiceHandler = (*Server)(nil)

// mapErr turns the service's sentinel into its Connect code; everything else (apierr errors such as FEATURE_DISABLED)
// passes through for the error middleware to convert.
func mapErr(err error) error {
	if errors.Is(err, ErrNotImplemented) {
		return connect.NewError(connect.CodeUnimplemented, errors.New("messaging is not implemented yet"))
	}
	return err
}

// call is the shared RPC shell: caller uid, deadline, the service method, error mapping.
func call[Req, Resp any](ctx context.Context, req *connect.Request[Req], fn func(context.Context, string, *Req) (*Resp, error)) (*connect.Response[Resp], error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := fn(ctx, uid, req.Msg)
	if err != nil {
		return nil, mapErr(err)
	}
	return connect.NewResponse(resp), nil
}

// SendMessage implements the RPC; the rules are Service.Send.
func (s *Server) SendMessage(ctx context.Context, req *connect.Request[messagingv1.SendMessageRequest]) (*connect.Response[messagingv1.SendMessageResponse], error) {
	return call(ctx, req, s.svc.Send)
}

// ListConversations implements the RPC; the rules are Service.ListConversations.
func (s *Server) ListConversations(ctx context.Context, req *connect.Request[messagingv1.ListConversationsRequest]) (*connect.Response[messagingv1.ListConversationsResponse], error) {
	return call(ctx, req, s.svc.ListConversations)
}

// ListMessages implements the RPC; the rules are Service.ListMessages.
func (s *Server) ListMessages(ctx context.Context, req *connect.Request[messagingv1.ListMessagesRequest]) (*connect.Response[messagingv1.ListMessagesResponse], error) {
	return call(ctx, req, s.svc.ListMessages)
}

// MarkConversationRead implements the RPC; the rules are Service.MarkRead.
func (s *Server) MarkConversationRead(ctx context.Context, req *connect.Request[messagingv1.MarkConversationReadRequest]) (*connect.Response[messagingv1.MarkConversationReadResponse], error) {
	return call(ctx, req, s.svc.MarkRead)
}

// AcceptMessageRequest implements the RPC; the rules are Service.Accept.
func (s *Server) AcceptMessageRequest(ctx context.Context, req *connect.Request[messagingv1.AcceptMessageRequestRequest]) (*connect.Response[messagingv1.AcceptMessageRequestResponse], error) {
	return call(ctx, req, s.svc.Accept)
}

// DeleteConversation implements the RPC; the rules are Service.Delete.
func (s *Server) DeleteConversation(ctx context.Context, req *connect.Request[messagingv1.DeleteConversationRequest]) (*connect.Response[messagingv1.DeleteConversationResponse], error) {
	return call(ctx, req, s.svc.Delete)
}
