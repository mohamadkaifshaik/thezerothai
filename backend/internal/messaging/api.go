// Package messaging is the direct-message module (ADR-0027): 1:1 text conversations, pull plus push, no realtime
// transport, no end-to-end encryption. It owns conversations/{convId}, conversations/{convId}/messages/{msgId},
// users/{uid}/dmInbox/{convId} and users/{uid}/dmRequests/{convId}. Other modules reach it through the interfaces in
// this file only (ADR-0027 D15).
//
// W7-4 shipped the skeleton: the flag gate (FEATURE_MESSAGING, D6) and the six Connect handlers. W7-5 adds SendMessage
// (service_send.go, repo_firestore.go) and W7-6 the lifecycle (eraser.go, export.go); the other four RPCs still answer
// Unimplemented once the gate passes (W7-7 to W7-9).
package messaging

import (
	"context"
	"errors"
	"io"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
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

// Eraser is messaging's step in the account-deletion cascade (ADR-0027 D8, plan W7-6, the `messaging` step between
// follow_requests and identity). PurgeUser is resumable: call again with the returned opaque checkpoint (JSON of
// Checkpoint) until done is true, like identity.StepEraser. NewEraser builds it.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint []byte) (next []byte, done bool, err error)
}

// Exporter writes the `messages` section of the account export (ADR-0027 F5, plan W7-6) as one JSON value. NewExporter
// builds it.
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

// Social is the seam to graph.Reader (*graph.service satisfies it): the 60 s cached social context of one user, used for
// the block, mute and mutual-follow rules of a send (ADR-0027 D4 step 3, A8).
type Social interface {
	Snapshot(ctx context.Context, uid string) (graph.Snapshot, error)
}

// Profiles is the part of identity.Directory a send needs: the cache-first batched profile lookup (non-ACTIVE users are
// absent from the result) and the eviction that makes the next lookup a fresh read (the purge-race check, D8).
type Profiles interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
	Forget(uids ...string)
}

// MessageEvent describes one delivered message for the push seam (ADR-0027 D4 step 6, D9). ConversationID is the
// opaque 32-hex id the push carries as its only data; it is never a uid.
type MessageEvent struct {
	ActorUID       string
	RecipientUID   string
	ConversationID string
	At             time.Time
}

// Events is messaging's outbound seam (CLAUDE.md "Events"): called after the commit of a send whose recipient side is
// accepted and not silent, never for a request, a muted sender or a replay. The composition root adapts it to
// notifications.Emitter. Best effort: it never fails the send.
type Events interface {
	MessageSent(ctx context.Context, e MessageEvent)
}

// BadgeCache is the seam to the unread-conversation badge cache (ADR-0027 D10, built by W7-11): Forget evicts the cached
// unread_conversation_count of these users on this instance. Nothing implements it before W7-11, so the Service skips
// the call while Deps.Badge is nil.
type BadgeCache interface {
	Forget(uids ...string)
}
