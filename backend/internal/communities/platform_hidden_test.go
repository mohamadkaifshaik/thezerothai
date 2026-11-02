package communities

import (
	"testing"
	"time"
)

// hiddenVerdict is the one rule of restore-hidden (real run and --dry-run): platform removals stay hidden, --since keeps older posts hidden and
// skips rows without a hide time, a run without --since restores everything else.
func TestHiddenVerdict(t *testing.T) {
	t.Parallel()
	since := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	cases := []struct {
		name      string
		since, at time.Time
		moderated bool
		restore   bool
		want      hiddenCounts
	}{
		{"no since, timed", time.Time{}, since.Add(-time.Hour), false, true, hiddenCounts{}},
		{"no since, no time restores", time.Time{}, time.Time{}, false, true, hiddenCounts{}},
		{"since, after", since, since.Add(time.Minute), false, true, hiddenCounts{}},
		{"since, exactly at", since, since, false, true, hiddenCounts{}},
		{"since, before stays", since, since.Add(-time.Minute), false, false, hiddenCounts{}},
		{"since, no time", since, time.Time{}, false, false, hiddenCounts{noTime: 1}},
		{"moderated, no since", time.Time{}, since, true, false, hiddenCounts{platform: 1}},
		{"moderated wins over no time", since, time.Time{}, true, false, hiddenCounts{platform: 1}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, c := hiddenVerdict(tc.since, tc.at, tc.moderated)
			if got != tc.restore || c != tc.want {
				t.Errorf("= %v %+v, want %v %+v", got, c, tc.restore, tc.want)
			}
		})
	}
}
