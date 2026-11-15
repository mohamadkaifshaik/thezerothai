package apiserver

import (
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestStatsDayIsTheImpressionDay (F2): a creator's dailyStats day key is the impressions dedupe day, on both sides of
// the IST rollover (18:30 UTC), so a counted view lands on the same day it was deduped on.
func TestStatsDayIsTheImpressionDay(t *testing.T) {
	for _, at := range []time.Time{
		time.Date(2026, 11, 15, 18, 29, 59, 0, time.UTC),
		time.Date(2026, 11, 15, 18, 30, 0, 0, time.UTC),
		time.Date(2026, 2, 28, 23, 0, 0, 0, time.UTC),
	} {
		if s, i := identity.StatsDay(at), engagement.ImpressionDay(at); s != i {
			t.Errorf("at %v: StatsDay %s, ImpressionDay %s", at, s, i)
		}
	}
}
