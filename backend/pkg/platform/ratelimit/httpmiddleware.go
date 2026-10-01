package ratelimit

import (
	"net/http"
	"strconv"
)

// PreAuthIPMiddleware is plain net/http middleware (not a Connect interceptor) that rate-limits by client
// IP *before* the request reaches any Connect interceptor — in particular before authn.AppCheckInterceptor
// and authn.IDTokenInterceptor, which do real JWT-verification work (M1, docs/reviews/security-audit-v0.1.0.md: "the
// per-IP rate limit runs after ID-token verification, so it can't throttle unauthenticated floods").
// Floods of garbage/expired tokens are now rejected here, before they cost any JWT-verify CPU or even reach
// the Connect handler chain, bounded only before by Cloud Run's own max-instances cap.
//
// This is deliberately generous and coarse: a single shared per-IP budget meant only to blunt a flood, not
// the fine-grained per-uid/per-procedure limiting ratelimit.Interceptor already does for authenticated
// traffic inside the Connect chain (a separate *Limiter instance — see apiserver.Build — so one request is
// never double-charged against the same bucket). exemptPaths (e.g. "/health", "/healthz") is checked
// against the *normalized* request path, i.e. the one the wrapped handler will see (after any
// http.StripPrefix), so both the bare and the Firebase Hosting `/api/**`-prefixed routes exempt correctly
// as long as this middleware itself is wrapped at the same point apiserver.Build wraps it (before the
// prefix split, per its doc comment).
//
// A request whose IP cannot be resolved (no X-Forwarded-For at all — never happens behind Cloud Run, but
// can in local dev/tests with no proxy in front) is let through unmetered, matching Interceptor's existing
// behavior for the same case.
func PreAuthIPMiddleware(limiter *Limiter, trustedProxyHops int, exemptPaths map[string]struct{}) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		if limiter == nil {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, exempt := exemptPaths[r.URL.Path]; exempt {
				next.ServeHTTP(w, r)
				return
			}
			// D5 A5: the canonical key (IPv4, or IPv6 /64), so rotating addresses inside a /64 shares one bucket
			// and a garbage X-Forwarded-For entry never becomes a key.
			if ip, ok := IPBudgetKey(ResolveClientIP(r.Header, trustedProxyHops).IP); ok {
				if allowed, wait := limiter.Allow(ip); !allowed {
					w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
					http.Error(w, "too many requests, please slow down", http.StatusTooManyRequests)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
