package beacons

import (
	"context"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// sharedScanRows is how many of the caller's upcoming memberships one ListShared call examines (the read bound).
	sharedScanRows     = 10
	sharedDefaultLimit = 3
	sharedMaxLimit     = 10
)

// sharedLimit clamps the page size: 0 = 3, above 10 = 10.
func sharedLimit(n int32) int {
	switch {
	case n <= 0:
		return sharedDefaultLimit
	case n > sharedMaxLimit:
		return sharedMaxLimit
	}
	return int(n)
}

// inPlan reports whether a membership row puts its user in the plan: the organiser, or an ACCEPTED participant.
func inPlan(m Membership) bool {
	return m.Role == RoleOrganiser || (m.Role == RoleParticipant && m.State == PStateAccepted)
}

// ListShared implements Service (the proto doc comment is the contract). Order of the work: the peer id (pure), the token
// (pure), the viewer's graph (cached; a block either way with the peer is an empty page), the peer's profile (cached; a
// missing or non-ACTIVE peer is an empty page), one query of at most sharedScanRows + 1 of the viewer's upcoming
// memberships (organiser or participant role), one GetAll of the peer's membership rows for the viewer's in-plan ones,
// one GetAll of the shared beacons, the per-row rules (hidden, cancelled, ended, a block with the organiser, and for a
// community audience a JOINED verdict for BOTH users, once per community each) and one batched profile read of the
// organisers. The page token follows the viewer's membership order, so a short page can still carry one.
func (s *service) ListShared(ctx context.Context, viewer string, in SharedInput) (Page, error) {
	begin(ctx, "shared")
	if !ids.ValidUID(in.PeerUID) || in.PeerUID == viewer {
		return Page{}, mapErr(ctx, "shared", viewer, "", apierr.Validation("peer_user_id", "peer_user_id must be another user's id"))
	}
	if err := s.sealed(); err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	binding := "beacons|shared|" + viewer + "|" + in.PeerUID
	afterEnd, afterID, err := s.decodeToken(binding, in.PageToken, ids.ValidPostID)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	bc, err := s.blocks(ctx, viewer)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	blocked, err := bc.blocked(ctx, in.PeerUID)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	if blocked {
		return Page{}, nil
	}
	peerProfs, err := s.d.Directory.GetProfiles(ctx, []string{in.PeerUID})
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", logger.RedactErr(fmt.Errorf("beacons: load peer profile: %w", err), viewer, in.PeerUID))
	}
	if p, ok := peerProfs[in.PeerUID]; !ok || p.Status != identity.AccountStatusActive {
		return Page{}, nil
	}
	now := s.now()
	rows, err := s.d.Repo.ListMemberships(ctx, MembershipQuery{
		UID: viewer, Roles: []string{RoleOrganiser, RoleParticipant}, Now: now, AfterEndAt: afterEnd, AfterID: afterID, Limit: sharedScanRows + 1,
	})
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	var out Page
	if len(rows) > sharedScanRows {
		rows = rows[:sharedScanRows]
		out.NextPageToken = s.encodeToken(binding, rows[sharedScanRows-1].EndAt, rows[sharedScanRows-1].BeaconID)
	}
	mine := make([]Membership, 0, len(rows))
	beaconIDs := make([]string, 0, len(rows))
	for _, m := range rows {
		if inPlan(m) {
			mine = append(mine, m)
			beaconIDs = append(beaconIDs, m.BeaconID)
		}
	}
	if len(mine) == 0 {
		return out, nil
	}
	theirs, err := s.d.Repo.GetMemberships(ctx, in.PeerUID, beaconIDs)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	var shared []Membership
	var sharedIDs []string
	for _, m := range mine {
		if t, ok := theirs[m.BeaconID]; ok && inPlan(t) {
			shared = append(shared, m)
			sharedIDs = append(sharedIDs, m.BeaconID)
		}
	}
	if len(shared) == 0 {
		return out, nil
	}
	beacons, err := s.d.Repo.GetBeacons(ctx, sharedIDs)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	type cand struct {
		m Membership
		b Beacon
	}
	var cands []cand
	var cids []string
	seenCID := map[string]bool{}
	for _, m := range shared {
		b, ok := beacons[m.BeaconID]
		if !ok || b.Hidden {
			continue
		}
		if st := b.EffectiveStatus(now); st != StatusOpen && st != StatusFull {
			continue
		}
		cause, err := visibleRow(ctx, bc, viewer, b)
		if err != nil {
			return Page{}, mapErr(ctx, "shared", viewer, "", err)
		}
		if cause != "" {
			continue
		}
		if b.CommunityID != "" && !seenCID[b.CommunityID] {
			seenCID[b.CommunityID] = true
			cids = append(cids, b.CommunityID)
		}
		cands = append(cands, cand{m: m, b: b})
	}
	mineOK, err := s.communityVerdicts(ctx, viewer, cids)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	peerOK, err := s.communityVerdicts(ctx, in.PeerUID, cids)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", err)
	}
	kept := make([]cand, 0, len(cands))
	organisers := make([]string, 0, len(cands))
	seen := map[string]bool{}
	for _, c := range cands {
		if c.b.CommunityID != "" && (!mineOK[c.b.CommunityID] || !peerOK[c.b.CommunityID]) {
			continue
		}
		kept = append(kept, c)
		if !seen[c.b.OrganiserID] {
			seen[c.b.OrganiserID] = true
			organisers = append(organisers, c.b.OrganiserID)
		}
	}
	logger.SetRequestField(ctx, "rows_dropped", len(shared)-len(kept))
	if len(kept) == 0 {
		return out, nil
	}
	profs, err := s.d.Directory.GetProfiles(ctx, organisers)
	if err != nil {
		return Page{}, mapErr(ctx, "shared", viewer, "", logger.RedactErr(fmt.Errorf("beacons: load organiser profiles: %w", err), organisers...))
	}
	limit := sharedLimit(in.Limit)
	for _, c := range kept {
		p, ok := profs[c.b.OrganiserID]
		if !ok || p.Status != identity.AccountStatusActive {
			continue
		}
		if len(out.Views) == limit {
			// More shared rows remain beyond this page: resume right after the last one returned.
			last := out.Views[len(out.Views)-1].Beacon
			out.NextPageToken = s.encodeToken(binding, last.EndAt, last.ID)
			break
		}
		pstate := c.m.State
		if c.m.Role == RoleOrganiser {
			pstate = ""
		}
		out.Views = append(out.Views, s.viewWith(c.b, p, viewer, pstate))
	}
	return out, nil
}
