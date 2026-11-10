// prefs.go is F6, notification settings: per type group, push on or off. The preferences live in one document,
// users/{uid}/settings/notifications, read by the fan-out before the FCM send (cached 60 s per instance) and by the
// Get/UpdateNotificationPrefs RPCs. In-app rows are never affected: a muted group still writes its row and moves the
// badge, only the push is skipped. The whole feature is behind FEATURE_NOTIFICATION_PREFS.
package notifications

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// PrefsFlagName is the wire name of FEATURE_NOTIFICATION_PREFS.
const PrefsFlagName = "notification_prefs"

const (
	// PrefsCacheTTL is how long the fan-out keeps a recipient's preferences. A change made on another instance takes up
	// to this long to reach a fan-out running elsewhere (the saving instance is evicted at once).
	PrefsCacheTTL = 60 * time.Second
	// PrefsCacheEntries bounds the per-instance cache.
	PrefsCacheEntries = 10000
)

// Group is a notification type group, the unit a user switches push on or off for. The strings are what is stored in the
// settings document's pushOff array, so a group added later defaults to on for every existing document.
type Group string

const (
	GroupPlans           Group = "plans"
	GroupMentionsReplies Group = "mentions_replies"
	GroupLikesReposts    Group = "likes_reposts"
	GroupFollowers       Group = "followers"
	GroupMessages        Group = "messages"
)

// Groups lists every group in a stable order.
var Groups = []Group{GroupPlans, GroupMentionsReplies, GroupLikesReposts, GroupFollowers, GroupMessages}

// GroupOf maps a notification type to its group ("" for a type no preference governs).
func GroupOf(t Type) Group {
	switch t {
	case TypeBeaconRequest, TypeBeaconAccepted, TypeBeaconCancelled:
		return GroupPlans
	case TypeMention, TypeReply, TypeQuote:
		return GroupMentionsReplies
	case TypeLike, TypeRepost:
		return GroupLikesReposts
	case TypeFollow, TypeFollowRequest, TypeFollowAccepted:
		return GroupFollowers
	case TypeMessage:
		return GroupMessages
	}
	return ""
}

// Prefs is the push preference of each group; true = push on. DefaultPrefs (all on) is today's behaviour and what a user
// who never saved anything has.
type Prefs struct {
	Plans, MentionsReplies, LikesReposts, Followers, Messages bool
}

// DefaultPrefs has every group on.
func DefaultPrefs() Prefs {
	return Prefs{Plans: true, MentionsReplies: true, LikesReposts: true, Followers: true, Messages: true}
}

// On reports whether push is on for g. An unknown group is on.
func (p Prefs) On(g Group) bool {
	switch g {
	case GroupPlans:
		return p.Plans
	case GroupMentionsReplies:
		return p.MentionsReplies
	case GroupLikesReposts:
		return p.LikesReposts
	case GroupFollowers:
		return p.Followers
	case GroupMessages:
		return p.Messages
	}
	return true
}

// PushAllowed reports whether a push of type t may be sent under p.
func (p Prefs) PushAllowed(t Type) bool { return p.On(GroupOf(t)) }

// Off returns the groups that are switched off, in Groups order (the stored form).
func (p Prefs) Off() []string {
	var off []string
	for _, g := range Groups {
		if !p.On(g) {
			off = append(off, string(g))
		}
	}
	return off
}

// PrefsFromOff rebuilds Prefs from the stored pushOff array; names it does not know are ignored.
func PrefsFromOff(off []string) Prefs {
	p := DefaultPrefs()
	for _, name := range off {
		switch Group(name) {
		case GroupPlans:
			p.Plans = false
		case GroupMentionsReplies:
			p.MentionsReplies = false
		case GroupLikesReposts:
			p.LikesReposts = false
		case GroupFollowers:
			p.Followers = false
		case GroupMessages:
			p.Messages = false
		}
	}
	return p
}

