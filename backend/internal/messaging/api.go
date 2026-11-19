// Package messaging is the direct-message module: 1:1 text conversations, pull plus push, no realtime
// transport, plaintext or end-to-end encrypted (MLS). It owns conversations/{convId}, conversations/{convId}/messages/{msgId},
// conversations/{convId}/commits/{gen_epoch}, users/{uid}/dmInbox/{convId}, users/{uid}/dmRequests/{convId} and
// users/{uid}/dmWelcomes/{welcomeId}. Other modules reach it through the interfaces in
// this file only.
//
// Layout: the flag gate (FEATURE_MESSAGING, D6) and the Connect handlers of every MessagingService RPC (server.go); SendMessage
// (service_send.go, repo_firestore.go) and the lifecycle (eraser.go, export.go), ListConversations
// (service_list.go), ListMessages and MarkConversationRead (service_messages.go), AcceptMessageRequest and
// DeleteConversation (service_accept_delete.go, repo_accept_delete.go); end-to-end encryption (MLS): mls_init in the send,
// CommitConversation (service_mls.go) and the sync RPCs ListConversationCommits, ListEpochMessages, ListWelcomes and
// AckWelcomes (service_sync.go), all on the commit and welcome documents of repo_mls.go.
package messaging

import (
	"context"
	"io"
	"time"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// FlagName is the wire name of FEATURE_MESSAGING, the `feature` metadata of FEATURE_DISABLED and the
// string in GetMe.enabled_features.
const FlagName = "messaging"

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Service is the Connect handler's dependency. Each method takes the caller's uid from the token (never
// from the request), checks the flag before any Firestore access (FEATURE_DISABLED feature=messaging, nothing read) and then
// applies the rules. The request and response are the wire messages: there is no domain model before then needs one.
//
// Flag class per method (D6): Send and Accept need the flag on for the caller; ListConversations, ListMessages, MarkRead
// and Delete only need it not globally off, so a caller dropped from an allowlist can still read and clean up.
//
// Worst-case Firestore reads and writes per method are in the RPC doc comments of proto/dzeroth/messaging/v1 and on the
// implementing methods.
type Service interface {
	Send(ctx context.Context, uid string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error)
	ListConversations(ctx context.Context, uid string, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, error)
	ListMessages(ctx context.Context, uid string, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, error)
	MarkRead(ctx context.Context, uid string, req *messagingv1.MarkConversationReadRequest) (*messagingv1.MarkConversationReadResponse, error)
	Accept(ctx context.Context, uid string, req *messagingv1.AcceptMessageRequestRequest) (*messagingv1.AcceptMessageRequestResponse, error)
	Delete(ctx context.Context, uid string, req *messagingv1.DeleteConversationRequest) (*messagingv1.DeleteConversationResponse, error)
	// ListSuggestions answers ListMessageSuggestions (F30): messaging and dm_suggestions on for the caller; nothing stored.
	ListSuggestions(ctx context.Context, uid string, req *messagingv1.ListMessageSuggestionsRequest) (*messagingv1.ListMessageSuggestionsResponse, error)
	// Commit answers CommitConversation (a commit or a reset of an encrypted conversation): messaging on for the caller
	// (perCaller, as Send), verified email; see service_mls.go and the RPC comment for the order of answers.
	Commit(ctx context.Context, uid string, req *messagingv1.CommitConversationRequest) (*messagingv1.CommitConversationResponse, error)
	// The MLS sync reads and AckWelcomes (service_sync.go): "messaging" only not globally off (a caller dropped from the
	// allowlist keeps catching up); e2ee_dm is never needed.
	ListCommits(ctx context.Context, uid string, req *messagingv1.ListConversationCommitsRequest) (*messagingv1.ListConversationCommitsResponse, error)
	ListEpochMessages(ctx context.Context, uid string, req *messagingv1.ListEpochMessagesRequest) (*messagingv1.ListEpochMessagesResponse, error)
	ListWelcomes(ctx context.Context, uid string, req *messagingv1.ListWelcomesRequest) (*messagingv1.ListWelcomesResponse, error)
	AckWelcomes(ctx context.Context, uid string, req *messagingv1.AckWelcomesRequest) (*messagingv1.AckWelcomesResponse, error)
}

// Permission is the messaging send rules as a yes/no question for another module (the key directory,
// internal/keys, through an apiserver adapter): may callerUID message targetUID? It is a separate interface, not part of
// Service, and the composition root type-asserts the service to it like MessageReporter (report.go, which also holds
// ReportCommitment and VerifyReportPayload, the one check of a reporter's payload against the sender's commitment). CanMessage writes nothing.
// Every refusal is ErrCannotMessage itself (never a wire error); ErrSelf is the caller asking about themselves; any
// other error is a failure to decide (a read failed), never a refusal. See permission.go for the rules and reads.
type Permission interface {
	CanMessage(ctx context.Context, callerUID, targetUID string) error
	// SharesEncryptedConversation reports whether the two users are the participants of an ACCEPTED conversation whose
	// encryption is MLS. One cache-first conversation read (up to 60 s stale); writes nothing. No conversation, a
	// plaintext one, a conversation still in the request state (for both participants), an invalid or equal uid, or a
	// conversation whose other participant is not targetUID => false, nil.
	// A failed read is an error built by permissionFailure (uids and conversation id hashed), never false.
	SharesEncryptedConversation(ctx context.Context, callerUID, targetUID string) (bool, error)
}

// Eraser is messaging's step in the account-deletion cascade (the `messaging` step between follow_requests and identity).
// PurgeUser is resumable: call again with the returned opaque checkpoint (JSON of
// Checkpoint) until done is true, like identity.StepEraser. NewEraser builds it.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, checkpoint []byte) (next []byte, done bool, err error)
}

// Exporter writes the `messages` section of the account export as one JSON value. NewExporter
// builds it.
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

// Social is the seam to graph.Reader (*graph.service satisfies it): the 60 s cached social context, of the CALLER for
// the caller-side block, mute and follow rules of a send and of a peer for a REQUESTS row when the
// caller is past the blockedBy cap. The recipient of a send is TxSocial.
type Social interface {
	Snapshot(ctx context.Context, uid string) (graph.Snapshot, error)
}

// Profiles is the part of identity.Directory a send needs: the cache-first batched profile lookup (non-ACTIVE users are
// absent from the result) and the eviction that makes the next lookup a fresh read (the purge-race check, D8).
type Profiles interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
	Forget(uids ...string)
}

