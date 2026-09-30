package ratelimit

import (
	"context"
	"log/slog"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
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
	// opt-in, so a future read RPC is covered automatically); ReadBudgetExempt (never charged) and
	// ReadBudgetChargeOnly (charged, never rejected) are the only escape hatches and must stay empty unless
	// a comment explains each entry. Before next the call is rejected when the uid's
	// spent reads are >= the cap; after next (success or error) budget.FromContext(ctx).Reads() is charged.
	ReadBudget *DailyCap
	// ReadBudgetIP is the per-IP (IPv4 address or IPv6 /64, IPBudgetKey) daily read budget (D5 A3-A4). It
	// applies to ReadBudgetIPEnforce procedures (reserved and charged), ReadBudgetIPChargeOnly procedures
	// (charged, never rejected) and to a uid this instance has seen without a profile (A3: its non-exempt
	// calls reserve the IP key and a verified caller's profile-less call is charged to it). It never applies to
	// callers with a profile, who can share a carrier-grade-NAT address with thousands of others. Its hold per
	// call should be WithMaxCallReads(IPBudgetMaxCallReads) (every IP-keyed call reads at most 1 doc).
	ReadBudgetIP *DailyCap
	// ReadBudgetIPEnforce and ReadBudgetIPChargeOnly are the A4 sets (CheckHandleAvailability; CreateProfile).
	// Their union must equal the authn profile-exempt set (guard test, security L6).
	ReadBudgetIPEnforce    map[string]struct{}
	ReadBudgetIPChargeOnly map[string]struct{}
	// ReadBudgetExempt lists procedures the read budget does not cover. Must stay empty (guard test).
	ReadBudgetExempt map[string]struct{}
	// ReadBudgetChargeOnly lists procedures that are charged against the budget but never rejected by it
	// (CLAUDE.md rule 10: the right-to-delete and export paths must work for a user who has spent the day's
	// budget). Every entry needs a reason in the guard test's allowedReadBudgetChargeOnly. Their reads are
	// small and still bounded by the per-minute bucket.
	ReadBudgetChargeOnly map[string]struct{}
}

// LimitReadBudgetDaily is the limit_name / metadata["limit"] of a read budget rejection.
const LimitReadBudgetDaily = "read_budget_daily"

// LimitReadBudgetInflight is the limit_name / metadata["limit"] of a rejection by the in-flight hold alone
// (ADR-0010 D5 A1/A7): the budget is not spent, the client retries in RetryAfterInFlight.
const LimitReadBudgetInflight = "read_budget_inflight"

// ReadBudgetCovers reports whether the read budget applies to procedure. The apiserver guard test asserts
// it for every registered NO_SIDE_EFFECTS procedure.
func (c Config) ReadBudgetCovers(procedure string) bool {
	if c.ReadBudget == nil {
		return false
	}
	_, exempt := c.ReadBudgetExempt[procedure]
	return !exempt
}

// ReadBudgetEnforces reports whether the read budget can REJECT procedure: it covers it and it is not
// charge-only.
func (c Config) ReadBudgetEnforces(procedure string) bool {
	_, chargeOnly := c.ReadBudgetChargeOnly[procedure]
	return c.ReadBudgetCovers(procedure) && !chargeOnly
}

// RetryAfterInFlight is the retry_after of a read budget rejection caused only by the single-flight guard
// (another call is in flight near the cap), not by an exhausted budget.
const RetryAfterInFlight = time.Second

// ProfileLessMarkTTL is how long a uid seen without a profile stays marked (D5 A3); it is also the
// retry_after of an IP-budget rejection of a marked uid, because the mark may be stale.
const ProfileLessMarkTTL = 10 * time.Minute

