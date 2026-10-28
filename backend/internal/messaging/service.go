package messaging

import (
	"context"
	"errors"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// flagClass says whom FEATURE_MESSAGING must be on for (ADR-0027 D6).
type flagClass int

const (
	// perCaller needs the flag on for this caller: SendMessage and AcceptMessageRequest, which create new state.
	perCaller flagClass = iota
	// notGloballyOff only needs the flag not switched off for everyone: the reads and the clean-up RPCs, so a user dropped
	// from the allowlist or percent bucket can still read, clean up and report.
	notGloballyOff
)

type service struct {
	flags FlagChecker
}

// New builds the skeleton Service: the flag gate, then Unimplemented. W7-5 onwards add the repo and the rules behind the
// same gate.
func New(fc FlagChecker) Service { return &service{flags: fc} }

// guard is the flag gate of every method, run before any Firestore access. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=messaging, 0 reads. A nil checker is off for everyone.
func (s *service) guard(ctx context.Context, uid string, class flagClass) error {
	enabled := func(uid, name string) bool {
		if s.flags == nil {
			return false
		}
		if class == notGloballyOff {
			return !s.flags.GloballyOff(name)
		}
		return s.flags.Enabled(uid, name)
	}
	err := flags.Guard(ctx, enabled, uid, FlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", FlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", FlagName)
	}
	return err
}

// Send: per caller. Skeleton: 0 reads, 0 writes (the real costs are in the proto doc comment).
func (s *service) Send(ctx context.Context, uid string, _ *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}

// ListConversations: not globally off. Skeleton: 0 reads, 0 writes.
func (s *service) ListConversations(ctx context.Context, uid string, _ *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}

// ListMessages: not globally off. Skeleton: 0 reads, 0 writes.
func (s *service) ListMessages(ctx context.Context, uid string, _ *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}

// MarkRead: not globally off. Skeleton: 0 reads, 0 writes.
func (s *service) MarkRead(ctx context.Context, uid string, _ *messagingv1.MarkConversationReadRequest) (*messagingv1.MarkConversationReadResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}

// Accept: per caller (and later per recipient). Skeleton: 0 reads, 0 writes.
func (s *service) Accept(ctx context.Context, uid string, _ *messagingv1.AcceptMessageRequestRequest) (*messagingv1.AcceptMessageRequestResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}

// Delete: not globally off. Skeleton: 0 reads, 0 writes.
func (s *service) Delete(ctx context.Context, uid string, _ *messagingv1.DeleteConversationRequest) (*messagingv1.DeleteConversationResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	return nil, ErrNotImplemented
}
