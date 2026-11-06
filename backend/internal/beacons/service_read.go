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

// access is what the visibility check proved for one (viewer, beacon): the beacon as stored and its organiser's live
// profile.
type access struct {
	beacon      Beacon
	organiser   identity.Profile
	isOrganiser bool
}

// resolve applies the visibility rules once for every read and organiser write. Order, cheapest first, each refusal the
// same ErrNotFound unless noted: the beacon (1 read); a hidden beacon to anyone but its organiser; a community audience
// needs the viewer JOINED (ErrNotMember; FEATURE_COMMUNITIES not globally off), except the organiser, who can always
// manage their own beacon (ruling: a beacon must stay cancellable after the organiser leaves the community); a block in
// either direction (viewer graph, cached); an organiser who is missing or not ACTIVE (profile, cached).
func (s *service) resolve(ctx context.Context, viewer, beaconID string) (access, error) {
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
	if b.CommunityID != "" && !a.isOrganiser {
		if err := s.requireMember(ctx, viewer, b.CommunityID, false); err != nil {
			return access{}, err
		}
	}
	if !a.isOrganiser {
		snap, err := s.social(ctx, viewer)
		if err != nil {
			return access{}, err
		}
		if snap.BlockedBy[b.OrganiserID] || snap.Blocked[b.OrganiserID] {
			return access{}, ErrNotFound
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
	return s.view(a.beacon, a.organiser, viewer), nil
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
// (cached) to drop beacons across a block, hidden beacons dropped unless the viewer organises them, then one batched
// profile read of the organisers (a missing or non-ACTIVE organiser drops the row).
func (s *service) ListBeacons(ctx context.Context, viewer string, in ListInput) (Page, error) {
	begin(ctx, "list")
	if err := validateAudience(in.CommunityID, in.Public); err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	if in.CommunityID != "" {
		if err := s.requireMember(ctx, viewer, in.CommunityID, false); err != nil {
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
	snap, err := s.social(ctx, viewer)
	if err != nil {
		return Page{}, mapErr(ctx, "list", viewer, "", err)
	}
	kept := make([]Beacon, 0, len(rows))
	organisers := make([]string, 0, len(rows))
	seen := map[string]bool{}
	droppedHidden, droppedBlocked := 0, 0
	for _, b := range rows {
		switch {
		case b.Hidden && b.OrganiserID != viewer:
			droppedHidden++
			continue
		case snap.BlockedBy[b.OrganiserID] || snap.Blocked[b.OrganiserID]:
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
	for _, b := range kept {
		p, ok := profs[b.OrganiserID]
		if !ok || p.Status != identity.AccountStatusActive {
			droppedGone++
			continue
		}
		out.Views = append(out.Views, s.view(b, p, viewer))
	}
	logger.SetRequestField(ctx, fieldDroppedGone, droppedGone)
	return out, nil
}
