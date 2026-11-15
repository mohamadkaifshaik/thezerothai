package beacons

import (
	"strconv"

	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/location"
)

// createInputFromProto converts a CreateBeaconRequest; the enum checks answer VALIDATION naming the field before the
// service runs (0 reads either way).
func createInputFromProto(m *beaconsv1.CreateBeaconRequest) (CreateInput, error) {
	activity, err := activityFromProto(m.GetActivity())
	if err != nil {
		return CreateInput{}, err
	}
	cost, err := costFromProto(m.GetCost())
	if err != nil {
		return CreateInput{}, err
	}
	chat, err := chatPrefFromProto(m.GetChatPreference())
	if err != nil {
		return CreateInput{}, err
	}
	in := CreateInput{
		Key: m.GetIdempotencyKey(), CommunityID: m.GetCommunityId(), Public: m.GetPublic(), Activity: activity,
		Title: m.GetTitle(), Details: m.GetDetails(), Venue: m.GetVenue(), DurationMin: int(m.GetDurationMinutes()),
		OpenSpots: int(m.GetOpenSpots()), Cost: cost, ChatPref: chat, AreaID: m.GetAreaId(),
	}
	if m.GetStartAt() != nil {
		in.StartAt = m.GetStartAt().AsTime()
	}
	return in, nil
}

// updateInputFromProto converts an UpdateBeaconRequest: an unset optional field is nil (unchanged); a set cost of
// UNSPECIFIED answers VALIDATION "cost" before the service runs.
func updateInputFromProto(m *beaconsv1.UpdateBeaconRequest) (UpdateInput, error) {
	in := UpdateInput{Key: m.GetIdempotencyKey(), BeaconID: m.GetBeaconId(), Title: m.Title, Details: m.Details, Venue: m.Venue, AreaID: m.AreaId}
	if m.OpenSpots != nil {
		n := int(m.GetOpenSpots())
		in.OpenSpots = &n
	}
	if m.GetStartAt() != nil {
		t := m.GetStartAt().AsTime()
		in.StartAt = &t
	}
	if m.DurationMinutes != nil {
		n := int(m.GetDurationMinutes())
		in.DurationMin = &n
	}
	if m.Cost != nil {
		c, err := costFromProto(m.GetCost())
		if err != nil {
			return UpdateInput{}, err
		}
		in.Cost = &c
	}
	switch a := m.GetAudience().(type) {
	case *beaconsv1.UpdateBeaconRequest_CommunityId:
		in.Audience = &AudienceInput{CommunityID: a.CommunityId}
	case *beaconsv1.UpdateBeaconRequest_Public:
		in.Audience = &AudienceInput{Public: a.Public}
	}
	return in, nil
}

// toAuthorSnapshot is the live row (the AuthorSnapshot thumbnail and lock badge, as graph's rows).
func toAuthorSnapshot(p identity.Profile) *commonv1.AuthorSnapshot {
	return &commonv1.AuthorSnapshot{
		UserId: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarUrl: p.AvatarThumbURL,
		Verified: p.Verified, IsPrivate: p.IsPrivate,
	}
}

// toParticipant renders one participant row: since is respondedAt for an ACCEPTED row and requestedAt otherwise.
func toParticipant(r ParticipantRow) *beaconsv1.Participant {
	since := r.Participant.RequestedAt
	if r.Participant.State == PStateAccepted {
		since = r.Participant.RespondedAt
	}
	return &beaconsv1.Participant{
		User: toAuthorSnapshot(r.User), State: participantStateToProto(r.Participant.State), Note: r.Participant.Note, Since: timestamppb.New(since),
	}
}

// myRoleFromProto maps the ListMyBeacons role filter ("" = all).
func myRoleFromProto(r beaconsv1.MyBeaconsRole) string {
	switch r {
	case beaconsv1.MyBeaconsRole_MY_BEACONS_ROLE_ORGANISER:
		return RoleOrganiser
	case beaconsv1.MyBeaconsRole_MY_BEACONS_ROLE_PARTICIPANT:
		return RoleParticipant
	}
	return ""
}

