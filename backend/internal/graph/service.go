package graph

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// graphFlagName is the wire name GraphService RPCs check (ADR-0008 D6: FEATURE_GRAPH <-> "graph").
const graphFlagName = "graph"

// FlagChecker is the minimal seam graph needs from pkg/platform/flags.Registry (ADR-0002: depend on
// interfaces, not the concrete platform type).
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// MutationOutcome is Created, Replay or Noop for the state-setting mutations (Follow/Block/Mute); the
// log field ADR-0008 calls "outcome" (created|replay|noop|rejected:<reason>).
type MutationOutcome string

const (
	OutcomeCreated MutationOutcome = "created"
	OutcomeReplay  MutationOutcome = "replay"
	OutcomeNoop    MutationOutcome = "noop"
)

// Repo is graph's storage seam; service.go depends on this, repo_firestore.go implements it against
// Firestore (identity.Counters is wired into the FirestoreRepo itself via SetCounters, since the counter
// increments must land in the same transaction/batch as the edge change — ADR-0008 D3), unit tests use an
// in-memory fake.
type Repo interface {
	// GetSnapshot reads graph/{uid} (Reader.Snapshot's cache-miss path). Missing doc -> empty Snapshot, no error.
	GetSnapshot(ctx context.Context, uid string) (Snapshot, error)

	// Follow runs the whole Follow transaction (ADR-0008 T7). dailyLimit is the caller's resolved
	// follows/day cap (service.go picks the new-account or standard limit before calling this).
	Follow(ctx context.Context, callerUID, targetUID string, targetIsPrivate bool, dailyLimit int64, now time.Time) (Relationship, MutationOutcome, error)
	// Unfollow is a blind batch (ADR-0008 T7): changed=false, nil error means "wasn't following" (0 writes).
	Unfollow(ctx context.Context, callerUID, targetUID string, now time.Time) (changed bool, err error)

	// Block runs the whole Block transaction (ADR-0008 T8). limits picks the new-account vs standard quota
	// tier internally (from the graph doc's own Firestore creation time, 0 extra reads).
	Block(ctx context.Context, callerUID, targetUID string, limits dailyLimits, now time.Time) (BlockResult, error)
	// Unblock is never quota-gated (ADR-0008 D9). changed=false means "wasn't blocking" (0 writes).
	Unblock(ctx context.Context, callerUID, targetUID string, now time.Time) (rel Relationship, changed bool, err error)
	// Mute runs the whole Mute transaction (ADR-0008 T8), sharing the same quota kind/limits as Block.
	Mute(ctx context.Context, callerUID, targetUID string, limits dailyLimits, now time.Time) (Relationship, MutationOutcome, error)
	// Unmute is never quota-gated. changed=false means "wasn't muting" (0 writes).
	Unmute(ctx context.Context, callerUID, targetUID string, now time.Time) (rel Relationship, changed bool, err error)

	// GetLists reads graph/{uid} once (1 read) and returns the ordered blocked/muted arrays (insertion order,
	// oldest first) plus the same doc as a Snapshot. Missing doc -> empty Lists, no error.
	GetLists(ctx context.Context, uid string) (Lists, error)
	// RemoveOwnArrayEntries ArrayRemoves uids from the caller's own blocked[]/muted[] (T27). 1 write, 0 reads.
	RemoveOwnArrayEntries(ctx context.Context, callerUID, kind string, uids []string, now time.Time) error
	// ListEdgesByFollowers returns the newest follow edges made by any of followers (1 to 30 uids), newest first, at
	// most limit (1 to 50): the ListSuggestedUsers friends-of-friends query (ADR-0024 D8). <= limit reads, minimum 1.
	ListEdgesByFollowers(ctx context.Context, followers []string, limit int) ([]Edge, error)

	Eraser

	// ListEdges returns one page of follow edges, newest first (ADR-0008 T10). <= q.Limit reads.
	ListEdges(ctx context.Context, q EdgeQuery) ([]Edge, error)
	// FollowEdgeExists reports whether follows/{followerUID}_{followeeUID} exists: one point read, 1 read whether or
	// not the document is there (ADR-0024 D7, GetProfileRelationship). A missing document is false, not an error.
	FollowEdgeExists(ctx context.Context, followerUID, followeeUID string) (bool, error)
}

