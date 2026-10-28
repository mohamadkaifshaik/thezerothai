package messaging

import (
	"context"
	"errors"
	"log/slog"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
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

// Limits are the messaging numbers the service enforces itself. Every value is config (CLAUDE.md rule 11), none a literal.
type Limits struct {
	// RequestMaxUnanswered is MESSAGES_REQUEST_MAX_UNANSWERED: messages a requester may send before the recipient answers.
	RequestMaxUnanswered int64
	// DMNewPerDay and NewAccountDMNewPerDay are QUOTA_DM_NEW_CONVERSATIONS_PER_DAY (20) and the new-account tier (5).
	DMNewPerDay, NewAccountDMNewPerDay int64
	// NewAccountSendsPerDay is MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY (50): the SendMessage call cap of a new account. The
	// interceptor's DailyCap holds one number per procedure (MESSAGES_SENDS_PER_DAY, 300), so this tier is applied here.
	NewAccountSendsPerDay int64
	// NewAccountWindow is how long an account counts as new (QUOTA_NEW_ACCOUNT_WINDOW).
	NewAccountWindow time.Duration
	// ConversationCacheEntries is CACHE_MESSAGING_CONVERSATION_ENTRIES.
	ConversationCacheEntries int
}

// Deps are the collaborators of the service. Repo and Social are required for ListConversations, Repo, Social and Profiles for SendMessage; Events and Badge may
// be nil (no push, no badge cache yet).
type Deps struct {
	Repo     Repo
	Social   Social
	Profiles Profiles
	Events   Events
	Badge    BadgeCache
	Limits   Limits
	// CursorKey seals the list tokens (CURSOR_HMAC_KEY, like every other module); required for ListConversations.
	CursorKey []byte
	// TokenTTL is the lifetime of a persisted since or page token (RefreshTokenTTL, 30 days, when zero).
	TokenTTL time.Duration
	// Now is the clock (tests); nil is time.Now.
	Now func() time.Time
	Log *slog.Logger
}

// convCacheTTL is the staleness bound of the per-instance conversation cache (ADR-0027 D14): membership is immutable in
// a 1:1 conversation, state and clearedAt converge on other instances within 60 s. SendMessage never trusts the cached
// state: it re-reads the document in its transaction.
const convCacheTTL = 60 * time.Second

type service struct {
	flags FlagChecker
	d     Deps
	// convs caches conversations/{id} for the participant check of a send by conversation_id (convCacheTTL).
	convs *cache.LRU[string, ConvDoc]
	// newSends is the new-account tier of the SendMessage daily call cap (Limits.NewAccountSendsPerDay), in memory per
	// instance like every ratelimit.DailyCap.
	newSends *ratelimit.DailyCap
}

// New builds the Service: the flag gate, then the rules of the RPCs that exist (SendMessage, ListConversations, ListMessages,
// MarkRead; Accept and Delete answer Unimplemented until W7-9).
func New(fc FlagChecker, d Deps) Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	entries := d.Limits.ConversationCacheEntries
	if entries <= 0 {
		entries = 5000
	}
	s := &service{flags: fc, d: d, convs: cache.New[string, ConvDoc](entries, convCacheTTL)}
	if d.Limits.NewAccountSendsPerDay > 0 {
		s.newSends = ratelimit.NewDailyCap(d.Limits.NewAccountSendsPerDay).WithClock(d.Now)
	}
	return s
}

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
