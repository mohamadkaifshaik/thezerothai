package beacons

import (
	"context"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// One-tap join (FEATURE_BEACON_QUICK_JOIN, owner decision 2026-11-13): with the flag on for the caller, RequestToJoin
// accepts an empty note only when the organiser follows the caller; everyone else must write one (ErrNoteRequired,
// FAILED_PRECONDITION "note_required"). The follow is the organiser -> caller edge, read from the organiser's graph
// snapshot through graph.Reader (cache-first, 60 s; one point read on a miss), never from graph storage. Following only:
// a pending follow request is not a follow. With the flag off the note stays optional.

// quickJoinOn is FEATURE_BEACON_QUICK_JOIN on for uid; a nil checker is off.
func (s *service) quickJoinOn(uid string) bool {
	return s.d.Flags != nil && s.d.Flags.Enabled(uid, QuickJoinFlagName)
}

// organiserFollows answers "does organiser follow viewer" from the organiser's graph snapshot.
func (s *service) organiserFollows(ctx context.Context, organiser, viewer string) (bool, error) {
	snap, err := s.social(ctx, organiser)
	if err != nil {
		return false, err
	}
	return snap.Following[viewer], nil
}

// noteGate is the RequestParams.Precheck of an empty-note request under the flag: ErrNoteRequired unless the organiser
// follows uid; a failed graph read refuses the write (fail closed).
func (s *service) noteGate(organiser, uid string) func(context.Context) error {
	return func(ctx context.Context) error {
		follows, err := s.organiserFollows(ctx, organiser, uid)
		if err != nil {
			return err
		}
		if !follows {
			return ErrNoteRequired
		}
		return nil
	}
}

// quickJoinAllowed is ViewerState.quick_join_allowed for GetBeacon: FEATURE_BEACONS and FEATURE_BEACON_QUICK_JOIN on for
// the viewer (GetBeacon is read class, so a caller dropped from the beacons allowlist must not be offered a join that
// FEATURE_DISABLED would refuse), the viewer may request, and the organiser follows the viewer. The graph read happens
// only when everything else holds. The field is advisory (RequestToJoin re-checks), so a failed read is false with a
// WARN line rather than a failed GetBeacon.
func (s *service) quickJoinAllowed(ctx context.Context, a access, viewer string, vs ViewerState) bool {
	if a.isOrganiser || !vs.CanRequest || s.d.Flags == nil || !s.d.Flags.Enabled(viewer, FlagName) || !s.quickJoinOn(viewer) {
		return false
	}
	follows, err := s.organiserFollows(ctx, a.beacon.OrganiserID, viewer)
	if err != nil {
		slog.WarnContext(ctx, "beacons_quick_join_unknown", fieldOp, "get", "err", logger.RedactErr(err, viewer, a.beacon.OrganiserID).Error())
		return false
	}
	return follows
}
