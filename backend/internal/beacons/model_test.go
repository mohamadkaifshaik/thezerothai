package beacons

import "testing"

// TestCanRequestAgain: a row that never existed or ended in DECLINED, WITHDRAWN, LEFT or REMOVED may request again; a
// REQUESTED or ACCEPTED row may not (already_requested / no-op success are decided by the caller).
func TestCanRequestAgain(t *testing.T) {
	for state, want := range map[string]bool{
		"":              true,
		PStateDeclined:  true,
		PStateWithdrawn: true,
		PStateLeft:      true,
		PStateRemoved:   true,
		PStateRequested: false,
		PStateAccepted:  false,
	} {
		if got := canRequestAgain(state); got != want {
			t.Errorf("canRequestAgain(%q) = %v, want %v", state, got, want)
		}
	}
}
