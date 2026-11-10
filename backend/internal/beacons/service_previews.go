package beacons

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// maxPreviewIDs bounds one Previews call (a post page is at most 50 rows).
const maxPreviewIDs = 50

// PlanPreview is what a post embed shows of a plan: the live fields, decided for one viewer. Status is the effective one
// (OPEN, FULL, CANCELLED, or ENDED from the clock).
type PlanPreview struct {
	BeaconID    string
	OrganiserID string
	Title       string
	Activity    Activity
	StartAt     time.Time
	Status      Status
	// CommunityID is "" for a public plan.
	CommunityID string
}

func previewOf(b Beacon, now time.Time) PlanPreview {
	return PlanPreview{
		BeaconID: b.ID, OrganiserID: b.OrganiserID, Title: b.Title, Activity: b.Activity, StartAt: b.StartAt,
		Status: b.EffectiveStatus(now), CommunityID: b.CommunityID,
	}
}

// Previews implements Service (the consumer is posts, through the apiserver adapter). One GetAll of the distinct, valid ids
// (at most maxPreviewIDs), then the per-row rules of ListMyBeacons for a viewer: a hidden plan renders only to its
// organiser, a block either way with the organiser drops it (the viewer's graph, cached 60 s; no read when the viewer
// organises every plan), a community plan needs the community verdict (once per community, cached 60 s) unless the
// viewer organises it, and the organiser must be ACTIVE (one cache-first Directory batch for the distinct organisers of
// the remaining plans, at most maxPreviewIDs, never the viewer: a SUSPENDED, DELETING or missing organiser's plan is
// unavailable, as GetBeacon answers NOT_FOUND for it). A plan that is missing, dropped or beyond the cap is absent from the
// map (the caller renders "Plan unavailable"); an ENDED or CANCELLED plan is present with that status. No participant row
// is read. FEATURE_BEACONS globally off answers an empty map with no read. A failed read is an error (the caller degrades
// closed).
func (s *service) Previews(ctx context.Context, viewer string, beaconIDs []string) (map[string]PlanPreview, error) {
	out := map[string]PlanPreview{}
	if s.d.CommunityFlags == nil || s.d.CommunityFlags.GloballyOff(FlagName) {
		return out, nil
	}
	seen := make(map[string]bool, len(beaconIDs))
	want := make([]string, 0, len(beaconIDs))
	for _, id := range beaconIDs {
		if !ids.ValidBeaconID(id) || seen[id] || len(want) == maxPreviewIDs {
			continue
		}
		seen[id] = true
		want = append(want, id)
	}
	if len(want) == 0 {
		return out, nil
	}
	found, err := s.d.Repo.GetBeacons(ctx, want)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: previews: %w", err), viewer)
	}
	var bc *blockCheck
	var cids []string
	seenCID := map[string]bool{}
	cands := make([]Beacon, 0, len(found))
	for _, id := range want {
		b, ok := found[id]
		if !ok {
			continue
		}
		if b.OrganiserID != viewer {
			if bc == nil {
				if bc, err = s.blocks(ctx, viewer); err != nil {
					return nil, err
				}
			}
			cause, err := visibleRow(ctx, bc, viewer, b)
			if err != nil {
				return nil, err
			}
			if cause != "" {
				continue
			}
			if b.CommunityID != "" && !seenCID[b.CommunityID] {
				seenCID[b.CommunityID] = true
				cids = append(cids, b.CommunityID)
			}
		}
		cands = append(cands, b)
	}
	verdicts, err := s.communityVerdicts(ctx, viewer, cids)
	if err != nil {
		return nil, err
	}
	kept := make([]Beacon, 0, len(cands))
	var organisers []string
	seenOrg := map[string]bool{}
	for _, b := range cands {
		if b.OrganiserID != viewer && b.CommunityID != "" && !verdicts[b.CommunityID] {
			continue
		}
		kept = append(kept, b)
		if b.OrganiserID != viewer && !seenOrg[b.OrganiserID] {
			seenOrg[b.OrganiserID] = true
			organisers = append(organisers, b.OrganiserID)
		}
	}
	active, err := s.activeOrganisers(ctx, viewer, organisers)
	if err != nil {
		return nil, err
	}
	now := s.now()
	for _, b := range kept {
		if b.OrganiserID != viewer && !active[b.OrganiserID] {
			continue
		}
		out[b.ID] = previewOf(b, now)
	}
	logger.SetRequestField(ctx, "beacon_previews_dropped", len(want)-len(out))
	return out, nil
}

// activeOrganisers is the set of organisers (at most maxPreviewIDs, the Directory's batch limit) whose profile is ACTIVE:
// one cache-first GetProfiles, none when the list is empty. A failure is an error, never an assumed status.
func (s *service) activeOrganisers(ctx context.Context, viewer string, organisers []string) (map[string]bool, error) {
	active := make(map[string]bool, len(organisers))
	if len(organisers) == 0 {
		return active, nil
	}
	profs, err := s.d.Directory.GetProfiles(ctx, organisers)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: previews: organiser profiles: %w", err), append([]string{viewer}, organisers...)...)
	}
	for uid, p := range profs {
		if p.Status == identity.AccountStatusActive {
			active[uid] = true
		}
	}
	return active, nil
}

// EmbedTarget implements Service: the plan uid may share on a post. FEATURE_BEACONS must be on for uid (Guard, before any
// read). The plan must exist, be uid's own and not hidden (one ErrNotFound for all, so another user's plan never
// leaks), then ErrCancelled or ErrEnded (the clock, EffectiveStatus). One point read.
func (s *service) EmbedTarget(ctx context.Context, uid, beaconID string) (PlanPreview, error) {
	if err := Guard(ctx, s.d.CommunityFlags, uid); err != nil {
		return PlanPreview{}, err
	}
	if !ids.ValidBeaconID(beaconID) {
		return PlanPreview{}, ErrNotFound
	}
	b, err := s.d.Repo.Get(ctx, beaconID)
	if err != nil {
		return PlanPreview{}, err
	}
	if b.OrganiserID != uid || b.Hidden {
		return PlanPreview{}, ErrNotFound
	}
	switch b.EffectiveStatus(s.now()) {
	case StatusCancelled:
		return PlanPreview{}, ErrCancelled
	case StatusEnded:
		return PlanPreview{}, ErrEnded
	}
	return previewOf(b, s.now()), nil
}
