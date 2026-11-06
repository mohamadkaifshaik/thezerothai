package beacons

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// encodeToken seals (at, id) as a page token bound to binding.
func (s *service) encodeToken(binding string, at time.Time, id string) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: at, DocID: tokenVersion + ":" + id}, s.now())
}

// decodeToken opens a token to (at, id); valid reports whether id is well formed. An empty token is the first page.
func (s *service) decodeToken(binding, token string, valid func(string) bool) (time.Time, string, error) {
	if token == "" {
		return time.Time{}, "", nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return time.Time{}, "", errPageToken()
	}
	v, id, ok := strings.Cut(cur.DocID, ":")
	if !ok || v != tokenVersion || !valid(id) {
		return time.Time{}, "", errPageToken()
	}
	return cur.CreatedAt, id, nil
}

// rolesFor maps the MyBeaconsRole filter to the stored roles (nil = every role).
func rolesFor(role string) ([]string, string, error) {
	switch role {
	case "":
		return nil, "all", nil
	case RoleOrganiser:
		return []string{RoleOrganiser}, RoleOrganiser, nil
	case RoleParticipant:
		return []string{RoleParticipant, RoleRequester}, RoleParticipant, nil
	}
	return nil, "", apierr.Validation("role", "role must be ALL, ORGANISER or PARTICIPANT")
}

// ListMyBeacons implements Service (the proto doc comment is the contract). Order of the work: the role filter and the
// token (pure), one query of page_size + 1 membership rows (the extra row decides next_page_token, from the raw rows),
// one GetAll of their beacons (a missing one is a dangling row after an erasure, R3, dropped; a hidden one is dropped
// unless the caller organises it), one batched profile read of the organisers (a missing or non-ACTIVE organiser drops
// the row), then the views with the caller's state from each membership row.
func (s *service) ListMyBeacons(ctx context.Context, uid string, in MyBeaconsInput) (Page, error) {
	begin(ctx, "mine")
	roles, roleKey, err := rolesFor(in.Role)
	if err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", err)
	}
	if err := s.sealed(); err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", err)
	}
	window := "upcoming"
	if in.Past {
		window = "past"
	}
	binding := "beacons|mine|" + uid + "|" + roleKey + "|" + window
	afterEnd, afterID, err := s.decodeToken(binding, in.PageToken, ids.ValidPostID)
	if err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", err)
	}
	now := s.now()
	size := limits.ClampPageSize(in.Limit)
	rows, err := s.d.Repo.ListMemberships(ctx, MembershipQuery{UID: uid, Roles: roles, Past: in.Past, Now: now, AfterEndAt: afterEnd, AfterID: afterID, Limit: size + 1})
	if err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", err)
	}
	var out Page
	if len(rows) > size {
		rows = rows[:size]
		out.NextPageToken = s.encodeToken(binding, rows[size-1].EndAt, rows[size-1].BeaconID)
	}
	if len(rows) == 0 {
		return out, nil
	}
	beaconIDs := make([]string, 0, len(rows))
	for _, m := range rows {
		beaconIDs = append(beaconIDs, m.BeaconID)
	}
	beacons, err := s.d.Repo.GetBeacons(ctx, beaconIDs)
	if err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", err)
	}
	organisers := make([]string, 0, len(rows))
	seen := map[string]bool{}
	dropped := 0
	for _, m := range rows {
		b, ok := beacons[m.BeaconID]
		if !ok || (b.Hidden && b.OrganiserID != uid) {
			dropped++
			continue
		}
		if !seen[b.OrganiserID] {
			seen[b.OrganiserID] = true
			organisers = append(organisers, b.OrganiserID)
		}
	}
	logger.SetRequestField(ctx, "rows_dropped_gone", dropped)
	if len(organisers) == 0 {
		return out, nil
	}
	profs, err := s.d.Directory.GetProfiles(ctx, organisers)
	if err != nil {
		return Page{}, mapErr(ctx, "mine", uid, "", logger.RedactErr(fmt.Errorf("beacons: load organiser profiles: %w", err), organisers...))
	}
	for _, m := range rows {
		b, ok := beacons[m.BeaconID]
		if !ok || (b.Hidden && b.OrganiserID != uid) {
			continue
		}
		p, ok := profs[b.OrganiserID]
		if !ok || p.Status != identity.AccountStatusActive {
			continue
		}
		pstate := m.State
		if m.Role == RoleOrganiser {
			pstate = ""
		}
		out.Views = append(out.Views, s.viewWith(b, p, uid, pstate))
	}
	return out, nil
}

// ListParticipants implements Service. Visibility first (resolve), then who may list what: REQUESTED rows are the
// organiser's (FORBIDDEN not_organiser); ACCEPTED rows are visible to the organiser and to ACCEPTED participants (one
// point read; anyone else is the one NOT_FOUND). One query of page_size + 1 rows, one batched profile read (a missing
// or non-ACTIVE user drops the row), notes only on REQUESTED rows.
func (s *service) ListParticipants(ctx context.Context, viewer string, in ListParticipantsInput) (ParticipantsPage, error) {
	begin(ctx, "participants")
	if err := validateBeaconID(in.BeaconID); err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
	}
	a, err := s.resolve(ctx, viewer, in.BeaconID)
	if err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
	}
	state, filter := PStateAccepted, "accepted"
	switch {
	case in.Requested && !a.isOrganiser:
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, ErrNotOrganiser)
	case in.Requested:
		state, filter = PStateRequested, "requested"
	case !a.isOrganiser:
		p, err := s.d.Repo.GetParticipant(ctx, in.BeaconID, viewer)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
		}
		if err != nil || p.State != PStateAccepted {
			return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, ErrNotFound)
		}
	}
	if err := s.sealed(); err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
	}
	binding := "beacons|participants|" + viewer + "|" + in.BeaconID + "|" + filter
	afterAt, afterUID, err := s.decodeToken(binding, in.PageToken, ids.ValidUID)
	if err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
	}
	size := limits.ClampPageSize(in.Limit)
	rows, err := s.d.Repo.ListParticipants(ctx, ParticipantQuery{BeaconID: in.BeaconID, State: state, AfterAt: afterAt, AfterUID: afterUID, Limit: size + 1})
	if err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, err)
	}
	var out ParticipantsPage
	if len(rows) > size {
		rows = rows[:size]
		last := rows[size-1]
		at := last.RequestedAt
		if state == PStateAccepted {
			at = last.RespondedAt
		}
		out.NextPageToken = s.encodeToken(binding, at, last.UID)
	}
	if len(rows) == 0 {
		return out, nil
	}
	uids := make([]string, 0, len(rows))
	for _, p := range rows {
		uids = append(uids, p.UID)
	}
	profs, err := s.d.Directory.GetProfiles(ctx, uids)
	if err != nil {
		return ParticipantsPage{}, mapErr(ctx, "participants", viewer, in.BeaconID, logger.RedactErr(fmt.Errorf("beacons: load participant profiles: %w", err), uids...))
	}
	dropped := 0
	for _, p := range rows {
		prof, ok := profs[p.UID]
		if !ok || prof.Status != identity.AccountStatusActive {
			dropped++
			continue
		}
		if !in.Requested {
			p.Note = ""
		}
		out.Rows = append(out.Rows, ParticipantRow{Participant: p, User: prof})
	}
	logger.SetRequestField(ctx, "rows_dropped_gone", dropped)
	return out, nil
}
