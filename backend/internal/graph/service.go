package graph

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
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

	Eraser

	// ListEdges returns one page of follow edges, newest first (ADR-0008 T10). <= q.Limit reads.
	ListEdges(ctx context.Context, q EdgeQuery) ([]Edge, error)
}

// Deps are service's constructor dependencies (ADR-0008 T5).
type Deps struct {
	Repo  Repo
	Cache *Cache
	Flags FlagChecker
	// CursorKey signs opaque page tokens (config.CursorHMACKey, ADR-0003).
	CursorKey []byte

	FollowsPerDay           int64
	NewAccountFollowsPerDay int64
	BlocksPerDay            int64
	NewAccountBlocksPerDay  int64
	NewAccountWindow        time.Duration
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

	followsPerDay           int64
	newAccountFollowsPerDay int64
	blocksPerDay            int64
	newAccountBlocksPerDay  int64
	newAccountWindow        time.Duration
}

// New builds the graph Service. Call SetDirectory once identity.Directory is available.
func New(d Deps) *service {
	return &service{
		repo:                    d.Repo,
		cache:                   d.Cache,
		flags:                   d.Flags,
		cursorKey:               d.CursorKey,
		now:                     time.Now,
		followsPerDay:           d.FollowsPerDay,
		newAccountFollowsPerDay: d.NewAccountFollowsPerDay,
		blocksPerDay:            d.BlocksPerDay,
		newAccountBlocksPerDay:  d.NewAccountBlocksPerDay,
		newAccountWindow:        d.NewAccountWindow,
	}
}

// SetDirectory wires identity.Directory after construction (see service's doc comment).
func (s *service) SetDirectory(d identity.Directory) {
	s.directory = d
}

var _ Service = (*service)(nil)
var _ Reader = (*service)(nil)
var _ FollowEvents = (*service)(nil)
var _ identity.BlockChecker = (*service)(nil)

// Snapshot implements Reader: cache-first read of graph/{uid}, 60s TTL (ADR-0008 D8). 1 read on a miss, 0 on
// a hit.
func (s *service) Snapshot(ctx context.Context, uid string) (Snapshot, error) {
	if snap, ok := s.cache.Get(uid); ok {
		return snap, nil
	}
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

// Followed implements FollowEvents: a no-op until the notifications plan (ADR-0008 D11).
func (s *service) Followed(context.Context, string, string, time.Time) {}

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

func featureDisabledErr() error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "this feature is not available yet")
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

func selfActionErr(field string) error {
	return apierr.Validation(field, "cannot target yourself")
}

var _ Eraser = (*service)(nil)

// PurgeUser implements Eraser by delegating to the repo (ADR-0008 D10); the local cache entry for uid is
// dropped so this instance stops serving the purged graph.
func (s *service) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	next, done, err := s.repo.PurgeUser(ctx, uid, cp)
	s.cache.Invalidate(uid)
	return next, done, err
}
