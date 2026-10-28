// Package messaging is the direct-message module (ADR-0027): 1:1 text conversations, pull plus push, no realtime
// transport, no end-to-end encryption. It will own conversations/{convId}, conversations/{convId}/messages/{msgId},
// users/{uid}/dmInbox/{convId} and users/{uid}/dmRequests/{convId}. Other modules reach it through the interfaces in
// this file only (ADR-0027 D15).
//
// W7-4 ships the skeleton: the flag gate (FEATURE_MESSAGING, D6) and the six Connect handlers, each answering
// Unimplemented once the gate passes. The rules arrive in W7-5 (SendMessage), W7-6 (lifecycle), W7-7 and W7-8 (reads and
// mark-read, accept, delete). The skeleton reads and writes nothing, so every path costs 0 Firestore reads and writes.
package messaging

import (
	"context"
	"errors"
	"io"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// FlagName is the wire name of FEATURE_MESSAGING (ADR-0027 D6), the `feature` metadata of FEATURE_DISABLED and the
// string in GetMe.enabled_features.
const FlagName = "messaging"

// ErrNotImplemented is what the skeleton service answers once the flag gate passes. The server maps it to the Connect
// code Unimplemented at the handler boundary.
var ErrNotImplemented = errors.New("messaging: not implemented")

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Service is the Connect handler's dependency (ADR-0027 D15). Each method takes the caller's uid from the token (never
// from the request), checks the flag before any Firestore access (FEATURE_DISABLED feature=messaging, 0 reads) and then
// applies the rules. The request and response are the wire messages: there is no domain model before W7-5 needs one.
//
// Flag class per method (D6): Send and Accept need the flag on for the caller; ListConversations, ListMessages, MarkRead
// and Delete only need it not globally off, so a caller dropped from an allowlist can still read and clean up.
//
// Worst-case Firestore reads and writes per method are in the RPC doc comments of proto/dzeroth/messaging/v1; the W7-4
// skeleton costs 0 and 0.
type Service interface {
	Send(ctx context.Context, uid string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error)
	ListConversations(ctx context.Context, uid string, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, error)
	ListMessages(ctx context.Context, uid string, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, error)
	MarkRead(ctx context.Context, uid string, req *messagingv1.MarkConversationReadRequest) (*messagingv1.MarkConversationReadResponse, error)
	Accept(ctx context.Context, uid string, req *messagingv1.AcceptMessageRequestRequest) (*messagingv1.AcceptMessageRequestResponse, error)
	Delete(ctx context.Context, uid string, req *messagingv1.DeleteConversationRequest) (*messagingv1.DeleteConversationResponse, error)
}

// Eraser is messaging's step in the account-deletion cascade (ADR-0027 D9, plan W7-6, the `messaging` step between
// follow_requests and identity). PurgeUser is resumable: call again with the returned opaque checkpoint until done is
// true, like identity.StepEraser. Declared here so the seam exists before its implementation (W7-6).
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint []byte) (next []byte, done bool, err error)
}

// Exporter writes the `messages` section of the account export (ADR-0027 F5, plan W7-6) as one JSON value. Declared here
// so the seam exists before its implementation (W7-6).
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}
