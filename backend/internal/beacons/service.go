package beacons

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields: counts and enums only, never a beacon id, title or venue.
const (
	fieldOp      = "beacon_op"
	fieldOutcome = "outcome"

	outcomeDone       = "done"
	outcomeReplay     = "replay"
	outcomeNoop       = "noop"
	outcomeNotFound   = "rejected:not_found"
	outcomeContention = "contention"

	// LIMIT_REACHED metadata["limit"] values (beacons.proto header).
	limitOpen         = "beacons_open"
	limitParticipants = "beacon_participants"
	limitPending      = "beacon_requests_pending"

	// notFoundText is the one message of every NOT_FOUND this module answers (byte-identical for every cause).
	notFoundText = "beacon not found"
)

type service struct {
	d   Deps
	now func() time.Time
}

// New builds the beacons service. It never touches Firestore itself; the flag gate is the handler's (Guard), before this
// runs.
func New(d Deps) Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &service{d: d, now: now}
}

var _ Service = (*service)(nil)

func notFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, notFoundText)
}

// forbidden is PERMISSION_DENIED + FORBIDDEN with metadata["reason"] = reason (not_organiser, not_member, blocked). The
// message is fixed and generic: the client branches on the reason.
func forbidden(reason string) *apierr.Error {
	return apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "you cannot do that with this beacon").
		WithMeta("reason", reason)
}

// stateConflict is FAILED_PRECONDITION with metadata["reason"] = reason (ended, cancelled, full, ...).
func stateConflict(reason string) *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "the beacon state does not allow that").
		WithMeta("reason", reason)
}

func limitReached(limit, message string) *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, message).WithMeta("limit", limit)
}

// canonical request bodies for IDEMPOTENCY_KEY_REUSED: every field as sent, an unset optional distinct from its zero value.
func optString(s *string) string {
	if s == nil {
		return "unset"
	}
	return strconv.Quote(*s)
}

func optInt(n *int) string {
	if n == nil {
		return "unset"
	}
	return strconv.Itoa(*n)
}

func createHash(b Beacon) string {
	return idempotency.HashRequest(fmt.Sprintf("community=%s|activity=%s|title=%q|details=%q|venue=%q|start=%d|duration=%d|spots=%d|cost=%s|chat=%s",
		b.CommunityID, b.Activity, b.Title, b.Details, b.Venue, b.StartAt.UnixMicro(), b.DurationMin, b.OpenSpots, b.Cost, b.ChatPref))
}

func updateHash(beaconID string, title, details, venue *string, spots *int) string {
	return idempotency.HashRequest(fmt.Sprintf("beacon_id=%s|title=%s|details=%s|venue=%s|open_spots=%s", beaconID, optString(title), optString(details), optString(venue), optInt(spots)))
}

func cancelHash(beaconID string) string { return idempotency.HashRequest("beacon_id=" + beaconID) }

// profile is the caller's live row, cache-first (the account-status interceptor has just loaded it).
func (s *service) profile(ctx context.Context, uid string) (identity.Profile, error) {
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return identity.Profile{}, logger.RedactErr(fmt.Errorf("beacons: load profile: %w", err), uid)
	}
	p, ok := profiles[uid]
	if !ok {
		return identity.Profile{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
	}
	return p, nil
}

// social is uid's cached social context; a nil Graph is an empty one (unit wirings).
func (s *service) social(ctx context.Context, uid string) (graph.Snapshot, error) {
	if s.d.Graph == nil {
		return graph.Snapshot{}, nil
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return graph.Snapshot{}, logger.RedactErr(fmt.Errorf("beacons: load graph: %w", err), uid)
	}
	return snap, nil
}

// requireMember is the community-audience gate: FEATURE_COMMUNITIES (on for the caller when mustBeOn, else not globally
// off), then the caller's role must be owner, moderator or member; none, banned, a missing community or a nil reader is
// ErrNotMember (fail closed).
func (s *service) requireMember(ctx context.Context, uid, communityID string, mustBeOn bool) error {
	if err := GuardCommunities(ctx, s.d.CommunityFlags, uid, mustBeOn); err != nil {
		return err
	}
	if s.d.Communities == nil {
		return ErrNotMember
	}
	role, err := s.d.Communities.Role(ctx, communityID, uid)
	if err != nil {
		if errors.Is(err, communities.ErrNotFound) {
			return ErrNotMember
		}
		return logger.RedactErr(fmt.Errorf("beacons: community role: %w", err), uid, communityID)
	}
	switch role {
	case communities.RoleOwner, communities.RoleModerator, communities.RoleMember:
		return nil
	}
	return ErrNotMember
}

