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
)

// Valid reports whether t is a known type.
func (t Type) Valid() bool {
	switch t {
	case TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote:
		return true
	}
	return false
}

// needsPost reports whether events of type t must name a post.
func (t Type) needsPost() bool { return t != TypeFollow }

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
	// Actor is the most recent actor; ActorIDs are all distinct actors folded into the row (>= 1).
	Actor     Actor
	ActorIDs  []string
	PostID    string
	CreatedAt time.Time
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
}

// ErrTokenUnregistered is returned by PushSender.Send when FCM says the token is no longer valid: the device is
// pruned (ADR-0017 D6).
var ErrTokenUnregistered = errors.New("notifications: fcm token unregistered")

// PushSender sends one push to one FCM token.
type PushSender interface {
	Send(ctx context.Context, token string, p Push) error
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
	// Deleted counts documents removed so far.
	Deleted int
}

// Eraser is the delete-cascade building block (ADR-0017 D10); PurgeUser is resumable.
type Eraser interface {
	PurgeUser(ctx context.Context, uid string, cp Checkpoint) (next Checkpoint, done bool, err error)
}