// MessageEvent describes one delivered message for the push seam (D9). ConversationID is the
// opaque 32-hex id the push carries as its only data; it is never a uid.
type MessageEvent struct {
	ActorUID       string
	RecipientUID   string
	ConversationID string
	At             time.Time
}

// Events is messaging's outbound seam (the "Events" rule): called after the commit of a send whose recipient side is
// accepted and not silent, never for a request, a muted sender or a replay. The composition root adapts it to
// notifications.Emitter. Best effort: it never fails the send.
type Events interface {
	MessageSent(ctx context.Context, e MessageEvent)
}

// BadgeCache is the seam to the unread-conversation badge cache: Forget evicts the cached
// unread_conversation_count of these users on this instance. identity.MessageBadgeCache implements it; the Service skips
// the call while Deps.Badge is nil.
type BadgeCache interface {
	Forget(uids ...string)
}

// UnreadCounter is the storage half of UnreadBadge (*FirestoreRepo and every Repo implement it).
type UnreadCounter interface {
	CountUnreadConversations(ctx context.Context, uid string) (int64, error)
}

// UnreadBadge implements identity.MessageBadge without importing identity: the method has exactly the
// interface's shape, so apiserver passes it to identity.WithMessageBadge. It is the count() of dmInbox entries with
// unreadCount > 0, Limit 100. It does not check the flag: identity calls it only for a caller with messaging on.
type UnreadBadge struct{ counter UnreadCounter }

// NewUnreadBadge builds the badge on the repo.
func NewUnreadBadge(c UnreadCounter) *UnreadBadge { return &UnreadBadge{counter: c} }

// UnreadConversations returns the unread conversation count, at most 100; it never writes.
func (b *UnreadBadge) UnreadConversations(ctx context.Context, uid string) (int64, error) {
	return b.counter.CountUnreadConversations(ctx, uid)
}

// Devices is the seam to the key directory (keys.DeviceDirectory, adapted by the composition root; messaging does not
// call the keys service): the ACTIVE encryption device ids of a user, at most 5, from one bounded query, without any
// permission or e2ee_dm check (messaging applies its own rules first). It is read for the welcome-device check only:
// before the send transaction of an mls_init, and during the CommitConversation transaction (after its conversation read
// names the peer; not a transactional read). A read failure is an error, never "no devices". Device ids are never logged.
// DeviceIDs is every REGISTERED device id of a user, active or not (at most 5, one bounded query): the ownership check of
// ListWelcomes and AckWelcomes device_id.
type Devices interface {
	ActiveDeviceIDs(ctx context.Context, uid string) ([]string, error)
	DeviceIDs(ctx context.Context, uid string) ([]string, error)
}

// TxSocial is the seam to graph.TxReader (*graph.FirestoreRepo satisfies it): the recipient's graph/{uid} read INSIDE
// the send transaction, uncached, so a Block, Mute or Unfollow by the recipient that committed on any instance decides
// the send, and a concurrent one conflicts with it. messaging never builds a graph path.
type TxSocial interface {
	SnapshotInTx(ctx context.Context, tx *firestore.Transaction, uid string) (graph.Snapshot, error)
}