// IPBudgetKey normalises a client IP into the key of every IP-keyed limiter (D5 A5): the canonical netip
// string of an IPv4 address, or of the /64 prefix of an IPv6 address (a single host rotates freely inside
// its /64; zones are dropped, IPv4-mapped addresses are unmapped). It never returns raw input: ok is false
// when ip does not parse, and the key is at most 43 bytes.
func IPBudgetKey(ip string) (key string, ok bool) {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return "", false
	}
	addr = addr.WithZone("").Unmap()
	if addr.Is4() {
		return addr.String(), true
	}
	p, err := addr.Prefix(64)
	if err != nil {
		return "", false
	}
	return p.String(), true
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
	// A3: uids this instance has seen without a profile (per-instance, TTL ProfileLessMarkTTL, LRU-bounded;
	// reuses cache.LRU, no new limiter type).
	profileLess := cache.New[string, struct{}](maxTrackedDailyKeys, ProfileLessMarkTTL)
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (resp connect.AnyResponse, err error) {
			procedure := req.Spec().Procedure
			result := ResolveClientIP(req.Header(), cfg.TrustedProxyHops)
			// M2: xff_hops/via_hosting ride the request's existing logger.RequestInfo pointer so mw.Logging's
			// one INFO-level line per request carries them — the previous approach (a separate DebugContext
			// log call here) never surfaced in prod, since Cloud Run's default log level is Info and Debug
			// lines are dropped before they're ever written (the exact defect this replaces).
			if info := logger.RequestInfoFromContext(ctx); info != nil {
				info.XFFHops = result.Hops
				info.ViaHosting = result.ViaHosting
			}
			// A5: every IP-keyed structure uses the canonical key (IPv4, or IPv6 /64); no key without one.
			ipKey, hasIP := IPBudgetKey(result.IP)

			if cfg.IP != nil && hasIP {
				if ok, wait := cfg.IP.Allow(ipKey); !ok {
					return nil, rateLimited(wait)
				}
			}

			limiter := cfg.Default
			if cfg.PerProcedure != nil {
				if l, ok := cfg.PerProcedure[procedure]; ok {
					limiter = l
				}
			}
			uid, hasUID := authn.UIDFromContext(ctx)
			if limiter != nil && hasUID {
				if allowed, wait := limiter.Allow(uid); !allowed {
					return nil, rateLimited(wait)
				}
			}

			// ADR-0010 D5 read budget. Keys: the uid (A6: charge-only for account operations) and the IP key
			// (A3-A4): enforced on CheckHandleAvailability and on the non-exempt calls of a marked uid,
			// charge-only on CreateProfile. Rejected before any Firestore read (this runs before account status).
			var budgetKeys []budgetKey
			if cfg.ReadBudgetCovers(procedure) {
				_, chargeOnly := cfg.ReadBudgetChargeOnly[procedure]
				if hasUID {
					budgetKeys = append(budgetKeys, budgetKey{cap: cfg.ReadBudget, key: uid, kind: "uid", chargeOnly: chargeOnly})
				}
				if cfg.ReadBudgetIP != nil && hasIP {
					_, enforce := cfg.ReadBudgetIPEnforce[procedure]
					_, ipChargeOnly := cfg.ReadBudgetIPChargeOnly[procedure]
					marked := false
					if hasUID && !enforce && !ipChargeOnly {
						_, marked = profileLess.Get(uid)
					}
					switch {
					case enforce:
						budgetKeys = append(budgetKeys, budgetKey{cap: cfg.ReadBudgetIP, key: ipKey, kind: "ip", chargeOnly: chargeOnly})
					case ipChargeOnly:
						budgetKeys = append(budgetKeys, budgetKey{cap: cfg.ReadBudgetIP, key: ipKey, kind: "ip", chargeOnly: true})
					case marked:
						budgetKeys = append(budgetKeys, budgetKey{cap: cfg.ReadBudgetIP, key: ipKey, kind: "ip", chargeOnly: chargeOnly, dailyRetry: ProfileLessMarkTTL})
					}
				}
			}
			for i := range budgetKeys {
				k := &budgetKeys[i]
				if k.chargeOnly {
					continue // charged after the call, never rejected
				}
				ok, spent := k.cap.Reserve(k.key)
				if !ok {
					// Free the in-flight slots already taken by earlier keys of this call (0 units).
					for _, taken := range budgetKeys[:i] {
						if taken.reserved {
							taken.cap.Release(taken.key, 0)
						}
					}
					return nil, rejectReadBudget(ctx, budgetKeys, i, spent)
				}
				k.reserved = true
			}
			// M1/m1: settle in a defer so the reads already spent are charged and the in-flight slot is freed
			// on every exit, including a panic unwinding to mw.Recover (which sits outside this interceptor).
			// It reads the counter at exit, so the account-status interceptor's reads are included
			// (mw.Logging, which owns the counter, is outermost).
			completed := false
			defer func() {
				s := settlement{keys: budgetKeys, procedure: procedure, uid: uid, ipKey: ipKey, hasUID: hasUID, hasIP: hasIP}
				settleReadBudget(ctx, cfg, profileLess, s, completed && err == nil)
			}()

			if cfg.DailyCaps != nil && hasUID {
				if named, ok := cfg.DailyCaps[procedure]; ok && named.Cap != nil {
					if !named.Cap.Allow(uid) {
						return nil, rejectDaily(ctx, named.Name, named.Cap)
					}
				}
			}

			resp, err = next(ctx, req)
			completed = true
			return resp, err
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

// budgetKey is one read-budget counter a call is checked and charged against.
type budgetKey struct {
	cap        *DailyCap
	key        string
	kind       string // "uid" or "ip": log-only (A7), never sent to the client
	chargeOnly bool
	reserved   bool          // Reserve admitted this call, so Release (not Charge) settles it
	dailyRetry time.Duration // retry_after of a daily rejection when not the time to IST midnight (A3)
}

// settlement is what settleReadBudget needs about the finished call.
type settlement struct {
	keys      []budgetKey
	procedure string
	uid       string
	ipKey     string
	hasUID    bool
	hasIP     bool
}

// settleReadBudget runs after the call on every exit path. It charges the reads the call actually spent to
// every key (releasing the in-flight slot of the reserved ones), applies A3 (a verified caller without a
// profile is charged to its IP key unless that key was already in play, and its uid is marked) and clears the
// mark after a successful CreateProfile (a charge-only IP procedure). It logs the A7 fields, and WARNs when a
// held call read more than its M, because the A1 bound assumes that never happens.
func settleReadBudget(ctx context.Context, cfg Config, profileLess *cache.LRU[string, struct{}], s settlement, succeeded bool) {
	reads := budget.FromContext(ctx).Reads()
	keys := s.keys
	for _, k := range keys {
		if !k.reserved {
			k.cap.Charge(k.key, reads)
			continue
		}
		k.cap.Release(k.key, reads)
		if m := k.cap.MaxCallReads(); m > 0 && reads > m {
			slog.Default().WarnContext(ctx, "read_budget_over_max", "read_budget_over_max", true,
				"key", k.kind, "reads", reads, "max_call_reads", m, "rpc", s.procedure, "uid_hash", logger.HashUID(s.uid))
		}
	}
	if info := logger.RequestInfoFromContext(ctx); info != nil && info.ProfileRequired && s.hasIP && cfg.ReadBudgetIP != nil && cfg.ReadBudgetCovers(s.procedure) {
		hasIPKey := false
		for _, k := range keys {
			hasIPKey = hasIPKey || k.kind == "ip"
		}
		if !hasIPKey {
			cfg.ReadBudgetIP.Charge(s.ipKey, reads)
			keys = append(keys[:len(keys):len(keys)], budgetKey{cap: cfg.ReadBudgetIP, key: s.ipKey, kind: "ip", chargeOnly: true})
		}
		if s.hasUID {
			profileLess.Set(s.uid, struct{}{})
		}
		info.Set("profile_required", true)
	}
	if _, createsProfile := cfg.ReadBudgetIPChargeOnly[s.procedure]; createsProfile && succeeded && s.hasUID {
		profileLess.Delete(s.uid)
	}
	logBudgetSpends(ctx, keys)
}

// logBudgetSpends sets read_budget_spent (always the uid's spend) and read_budget_ip_spent (the IP key's, when
// that key was reserved, charged or rejected) on the request's log line. The IP address itself is never logged.
func logBudgetSpends(ctx context.Context, keys []budgetKey) {
	info := logger.RequestInfoFromContext(ctx)
	if info == nil {
		return
	}
	for _, k := range keys {
		if k.kind == "uid" {
			info.Set("read_budget_spent", k.cap.Spent(k.key))
		} else {
			info.Set("read_budget_ip_spent", k.cap.Spent(k.key))
		}
	}
}

func rateLimited(wait time.Duration) error {
	return apierr.ToConnect(apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED,
		"too many requests, please slow down",
	).WithRetryAfter(wait))
}

