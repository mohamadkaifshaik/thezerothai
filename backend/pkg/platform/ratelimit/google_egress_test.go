package ratelimit

import (
	"net/netip"
	"testing"
)

func TestIsGoogleEgressIP_KnownGoogleAddress(t *testing.T) {
	// Inside 66.249.64.0/19 — the range the 2026-09-27 security audit directly observed live as Cloud
	// Run's httpRequest.remoteIp for a Firebase Hosting-proxied request.
	if !isGoogleEgressIP("66.249.64.5") {
		t.Error("expected 66.249.64.5 (observed Hosting egress range) to be recognized")
	}
}

func TestIsGoogleEgressIP_OrdinaryPublicIP(t *testing.T) {
	for _, ip := range []string{"1.2.3.4", "9.9.9.9", "203.0.113.7"} {
		if isGoogleEgressIP(ip) {
			t.Errorf("isGoogleEgressIP(%q) = true, want false (not a Google-operated range)", ip)
		}
	}
}

func TestIsGoogleEgressIP_MalformedInput(t *testing.T) {
	for _, in := range []string{"", "not-an-ip", "999.999.999.999", "  "} {
		if isGoogleEgressIP(in) {
			t.Errorf("isGoogleEgressIP(%q) = true, want false", in)
		}
	}
}

// TestIsGoogleEgressIP_ExcludesCustomerAssignableRanges is the property googleEgressCIDRs's doc comment
// promises: Google Cloud hands these specific ranges out to paying customers (any attacker with a
// free-tier GCE VM can get an address here), so treating them as "one of our own proxies" would let that
// attacker spoof an X-Forwarded-For entry to our left and have it trusted. Addresses below were confirmed
// (2026-09-27) to fall inside a live https://www.gstatic.com/ipranges/cloud.json prefix nested under a
// broader goog.json prefix that would otherwise look Google-owned.
func TestIsGoogleEgressIP_ExcludesCustomerAssignableRanges(t *testing.T) {
	customerAssignable := []string{
		"34.1.208.5",    // under 34.0.0.0/15 (goog.json), but 34.1.208.0/20 is a cloud.json customer range
		"35.185.128.5",  // under 35.184.0.0/13 (goog.json), but 35.185.128.0/19 is a cloud.json customer range
		"104.155.192.5", // under 104.154.0.0/15 (goog.json), but 104.155.192.0/19 is a cloud.json customer range
		"130.211.240.5", // under 130.211.0.0/16 (goog.json), but 130.211.240.0/20 is a cloud.json customer range
	}
	for _, ip := range customerAssignable {
		if isGoogleEgressIP(ip) {
			t.Errorf("isGoogleEgressIP(%q) = true, want false: this is a Google Cloud customer-assignable address, trusting it as a Hosting egress IP would let an attacker who rents it spoof X-Forwarded-For", ip)
		}
	}
}

// TestGoogleEgressCIDRs_NoPrivateRanges guards against a copy/paste mistake ever adding an RFC1918 (or
// similar) private range to the allowlist, which would make every internal/test caller from that range
// look like "our own proxy".
func TestGoogleEgressCIDRs_NoPrivateRanges(t *testing.T) {
	for _, c := range googleEgressCIDRs {
		p := netip.MustParsePrefix(c)
		if p.Addr().IsPrivate() || p.Addr().IsLoopback() || p.Addr().IsLinkLocalUnicast() {
			t.Errorf("googleEgressCIDRs contains a private/loopback/link-local prefix: %s", c)
		}
	}
}

func TestParsePrefixes_PanicsOnInvalidCIDR(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected parsePrefixes to panic on an invalid CIDR")
		}
	}()
	parsePrefixes([]string{"not-a-cidr"})
}
