// Package notifications is the P6 module (ADR-0017): in-app notifications under users/{uid}/notifications, FCM
// device registration under users/{uid}/devices (+ the deviceTokens reverse index), the Pub/Sub fan-out handler
// that turns events from other modules into rows and pushes, and the module's Eraser and exporter.
//
// Other modules never import this package's internals: producers (graph FollowEvents, posts PostEvents, later
// replies/likes/reposts/quotes) call Emitter.Emit through small adapters in apiserver. The module itself depends on
// identity (Directory), graph (Reader) and the platform packages only.
package notifications

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// FlagName is the wire name RPCs, producers and the handler check (ADR-0017 D7: FEATURE_NOTIFICATIONS).
const FlagName = "notifications"

// Limits (ADR-0017).
const (
	// MaxDevicesPerUser is the cap on users/{uid}/devices; a further registration evicts the least recently updated.
	MaxDevicesPerUser = 5
	// MaxRecipientsPerEvent is the most recipients one event carries (one post carries at most 10 mentions).
	MaxRecipientsPerEvent = 10
	// TTL is how long a notification lives (the Firestore TTL policy on expireAt, ADR-0003).
	TTL = 90 * 24 * time.Hour
	// DefaultPageSize and MaxPageSize are CLAUDE.md rule 5.
	DefaultPageSize = 20
	MaxPageSize     = 50
	// SettleWindow is how far since_token trails the newest returned row, so a row committed by another instance a
	// moment later is still returned by the next refresh (the client dedupes by id).
	SettleWindow = 5 * time.Second
	// RefreshTokenTTL is how long a persisted since/gap token is accepted (same as the timelines, ADR-0010 D14).
	RefreshTokenTTL = 30 * 24 * time.Hour
	// MaxActorIDs bounds Notification.ActorIDs on a collapsed like row (the last N distinct actors, ADR-0017 D4):
	// a viral post must not grow one document toward Firestore's 1 MiB or its 1 write/s sustained limit.
	MaxActorIDs = 50
	// MaxFCMTokenBytes bounds a registration token (real ones are ~160-200 bytes).
	MaxFCMTokenBytes = 4096
)

// Type is a notification kind. The string values are the wire format of Event and the Firestore `type` field.
type Type string

const (
	TypeFollow  Type = "follow"
	TypeMention Type = "mention"
	TypeReply   Type = "reply"
	TypeLike    Type = "like"
	TypeRepost  Type = "repost"
	TypeQuote   Type = "quote"
	// TypeFollowRequest goes to a protected account when someone asks to follow it; TypeFollowAccepted goes to the
	// requester when the request is approved (ADR-0025 D10). Neither carries a post or needs the protected set.
	TypeFollowRequest  Type = "follow_request"
	TypeFollowAccepted Type = "follow_accepted"
	// TypeMessage is the push-only direct-message type (ADR-0027 D9, ADR-0017 note 2026-10-28): one generic FCM push
	// to the recipient, no users/{uid}/notifications row, no badge move, never listed. It names a conversation, not a post.
	TypeMessage Type = "message"
)

// MessagingFlagName is the wire name of FEATURE_MESSAGING (messaging.FlagName). notifications cannot import messaging,
// so the push-only message type checks the recipient's flag by this literal; a test pins it to the messaging constant
// through the apiserver wiring.
const MessagingFlagName = "messaging"

// Valid reports whether t is a known type.
func (t Type) Valid() bool {
	switch t {
	case TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote, TypeFollowRequest, TypeFollowAccepted, TypeMessage:
		return true
	}
	return false
}

// needsPost reports whether events of type t must name a post.
func (t Type) needsPost() bool {
	return t != TypeFollow && t != TypeFollowRequest && t != TypeFollowAccepted && t != TypeMessage
}

// pushOnly reports whether events of type t produce a push and no users/{uid}/notifications row.
func (t Type) pushOnly() bool { return t == TypeMessage }

// postBearing reports whether a row of type t exposes a post of the actor to the recipient, so an actor the recipient
// may not see must not produce it (ADR-0025 D10). Like is excluded by design (the actor liked the recipient's own
// post); follow, follow_request and follow_accepted name no post.
func (t Type) postBearing() bool {
	switch t {
	case TypeMention, TypeReply, TypeQuote, TypeRepost:
		return true
	}
	return false
}

// Platform is a device platform. Web push is out of scope (ADR-0017 D11).
type Platform string

const (
	PlatformIOS     Platform = "ios"
	PlatformAndroid Platform = "android"
)

// Event is what a producer reports: Actor did Type to each recipient (about PostID, except follows).
type Event struct {
	Type         Type
	ActorID      string
	RecipientIDs []string
	// PostID is the subject post: the mentioning/replying/quoting post, or the liked/reposted post.
	PostID string
	// ConversationID is the 32-hex direct-message conversation (TypeMessage only; additive, wire v stays 1).
	ConversationID string
	// At is when the action committed (informational: createdAt is the handler's commit time, ADR-0017 D3).
	At time.Time
}

