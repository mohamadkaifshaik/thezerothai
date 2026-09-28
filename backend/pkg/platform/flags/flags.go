// Package flags implements the Phase 1 server feature-flag pattern (ADR-0008 D6): every flag is an env
// var on the `api` Cloud Run service, 0 Firestore reads, mirrored to clients through
// IdentityService.GetMeResponse.enabled_features. The server is always authoritative — a guarded RPC
// checks the flag in its own service layer (never a shared interceptor, since only that module knows
// which of its RPCs are guarded) and returns FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED when off
// for the caller.
//
// Per feature <NAME> (upper snake case in env, lower snake case on the wire, e.g. FEATURE_GRAPH <-> "graph"):
//   - FEATURE_<NAME> = off | allowlist | percent | on (default off); any other value fails startup.
//   - FEATURE_<NAME>_ALLOWLIST = comma-separated uids (a Terraform variable, not a secret). Applies in both
//     allowlist and percent modes, so allowlisted uids stay on while a percentage rollout ramps.
//   - FEATURE_<NAME>_PERCENT = 0-100. Bucket = fnv32a(name + ":" + uid) % 100, salted with the flag's own
//     name so two different flags never share the same cohort of uids.
//
// Retirement (ADR-0008 D6): once a flag reaches "on" and its env vars are removed, Registry.EnabledFeatures
// must keep reporting the name as enabled (via a Retired flag entry, see NewRetired) until the minimum
// supported client version no longer reads it. Never reuse a retired name for a different feature.
package flags

import (
	"fmt"
	"hash/fnv"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Mode is one of the four rollout stages for a single flag.
type Mode string

const (
	Off       Mode = "off"
	Allowlist Mode = "allowlist"
	Percent   Mode = "percent"
	On        Mode = "on"
)

func (m Mode) valid() bool {
	switch m {
	case Off, Allowlist, Percent, On:
		return true
	default:
		return false
	}
}

// Spec is one flag's fully-resolved configuration, loaded once at startup.
type Spec struct {
	// Name is the wire (client-facing) name, lower_snake_case, e.g. "graph". This is also the salt for the
	// percent-mode bucket hash, so two flags never share a cohort (ADR-0008 D6, "changed vs plan").
	Name string
	Mode Mode
	// Allowlist applies in both Allowlist and Percent modes.
	Allowlist map[string]struct{}
	// Percent is 0-100, only meaningful in Percent mode.
	Percent int
	// retired marks a flag that has reached 100% rollout and had its env vars removed, but must keep
	// reporting "enabled" for every caller until old clients stop reading GetMe.enabled_features for it
	// (ADR-0008 D6 retirement rule). Set via NewRetired, never by parsing env.
	retired bool
}

// NewRetired builds a Spec for a flag that always reports enabled, regardless of env vars (ADR-0008 D6
// retirement rule). Use this in place of LoadSpec once a flag has been fully rolled out and its env vars
// have been removed from Terraform.
func NewRetired(wireName string) Spec {
	return Spec{Name: wireName, Mode: On, retired: true}
}

// enabledFor reports whether the flag is on for uid.
func (s Spec) enabledFor(uid string) bool {
	if s.retired {
		return true
	}
	switch s.Mode {
	case On:
		return true
	case Off:
		return false
	case Allowlist:
		_, ok := s.Allowlist[uid]
		return ok
	case Percent:
		if _, ok := s.Allowlist[uid]; ok {
			return true
		}
		return bucket(s.Name, uid) < s.Percent
	default:
		return false
	}
}

// bucket is fnv32a(name + ":" + uid) % 100 (ADR-0008 D6): deterministic per uid, independent per flag name.
func bucket(name, uid string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(name + ":" + uid))
	return int(h.Sum32() % 100)
}

// LoadSpec reads FEATURE_<envName>[_ALLOWLIST|_PERCENT] from the environment. envName is the upper
// snake-case env-var suffix (e.g. "GRAPH"); wireName is the lower_snake_case client-facing name (e.g.
// "graph"). defaultMode is used when FEATURE_<envName> is unset. Fails fast (never silently defaults to
// on) on an invalid mode or an out-of-range percent, per the plan's acceptance criteria.
func LoadSpec(envName, wireName string, defaultMode Mode) (Spec, error) {
	modeStr := getenv("FEATURE_"+envName, string(defaultMode))
	mode := Mode(strings.TrimSpace(modeStr))
	if !mode.valid() {
		return Spec{}, fmt.Errorf("flags: invalid FEATURE_%s %q (want off|allowlist|percent|on)", envName, modeStr)
	}

	allow := map[string]struct{}{}
	for _, uid := range splitCSV(os.Getenv("FEATURE_" + envName + "_ALLOWLIST")) {
		allow[uid] = struct{}{}
	}

	percent := 0
	if v := os.Getenv("FEATURE_" + envName + "_PERCENT"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 100 {
			return Spec{}, fmt.Errorf("flags: invalid FEATURE_%s_PERCENT %q (want an integer 0-100)", envName, v)
		}
		percent = n
	}

	return Spec{Name: wireName, Mode: mode, Allowlist: allow, Percent: percent}, nil
}

// Registry answers "is <name> enabled for <uid>" for every flag loaded at startup (0 reads: everything is
// resolved from the Spec values captured at process start).
type Registry struct {
	specs map[string]Spec
}

// NewRegistry builds a Registry from a fixed set of specs (one per LoadSpec/NewRetired call in main.go).
func NewRegistry(specs ...Spec) *Registry {
	m := make(map[string]Spec, len(specs))
	for _, s := range specs {
		m[s.Name] = s
	}
	return &Registry{specs: m}
}

// Enabled reports whether the named flag is on for uid. An unknown name is always off (never panics) so a
// module can check a flag defensively without the registry having to know about every module in advance.
func (r *Registry) Enabled(uid, name string) bool {
	if r == nil {
		return false
	}
	s, ok := r.specs[name]
	if !ok {
		return false
	}
	return s.enabledFor(uid)
}

// EnabledFeatures returns the sorted list of flag names enabled for uid, for GetMeResponse.enabled_features
// (ADR-0008 D6). Implements identity.FeatureFlags.
func (r *Registry) EnabledFeatures(uid string) []string {
	if r == nil {
		return nil
	}
	var out []string
	for name, s := range r.specs {
		if s.enabledFor(uid) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// StartupLogValues returns name->mode for the one-line startup log ("feature_flags={graph: mode}"),
// sorted by name for stable log output.
func (r *Registry) StartupLogValues() map[string]string {
	out := make(map[string]string, len(r.specs))
	for name, s := range r.specs {
		mode := string(s.Mode)
		if s.retired {
			mode = "retired"
		}
		out[name] = mode
	}
	return out
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitCSV(v string) []string {
	if v == "" {
		return nil
	}
	var out []string
	for _, s := range strings.Split(v, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}
