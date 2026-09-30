package ratelimit

import (
	"context"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Config wires the interceptor: PerProcedure overrides the per-uid Default limiter for specific hot
// RPCs (home timeline, CheckHandleAvailability, likes per ADR-0006 §3); IP is checked in addition to the
// per-uid limit.
type Config struct {
	Default      *Limiter
	PerProcedure map[string]*Limiter
	IP           *Limiter

	// TrustedProxyHops, left at the default (<=1), lets ResolveClientIP's Google-egress detection decide
	// whether to count one extra hop in from the right (see its doc comment). Set above 1 only as an
	// explicit operator override for a topology that heuristic does not fit — e.g. a proxy hop we have
	// since added in front of Cloud Run that ResolveClientIP cannot recognize by IP. Configurable via
	// config.Config.TrustedProxyHops (env TRUSTED_PROXY_HOPS).
	TrustedProxyHops int

	// DailyCaps applies an additional per-uid-per-instance daily cap (ADR-0008 D7/T4: "an extension of the
	// existing limiter... don't write a second limiter") on top of the per-minute limiters above, keyed by
	// fully-qualified Connect procedure. Checked after PerProcedure/Default so a burst is still rejected by
	// the per-minute bucket first; a rejection here sets logger.RequestInfo.LimitName so mw.Logging's
	// per-request line can be queried by limiter (e.g. "graph_list_daily").
	DailyCaps map[string]NamedDailyCap

	// ReadBudget is the per-uid daily Firestore read budget (ADR-0010 D5, T3): the same DailyCap type as
	// DailyCaps, counting reads instead of calls. It covers EVERY procedure (there is no per-procedure
	// opt-in, so a future read RPC is covered automatically); ReadBudgetExempt is the only escape hatch and
	// must stay empty unless a comment explains each entry. Before next the call is rejected when the uid's
	// spent reads are >= the cap; after next (success or error) budget.FromContext(ctx).Reads() is charged.
	ReadBudget *DailyCap
	// ReadBudgetIP is the per-IP (IPv4 address or IPv6 /64) daily read budget. Refinement 1 of D5: it is
	// enforced and charged only for procedures in ProfileExempt (callers there may have no profile), never
	// for callers with a profile, who can share a carrier-grade-NAT address with thousands of others.
	ReadBudgetIP *DailyCap
	// ProfileExempt is the authn.ProfileExemptProcedures set; it scopes ReadBudgetIP.
	ProfileExempt map[string]struct{}
	// ReadBudgetExempt lists procedures the read budget does not cover. Must stay empty (guard test).
	ReadBudgetExempt map[string]struct{}
}

// LimitReadBudgetDaily is the limit_name / metadata["limit"] of a read budget rejection.
const LimitReadBudgetDaily = "read_budget_daily"

// ReadBudgetCovers reports whether the read budget applies to procedure. The apiserver guard test asserts
// it for every registered NO_SIDE_EFFECTS procedure.
func (c Config) ReadBudgetCovers(procedure string) bool {
	if c.ReadBudget == nil {
		return false
	}
	_, exempt := c.ReadBudgetExempt[procedure]
	return !exempt
}

// IPBudgetKey normalises a client IP into its read-budget key: an IPv4 address as is, an IPv6 address as
// its /64 prefix (D5 refinement 2: a single host rotates freely inside its /64). Unparseable input is
// returned unchanged.
func IPBudgetKey(ip string) string {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return ip
	}
	addr = addr.Unmap()
	if addr.Is4() {
		return addr.String()
	}
	p, err := addr.Prefix(64)
	if err != nil {
		return ip
	}
	return p.String()
}

// NamedDailyCap pairs a DailyCap with the name it reports in logs/metadata when it rejects a call.
type NamedDailyCap struct {
	Name string
	Cap  *DailyCap
}

