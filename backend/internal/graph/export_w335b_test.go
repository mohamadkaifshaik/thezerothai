package graph

// Test-only window into the privacy_public job for the W3-35b suites (no production seam): a smaller page makes the
// 50-page cap of one delivery reachable with a handful of requests instead of 5,001.

// SetPrivacyPublicPage sets the page size of a job built by (*service).PrivacyPublicJob. The production value is
// privacyPublicPage (100).
func SetPrivacyPublicPage(j *PrivacyPublicJob, n int) { j.page = n }

// PrivacyPublicMaxPagesForTest is the per-delivery page cap.
const PrivacyPublicMaxPagesForTest = privacyPublicMaxPages