// Deps are service's constructor dependencies (ADR-0008 T5).
type Deps struct {
	Repo  Repo
	Cache *Cache
	Flags FlagChecker
	// CursorKey signs opaque page tokens (config.CursorHMACKey, ADR-0003).
	CursorKey []byte
	// ReadOnly is true when DEGRADED_MODE=readonly (config.DegradedReadonly). The list RPCs are
	// NO_SIDE_EFFECTS, so the degraded interceptor lets them through; ReadOnly makes the T27 lazy clean-up
	// skip its one write so that mode stays write-free.
	ReadOnly bool
	// Events receives the post-commit FollowEvents.Followed hook (ADR-0008 D11; apiserver wires the P6 notifications
	// adapter). Nil keeps the no-op.
	Events FollowEvents

	FollowsPerDay           int64
	NewAccountFollowsPerDay int64
	BlocksPerDay            int64
	NewAccountBlocksPerDay  int64
	NewAccountWindow        time.Duration

	// Suggestions are the ListSuggestedUsers limits and curated list (ADR-0024 D8, D10); zero or out-of-range values
	// fall back to the config defaults and bounds (SuggestionLimits.normalized).
	Suggestions SuggestionLimits
	// Suggester overrides the candidate source of ListSuggestedUsers (friends of friends with the curated fallback by
	// default). It is the seam for ADR-0024 D8 option (b) or a precomputed list: callers see no change.
	Suggester Suggester
}

// service is the default Service implementation. It also implements Reader, FollowEvents, Eraser and
// identity.BlockChecker (all on this one concrete type — see the method set below and in follow.go,
// block.go, etc. as they land) so apiserver.Build wires a single object into every seam.
//
// directory (identity.Directory) is set after construction via SetDirectory, because identity.New needs
// this service as its BlockChecker and this service needs identity.Directory: apiserver.Build breaks that
// cycle by constructing this service first (without a directory), then identity.New with this service as
// BlockChecker, then calling SetDirectory(identitySvc) — safe because it happens once, synchronously, at
// startup before any request is served (ADR-0002 cold-start wiring).
type service struct {
	repo      Repo
	cache     *Cache
	flags     FlagChecker
	cursorKey []byte
	directory identity.Directory
	now       func() time.Time
	readOnly  bool
	events    FollowEvents

	followsPerDay           int64
	newAccountFollowsPerDay int64
	blocksPerDay            int64
	newAccountBlocksPerDay  int64
	newAccountWindow        time.Duration
	suggestions             SuggestionLimits
	suggester               Suggester
	// suggested is the per-viewer ListSuggestedUsers result cache (suggestion_cache.go).
	suggested *suggestionCache
}

// New builds the graph Service. Call SetDirectory once identity.Directory is available.
func New(d Deps) *service {
	s := &service{
		events:                  d.Events,
		repo:                    d.Repo,
		cache:                   d.Cache,
		flags:                   d.Flags,
		cursorKey:               d.CursorKey,
		now:                     time.Now,
		readOnly:                d.ReadOnly,
		followsPerDay:           d.FollowsPerDay,
		newAccountFollowsPerDay: d.NewAccountFollowsPerDay,
		blocksPerDay:            d.BlocksPerDay,
		newAccountBlocksPerDay:  d.NewAccountBlocksPerDay,
		newAccountWindow:        d.NewAccountWindow,
		suggestions:             d.Suggestions.normalized(),
		suggester:               d.Suggester,
	}
	s.suggested = newSuggestionCache(s.suggestions.CacheTTL)
	if s.events == nil {
		s.events = s // the no-op Followed below
	}
	if s.suggester == nil {
		fof := newFriendsOfFriends(s.repo, s.suggestions, func() time.Time { return s.now() })
		fof.inactive = s.knownInactive
		s.suggester = fof
	}
	return s
}

// SetDirectory wires identity.Directory after construction (see service's doc comment).
func (s *service) SetDirectory(d identity.Directory) {
	s.directory = d
}

// knownInactive is the friends-of-friends suggester's cache-only status probe (W3-22 L-5): which uids the Directory's
// profile cache already knows are not ACTIVE. It looks at s.directory when called, because SetDirectory runs after New;
// a Directory that does not implement inactiveProber (a fake) knows nothing, so nothing is skipped.
func (s *service) knownInactive(uids []string) map[string]bool {
	if p, ok := s.directory.(inactiveProber); ok {
		return p.KnownInactive(uids)
	}
	return nil
}

