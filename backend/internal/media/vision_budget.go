package media

import "time"

// monthKey is the usage counter's month (document admin/vision-{yyyymm}), in UTC like Google Cloud billing. The counter
// only meters SafeSearch spend for scripts/cost-vision.sh; nothing reads it to decide whether an image is screened.
func monthKey(t time.Time) string { return t.UTC().Format("200601") }
