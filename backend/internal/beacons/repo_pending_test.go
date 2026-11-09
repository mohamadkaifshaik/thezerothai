package beacons

import (
	"strings"
	"testing"
	"time"
)

// TestStalePending (B08): the pending-cap re-check discounts rows whose beacon is cancelled, ended or gone, and keeps
// rows on open, full and hidden beacons.
func TestStalePending(t *testing.T) {
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	live := func(s Status) *Beacon { return &Beacon{Status: s, EndAt: now.Add(time.Hour)} }
	ended := &Beacon{Status: StatusOpen, EndAt: now}
	hidden := live(StatusOpen)
	hidden.Hidden = true
	beacons := map[string]*Beacon{
		"open": live(StatusOpen), "full": live(StatusFull), "cancelled": live(StatusCancelled), "ended": ended,
		"hidden": hidden, "nil": nil,
	}
	for _, tt := range []struct {
		name string
		ids  []string
		want string
	}{
		{"none", nil, ""},
		{"all live", []string{"open", "full", "hidden"}, ""},
		{"cancelled", []string{"open", "cancelled"}, "cancelled"},
		{"ended at now", []string{"ended", "full"}, "ended"},
		{"missing or nil beacon", []string{"gone", "open", "nil"}, "gone,nil"},
		{"mixed keeps input order", []string{"cancelled", "open", "ended", "gone"}, "cancelled,ended,gone"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := strings.Join(stalePending(tt.ids, beacons, now), ","); got != tt.want {
				t.Errorf("stalePending = %q, want %q", got, tt.want)
			}
		})
	}
}
