package ratelimit

import (
	"net/netip"
	"strings"
)

// googleEgressCIDRs lists IPv4 netblocks Google operates for its own edge/service infrastructure (Google
// Front End, Firebase Hosting egress, Googlebot/fetchers, Search, Gmail, etc.) — used by isGoogleEgressIP
// to recognize when the rightmost X-Forwarded-For entry is one of *our own* Google-run proxies rather than
// the real client (M2, ADR-0006 §3 amendment; see ResolveClientIP's doc comment for the full reasoning).
//
// Deliberately NOT the full published Google netblock list. Google Cloud (GCE / Cloud Run / GKE) hands out
// external IPs from a documented subset of that list to any paying customer — including an attacker who
// can provision a free/cheap VM and call our Cloud Run URL directly from it. Treating those ranges as "one
// of our own proxies" would let such an attacker put an arbitrary spoofed address one position to the left
// in X-Forwarded-For and have us trust it as the real client. So this list is:
//
//	(Google-owned prefixes, https://www.gstatic.com/ipranges/goog.json)
//	  MINUS (Google Cloud customer-assignable prefixes, https://www.gstatic.com/ipranges/cloud.json)
//
// i.e. Google-operated infrastructure only — verified (2026-09-27) to never overlap a customer-assignable
// range. The entry the 2026-09-27 security audit directly observed live as Cloud Run's
// httpRequest.remoteIp for a dev.dzeroth.com/api/** (Firebase Hosting) request is called out below; the
// rest is the same methodology applied to the remaining published ranges, so a Hosting egress IP on a
// range we have not personally observed is still recognized instead of silently falling through to the
// (safe, but un-fixed-M2) rightmost-entry default.
//
// A stale or incomplete list only produces false negatives here (an unrecognized Google egress IP falls
// back to the pre-existing "trust the rightmost entry" behavior) — never a false positive that would let a
// spoofed entry be trusted — so staleness is safe, not silent. Regenerate by fetching both files above and
// keeping goog.json prefixes that do not net.overlaps() any cloud.json prefix; see
// TestIsGoogleEgressIP_ExcludesCustomerAssignableRanges for the property this must keep holding.
var googleEgressCIDRs = []string{
	"8.8.4.0/24",
	"8.8.8.0/24",
	"34.3.0.0/23",
	"34.3.3.0/24",
	"34.3.4.0/24",
	"34.3.8.0/21",
	"34.3.16.0/20",
	"64.15.112.0/20",
	"64.233.160.0/19",
	"66.102.0.0/20",
	"66.249.64.0/19", // observed live: Cloud Run httpRequest.remoteIp for a dev.dzeroth.com/api/** (Hosting) request
	"70.32.128.0/19",
	"72.14.192.0/18",
	"74.114.24.0/21",
	"74.125.0.0/16",
	"104.237.160.0/19",
	"108.170.192.0/18",
	"108.177.0.0/17",
	"136.22.2.0/23",
	"136.22.4.0/23",
	"136.22.8.0/22",
	"136.22.160.0/20",
	"136.22.176.0/21",
	"136.22.184.0/23",
	"136.22.186.0/24",
	"136.23.39.0/24",
	"136.23.48.0/20",
	"136.120.0.0/22",
	"136.121.8.0/21",
	"136.124.0.0/15",
	"142.250.0.0/15",
	"152.238.0.0/16",
	"152.239.128.0/17",
	"162.120.128.0/17",
	"172.110.32.0/21",
	"172.217.0.0/16",
	"172.253.0.0/16",
	"173.194.0.0/16",
	"177.176.0.0/16",
	"177.178.0.0/15",
	"177.208.0.0/15",
	"179.67.0.0/17",
	"179.69.128.0/17",
	"179.193.128.0/17",
	"179.199.0.0/17",
	"186.242.0.0/17",
	"186.245.0.0/16",
	"187.78.0.0/17",
	"187.79.0.0/17",
	"187.126.128.0/17",
	"189.24.128.0/17",
	"189.48.0.0/16",
	"189.49.128.0/17",
	"189.70.0.0/15",
	"189.82.0.0/15",
	"189.105.128.0/17",
	"189.106.0.0/15",
	"191.0.128.0/17",
	"191.2.0.0/15",
	"191.40.128.0/17",
	"191.44.128.0/17",
	"191.45.128.0/17",
	"191.46.0.0/15",
	"191.212.0.0/15",
	"191.216.128.0/17",
	"191.218.0.0/17",
	"191.220.0.0/15",
	"192.104.160.0/23",
	"192.178.0.0/15",
	"193.186.4.0/24",
	"199.36.154.0/23",
	"199.36.156.0/24",
	"200.226.0.0/16",
	"207.223.160.0/20",
	"208.65.152.0/22",
	"208.68.108.0/22",
	"208.81.188.0/22",
	"208.117.224.0/19",
	"209.85.128.0/17",
	"216.58.192.0/19",
	"216.73.80.0/20",
	"216.239.32.0/19",
	"216.252.220.0/22",
}

var googleEgressPrefixes = parsePrefixes(googleEgressCIDRs)

func parsePrefixes(cidrs []string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, c := range cidrs {
		p, err := netip.ParsePrefix(c)
		if err != nil {
			// Only ever reachable if googleEgressCIDRs itself is hand-edited into invalid CIDRs — the
			// regeneration recipe above only ever emits valid ones. Fail loudly at package init (a startup
			// panic in a config-shaped data file, not a request path) rather than silently degrading to
			// "never recognizes any Hosting IP" for the rest of the process's life.
			panic("ratelimit: invalid entry in googleEgressCIDRs: " + c + ": " + err.Error())
		}
		out = append(out, p)
	}
	return out
}

// isGoogleEgressIP reports whether ip (a bare IPv4/IPv6 address, no port, as found in an
// X-Forwarded-For entry) falls within a netblock Google operates for its own edge/service
// infrastructure (see googleEgressCIDRs) rather than a customer-assignable Google Cloud range.
func isGoogleEgressIP(ip string) bool {
	addr, err := netip.ParseAddr(strings.TrimSpace(ip))
	if err != nil {
		return false
	}
	for _, p := range googleEgressPrefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}
