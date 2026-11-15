// area.go is the plan area of Location P2 (location design 2026-11-15, sections 2.3, 4 and 5.2): the organiser-chosen
// catalogue area of a plan's meeting point, validated through location.Catalog, denormalised into areaId, cityId and
// nearAreaIds on the beacon doc, and the proximity a Nearby row carries. Place-based: nothing here reads or derives a
// person's location; the caller's own stored area is read only by ListNearby (location.Reader), never stored here.
package beacons

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/internal/location"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// fieldAreaID is the VALIDATION field of a bad area id; the value is never echoed.
const fieldAreaID = "area_id"

// errAreaID is the one answer for an area id that is malformed, unknown or (for a plan) retired.
func errAreaID() error { return apierr.Validation(fieldAreaID, "area_id is not a known area") }

// Proximity is where a Nearby row's plan area sits relative to the requested area (AreaProximity).
type Proximity string

// The three proximities.
const (
	ProximitySameArea     Proximity = "same_area"
	ProximityNeighbouring Proximity = "neighbouring"
	ProximitySameCity     Proximity = "same_city"
)

// denormalise is the stored form of catalogue area a: its id, its city and nearAreaIds = the area plus its curated
// neighbours (a CITY stores just itself), so "plans near X" is one array-contains query on X.
func denormalise(a location.Area) AreaFields {
	near := make([]string, 0, 1+len(a.Neighbours))
	near = append(near, a.ID)
	if a.Kind == location.KindArea {
		near = append(near, a.Neighbours...)
	}
	return AreaFields{AreaID: a.ID, CityID: a.CityID, NearAreaIDs: near}
}

// pickableArea resolves an id a plan may be given: well-formed, in the catalogue and not retired. Anything else is the
// one VALIDATION "area_id" (0 reads; the value never echoed).
func (s *service) pickableArea(id string) (location.Area, error) {
	if !location.ValidIDFormat(id) || s.d.Areas == nil || !s.d.Areas.Pickable(id) {
		return location.Area{}, errAreaID()
	}
	a, ok := s.d.Areas.Lookup(id)
	if !ok {
		return location.Area{}, errAreaID()
	}
	return a, nil
}

// createArea is CreateBeacon's area branch, before any lookup: "" is no area (no gate); otherwise FEATURE_LOCATION on for
// the caller (FEATURE_DISABLED "location") and then a pickable id.
func (s *service) createArea(ctx context.Context, uid, id string) (AreaFields, error) {
	if id == "" {
		return AreaFields{}, nil
	}
	if err := location.Guard(ctx, s.d.Flags, uid); err != nil {
		return AreaFields{}, err
	}
	a, err := s.pickableArea(id)
	if err != nil {
		return AreaFields{}, err
	}
	return denormalise(a), nil
}

// updateArea is UpdateBeacon's area branch, before any lookup: nil is unchanged; "" removes the area and needs
// FEATURE_LOCATION only not globally off (a caller dropped from the allowlist can still take a label off); an id needs
// the flag on for the caller and a pickable id.
func (s *service) updateArea(ctx context.Context, uid string, id *string) (*AreaFields, error) {
	switch {
	case id == nil:
		return nil, nil
	case *id == "":
		if err := location.GuardNotOff(ctx, s.d.Flags, uid); err != nil {
			return nil, err
		}
		return &AreaFields{}, nil
	}
	f, err := s.createArea(ctx, uid, *id)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// areaLabel is the catalogue entry View.Area renders (Beacon.area): nil when the plan has no area, the catalogue does not
// know it (never expected: ids are permanent) or FEATURE_LOCATION is globally off (the kill switch hides every label).
// Retired areas still resolve. 0 reads.
func (s *service) areaLabel(b Beacon) *location.Area {
	if b.Area.AreaID == "" || s.d.Areas == nil || s.d.Flags == nil || s.d.Flags.GloballyOff(location.FlagName) {
		return nil
	}
	a, ok := s.d.Areas.Lookup(b.Area.AreaID)
	if !ok {
		return nil
	}
	return &a
}

// proximity places a listed plan's area relative to the requested area req: the same id is SAME_AREA (for a CITY
// request, a plan tagged with the city itself); one of req's curated neighbours is NEIGHBOURING; anything else in the
// city (CITY scope only) is SAME_CITY.
func proximity(planAreaID string, req location.Area) Proximity {
	if planAreaID == req.ID {
		return ProximitySameArea
	}
	if req.Kind == location.KindArea {
		for _, n := range req.Neighbours {
			if n == planAreaID {
				return ProximityNeighbouring
			}
		}
	}
	return ProximitySameCity
}
