package beacons

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
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
	params := RequestParams{
		UID: uid, BeaconID: beaconID, IdemKey: idempotency.Key(uid, rpcRequestToJoin, key), RequestHash: requestHash(beaconID, n),
		Note: n, MaxPending: s.d.Limits.MaxPendingRequests, Now: now,
	}
	if n == "" && s.quickJoinOn(uid) {
		// After the idempotency lookup and the state checks, so a same-key retry of a committed one-tap join replays
		// its answer even if the organiser has since unfollowed, and a full or already-requested beacon keeps its reason.
		params.Precheck = s.noteGate(a.beacon.OrganiserID, uid)
	}
	res, err := s.d.Repo.Request(ctx, params)
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
		params.Precheck = func(ctx context.Context, tx *firestore.Transaction, cid string) error {
			return logger.RedactErr(s.acceptable(ctx, tx, cid, uid, targetUID), cid, uid, targetUID)
		}
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

// acceptable reads every mutable eligibility record in the participation transaction.
func (s *service) acceptable(ctx context.Context, tx *firestore.Transaction, cid, organiser, target string) error {
	if s.d.TxProfiles == nil || s.d.TxGraph == nil {
		return errors.New("beacons: missing transactional eligibility readers")
	}
	profile, err := s.d.TxProfiles.ProfileInTx(ctx, tx, target)
	if errors.Is(err, identity.ErrNotFound) {
		return ErrNotRequested
	}
	if err != nil {
		return err
	}
	if profile.Status != identity.AccountStatusActive {
		return ErrNotRequested
	}
	snap, err := s.d.TxGraph.SnapshotInTx(ctx, tx, organiser)
	if err != nil {
		return err
	}
	if snap.Blocked[target] || snap.BlockedBy[target] {
		return ErrNotRequested
	}
	if snap.BlockedByOverflow {
		peer, err := s.d.TxGraph.SnapshotInTx(ctx, tx, target)
		if err != nil {
			return err
		}
		if peer.Blocked[organiser] {
			return ErrNotRequested
		}
	}
	if cid == "" {
		return nil
	}
	if err := GuardCommunities(ctx, s.d.CommunityFlags, target, false); err != nil {
		return err
	}
	if s.d.TxCommunities == nil {
		return ErrNotRequested
	}
	c, err := s.d.TxCommunities.GetInTx(ctx, tx, cid)
	if errors.Is(err, communities.ErrNotFound) {
		return ErrNotRequested
	}
	if err != nil {
		return err
	}
	if c.Status == communities.StatusSuspended {
		return ErrNotRequested
	}
	if c.Status == communities.StatusArchived {
		return communities.StateConflict(communities.StateArchived)
	}
	if c.RoleOf(target) != communities.RoleNone {
		return nil
	}
	member, err := s.d.TxCommunities.MemberInTx(ctx, tx, cid, target)
	if err != nil {
		return err
	}
	if member != communities.MemberJoined {
		return ErrNotRequested
	}
	return nil
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
