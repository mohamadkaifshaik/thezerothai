// service_nearby.go is ListNearbyBeacons (Explore Nearby, location design 2026-11-15, sections 4.4 and 5.2): public OPEN
// and FULL plans in one catalogue area, soonest first, through the ListBeacons row pipeline (visibleRows, renderRows),
// with a K-anonymous count on the first page. The match is on the plan's organiser-chosen area, never on a person; the
// caller's own stored area is read through location.Reader only when the request names none, and no area id is logged.
package beacons

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/location"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// DefaultNearbyKMin is LOCATION_NEARBY_K_MIN's default: below it the count says "a few", never a number.
	DefaultNearbyKMin = 5
	// nearbyCountCap bounds the count aggregation of a multi-page result (one read per 1,000 index entries, so one read):
	// past it the count reads nearbyCountCap ("about").
	nearbyCountCap = 1000

	reasonAreaNotSet = "area_not_set"

	// Request-line fields of ListNearby: the scope and whether the request named an area, never an id.
	fieldNearbyScope  = "nearby_scope"
	fieldHasAreaParam = "has_area_param"
)

// NearbyScope is ListNearbyBeacons' reach.
type NearbyScope string

// The two scopes: the area plus its catalogue neighbours, or the whole city.
const (
	NearbyScopeArea NearbyScope = "area"
	NearbyScopeCity NearbyScope = "city"
)

// NearbyInput is a ListNearbyBeacons request after the transport layer. AreaID "" means the caller's stored area; Scope
// "" means NearbyScopeArea.
type NearbyInput struct {
	AreaID    string
	Scope     NearbyScope
	Limit     int32
	PageToken string
}

// NearbyItem is one listed plan with where its area sits relative to the requested one.
type NearbyItem struct {
	View      View
	Proximity Proximity
}

// NearbyCount is the K-anonymous size of the result: Few for 1..K_MIN-1 plans, else Plans (0 for none).
type NearbyCount struct {
	Few   bool
	Plans int
}

// NearbyPage is one page of ListNearby. Count is set on the first page only (and not when the index is not ready).
type NearbyPage struct {
	Items         []NearbyItem
	NextPageToken string
	Area          location.Area
	Count         *NearbyCount
}

// errAreaNotSet: ListNearbyBeacons without an area_id while the caller has no usable stored area (none, or a consent
// below the current copy version: location.Reader answers ok false).
func errAreaNotSet() error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "choose an area first").
		WithMeta("reason", reasonAreaNotSet)
}

// kAnon is the count the response may carry for n live plans.
func kAnon(n, kMin int) NearbyCount {
	switch {
	case n <= 0:
		return NearbyCount{}
	case n < kMin:
		return NearbyCount{Few: true}
	}
	return NearbyCount{Plans: n}
}

func (s *service) kMin() int {
	if s.d.Limits.NearbyKMin > 0 {
		return s.d.Limits.NearbyKMin
	}
	return DefaultNearbyKMin
}

// nearbyBinding ties a page token to the viewer, the resolved area and the effective scope.
func nearbyBinding(viewer, areaID string, scope NearbyScope) string {
	return "beacons|nearby|" + viewer + "|" + areaID + "|" + string(scope)
}

// resolveNearbyArea is step 4 of the gates: the request's area (any catalogue id, retired included: browsing an area is
// not storing it) or the caller's stored one (1 read; none is area_not_set).
func (s *service) resolveNearbyArea(ctx context.Context, viewer, id string) (location.Area, error) {
	if id != "" {
		if !location.ValidIDFormat(id) || s.d.Areas == nil {
			return location.Area{}, errAreaID()
		}
		a, ok := s.d.Areas.Lookup(id)
		if !ok {
			return location.Area{}, errAreaID()
		}
		return a, nil
	}
	if s.d.MyArea == nil || s.d.Areas == nil {
		return location.Area{}, errAreaNotSet()
	}
	stored, ok, err := s.d.MyArea.MyArea(ctx, viewer)
	if err != nil {
		return location.Area{}, redactAreaIDs(fmt.Errorf("beacons: my area: %w", err))
	}
	if !ok {
		return location.Area{}, errAreaNotSet()
	}
	a, found := s.d.Areas.Lookup(stored)
	if !found {
		return location.Area{}, errAreaNotSet()
	}
	return a, nil
}

