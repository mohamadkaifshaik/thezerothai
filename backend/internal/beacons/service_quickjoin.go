package beacons

import (
	"context"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// One-tap join (FEATURE_BEACON_QUICK_JOIN, owner decisions 2026-11-13): with the flag on for the caller, RequestToJoin
// accepts an empty note only when the organiser follows the caller; everyone else must write one (ErrNoteRequired,
// FAILED_PRECONDITION "note_required"). The follow is the organiser -> caller edge, answered by graph.FollowLookup (the
// follow edge docs, the source of followed_by: the instance's edge cache first, then batched reads), never from graph
// storage directly. A pending follow request is not an edge. Every path asks the same lookup, so the card, the detail
// and the write agree up to the edge cache's staleness bound (<= 60 s behind another instance's follow or unfollow).
// With the flag off the note stays optional and nothing is read.

// fieldQuickJoinLookups is the request-line count of FollowLookup calls (0 or 1 per request).
const fieldQuickJoinLookups = "quick_join_lookups"

// quickJoinOn is FEATURE_BEACON_QUICK_JOIN on for uid; a nil checker is off.
func (s *service) quickJoinOn(uid string) bool {
	return s.d.Flags != nil && s.d.Flags.Enabled(uid, QuickJoinFlagName)
}

// followers answers which of organisers follow viewer, in one FollowLookup call. A nil lookup is nobody.
func (s *service) followers(ctx context.Context, viewer string, organisers []string) (map[string]bool, error) {
	if s.d.Follows == nil || len(organisers) == 0 {
		return map[string]bool{}, nil
	}
	logger.SetRequestField(ctx, fieldQuickJoinLookups, 1)
	out, err := s.d.Follows.FollowersAmong(ctx, viewer, organisers)
	if err != nil {
		return nil, logger.RedactErr(err, append([]string{viewer}, organisers...)...)
	}
	return out, nil
}

// noteGate is the RequestParams.Precheck of an empty-note request under the flag: ErrNoteRequired unless the organiser
// follows uid; a failed read refuses the write (fail closed).
func (s *service) noteGate(organiser, uid string) func(context.Context) error {
	return func(ctx context.Context) error {
		f, err := s.followers(ctx, uid, []string{organiser})
		if err != nil {
			return err
		}
		if !f[organiser] {
			return ErrNoteRequired
		}
		return nil
	}
}

// markQuickJoin sets Viewer.QuickJoinAllowed on every view the viewer may request (can_request, not their own) whose
// organiser follows them, with FEATURE_BEACONS and FEATURE_BEACON_QUICK_JOIN on for the viewer (GetBeacon and the lists
// are read class, so a caller dropped from the beacons allowlist must not be offered a join FEATURE_DISABLED would
// refuse). Cost: no read when a flag is off or no row is requestable; otherwise ONE FollowLookup call for the page's
// distinct requestable organisers (a page holds at most 50 rows: at most 2 batched edge reads, fewer on cache hits).
// The field is advisory (RequestToJoin re-checks), so a failed read leaves every row false with a WARN line.
func (s *service) markQuickJoin(ctx context.Context, viewer string, views []View) {
	if len(views) == 0 || s.d.Flags == nil || !s.d.Flags.Enabled(viewer, FlagName) || !s.quickJoinOn(viewer) {
		return
	}
	seen := map[string]bool{}
	var organisers []string
	for _, v := range views {
		org := v.Beacon.OrganiserID
		if !v.Viewer.CanRequest || org == viewer || seen[org] {
			continue
		}
		seen[org] = true
		organisers = append(organisers, org)
	}
	if len(organisers) == 0 {
		return
	}
	follows, err := s.followers(ctx, viewer, organisers)
	if err != nil {
		slog.WarnContext(ctx, "beacons_quick_join_unknown", fieldOp, "quick_join", "rows", len(views), "err", err.Error())
		return
	}
	for i := range views {
		v := &views[i]
		if v.Viewer.CanRequest && v.Beacon.OrganiserID != viewer && follows[v.Beacon.OrganiserID] {
			v.Viewer.QuickJoinAllowed = true
		}
	}
}
