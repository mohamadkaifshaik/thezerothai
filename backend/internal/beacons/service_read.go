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

const (
	tokenVersion = "v1"
	// Request-line fields of the read side: counts only.
	fieldDroppedHidden  = "rows_dropped_hidden"
	fieldDroppedBlocked = "rows_dropped_blocked"
	fieldDroppedGone    = "rows_dropped_gone"
)

// errPageToken is the one answer for a page token that does not open or whose payload does not parse.
func errPageToken() error { return apierr.Validation("page_token", "page_token is invalid or expired") }

// access is what the visibility check proved for one (viewer, beacon): the beacon as stored, its organiser's live
// profile and, for a non-organiser, the viewer's block check (its graph already loaded).
type access struct {
	beacon      Beacon
	organiser   identity.Profile
	isOrganiser bool
	blocks      *blockCheck
}

// resolve is resolveFor a read.
func (s *service) resolve(ctx context.Context, viewer, beaconID string) (access, error) {
	return s.resolveFor(ctx, viewer, beaconID, false)
}

// resolveFor applies the visibility rules once for every read and participation or organiser write. Order, cheapest
// first, each refusal the same ErrNotFound unless noted: the beacon (1 read); a hidden beacon to anyone but its
// organiser; a block in either direction (viewer graph, cached; past an overflowed blockedBy also the organiser's own
// graph, fail closed; before the membership check, R15, so a blocked viewer never learns the beacon exists); a
// community audience needs the community verdict (requireMember: JOINED, ErrNotMember; SUSPENDED is ErrNotFound;
// write refuses ARCHIVED; FEATURE_COMMUNITIES not globally off), except for the organiser, who can always manage their
// own beacon (a beacon must stay cancellable after the organiser leaves the community or it is suspended); an organiser
// who is missing or not ACTIVE (profile, cached).
func (s *service) resolveFor(ctx context.Context, viewer, beaconID string, write bool) (access, error) {
	if !ids.ValidPostID(beaconID) {
		return access{}, ErrNotFound
	}
	b, err := s.d.Repo.Get(ctx, beaconID)
	if err != nil {
		return access{}, err
	}
	a := access{beacon: b, isOrganiser: b.OrganiserID == viewer}
	if b.Hidden && !a.isOrganiser {
		return access{}, ErrNotFound
	}
	if !a.isOrganiser {
		bc, err := s.blocks(ctx, viewer)
		if err != nil {
			return access{}, err
		}
		blocked, err := bc.blocked(ctx, b.OrganiserID)
		if err != nil {
			return access{}, err
		}
		if blocked {
			return access{}, ErrNotFound
		}
		a.blocks = bc
		if b.CommunityID != "" {
			if err := s.requireMember(ctx, viewer, b.CommunityID, false, write); err != nil {
				return access{}, err
			}
		}
	}
	profs, err := s.d.Directory.GetProfiles(ctx, []string{b.OrganiserID})
	if err != nil {
		return access{}, logger.RedactErr(fmt.Errorf("beacons: load organiser profile: %w", err), viewer, b.OrganiserID)
	}
	op, ok := profs[b.OrganiserID]
	if !ok || op.Status != identity.AccountStatusActive {
		return access{}, ErrNotFound
	}
	a.organiser = op
	return a, nil
}

// visibleRow is the per-row rule of ListBeacons and ListMyBeacons, the same as resolve's: a hidden beacon renders only
// to its organiser; a block in either direction with the organiser (bc, overflow-aware) drops it. cause names the drop
// ("hidden", "blocked"); err is a failed graph read (the page fails closed).
func visibleRow(ctx context.Context, bc *blockCheck, viewer string, b Beacon) (cause string, err error) {
	if b.OrganiserID == viewer {
		return "", nil
	}
	if b.Hidden {
		return "hidden", nil
	}
	blocked, err := bc.blocked(ctx, b.OrganiserID)
	if err != nil {
		return "", err
	}
	if blocked {
		return "blocked", nil
	}
	return "", nil
}

// GetBeacon implements Service.
func (s *service) GetBeacon(ctx context.Context, viewer, beaconID string) (View, error) {
	begin(ctx, "get")
	if err := validateBeaconID(beaconID); err != nil {
		return View{}, mapErr(ctx, "get", viewer, beaconID, err)
	}
	a, err := s.resolve(ctx, viewer, beaconID)
	if err != nil {
		return View{}, mapErr(ctx, "get", viewer, beaconID, err)
	}
	pstate, err := s.participantState(ctx, a, viewer)
	if err != nil {
		return View{}, mapErr(ctx, "get", viewer, beaconID, err)
	}
	return s.viewWith(a.beacon, a.organiser, viewer, pstate), nil
}

// participantState is the viewer's participant row state on a resolved beacon ("" for the organiser or no row): one
// point read for a non-organiser.
func (s *service) participantState(ctx context.Context, a access, viewer string) (string, error) {
	if a.isOrganiser {
		return "", nil
	}
	p, err := s.d.Repo.GetParticipant(ctx, a.beacon.ID, viewer)
	switch {
	case err == nil:
		return p.State, nil
	case errors.Is(err, ErrNotFound):
		return "", nil
	}
	return "", err
}

