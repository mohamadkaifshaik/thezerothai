package beacons

import (
	"context"
	"fmt"
	"strconv"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// The participation RPCs. Each validates its fields (0 reads), proves the caller may see the beacon (resolve: NOT_FOUND
// for hidden, blocked or missing; FORBIDDEN not_member for a community the caller left), then runs one repository
// transaction and maps its verdict. The organiser-only ones (Respond, Remove) use organised; the self ones (Request,
// Withdraw, Leave) act on the caller's own row.

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
	a, err := s.resolve(ctx, uid, beaconID)
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

// selfTransition is the shared body of WithdrawJoinRequest and LeaveBeacon: the caller acts on their own row.
func (s *service) selfTransition(ctx context.Context, op, rpc, uid, key, beaconID string, run func(context.Context, StateParams) (ParticipantResult, error)) error {
	begin(ctx, op)
	if err := validateKey(key); err != nil {
		return mapErr(ctx, op, uid, beaconID, err)
	}
	if err := validateBeaconID(beaconID); err != nil {
		return mapErr(ctx, op, uid, beaconID, err)
	}
	if _, err := s.resolve(ctx, uid, beaconID); err != nil {
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
	res, err := s.d.Repo.Respond(ctx, RespondParams{
		UID: uid, BeaconID: beaconID, TargetUID: targetUID, IdemKey: idempotency.Key(uid, rpcRespondToJoinRequest, key),
		RequestHash: respondHash(beaconID, targetUID, accept), Accept: accept, Now: now,
	})
	if err != nil {
		return View{}, mapErr(ctx, "respond", uid, beaconID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if s.d.Events != nil && accept && res.Outcome == Written {
		s.d.Events.RequestAccepted(ctx, ParticipationEvent{BeaconID: beaconID, OrganiserUID: uid, ParticipantUID: targetUID, At: now})
	}
	return s.view(res.Beacon, a.organiser, uid), nil
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
