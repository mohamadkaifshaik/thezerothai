// Package limits centralizes the page-size clamp every list RPC must apply (ADR-0003 rule 5:
// "page_size (0 => 20, max 50, larger values are clamped)").
package limits

const (
	DefaultPageSize = 20
	MaxPageSize     = 50
)

// ClampPageSize maps a client-supplied page_size (proto int32) to the effective Firestore query Limit.
func ClampPageSize(requested int32) int {
	switch {
	case requested <= 0:
		return DefaultPageSize
	case requested > MaxPageSize:
		return MaxPageSize
	default:
		return int(requested)
	}
}
