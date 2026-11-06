package beacons

import (
	"errors"
	"strings"
	"testing"
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

var testNow = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

// assertValidation checks err is INVALID_ARGUMENT + VALIDATION naming field.
func assertValidation(t *testing.T, err error, field string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if got := ae.Metadata["field"]; got != field {
		t.Fatalf("validation field = %q (%v), want %q", got, err, field)
	}
}

// TestValidateCreateFields pins the spec's field rules (docs/beacons-plan.md section 3), each refused before any read.
func TestValidateCreateFields(t *testing.T) {
	t.Run("title", func(t *testing.T) {
		if _, err := validateTitle(""); err == nil {
			t.Fatal("empty title accepted")
		} else {
			assertValidation(t, err, "title")
		}
		if _, err := validateTitle(strings.Repeat("a", 61)); err == nil {
			t.Fatal("61-rune title accepted")
		} else {
			assertValidation(t, err, "title")
		}
		if got, err := validateTitle("  Coffee at 4  "); err != nil || got != "Coffee at 4" {
			t.Fatalf("validateTitle = %q, %v, want trimmed", got, err)
		}
	})
	t.Run("details", func(t *testing.T) {
		if _, err := validateDetails(strings.Repeat("d", 301)); err == nil {
			t.Fatal("301-rune details accepted")
		} else {
			assertValidation(t, err, "details")
		}
		if got, err := validateDetails(""); err != nil || got != "" {
			t.Fatalf("empty details = %q, %v, want accepted", got, err)
		}
	})
	t.Run("venue", func(t *testing.T) {
		if _, err := validateVenue(""); err == nil {
			t.Fatal("empty venue accepted")
		} else {
			assertValidation(t, err, "venue")
		}
		if _, err := validateVenue(strings.Repeat("v", 81)); err == nil {
			t.Fatal("81-rune venue accepted")
		} else {
			assertValidation(t, err, "venue")
		}
	})
	t.Run("start_at window", func(t *testing.T) {
		assertValidation(t, validateStart(testNow.Add(4*time.Minute), testNow), "start_at")
		assertValidation(t, validateStart(testNow.Add(31*24*time.Hour), testNow), "start_at")
		assertValidation(t, validateStart(time.Time{}, testNow), "start_at")
		if err := validateStart(testNow.Add(5*time.Minute), testNow); err != nil {
			t.Fatalf("now+5m refused: %v", err)
		}
		if err := validateStart(testNow.Add(30*24*time.Hour), testNow); err != nil {
			t.Fatalf("now+30d refused: %v", err)
		}
	})
	t.Run("duration", func(t *testing.T) {
		assertValidation(t, validateDuration(14), "duration_minutes")
		assertValidation(t, validateDuration(241), "duration_minutes")
		if err := validateDuration(15); err != nil {
			t.Fatal(err)
		}
		if err := validateDuration(240); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("open_spots", func(t *testing.T) {
		assertValidation(t, validateOpenSpots(0, 20), "open_spots")
		if err := validateOpenSpots(21, 20); !errors.Is(err, ErrSpotsLimit) {
			t.Fatalf("21 of max 20 = %v, want ErrSpotsLimit", err)
		}
		if err := validateOpenSpots(20, 20); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("enums", func(t *testing.T) {
		if _, err := activityFromProto(beaconsv1.BeaconActivity_BEACON_ACTIVITY_UNSPECIFIED); err == nil {
			t.Fatal("UNSPECIFIED activity accepted")
		} else {
			assertValidation(t, err, "activity")
		}
		if a, err := activityFromProto(beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE); err != nil || a != ActivityCoffee {
			t.Fatalf("coffee = %q, %v", a, err)
		}
		if _, err := costFromProto(beaconsv1.BeaconCost_BEACON_COST_UNSPECIFIED); err == nil {
			t.Fatal("UNSPECIFIED cost accepted")
		} else {
			assertValidation(t, err, "cost")
		}
		if _, err := chatPrefFromProto(beaconsv1.ChatPreference_CHAT_PREFERENCE_UNSPECIFIED); err == nil {
			t.Fatal("UNSPECIFIED chat_preference accepted")
		} else {
			assertValidation(t, err, "chat_preference")
		}
		for _, a := range []Activity{ActivityCoffee, ActivityMeal, ActivityStudy, ActivitySports, ActivityWalk, ActivityShopping, ActivityOther} {
			if back, err := activityFromProto(activityToProto(a)); err != nil || back != a {
				t.Fatalf("activity round trip %q = %q, %v", a, back, err)
			}
		}
	})
	t.Run("audience", func(t *testing.T) {
		assertValidation(t, validateAudience("", false), "audience")
		assertValidation(t, validateAudience("1234567890123456789", true), "audience")
		assertValidation(t, validateAudience("abc", false), "community_id")
		if err := validateAudience("1234567890123456789", false); err != nil {
			t.Fatal(err)
		}
		if err := validateAudience("", true); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("beacon_id and key", func(t *testing.T) {
		assertValidation(t, validateBeaconID("12"), "beacon_id")
		assertValidation(t, validateKey("short"), "idempotency_key")
		if err := validateKey("0123456789abcdef0123"); err != nil {
			t.Fatal(err)
		}
	})
}

// TestValidateNote: 0-140 code points, trimmed; a user_id must be a uid; a join response must be set.
func TestValidateNote(t *testing.T) {
	if _, err := validateNote(strings.Repeat("n", 141)); err == nil {
		t.Fatal("141-rune note accepted")
	} else {
		assertValidation(t, err, "note")
	}
	if got, err := validateNote(""); err != nil || got != "" {
		t.Fatalf("empty note = %q, %v, want accepted", got, err)
	}
	if got, err := validateNote("  see you there  "); err != nil || got != "see you there" {
		t.Fatalf("note = %q, %v, want trimmed", got, err)
	}
	assertValidation(t, validateUserID(""), "user_id")
	assertValidation(t, validateUserID("bad id"), "user_id")
	if err := validateUserID("user-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := responseFromProto(beaconsv1.JoinResponse_JOIN_RESPONSE_UNSPECIFIED); err == nil {
		t.Fatal("UNSPECIFIED response accepted")
	} else {
		assertValidation(t, err, "response")
	}
	if accept, err := responseFromProto(beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT); err != nil || !accept {
		t.Fatalf("ACCEPT = %v, %v", accept, err)
	}
	if accept, err := responseFromProto(beaconsv1.JoinResponse_JOIN_RESPONSE_DECLINE); err != nil || accept {
		t.Fatalf("DECLINE = %v, %v", accept, err)
	}
}

// TestEffectiveStatus: CANCELLED is final; otherwise ENDED exactly from endAt on; otherwise the stored status.
func TestEffectiveStatus(t *testing.T) {
	end := testNow.Add(25 * time.Minute)
	b := Beacon{StartAt: testNow, EndAt: end, Status: StatusOpen}
	if got := b.EffectiveStatus(end.Add(-time.Second)); got != StatusOpen {
		t.Fatalf("one second before end = %q, want open", got)
	}
	if got := b.EffectiveStatus(end); got != StatusEnded {
		t.Fatalf("at end = %q, want ended", got)
	}
	b.Status = StatusFull
	if got := b.EffectiveStatus(end.Add(time.Hour)); got != StatusEnded {
		t.Fatalf("full past end = %q, want ended", got)
	}
	b.Status = StatusCancelled
	if got := b.EffectiveStatus(end.Add(time.Hour)); got != StatusCancelled {
		t.Fatalf("cancelled past end = %q, want cancelled", got)
	}
}