var _ Service = (*service)(nil)
var _ Reader = (*service)(nil)
var _ FollowEvents = (*service)(nil)
var _ identity.BlockChecker = (*service)(nil)

// Snapshot implements Reader: cache-first read of graph/{uid}, 60s TTL (ADR-0008 D8). 1 read on a miss, 0 on
// a hit.
func (s *service) Snapshot(ctx context.Context, uid string) (Snapshot, error) {
	if snap, ok := s.cache.Get(uid); ok {
		noteCacheHit(ctx, true)
		return snap, nil
	}
	noteCacheHit(ctx, false)
	snap, err := s.repo.GetSnapshot(ctx, uid)
	if err != nil {
		return Snapshot{}, err
	}
	s.cache.Set(uid, snap)
	return snap, nil
}

// IsBlockedBy implements identity.BlockChecker: true if targetUID has blocked viewerUID, trusting the
// viewer's own cached blockedBy set unless it may be incomplete (ADR-0008 D2 overflow fallback), in which
// case it also reads targetUID's own .blocked array directly (+1 read, cached 60s like every other read
// path; D8).
func (s *service) IsBlockedBy(ctx context.Context, viewerUID, targetUID string) (bool, error) {
	viewerSnap, err := s.Snapshot(ctx, viewerUID)
	if err != nil {
		return false, err
	}
	if viewerSnap.isBlockedBy(targetUID) {
		return true, nil
	}
	if !viewerSnap.BlockedByOverflow {
		return false, nil
	}
	targetSnap, err := s.Snapshot(ctx, targetUID)
	if err != nil {
		return false, err
	}
	return targetSnap.isBlocked(viewerUID), nil
}

// Followed implements FollowEvents as the default no-op; Deps.Events replaces it (ADR-0008 D11, ADR-0017 D2).
func (s *service) Followed(context.Context, string, string, time.Time) {}

// FollowRequested and FollowRequestAccepted implement FollowEvents as default no-ops (ADR-0025 D10); Deps.Events
// replaces them and W3-27 / W3-28a call them.
func (s *service) FollowRequested(context.Context, string, string, time.Time)       {}
func (s *service) FollowRequestAccepted(context.Context, string, string, time.Time) {}

// isNewAccount reports whether p was created within s.newAccountWindow of now (ADR-0008 D7 new-account quotas).
func (s *service) isNewAccount(p identity.Profile, now time.Time) bool {
	if p.CreatedAt.IsZero() {
		return false
	}
	return now.Sub(p.CreatedAt) < s.newAccountWindow
}

func (s *service) followsLimit(newAccount bool) int64 {
	if newAccount {
		return s.newAccountFollowsPerDay
	}
	return s.followsPerDay
}

func notFoundErr() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "user not found")
}

func targetBlockedErr() error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED, "you have blocked this account; unblock first")
}

func limitReachedErr(limit string) error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit reached").WithMeta("limit", limit)
}

// contentionErr is the retryable answer for a write that kept losing lock races (D1): UNAVAILABLE, never
// INTERNAL, so clients and the SLO alert treat it as transient.
func contentionErr() error {
	return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
		WithRetryAfter(time.Second)
}

// internalErr is the one place a mutation's unexpected repo error is shaped: lost lock races become the
// retryable contentionErr; anything else is wrapped with the raw uids redacted (security review L4), because
// mw.ErrorMapping logs the whole cause chain at ERROR and Firestore's own error text embeds document paths.
func (s *service) internalErr(op string, err error, uids ...string) error {
	if errors.Is(err, ErrContention) || store.IsContention(err) {
		return contentionErr()
	}
	// A client disconnect or deadline is not a server fault: no INTERNAL, no ERROR line (S4).
	switch {
	case errors.Is(err, context.Canceled) || status.Code(err) == codes.Canceled:
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	}
	return logger.RedactErr(fmt.Errorf("graph: %s: %w", op, err), uids...)
}

func selfActionErr(field string) error {
	return apierr.Validation(field, "cannot target yourself")
}

var _ Eraser = (*service)(nil)

// PurgeUser implements Eraser by delegating to the repo (ADR-0008 D10); the local cache entry for uid is
// dropped so this instance stops serving the purged graph.
func (s *service) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	logger.SetRequestField(ctx, fieldOp, "purge")
	next, done, err := s.repo.PurgeUser(ctx, uid, cp)
	s.cache.Invalidate(uid)
	return next, done, err
}