// Interceptor enforces per-uid and per-IP token buckets. Must run after authn.IDTokenInterceptor so a
// verified uid is available; falls back to IP-only limiting if somehow no uid is present.
//
// This is the *inside-the-Connect-chain* limiter (ADR-0006 §2/§3): it still does real JWT-verify work
// upstream of it (App Check + ID token) before this ever runs. PreAuthIPMiddleware (httpmiddleware.go) is
// the separate, coarser *pre-auth* limiter added for M1 (docs/reviews/security-audit-v0.1.0.md) that runs as plain
// net/http middleware in front of the whole Connect handler, before any of that verification work happens
// — the two are independent Limiter instances (see apiserver.Build) so a request is never double-charged
// against the same bucket.
func Interceptor(cfg Config) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			result := ResolveClientIP(req.Header(), cfg.TrustedProxyHops)
			// M2: xff_hops/via_hosting ride the request's existing logger.RequestInfo pointer so mw.Logging's
			// one INFO-level line per request carries them — the previous approach (a separate DebugContext
			// log call here) never surfaced in prod, since Cloud Run's default log level is Info and Debug
			// lines are dropped before they're ever written (the exact defect this replaces).
			if info := logger.RequestInfoFromContext(ctx); info != nil {
				info.XFFHops = result.Hops
				info.ViaHosting = result.ViaHosting
			}

			if cfg.IP != nil && result.IP != "" {
				if ok, wait := cfg.IP.Allow(result.IP); !ok {
					return nil, rateLimited(wait)
				}
			}

			limiter := cfg.Default
			if cfg.PerProcedure != nil {
				if l, ok := cfg.PerProcedure[req.Spec().Procedure]; ok {
					limiter = l
				}
			}
			uid, hasUID := authn.UIDFromContext(ctx)
			if limiter != nil && hasUID {
				if allowed, wait := limiter.Allow(uid); !allowed {
					return nil, rateLimited(wait)
				}
			}

			// ADR-0010 D5 read budget: keys are the uid and, on profile-exempt procedures only, the client IP
			// (/64 for IPv6). Rejected before any Firestore read (this runs before account status).
			var budgetKeys []budgetKey
			if cfg.ReadBudgetCovers(req.Spec().Procedure) {
				if hasUID {
					budgetKeys = append(budgetKeys, budgetKey{cfg.ReadBudget, uid})
				}
				if _, exempt := cfg.ProfileExempt[req.Spec().Procedure]; exempt && cfg.ReadBudgetIP != nil && result.IP != "" {
					budgetKeys = append(budgetKeys, budgetKey{cfg.ReadBudgetIP, IPBudgetKey(result.IP)})
				}
			}
			for _, k := range budgetKeys {
				if !k.cap.Reserve(k.key) {
					return nil, rejectDaily(ctx, LimitReadBudgetDaily, k.cap, k.cap.Spent(k.key))
				}
			}

			if cfg.DailyCaps != nil && hasUID {
				if named, ok := cfg.DailyCaps[req.Spec().Procedure]; ok && named.Cap != nil {
					if !named.Cap.Allow(uid) {
						return nil, rejectDaily(ctx, named.Name, named.Cap, -1)
					}
				}
			}

			resp, err := next(ctx, req)

			// Charge the reads actually spent (interceptor reads included: mw.Logging is outermost), on
			// success and error alike.
			if len(budgetKeys) > 0 {
				reads := budget.FromContext(ctx).Reads()
				var spent int64
				for i, k := range budgetKeys {
					k.cap.Charge(k.key, reads)
					if i == 0 {
						spent = k.cap.Spent(k.key)
					}
				}
				if info := logger.RequestInfoFromContext(ctx); info != nil {
					info.Set("read_budget_spent", spent)
				}
			}
			return resp, err
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

type budgetKey struct {
	cap *DailyCap
	key string
}

func rateLimited(wait time.Duration) error {
	return apierr.ToConnect(apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED,
		"too many requests, please slow down",
	).WithRetryAfter(wait))
}

// rejectDaily is the RATE_LIMITED rejection of a daily counter (ADR-0010 D5): retry_after is the time to
// the next IST midnight, metadata["limit"] and the request log's limit_name carry name. spent >= 0 is also
// logged as read_budget_spent.
func rejectDaily(ctx context.Context, name string, c *DailyCap, spent int64) error {
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.LimitName = name
		if spent >= 0 {
			info.Set("read_budget_spent", spent)
		}
	}
	return apierr.ToConnect(apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED,
		"too many requests, please slow down",
	).WithMeta("limit", name).WithRetryAfter(quota.UntilNextDay(c.now())))
}