// rejectDaily is the RATE_LIMITED rejection of a daily call counter: retry_after is the time to the next
// IST midnight, metadata["limit"] and the request log's limit_name carry name.
func rejectDaily(ctx context.Context, name string, c *DailyCap) error {
	return rejectWith(ctx, name, quota.UntilNextDay(c.now()))
}

// rejectReadBudget is the RATE_LIMITED rejection of the read budget (ADR-0010 D5). The client always sees
// limit=read_budget_daily, or read_budget_inflight when only the in-flight hold (A1) rejected; the request log
// additionally gets read_budget_key (uid or ip, A7), the spends (logBudgetSpends) and, for the hold,
// read_budget_inflight. retry_after is 1 s for the hold, else k.dailyRetry when set (a marked uid's IP budget,
// A3) or the time to IST midnight. keys[:tripped+1] are the keys Reserve looked at.
func rejectReadBudget(ctx context.Context, keys []budgetKey, tripped int, spent int64) error {
	k := &keys[tripped]
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.Set("read_budget_key", k.kind)
	}
	logBudgetSpends(ctx, keys[:tripped+1])
	if k.cap.IsTransient(spent) {
		logger.SetRequestField(ctx, "read_budget_inflight", k.cap.Inflight(k.key))
		return rejectWith(ctx, LimitReadBudgetInflight, RetryAfterInFlight)
	}
	if k.dailyRetry > 0 {
		logger.SetRequestField(ctx, "profile_required", true)
		return rejectWith(ctx, LimitReadBudgetDaily, k.dailyRetry)
	}
	return rejectWith(ctx, LimitReadBudgetDaily, quota.UntilNextDay(k.cap.now()))
}

func rejectWith(ctx context.Context, name string, retryAfter time.Duration) error {
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.LimitName = name
	}
	return apierr.ToConnect(apierr.New(
		connect.CodeResourceExhausted,
		commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED,
		"too many requests, please slow down",
	).WithMeta("limit", name).WithRetryAfter(retryAfter))
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
	// A5: the chosen entry may be garbage (a caller-supplied left entry, or an operator override that lands
	// on one). Fall back to the rightmost entry, which the Google front end appended; if that does not parse
	// either there is no IP (as without X-Forwarded-For, which happens only locally).
	if _, err := netip.ParseAddr(parts[idx]); err != nil {
		idx = hops - 1
		viaHosting = false
		if _, err := netip.ParseAddr(parts[idx]); err != nil {
			return ClientIPResult{Hops: hops}
		}
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