// PrefsRepo is the storage seam of users/{uid}/settings/notifications. FirestoreRepo implements it.
type PrefsRepo interface {
	// GetPrefs reads the document; a missing document is DefaultPrefs, not an error.
	GetPrefs(ctx context.Context, uid string) (Prefs, error)
	// SetPrefs replaces the document. It reads first and writes nothing when the stored value already equals p
	// (changed=false), so a replay of the same update costs one read.
	SetPrefs(ctx context.Context, uid string, p Prefs, now time.Time) (changed bool, err error)
}

// PrefsReader is what the fan-out needs: the recipient's preferences, cached.
type PrefsReader interface {
	PrefsFor(ctx context.Context, uid string) (Prefs, error)
}

// PrefsService is the service behind GetNotificationPrefs and UpdateNotificationPrefs.
type PrefsService interface {
	// GetPrefs reads the caller's preferences from storage (a settings screen read, not the cache).
	GetPrefs(ctx context.Context, uid string) (Prefs, error)
	// UpdatePrefs replaces the caller's preferences and returns them. idempotencyKey is format-checked only: the
	// operation is a full replace, so a repeat finds the state the first call left.
	UpdatePrefs(ctx context.Context, uid, idempotencyKey string, p Prefs) (Prefs, error)
}

// PrefsStore combines storage, the 60 s instance cache the fan-out reads through, and the RPC rules.
type PrefsStore struct {
	repo  PrefsRepo
	dir   Directory
	cache *cache.LRU[string, Prefs]
	now   func() time.Time
}

var (
	_ PrefsReader  = (*PrefsStore)(nil)
	_ PrefsService = (*PrefsStore)(nil)
)

// NewPrefsStore builds the store. dir (optional) lets UpdatePrefs refuse a caller who has no profile instead of creating
// a settings document under a user that does not exist.
func NewPrefsStore(repo PrefsRepo, dir Directory) *PrefsStore {
	return &PrefsStore{repo: repo, dir: dir, cache: cache.New[string, Prefs](PrefsCacheEntries, PrefsCacheTTL), now: time.Now}
}

// PrefsFor implements PrefsReader: cached for PrefsCacheTTL, one Firestore read on a miss.
func (s *PrefsStore) PrefsFor(ctx context.Context, uid string) (Prefs, error) {
	if p, ok := s.cache.Get(uid); ok {
		return p, nil
	}
	p, err := s.repo.GetPrefs(ctx, uid)
	if err != nil {
		return Prefs{}, fmt.Errorf("notifications: prefs for %s: %w", logger.HashUID(uid), err)
	}
	s.cache.Set(uid, p)
	return p, nil
}

// GetPrefs implements PrefsService.
func (s *PrefsStore) GetPrefs(ctx context.Context, uid string) (Prefs, error) {
	p, err := s.repo.GetPrefs(ctx, uid)
	if err != nil {
		return Prefs{}, logger.RedactErr(fmt.Errorf("notifications: get prefs: %w", err), uid)
	}
	s.cache.Set(uid, p)
	return p, nil
}

// UpdatePrefs implements PrefsService.
func (s *PrefsStore) UpdatePrefs(ctx context.Context, uid, idempotencyKey string, p Prefs) (Prefs, error) {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return Prefs{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if s.dir != nil {
		profiles, err := s.dir.GetProfiles(ctx, []string{uid})
		if err != nil {
			return Prefs{}, logger.RedactErr(fmt.Errorf("notifications: update prefs profile: %w", err), uid)
		}
		if _, ok := profiles[uid]; !ok {
			return Prefs{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "profile required")
		}
	}
	if _, err := s.repo.SetPrefs(ctx, uid, p, s.now().UTC().Truncate(time.Microsecond)); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			return Prefs{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "profile required")
		}
		return Prefs{}, logger.RedactErr(fmt.Errorf("notifications: update prefs: %w", err), uid)
	}
	s.cache.Set(uid, p) // this instance's fan-out sees the change at once; others within PrefsCacheTTL
	return p, nil
}
