package ratelimit

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// Config wires the interceptor: PerProcedure overrides the per-uid Default limiter for specific hot
// RPCs (home timeline, CheckHandleAvailability, likes per ADR-0006 §3); IP is checked in addition to the
// per-uid limit.
type Config struct {
	Default      *Limiter
	PerProcedure map[string]*Limiter
	IP           *Limiter

	// TrustedProxyHops is how many comma-separated entries from the *right* of X-Forwarded-For to count
	// past to find the real client IP (see ClientIP). Defaults to 1 (the pre-existing, ADR-0006 §3
	// behavior: trust exactly one hop, appended by Google's front end / Firebase Hosting). Configurable via
	// config.Config.TrustedProxyHops (env TRUSTED_PROXY_HOPS) because the *actual* number of hops Firebase
	// Hosting -> Cloud Run adds in front of the real client IP has not been measured yet in dev — don't
	// guess it here; see the XFF hop-count debug log below, meant to help calibrate it.
	TrustedProxyHops int

	// Log, if non-nil, gets one DebugContext line per request with the X-Forwarded-For hop count (never the
	// IPs themselves — they're PII) so TrustedProxyHops can be calibrated from real dev traffic instead of
	// guessed. Optional so existing callers/tests that build a Config without a logger keep working.
	Log *slog.Logger
}

// Interceptor enforces per-uid and per-IP token buckets. Must run after authn.IDTokenInterceptor so a
// verified uid is available; falls back to IP-only limiting if somehow no uid is present.
func Interceptor(cfg Config) connect.UnaryInterceptorFunc {
	hops := cfg.TrustedProxyHops
	if hops < 1 {
		hops = 1
	}
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if cfg.Log != nil {
				cfg.Log.DebugContext(ctx, "xff hop count",
					"xff_hops", XFFHopCount(req.Header()),
					"trusted_proxy_hops", hops,
				)
			}
			if cfg.IP != nil {
				ip := ClientIP(req.Header(), hops)
				if ip != "" {
					if ok, wait := cfg.IP.Allow(ip); !ok {
						return nil, rateLimited(wait)
					}
				}
			}

			limiter := cfg.Default
			if cfg.PerProcedure != nil {
				if l, ok := cfg.PerProcedure[req.Spec().Procedure]; ok {
					limiter = l
				}
			}
			if limiter != nil {
				uid, ok := authn.UIDFromContext(ctx)
				if ok {
					if allowed, wait := limiter.Allow(uid); !allowed {
						return nil, rateLimited(wait)
					}
				}
			}
			return next(ctx, req)
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

func rateLimited(wait time.Duration) error {
	return apierr.ToConnect(apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED,
		"too many requests, please slow down",
	).WithRetryAfter(wait))
}

// ClientIP extracts the caller's IP from X-Forwarded-For, counting `hops` entries in from the right
// (ADR-0006 §3, amended): entries appended by our own infra (Firebase Hosting / Google's front end) sit at
// the right end and can't be spoofed by the client, unlike the leftmost, client-supplied entries — but
// through a hop like Firebase Hosting -> Cloud Run there may be more than one such trusted hop, so the
// rightmost entry (hops=1) is not always the real client IP. `hops` should equal exactly how many trusted
// proxy hops sit between the client and us; less than 1 is treated as 1 (the original, always-safe
// behavior: never read a client-supplied entry).
func ClientIP(h http.Header, hops int) string {
	xff := h.Get("X-Forwarded-For")
	if xff == "" {
		return ""
	}
	if hops < 1 {
		hops = 1
	}
	parts := strings.Split(xff, ",")
	idx := len(parts) - hops
	if idx < 0 {
		idx = 0
	}
	return strings.TrimSpace(parts[idx])
}

// XFFHopCount returns the number of comma-separated entries in X-Forwarded-For, or 0 if the header is
// absent. It is safe to log (a count, not an address — never PII): the intended use is calibrating
// TRUSTED_PROXY_HOPS from real traffic in dev, per request, without ever logging an IP.
func XFFHopCount(h http.Header) int {
	xff := h.Get("X-Forwarded-For")
	if xff == "" {
		return 0
	}
	return len(strings.Split(xff, ","))
}