// toView renders a View. The organiser row is the live profile; Beacon.area is View.Area (the service decided the label).
func toView(v View) *beaconsv1.BeaconView {
	b := v.Beacon
	var area *locationv1.AreaSummary
	if v.Area != nil {
		area = location.ToSummary(*v.Area)
	}
	return &beaconsv1.BeaconView{
		Beacon: &beaconsv1.Beacon{
			BeaconId:        b.ID,
			Organiser:       toAuthorSnapshot(v.Organiser),
			CommunityId:     b.CommunityID,
			Activity:        activityToProto(b.Activity),
			Title:           b.Title,
			Details:         b.Details,
			Venue:           b.Venue,
			StartAt:         timestamppb.New(b.StartAt),
			DurationMinutes: int32(b.DurationMin),   //nolint:gosec // bounded by MaxDurationMin (240)
			OpenSpots:       int32(b.OpenSpots),     //nolint:gosec // bounded by MaxBeaconOpenSpotsCeiling (50)
			AcceptedCount:   int32(b.AcceptedCount), //nolint:gosec // never above open_spots
			Cost:            costToProto(b.Cost),
			ChatPreference:  chatPrefToProto(b.ChatPref),
			Eligibility:     beaconsv1.BeaconEligibility_BEACON_ELIGIBILITY_EVERYONE,
			Status:          statusToProto(b.Status),
			Hidden:          b.Hidden,
			CreatedAt:       timestamppb.New(b.CreatedAt),
			UpdatedAt:       timestamppb.New(b.UpdatedAt),
			Area:            area,
		},
		Viewer: toViewerState(v.Viewer),
	}
}

func toViewerState(s ViewerState) *beaconsv1.ViewerState {
	role := beaconsv1.ViewerRole_VIEWER_ROLE_NONE
	switch s.Role {
	case RoleOrganiser:
		role = beaconsv1.ViewerRole_VIEWER_ROLE_ORGANISER
	case RoleParticipant:
		role = beaconsv1.ViewerRole_VIEWER_ROLE_PARTICIPANT
	}
	return &beaconsv1.ViewerState{
		Role: role, ParticipantState: participantStateToProto(s.ParticipantState),
		CanRequest: s.CanRequest, CanWithdraw: s.CanWithdraw, CanLeave: s.CanLeave, CanManage: s.CanManage,
		QuickJoinAllowed: s.QuickJoinAllowed,
	}
}

// participantStateToProto maps the stored participant state ("" when the viewer never requested) to the wire enum.
func participantStateToProto(st string) beaconsv1.ParticipantState {
	switch st {
	case "requested":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED
	case "accepted":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_ACCEPTED
	case "declined":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_DECLINED
	case "withdrawn":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_WITHDRAWN
	case "left":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_LEFT
	case "removed":
		return beaconsv1.ParticipantState_PARTICIPANT_STATE_REMOVED
	}
	return beaconsv1.ParticipantState_PARTICIPANT_STATE_UNSPECIFIED
}

// PreviewActivityProto and PreviewStatusProto render a PlanPreview's enums for the post embed adapter (apiserver), so the
// wire mapping stays in one place.
func PreviewActivityProto(a Activity) beaconsv1.BeaconActivity { return activityToProto(a) }

// PreviewStatusProto is PreviewActivityProto for the effective status.
func PreviewStatusProto(s Status) beaconsv1.BeaconStatus { return statusToProto(s) }

// nearbyScopeFromProto maps NearbyScope without judging it (UNSPECIFIED = ""; the service treats it as AREA). A value
// outside the enum passes through as an unknown scope, so ListNearby refuses it with VALIDATION "scope" only after the
// FEATURE_LOCATION gate (a caller with the flag off learns FEATURE_DISABLED first, whatever they sent).
func nearbyScopeFromProto(sc beaconsv1.NearbyScope) NearbyScope {
	switch sc {
	case beaconsv1.NearbyScope_NEARBY_SCOPE_UNSPECIFIED:
		return ""
	case beaconsv1.NearbyScope_NEARBY_SCOPE_AREA:
		return NearbyScopeArea
	case beaconsv1.NearbyScope_NEARBY_SCOPE_CITY:
		return NearbyScopeCity
	}
	return NearbyScope("unknown:" + strconv.Itoa(int(sc)))
}

func proximityToProto(p Proximity) beaconsv1.AreaProximity {
	switch p {
	case ProximitySameArea:
		return beaconsv1.AreaProximity_AREA_PROXIMITY_SAME_AREA
	case ProximityNeighbouring:
		return beaconsv1.AreaProximity_AREA_PROXIMITY_NEIGHBOURING
	case ProximitySameCity:
		return beaconsv1.AreaProximity_AREA_PROXIMITY_SAME_CITY
	}
	return beaconsv1.AreaProximity_AREA_PROXIMITY_UNSPECIFIED
}

// toNearbyResponse renders a NearbyPage; count only when the page carries one (the first page).
func toNearbyResponse(p NearbyPage) *beaconsv1.ListNearbyBeaconsResponse {
	out := &beaconsv1.ListNearbyBeaconsResponse{NextPageToken: p.NextPageToken, Area: location.ToSummary(p.Area)}
	for _, it := range p.Items {
		out.Items = append(out.Items, &beaconsv1.NearbyBeacon{View: toView(it.View), Proximity: proximityToProto(it.Proximity)})
	}
	if p.Count != nil {
		out.Count = &beaconsv1.NearbyCount{Few: p.Count.Few, Plans: int32(min(p.Count.Plans, nearbyCountCap))} //nolint:gosec // bounded by nearbyCountCap
	}
	return out
}