// Emitter is the one seam other slices call after their commit (ADR-0017 D2). Emit is best effort: it never fails
// the caller's operation, and it must not be called inside a transaction or its read budget. A returned error is
// informational (already logged); callers ignore it.
type Emitter interface {
	Emit(ctx context.Context, e Event) error
}

// Actor is the denormalized actor snapshot stored on a notification row.
type Actor struct {
	UserID      string
	Handle      string
	DisplayName string
	AvatarURL   string
	Verified    bool
}

// Notification is one users/{uid}/notifications/{id} row.
type Notification struct {
	ID   string
	Type Type
	// Actor is the most recent actor; ActorIDs are the last MaxActorIDs distinct actors folded into the row (>= 1).
	Actor    Actor
	ActorIDs []string
	// ActorCount is every distinct actor folded in (>= len(ActorIDs); 0 on rows written before the field).
	ActorCount int
	PostID     string
	CreatedAt  time.Time
}

// Device is one users/{uid}/devices/{deviceId} row.
type Device struct {
	ID        string
	Token     string
	Platform  Platform
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Push is the FCM payload: no post text, no handle (ADR-0017 D6).
type Push struct {
	Type           Type
	NotificationID string
	PostID         string
	ActorID        string
	// ConversationID is the only identifier a TypeMessage push carries (no actor, no post, no text).
	ConversationID string
}

// ErrTokenUnregistered is returned by PushSender.Send when FCM says the token is no longer valid: the device is
// pruned (ADR-0017 D6).
var ErrTokenUnregistered = errors.New("notifications: fcm token unregistered")

// PushSender sends one push to one FCM token.
type PushSender interface {
	Send(ctx context.Context, token string, p Push) error
}

// ErrTokenInvalid is returned by TokenValidator.Validate when FCM definitively rejects the registration token
// (INVALID_ARGUMENT, UNREGISTERED or SENDER_ID_MISMATCH): it is not a real token of this project.
var ErrTokenInvalid = errors.New("notifications: fcm token invalid")

// TokenValidator checks a registration token with FCM before it is stored (N-5). nil error = accept. An error that
// is not ErrTokenInvalid means "could not tell" (FCM unconfigured, quota, network, permission): the caller fails
// open, because the FCM IAM role may not be applied yet and a push outage must not block device registration.
type TokenValidator interface {
	Validate(ctx context.Context, token string) error
}

// Publisher publishes one Pub/Sub message (pkg/platform/pubsubpublish.Publisher).
type Publisher interface {
	Publish(ctx context.Context, data []byte) error
}

// FlagChecker is the seam to pkg/platform/flags.Registry.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// SeenStore writes users/{uid}.notificationsSeenAt (identity.FirestoreRepo).
type SeenStore interface {
	MarkNotificationsSeen(ctx context.Context, uid string, at time.Time) error
}

// Directory is the identity seam (identity.Directory).
type Directory = identity.Directory

// Social is the graph seam (graph.Reader): the recipient's cached social context for suppression.
type Social = graph.Reader

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning.
type Checkpoint struct {
	// Step: 0 devices, 1 the user's own notifications, 2 notifications other users hold about this user.
	Step int
	// Deleted counts documents processed so far: deleted, or (purge step 2) repointed/unfolded in place.
	Deleted int
}

// Eraser is the delete-cascade building block (ADR-0017 D10); PurgeUser is resumable.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, cp Checkpoint) (next Checkpoint, done bool, err error)
}

// ActorSweeper is the opsctl seam over purge step 2 (N-4): remove the rows other users hold about an actor.
// Implemented by FirestoreRepo.SweepActorRows (sweep.go).
type ActorSweeper interface {
	SweepActorRows(ctx context.Context, uid string, cp Checkpoint) (next Checkpoint, done bool, err error)
}

// AudienceChecker is the consumer-side audience seam (ADR-0025 AQ5): may viewer see author's posts, given whether
// viewer follows author (read from the viewer's graph snapshot, which the fan-out already holds, so a check costs 0
// reads). apiserver adapts it from posts.Audience.CanSee, so the one rule stays in one place and this package never
// reads the protected set itself. A non-nil error means the set is unavailable (the loader failed closed): the
// caller must not treat it as "visible".
type AudienceChecker interface {
	CanSee(ctx context.Context, viewerUID, authorUID string, following bool) (bool, error)
}

// AudienceFunc adapts a function to AudienceChecker.
type AudienceFunc func(ctx context.Context, viewerUID, authorUID string, following bool) (bool, error)

// CanSee implements AudienceChecker.
func (f AudienceFunc) CanSee(ctx context.Context, viewerUID, authorUID string, following bool) (bool, error) {
	return f(ctx, viewerUID, authorUID, following)
}
