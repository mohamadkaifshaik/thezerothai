package beacons

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The participation RPCs. Each validates its fields (0 reads), then runs one repository transaction and maps its
// verdict. Request and the organiser-only ones (Respond, Remove: organised) first prove the caller may see the beacon
// (resolve: NOT_FOUND for hidden, blocked or missing; FORBIDDEN not_member for a community the caller left). Withdraw and
// Leave are the way out and are always allowed (proto): their only gate is the caller's own participant row, read in
// the repository's transaction (no row is the one NOT_FOUND), so a block, a hide or a lost membership never traps a
// caller in a plan.

func requestHash(beaconID, note string) string {
	return idempotency.HashRequest("beacon_id=" + beaconID + "|note=" + strconv.Quote(note))
}

func stateHash(beaconID, target string) string {
	return idempotency.HashRequest("beacon_id=" + beaconID + "|user_id=" + target)
}

func respondHash(beaconID, target string, accept bool) string {
	return idempotency.HashRequest(fmt.Sprintf("beacon_id=%s|user_id=%s|accept=%v", beaconID, target, accept))
}

// RequestToJoin implements Service.
func (s *service) RequestToJoin(ctx context.Context, uid, key, beaconID, note string) (ViewerState, error) {
	begin(ctx, "request")
	if err := validateKey(key); err != nil {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, err)
	}
	if err := validateBeaconID(beaconID); err != nil {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, err)
	}
	n, err := validateNote(note)
	if err != nil {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, err)
	}
	a, err := s.resolveFor(ctx, uid, beaconID, true)
	if err != nil {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, err)
	}
	if a.isOrganiser {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, ErrOrganiser)
	}
	now := s.now()
	res, err := s.d.Repo.Request(ctx, RequestParams{
		UID: uid, BeaconID: beaconID, IdemKey: idempotency.Key(uid, rpcRequestToJoin, key), RequestHash: requestHash(beaconID, n),
		Note: n, MaxPending: s.d.Limits.MaxPendingRequests, Now: now,
	})
	if err != nil {
		return ViewerState{}, mapErr(ctx, "request", uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if s.d.Events != nil && res.Outcome == Written {
		s.d.Events.JoinRequested(ctx, ParticipationEvent{BeaconID: beaconID, OrganiserUID: res.Beacon.OrganiserID, ParticipantUID: uid, At: now})
	}
	return viewerState(res.Beacon, uid, res.Participant.State, now), nil
}

// selfTransition is the shared body of WithdrawJoinRequest and LeaveBeacon: the caller acts on their own row only. No
// visibility check (no beacon, graph, community or profile read here): the repository transaction needs the beacon and
// the caller's row and answers ErrNotFound when either is missing, so the answer never says more than the caller's own
// row already does. Nothing of the beacon is returned.
func (s *service) selfTransition(ctx context.Context, op, rpc, uid, key, beaconID string, run func(context.Context, StateParams) (ParticipantResult, error)) error {
	begin(ctx, op)
	if err := validateKey(key); err != nil {
		return mapErr(ctx, op, uid, beaconID, err)
	}
	if err := validateBeaconID(beaconID); err != nil {
		return mapErr(ctx, op, uid, beaconID, err)
	}
	res, err := run(ctx, StateParams{
		UID: uid, BeaconID: beaconID, TargetUID: uid, IdemKey: idempotency.Key(uid, rpc, key), RequestHash: stateHash(beaconID, uid), Now: s.now(),
	})
	if err != nil {
		return mapErr(ctx, op, uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	return nil
}

// WithdrawJoinRequest implements Service.
func (s *service) WithdrawJoinRequest(ctx context.Context, uid, key, beaconID string) error {
	return s.selfTransition(ctx, "withdraw", rpcWithdrawJoinRequest, uid, key, beaconID, s.d.Repo.Withdraw)
}

// LeaveBeacon implements Service.
func (s *service) LeaveBeacon(ctx context.Context, uid, key, beaconID string) error {
	return s.selfTransition(ctx, "leave", rpcLeaveBeacon, uid, key, beaconID, s.d.Repo.Leave)
}

// organiserAction is the shared front of RespondToJoinRequest and RemoveParticipant: fields, then visibility and the
// organiser check.
func (s *service) organiserAction(ctx context.Context, op, uid, key, beaconID, target string) (access, error) {
	begin(ctx, op)
	if err := validateKey(key); err != nil {
		return access{}, err
	}
	if err := validateBeaconID(beaconID); err != nil {
		return access{}, err
	}
	if err := validateUserID(target); err != nil {
		return access{}, err
	}
	return s.organised(ctx, uid, beaconID)
}

// RespondToJoinRequest implements Service.
func (s *service) RespondToJoinRequest(ctx context.Context, uid, key, beaconID, targetUID string, accept bool) (View, error) {
	a, err := s.organiserAction(ctx, "respond", uid, key, beaconID, targetUID)
	if err != nil {
		return View{}, mapErr(ctx, "respond", uid, beaconID, err)
	}
	now := s.now()
	params := RespondParams{
		UID: uid, BeaconID: beaconID, TargetUID: targetUID, IdemKey: idempotency.Key(uid, rpcRespondToJoinRequest, key),
		RequestHash: respondHash(beaconID, targetUID, accept), Accept: accept, Now: now,
	}
	if accept {
		// After the idempotency lookup, so a same-key retry of a committed ACCEPT replays its answer.
		params.Precheck = func(ctx context.Context) error { return s.acceptable(ctx, a, uid, targetUID) }
	}
	res, err := s.d.Repo.Respond(ctx, params)
	if err != nil {
		return View{}, mapErr(ctx, "respond", uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if s.d.Events != nil && accept && res.Outcome == Written {
		s.d.Events.RequestAccepted(ctx, ParticipationEvent{BeaconID: beaconID, OrganiserUID: uid, ParticipantUID: targetUID, At: now})
	}
	return s.view(res.Beacon, a.organiser, uid), nil
}

// acceptable is the ACCEPT recheck of the target, run by Repo.Respond after its idempotency lookup missed (a replay
// keeps its stored answer) and before any write: an ACTIVE profile (cached), no block either way with
// the organiser (the organiser's graph, overflow-aware) and, for a community beacon, the target's community verdict
// for a write (JOINED, community not suspended). An ineligible target is not_requested, the same answer as a request
// that is no longer there; ARCHIVED is COMMUNITY_STATE community_archived; a failed read is returned (nothing written).
// DECLINE and REMOVE never run it.
func (s *service) acceptable(ctx context.Context, a access, organiser, target string) error {
	profs, err := s.d.Directory.GetProfiles(ctx, []string{target})
	if err != nil {
		return logger.RedactErr(fmt.Errorf("beacons: load target profile: %w", err), organiser, target)
	}
	if p, ok := profs[target]; !ok || p.Status != identity.AccountStatusActive {
		return ErrNotRequested
	}
	bc, err := s.blocks(ctx, organiser)
	if err != nil {
		return err
	}
	blocked, err := bc.blocked(ctx, target)
	if err != nil {
		return err
	}
	if blocked {
		return ErrNotRequested
	}
	if a.beacon.CommunityID == "" {
		return nil
	}
	err = s.requireMember(ctx, target, a.beacon.CommunityID, false, true)
	if errors.Is(err, ErrNotMember) || errors.Is(err, ErrNotFound) {
		return ErrNotRequested
	}
	return err
}

// RemoveParticipant implements Service.
func (s *service) RemoveParticipant(ctx context.Context, uid, key, beaconID, targetUID string) (View, error) {
	a, err := s.organiserAction(ctx, "remove", uid, key, beaconID, targetUID)
	if err != nil {
		return View{}, mapErr(ctx, "remove", uid, beaconID, err)
	}
	res, err := s.d.Repo.Remove(ctx, StateParams{
		UID: uid, BeaconID: beaconID, TargetUID: targetUID, IdemKey: idempotency.Key(uid, rpcRemoveParticipant, key),
		RequestHash: stateHash(beaconID, targetUID), Now: s.now(),
	})
	if err != nil {
		return View{}, mapErr(ctx, "remove", uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	return s.view(res.Beacon, a.organiser, uid), nil
}
