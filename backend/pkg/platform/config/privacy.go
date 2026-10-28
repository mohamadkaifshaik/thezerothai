package config

import (
	"fmt"
	"time"
)

// MaxProtectedAuthors is the hard ceiling of PROTECTED_AUTHORS_MAX (ADR-0025 D2: about 30 B per uid, so 20,000 uids
// is about 600 KB of the 1 MiB document limit). Raising it needs an ADR (the sharded set is the Stage 2 rung).
const MaxProtectedAuthors = 20000

// MaxProtectedSetStale is the longest PROTECTED_SET_MAX_STALE may be set to. The default is 10 minutes (ADR-0025 D3).
const MaxProtectedSetStale = time.Hour

// PrivacyConfig holds the private-accounts limits that are not per-minute buckets or per-day quotas (ADR-0025 D2, D3).
// The daily toggle quota lives in QuotaConfig (QUOTA_PRIVACY_TOGGLES_PER_DAY) and the Respond bucket in
// RateLimitConfig (RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN).
type PrivacyConfig struct {
	// ProtectedAuthorsMax is the most uids privacy/protectedAuthors may hold (PROTECTED_AUTHORS_MAX, default 20,000, at
	// most MaxProtectedAuthors). Protecting an account at the cap is FAILED_PRECONDITION LIMIT_REACHED limit=private_accounts.
	ProtectedAuthorsMax int
	// ProtectedSetMaxStale is how long an instance keeps serving its last good copy of the set after a failed refresh
	// (PROTECTED_SET_MAX_STALE, default 10m, 1s to MaxProtectedSetStale). Past it the loader fails closed: callers answer
	// UNAVAILABLE and an unknown set is never read as "everyone public".
	ProtectedSetMaxStale time.Duration
}

// loadPrivacy reads and validates PROTECTED_AUTHORS_MAX and PROTECTED_SET_MAX_STALE. An out-of-range value fails
// startup instead of silently weakening the fail-closed window or the document-size bound.
func loadPrivacy() (PrivacyConfig, error) {
	var (
		c   PrivacyConfig
		err error
	)
	if c.ProtectedAuthorsMax, err = getInt("PROTECTED_AUTHORS_MAX", MaxProtectedAuthors); err != nil {
		return PrivacyConfig{}, err
	}
	if c.ProtectedAuthorsMax < 1 || c.ProtectedAuthorsMax > MaxProtectedAuthors {
		return PrivacyConfig{}, fmt.Errorf("config: PROTECTED_AUTHORS_MAX must be 1..%d (got %d)", MaxProtectedAuthors, c.ProtectedAuthorsMax)
	}
	if c.ProtectedSetMaxStale, err = getDuration("PROTECTED_SET_MAX_STALE", 10*time.Minute); err != nil {
		return PrivacyConfig{}, err
	}
	if c.ProtectedSetMaxStale < time.Second || c.ProtectedSetMaxStale > MaxProtectedSetStale {
		return PrivacyConfig{}, fmt.Errorf("config: PROTECTED_SET_MAX_STALE must be 1s..%s (got %s)", MaxProtectedSetStale, c.ProtectedSetMaxStale)
	}
	return c, nil
}