// ClientIPResult is what ResolveClientIP found, split into the trusted client IP plus metadata that is
// safe to log (M2): Hops and ViaHosting are a count and a bool, never an address, and are meant to be
// attached to logger.RequestInfo so mw.Logging's one-line-per-request log can carry xff_hops/via_hosting
// without ever logging an IP (PII; see ratelimit.Interceptor).
type ClientIPResult struct {
	IP         string
	Hops       int
	ViaHosting bool
}

// ResolveClientIP extracts the caller's real IP from X-Forwarded-For (ADR-0006 §3, as amended by the
// 2026-09-27 security audit's M2 finding).
//
// Facts about our two ingress paths (confirmed live by that audit):
//   - Mobile calls Cloud Run directly: Google Front End (GFE) appends exactly one entry, the real client
//     IP, at the *rightmost* position of X-Forwarded-For. Any entries to its left are supplied by the
//     caller and are trivially spoofable — never trusted.
//   - Web calls go through the Firebase Hosting `/api/**` rewrite (firebase.json): Hosting is itself a
//     Google-run reverse proxy sitting in front of Cloud Run, so by that same "rightmost entry is appended
//     by whoever just connected to us, and that append can't be forged by anything upstream of it" logic,
//     GFE (fronting Cloud Run) appends *Hosting's own egress IP* as the new rightmost entry — a real
//     Google address (the audit observed 66.249.x.x live) — and the entry Hosting itself appended one
//     position to the left of that is the real browser IP, exactly as non-spoofable as the direct-path
//     case, just one hop further in.
//
// So: the rightmost entry is always trustworthy by construction (it is never something the original
// caller could have supplied — only the proxy immediately in front of us appends it), and the only open
// question is whether that proxy is *our own infrastructure* (Hosting) rather than the end user.
// isGoogleEgressIP answers that, and — critically — its allowlist deliberately excludes Google Cloud's
// customer-assignable ranges (googleEgressCIDRs' doc comment), so a positive match cannot be an address an
// attacker rented for themselves; only then do we step one entry to the left.
//
// trustedProxyHops, if > 1, is an explicit operator override (config.Config.TrustedProxyHops /
// TRUSTED_PROXY_HOPS) that skips the detection above and always counts that many entries in from the
// right — an escape hatch for a future topology this heuristic does not fit. Left at the default (<=1),
// the detection above runs; when the rightmost entry is not recognized as Google's own, this is exactly
// the original "trust the rightmost entry" behavior (safe default when offline evidence is inconclusive).
func ResolveClientIP(h http.Header, trustedProxyHops int) ClientIPResult {
	xff := h.Get("X-Forwarded-For")
	if xff == "" {
		return ClientIPResult{}
	}
	parts := strings.Split(xff, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	hops := len(parts)
	idx := hops - 1

	var viaHosting bool
	switch {
	case trustedProxyHops > 1:
		// Explicit operator override: ignore the heuristic, count a fixed number of hops in from the right.
		idx = hops - trustedProxyHops
		if idx < 0 {
			idx = 0
		}
	case isGoogleEgressIP(parts[idx]) && idx > 0:
		viaHosting = true
		idx--
	}
	return ClientIPResult{IP: parts[idx], Hops: hops, ViaHosting: viaHosting}
}

// ClientIP is ResolveClientIP for callers that only need the IP string.
func ClientIP(h http.Header, hops int) string {
	return ResolveClientIP(h, hops).IP
}

// XFFHopCount returns the number of comma-separated entries in X-Forwarded-For, or 0 if the header is
// absent. Safe to log on its own (a count, never an address).
func XFFHopCount(h http.Header) int {
	xff := h.Get("X-Forwarded-For")
	if xff == "" {
		return 0
	}
	return len(strings.Split(xff, ","))
}
