package beacons

import (
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// The front checks: no reads, the field named in the VALIDATION metadata (beacons.proto header).

func validateKey(key string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

func validateBeaconID(id string) error {
	if !ids.ValidBeaconID(id) {
		return apierr.Validation("beacon_id", "beacon_id must be a 19-digit beacon id")
	}
	return nil
}

func validateTitle(s string) (string, error) {
	n, ok := identity.SingleLineText(s, MinTitleRunes, MaxTitleRunes)
	if !ok {
		return "", apierr.Validation("title", "title must be 1-60 characters on one line, with a visible character and without control, invisible or direction characters")
	}
	return n, nil
}

func validateDetails(s string) (string, error) {
	n, ok := identity.SingleLineText(s, 0, MaxDetailsRunes)
	if !ok {
		return "", apierr.Validation("details", "details must be at most 300 characters on one line, without control, invisible or direction characters")
	}
	return n, nil
}

func validateVenue(s string) (string, error) {
	n, ok := identity.SingleLineText(s, MinVenueRunes, MaxVenueRunes)
	if !ok {
		return "", apierr.Validation("venue", "venue must be 1-80 characters on one line, with a visible character and without control, invisible or direction characters")
	}
	return n, nil
}

func validateNote(s string) (string, error) {
	n, ok := identity.SingleLineText(s, 0, MaxNoteRunes)
	if !ok {
		return "", apierr.Validation("note", "note must be at most 140 characters on one line, without control, invisible or direction characters")
	}
	return n, nil
}

func validateUserID(id string) error {
	if !ids.ValidUID(id) {
		return apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9-]")
	}
	return nil
}

// responseFromProto maps JoinResponse to accept; UNSPECIFIED is VALIDATION "response".
func responseFromProto(r beaconsv1.JoinResponse) (bool, error) {
	switch r {
	case beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT:
		return true, nil
	case beaconsv1.JoinResponse_JOIN_RESPONSE_DECLINE:
		return false, nil
	}
	return false, apierr.Validation("response", "response must be ACCEPT or DECLINE")
}

// validateStart: start_at in [now + MinStartLead, now + MaxStartLead].
func validateStart(start, now time.Time) error {
	if start.IsZero() || start.Before(now.Add(MinStartLead)) || start.After(now.Add(MaxStartLead)) {
		return apierr.Validation("start_at", "start_at must be between 5 minutes and 30 days from now")
	}
	return nil
}

func validateDuration(n int) error {
	if n < MinDurationMin || n > MaxDurationMin {
		return apierr.Validation("duration_minutes", "duration_minutes must be 15-240")
	}
	return nil
}

// validateOpenSpots: 1..max; above max is the LIMIT_REACHED "beacon_participants" refusal (ErrSpotsLimit), not a
// validation error, because max is config.
func validateOpenSpots(n, maxSpots int) error {
	if n < 1 {
		return apierr.Validation("open_spots", "open_spots must be at least 1")
	}
	if n > maxSpots {
		return ErrSpotsLimit
	}
	return nil
}

// validateAudience: exactly one of community_id and public, and a well-formed community id.
func validateAudience(communityID string, public bool) error {
	if (communityID == "") == !public {
		return apierr.Validation("audience", "set exactly one of community_id and public")
	}
	if communityID != "" && !ids.ValidPostID(communityID) {
		return apierr.Validation("community_id", "community_id must be a 19-digit community id")
	}
	return nil
}

// validateListActivity: the ListBeacons filter is empty (every activity) or one stored activity value.
func validateListActivity(a Activity) error {
	if a == "" {
		return nil
	}
	for _, v := range activityByProto {
		if v == a {
			return nil
		}
	}
	return apierr.Validation("activity", "activity is not a known value")
}

// ---- enum conversion, both ways ----

var activityByProto = map[beaconsv1.BeaconActivity]Activity{
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE:   ActivityCoffee,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_MEAL:     ActivityMeal,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_STUDY:    ActivityStudy,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_SPORTS:   ActivitySports,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_WALK:     ActivityWalk,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_SHOPPING: ActivityShopping,
	beaconsv1.BeaconActivity_BEACON_ACTIVITY_OTHER:    ActivityOther,
}

func activityFromProto(a beaconsv1.BeaconActivity) (Activity, error) {
	if v, ok := activityByProto[a]; ok {
		return v, nil
	}
	return "", apierr.Validation("activity", "activity must be set")
}

// listActivityFromProto converts ListBeaconsRequest.activity: UNSPECIFIED is no filter (""), a known value its stored
// form, anything else (a value this server does not know) VALIDATION "activity".
func listActivityFromProto(a beaconsv1.BeaconActivity) (Activity, error) {
	if a == beaconsv1.BeaconActivity_BEACON_ACTIVITY_UNSPECIFIED {
		return "", nil
	}
	if v, ok := activityByProto[a]; ok {
		return v, nil
	}
	return "", apierr.Validation("activity", "activity is not a known value")
}

func activityToProto(a Activity) beaconsv1.BeaconActivity {
	for p, v := range activityByProto {
		if v == a {
			return p
		}
	}
	return beaconsv1.BeaconActivity_BEACON_ACTIVITY_UNSPECIFIED
}

var costByProto = map[beaconsv1.BeaconCost]Cost{
	beaconsv1.BeaconCost_BEACON_COST_FREE:              CostFree,
	beaconsv1.BeaconCost_BEACON_COST_EVERYONE_PAYS_OWN: CostEveryonePaysOwn,
	beaconsv1.BeaconCost_BEACON_COST_SPLIT_EVENLY:      CostSplitEvenly,
}

func costFromProto(c beaconsv1.BeaconCost) (Cost, error) {
	if v, ok := costByProto[c]; ok {
		return v, nil
	}
	return "", apierr.Validation("cost", "cost must be set")
}

func costToProto(c Cost) beaconsv1.BeaconCost {
	for p, v := range costByProto {
		if v == c {
			return p
		}
	}
	return beaconsv1.BeaconCost_BEACON_COST_UNSPECIFIED
}

var chatPrefByProto = map[beaconsv1.ChatPreference]ChatPref{
	beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET:        ChatQuiet,
	beaconsv1.ChatPreference_CHAT_PREFERENCE_TASK_FOCUSED: ChatTaskFocused,
	beaconsv1.ChatPreference_CHAT_PREFERENCE_OPEN_TO_CHAT: ChatOpen,
}

func chatPrefFromProto(c beaconsv1.ChatPreference) (ChatPref, error) {
	if v, ok := chatPrefByProto[c]; ok {
		return v, nil
	}
	return "", apierr.Validation("chat_preference", "chat_preference must be set")
}

func chatPrefToProto(c ChatPref) beaconsv1.ChatPreference {
	for p, v := range chatPrefByProto {
		if v == c {
			return p
		}
	}
	return beaconsv1.ChatPreference_CHAT_PREFERENCE_UNSPECIFIED
}

func statusToProto(s Status) beaconsv1.BeaconStatus {
	switch s {
	case StatusOpen:
		return beaconsv1.BeaconStatus_BEACON_STATUS_OPEN
	case StatusFull:
		return beaconsv1.BeaconStatus_BEACON_STATUS_FULL
	case StatusCancelled:
		return beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED
	case StatusEnded:
		return beaconsv1.BeaconStatus_BEACON_STATUS_ENDED
	}
	return beaconsv1.BeaconStatus_BEACON_STATUS_UNSPECIFIED
}