// begin records the op on the request line.
func begin(ctx context.Context, op string) {
	logger.SetRequestField(ctx, fieldOp, op)
}

func noteOutcome(ctx context.Context, o Outcome) {
	switch o {
	case Written:
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	case Replayed:
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	default:
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
}

// mapErr turns a repository or rule error into the handler's answer. Known sentinels and already shaped apierrs pass
// through; a client that left is CANCELED / DEADLINE_EXCEEDED; contention is a retryable UNAVAILABLE logged at WARN;
// anything else is a redacted internal error. The uid and beacon id are redacted from the chain.
func mapErr(ctx context.Context, op, uid, beaconID string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return notFound()
	case errors.Is(err, ErrOpenLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitOpen)
		return limitReached(limitOpen, "open beacon limit reached")
	case errors.Is(err, ErrSpotsLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitParticipants)
		return limitReached(limitParticipants, "open_spots is above the limit")
	case errors.Is(err, ErrNotOrganiser):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_organiser")
		return forbidden("not_organiser")
	case errors.Is(err, ErrNotMember):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_member")
		return forbidden("not_member")
	case errors.Is(err, ErrEnded):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:ended")
		return stateConflict("ended")
	case errors.Is(err, ErrCancelled):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:cancelled")
		return stateConflict("cancelled")
	case errors.Is(err, ErrFull):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:full")
		return stateConflict("full")
	case errors.Is(err, ErrAlreadyRequested):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:already_requested")
		return stateConflict("already_requested")
	case errors.Is(err, ErrNotRequested):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_requested")
		return stateConflict("not_requested")
	case errors.Is(err, ErrNotParticipant):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_participant")
		return stateConflict("not_participant")
	case errors.Is(err, ErrOrganiser):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:organiser")
		return stateConflict("organiser")
	case errors.Is(err, ErrPendingLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitPending)
		return limitReached(limitPending, "pending request limit reached")
	case errors.Is(err, ErrKeyReused):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:key_reused")
		return apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	case errors.As(err, &ae):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:"+ae.Code.String())
		return err
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldOutcome, outcomeContention)
		slog.WarnContext(ctx, "beacons_contention", fieldOp, op, "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("beacons: %s: %w", op, err), uid, beaconID)
}

// viewerState is the caller's relationship with b at now, from their participant row state ("" when there is none):
// the organiser manages a live beacon; an ACCEPTED participant may leave while it is live; a REQUESTED caller may
// withdraw while it is live; anyone else may request while it is OPEN.
func viewerState(b Beacon, viewer, pstate string, now time.Time) ViewerState {
	st := b.EffectiveStatus(now)
	live := st == StatusOpen || st == StatusFull
	if b.OrganiserID == viewer {
		return ViewerState{Role: RoleOrganiser, CanManage: live}
	}
	vs := ViewerState{Role: RoleNone, ParticipantState: pstate}
	switch pstate {
	case PStateAccepted:
		vs.Role, vs.CanLeave = RoleParticipant, live
	case PStateRequested:
		vs.CanWithdraw = true // a stale request on an ended or cancelled beacon can always be cleared
	default:
		vs.CanRequest = st == StatusOpen
	}
	return vs
}

// view renders b for viewer with no participant row (the organiser's own views).
func (s *service) view(b Beacon, organiser identity.Profile, viewer string) View {
	return s.viewWith(b, organiser, viewer, "")
}

// viewWith renders b for viewer: the effective status and the viewer state from pstate.
func (s *service) viewWith(b Beacon, organiser identity.Profile, viewer, pstate string) View {
	now := s.now()
	b.Status = b.EffectiveStatus(now)
	return View{Beacon: b, Organiser: organiser, Viewer: viewerState(b, viewer, pstate, now)}
}

// normalizeCreate applies every field rule of CreateBeacon in order (0 reads) and returns the beacon to store.
func (s *service) normalizeCreate(uid string, in CreateInput, now time.Time) (Beacon, error) {
	if err := validateKey(in.Key); err != nil {
		return Beacon{}, err
	}
	if err := validateAudience(in.CommunityID, in.Public); err != nil {
		return Beacon{}, err
	}
	if in.Activity == "" {
		return Beacon{}, apierr.Validation("activity", "activity must be set")
	}
	title, err := validateTitle(in.Title)
	if err != nil {
		return Beacon{}, err
	}
	details, err := validateDetails(in.Details)
	if err != nil {
		return Beacon{}, err
	}
	venue, err := validateVenue(in.Venue)
	if err != nil {
		return Beacon{}, err
	}
	if err := validateStart(in.StartAt, now); err != nil {
		return Beacon{}, err
	}
	if err := validateDuration(in.DurationMin); err != nil {
		return Beacon{}, err
	}
	if err := validateOpenSpots(in.OpenSpots, s.d.Limits.MaxOpenSpots); err != nil {
		return Beacon{}, err
	}
	if in.Cost == "" {
		return Beacon{}, apierr.Validation("cost", "cost must be set")
	}
	if in.ChatPref == "" {
		return Beacon{}, apierr.Validation("chat_preference", "chat_preference must be set")
	}
	start := in.StartAt.UTC()
	return Beacon{
		OrganiserID: uid, CommunityID: in.CommunityID, Activity: in.Activity, Title: title, Details: details, Venue: venue,
		StartAt: start, EndAt: start.Add(time.Duration(in.DurationMin) * time.Minute), DurationMin: in.DurationMin,
		OpenSpots: in.OpenSpots, Cost: in.Cost, ChatPref: in.ChatPref,
	}, nil
}

// CreateBeacon implements Service. Validation first (no reads), the community gate for a community audience (flag, then
// role), the caller's profile (cache-first; it is the response's organiser row), then one repository transaction.
func (s *service) CreateBeacon(ctx context.Context, uid string, in CreateInput) (View, error) {
	begin(ctx, "create")
	b, err := s.normalizeCreate(uid, in, s.now())
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	if b.CommunityID != "" {
		if err := s.requireMember(ctx, uid, b.CommunityID, true); err != nil {
			return View{}, mapErr(ctx, "create", uid, "", err)
		}
	}
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	res, err := s.d.Repo.Create(ctx, CreateParams{
		UID: uid, ID: s.d.IDs.Generate(), IdemKey: idempotency.Key(uid, rpcCreateBeacon, in.Key), RequestHash: createHash(b),
		Beacon: b, MaxOpenPerUser: s.d.Limits.MaxOpenPerUser,
	})
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	noteOutcome(ctx, res.Outcome)
	return s.view(res.Beacon, prof, uid), nil
}

// organised proves uid may see the beacon (resolve) and organises it; any other organiser is ErrNotOrganiser.
func (s *service) organised(ctx context.Context, uid, beaconID string) (access, error) {
	a, err := s.resolve(ctx, uid, beaconID)
	if err != nil {
		return access{}, err
	}
	if !a.isOrganiser {
		return access{}, ErrNotOrganiser
	}
	return a, nil
}

// UpdateBeacon implements Service: validation (0 reads), visibility and organiser (resolve), then one transaction.
func (s *service) UpdateBeacon(ctx context.Context, uid string, in UpdateInput) (View, error) {
	begin(ctx, "update")
	if err := validateKey(in.Key); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
	}
	if err := validateBeaconID(in.BeaconID); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
	}
	var title, details, venue *string
	if in.Title != nil {
		t, err := validateTitle(*in.Title)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
		}
		title = &t
	}
	if in.Details != nil {
		d, err := validateDetails(*in.Details)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
		}
		details = &d
	}
	if in.Venue != nil {
		v, err := validateVenue(*in.Venue)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
		}
		venue = &v
	}
	if in.OpenSpots != nil {
		if err := validateOpenSpots(*in.OpenSpots, s.d.Limits.MaxOpenSpots); err != nil {
			return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
		}
	}
	a, err := s.organised(ctx, uid, in.BeaconID)
	if err != nil {
		return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
	}
	res, err := s.d.Repo.Update(ctx, UpdateParams{
		UID: uid, BeaconID: in.BeaconID, IdemKey: idempotency.Key(uid, rpcUpdateBeacon, in.Key),
		RequestHash: updateHash(in.BeaconID, title, details, venue, in.OpenSpots),
		Title:       title, Details: details, Venue: venue, OpenSpots: in.OpenSpots, Now: s.now(),
	})
	if err != nil {
		return View{}, mapErr(ctx, "update", uid, in.BeaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	return s.view(res.Beacon, a.organiser, uid), nil
}
