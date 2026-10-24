package config

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
