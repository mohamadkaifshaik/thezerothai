// Package limits centralizes the page-size clamp every list RPC must apply (ADR-0003 rule 5:
// "page_size (0 => 20, max 50, larger values are clamped)") and the request-body size cap every Connect
// handler applies (2026-09-27 security audit, informational finding).
package limits

const (
	DefaultPageSize = 20
	MaxPageSize     = 50

	// MaxRequestBytes caps a single Connect request body: passed to connect.WithReadMaxBytes on every
	// service handler (limits the *decompressed* size — guards a gzip-bomb: a tiny compressed body that
	// inflates to something huge) and to http.MaxBytesHandler wrapping the mux (limits the raw bytes read
	// off the socket before any decompression). No RPC in this API legitimately needs anywhere near 256
	// KiB (posts are capped far smaller; media bytes never pass through the API — CLAUDE.md rule 7), so
	// this is generous headroom, not a tuned-per-RPC limit. See backend/internal/apiserver.Build.
	MaxRequestBytes = 256 * 1024
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