// participantStates is the viewer's participant row state per beacon id (absent = no row) in one batched read; none
// for an empty page.
func (s *service) participantStates(ctx context.Context, viewer string, beaconIDs []string) (map[string]string, error) {
	out := make(map[string]string, len(beaconIDs))
	if len(beaconIDs) == 0 {
		return out, nil
	}
	rows, err := s.d.Repo.GetParticipants(ctx, viewer, beaconIDs)
	if err != nil {
		return nil, err
	}
	for id, p := range rows {
		out[id] = p.State
	}
	return out, nil
}

// ---- page tokens ----

func (s *service) sealed() error {
	if len(s.d.CursorKey) == 0 {
		return errors.New("beacons: page tokens are not wired (no CursorKey)")
	}
	return nil
}

// listBinding ties a ListBeacons token to the viewer and the audience, so it opens for no one else and no other list.
func listBinding(viewer, communityID string) string {
	audience := "public"
	if communityID != "" {
		audience = "c:" + communityID
	}
	return "beacons|list|" + viewer + "|" + audience
}

// decodeAfter opens a ListBeacons token to the (startAt, id) of the last row returned. An empty token is the first page.
func (s *service) decodeAfter(binding, token string) (time.Time, string, error) {
	if token == "" {
		return time.Time{}, "", nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return time.Time{}, "", errPageToken()
	}
	v, id, ok := strings.Cut(cur.DocID, ":")
	if !ok || v != tokenVersion || !ids.ValidPostID(id) {
		return time.Time{}, "", errPageToken()
	}
	return cur.CreatedAt, id, nil
}

func (s *service) encodeAfter(binding string, b Beacon) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: b.StartAt, DocID: tokenVersion + ":" + b.ID}, s.now())
}

// ListBeacons implements Service (the proto doc comment is the contract). Order of the work: validation and the community
// gate (0 Firestore reads: the role is cached), the token (pure), one query of page_size + 1 docs (the extra row decides
// next_page_token, computed from the raw rows so a filtered page still resumes correctly, R8), the viewer's graph
// (cached; past an overflowed blockedBy each organiser's own graph, once per organiser) to drop beacons across a block,
// hidden beacons dropped unless the viewer organises them, one batched profile read of the organisers (a missing or
// non-ACTIVE organiser drops the row), then one GetAll of the viewer's participant rows on the shown beacons they do
// not organise, so each row carries the same viewer state GetBeacon answers.
func (s *service) ListBeacons(ctx context.Context, viewer string, in ListInput) (Page, error) {
	begin(ctx, "list")
	if err := validateAudience(in.CommunityID, in.Public); err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	if in.CommunityID != "" {
		if err := s.requireMember(ctx, viewer, in.CommunityID, false, false); err != nil {
			return Page{}, mapErr(ctx, "list", viewer, "", err)
		}
	}
	if err := s.sealed(); err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	binding := listBinding(viewer, in.CommunityID)
	afterStart, afterID, err := s.decodeAfter(binding, in.PageToken)
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	now := s.now()
	from := in.From
	if from.IsZero() {
		from = now
	}
	size := limits.ClampPageSize(in.Limit)
	rows, err := s.d.Repo.ListByAudience(ctx, ListQuery{CommunityID: in.CommunityID, From: from, AfterStartAt: afterStart, AfterID: afterID, Limit: size + 1})
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	var out Page
	if len(rows) > size {
		rows = rows[:size]
		out.NextPageToken = s.encodeAfter(binding, rows[size-1])
	}
	if len(rows) == 0 {
		return out, nil
	}
	bc, err := s.blocks(ctx, viewer)
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	kept := make([]Beacon, 0, len(rows))
	organisers := make([]string, 0, len(rows))
	seen := map[string]bool{}
	droppedHidden, droppedBlocked := 0, 0
	for _, b := range rows {
		cause, err := visibleRow(ctx, bc, viewer, b)
		if err != nil {
			return Page{}, mapErr(ctx, "list", viewer, "", err)
		}
		switch cause {
		case "hidden":
			droppedHidden++
			continue
		case "blocked":
			droppedBlocked++
			continue
		}
		kept = append(kept, b)
		if !seen[b.OrganiserID] {
			seen[b.OrganiserID] = true
			organisers = append(organisers, b.OrganiserID)
		}
	}
	logger.SetRequestField(ctx, fieldDroppedHidden, droppedHidden)
	logger.SetRequestField(ctx, fieldDroppedBlocked, droppedBlocked)
	if len(kept) == 0 {
		return out, nil
	}
	profs, err := s.d.Directory.GetProfiles(ctx, organisers)
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", logger.RedactErr(fmt.Errorf("beacons: load organiser profiles: %w", err), organisers...))
	}
	droppedGone := 0
	shown := make([]Beacon, 0, len(kept))
	others := make([]string, 0, len(kept))
	for _, b := range kept {
		p, ok := profs[b.OrganiserID]
		if !ok || p.Status != identity.AccountStatusActive {
			droppedGone++
			continue
		}
		shown = append(shown, b)
		if b.OrganiserID != viewer {
			others = append(others, b.ID)
		}
	}
	states, err := s.participantStates(ctx, viewer, others)
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	for _, b := range shown {
		out.Views = append(out.Views, s.viewWith(b, profs[b.OrganiserID], viewer, states[b.ID]))
	}
	logger.SetRequestField(ctx, fieldDroppedGone, droppedGone)
	return out, nil
}
