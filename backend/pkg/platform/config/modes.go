package config

import "fmt"

// DegradedMode gates writes/media at the platform level (CLAUDE.md "degraded-mode switch").
type DegradedMode string

const (
	DegradedOff      DegradedMode = "off"
	DegradedReadonly DegradedMode = "readonly"
	DegradedNoMedia  DegradedMode = "nomedia"
)

func (m DegradedMode) valid() bool {
	switch m {
	case DegradedOff, DegradedReadonly, DegradedNoMedia:
		return true
	default:
		return false
	}
}

// AppCheckMode controls whether a missing/invalid App Check token rejects the request (ADR-0006 §2).
type AppCheckMode string

const (
	AppCheckEnforce AppCheckMode = "enforce"
	AppCheckMonitor AppCheckMode = "monitor"
)

func (m AppCheckMode) valid() bool {
	switch m {
	case AppCheckEnforce, AppCheckMonitor:
		return true
	default:
		return false
	}
}

// VisionExhaustedPolicy is what happens to an upload once VISION_MONTHLY_CAP is spent (ADR-0005).
type VisionExhaustedPolicy string

const (
	// VisionPolicyEstablished (default): accounts older than 7 days publish as READY_UNSCREENED (queued for
	// report-driven review); newer accounts are REJECTED until the 1st of the month.
	VisionPolicyEstablished VisionExhaustedPolicy = "unscreened_established"
	// VisionPolicyReject: every upload is REJECTED once the cap is spent (strictest; no unscreened bytes at all).
	VisionPolicyReject VisionExhaustedPolicy = "reject"
)

func (p VisionExhaustedPolicy) valid() bool {
	return p == VisionPolicyEstablished || p == VisionPolicyReject
}

// ProfileMediaRetire is PROFILE_MEDIA_RETIRE (ADR-0024 Amendment 1 A4): which replaced or removed profile images the
// retire step deletes after the grace. It is per-project retention config, not a FEATURE_ flag (no cohort, no
// allowlist), and it defaults to off: nothing is deleted until a project's operator has applied the media bucket's
// customTime lifecycle rule there and set it.
type ProfileMediaRetire string

const (
	// ProfileMediaRetireOff (default): the step publishes nothing and acks every message without acting.
	ProfileMediaRetireOff ProfileMediaRetire = "off"
	// ProfileMediaRetireBanner: only BANNER images. Set after the lifecycle rule exists in the project, because a
	// tagged object without the rule outlives its TTL'd media doc and escapes the account eraser.
	ProfileMediaRetireBanner ProfileMediaRetire = "banner"
	// ProfileMediaRetireAll: BANNER and AVATAR images. Set after the app release that shows a placeholder for an
	// avatar image that no longer loads.
	ProfileMediaRetireAll ProfileMediaRetire = "all"
)

func (m ProfileMediaRetire) valid() bool {
	switch m {
	case ProfileMediaRetireOff, ProfileMediaRetireBanner, ProfileMediaRetireAll:
		return true
	default:
		return false
	}
}

// Allows reports whether the switch lets the step retire an image of this media purpose ("BANNER" or "AVATAR", the
// stored purpose names). It is the one rule publish, handler and opsctl share, so the three can never disagree.
func (m ProfileMediaRetire) Allows(purpose string) bool {
	switch m {
	case ProfileMediaRetireBanner:
		return purpose == "BANNER"
	case ProfileMediaRetireAll:
		return purpose == "BANNER" || purpose == "AVATAR"
	default:
		return false
	}
}

// ParseProfileMediaRetire parses PROFILE_MEDIA_RETIRE: "" is off, anything outside off|banner|all is an error. Load uses
// it, and so does opsctl, which has no Cloud Run environment and reads the same variable from the operator's shell.
func ParseProfileMediaRetire(v string) (ProfileMediaRetire, error) {
	if v == "" {
		return ProfileMediaRetireOff, nil
	}
	m := ProfileMediaRetire(v)
	if !m.valid() {
		return "", fmt.Errorf("config: invalid PROFILE_MEDIA_RETIRE %q (want off|banner|all)", v)
	}
	return m, nil
}