// ListNearby implements Service (the proto doc comment is the contract). Order: FEATURE_LOCATION on for the viewer (the
// handler already ran FEATURE_BEACONS not globally off), the area_id format and the scope (no lookup), the area (the
// catalogue, or the stored one: 1 read), the page token (pure, bound to the resolved area and the effective scope), one
// query, the row pipeline, and on the first page the count.
//
// The count is decided on a first page that probes max(limit, K_MIN) + 1 rows, so a small client limit cannot turn a
// thin area into a multi-page one: when the probe holds the whole result the count is the rows that survive the filters
// (hidden, blocks, gone organisers), so a plan the viewer cannot see never moves "a few" to a number; otherwise the result
// has more than K_MIN raw rows and the count is one aggregation over the query, before filtering.
//
// A missing or building composite index (ErrNearbyIndex, a real project only) answers an empty page without a count and
// logs a warning, never an error: the index is an owner deploy that may trail the code.
func (s *service) ListNearby(ctx context.Context, viewer string, in NearbyInput) (NearbyPage, error) {
	begin(ctx, "nearby")
	logger.SetRequestField(ctx, fieldHasAreaParam, in.AreaID != "")
	if err := location.Guard(ctx, s.d.Flags, viewer); err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	if err := s.sealed(); err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	if in.AreaID != "" && !location.ValidIDFormat(in.AreaID) {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", errAreaID())
	}
	scope := in.Scope
	switch scope {
	case "":
		scope = NearbyScopeArea
	case NearbyScopeArea, NearbyScopeCity:
	default:
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", apierr.Validation("scope", "scope is not a known value"))
	}
	area, err := s.resolveNearbyArea(ctx, viewer, in.AreaID) // its only raw error (the stored-area read) is redacted there
	if err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	if area.Kind == location.KindCity {
		scope = NearbyScopeCity // a city-level area matches its whole city, whatever was sent
	}
	logger.SetRequestField(ctx, fieldNearbyScope, string(scope))
	binding := nearbyBinding(viewer, area.ID, scope)
	afterStart, afterID, err := s.decodeAfter(binding, in.PageToken)
	if err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	first := in.PageToken == ""
	size := limits.ClampPageSize(in.Limit)
	probe := size + 1
	if first {
		probe = min(max(size, s.kMin())+1, maxListDocs)
	}
	q := NearbyQuery{From: s.now(), AfterStartAt: afterStart, AfterID: afterID, Limit: probe}
	if scope == NearbyScopeCity {
		q.CityID = area.CityID
	} else {
		q.AreaID = area.ID
	}
	out := NearbyPage{Area: area}
	raw, err := s.d.Repo.ListNearby(ctx, q)
	if errors.Is(err, ErrNearbyIndex) {
		slog.WarnContext(ctx, "beacons_nearby_index_not_ready", fieldNearbyScope, string(scope), "query", "list")
		return out, nil
	}
	if err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	page := raw[:min(len(raw), size)]
	if len(raw) > size {
		out.NextPageToken = s.encodeAfter(binding, raw[size-1])
	}
	whole := first && len(raw) < probe
	filtered := page
	if whole {
		filtered = raw // count every probed row the viewer may see; render only this page's
	}
	shown, profs, err := s.visibleRows(ctx, viewer, filtered, len(page)) // page is a prefix of filtered
	if err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	if first {
		if out.Count, err = s.nearbyCount(ctx, q, scope, whole, len(shown)); err != nil {
			return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
		}
	}
	shown = onPage(shown, page)
	views, err := s.renderRows(ctx, viewer, shown, profs)
	if err != nil {
		return NearbyPage{}, mapErr(ctx, "nearby", viewer, "", err)
	}
	out.Items = make([]NearbyItem, 0, len(views))
	for _, v := range views {
		out.Items = append(out.Items, NearbyItem{View: v, Proximity: proximity(v.Beacon.Area.AreaID, area)})
	}
	return out, nil
}

// nearbyCount is the first page's count: visible rows when the probe held the whole result, else one aggregation
// (ErrNearbyIndex there leaves the count unset, logged).
func (s *service) nearbyCount(ctx context.Context, q NearbyQuery, scope NearbyScope, whole bool, visible int) (*NearbyCount, error) {
	if whole {
		c := kAnon(visible, s.kMin())
		return &c, nil
	}
	q.AfterID, q.AfterStartAt, q.Limit = "", time.Time{}, nearbyCountCap
	n, err := s.d.Repo.CountNearby(ctx, q)
	if errors.Is(err, ErrNearbyIndex) {
		slog.WarnContext(ctx, "beacons_nearby_index_not_ready", fieldNearbyScope, string(scope), "query", "count")
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c := kAnon(int(n), s.kMin())
	return &c, nil
}

// onPage keeps the rows of shown whose beacon is on page (the probe may have read past it), in order.
func onPage(shown, page []Beacon) []Beacon {
	if len(shown) == 0 {
		return shown
	}
	in := make(map[string]bool, len(page))
	for _, b := range page {
		in[b.ID] = true
	}
	out := make([]Beacon, 0, len(shown))
	for _, b := range shown {
		if in[b.ID] {
			out = append(out, b)
		}
	}
	return out
}
