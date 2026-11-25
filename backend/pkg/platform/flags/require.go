package flags

import (
	"cmp"
	"slices"
)

// Reasons of a CouplingWarning.
const (
	// ReasonParentNarrower: the flag is not off while a flag it requires is off, or is on while that flag is an allowlist
	// or a percentage, so the flag is effective for fewer users (or none) than its own mode says.
	ReasonParentNarrower = "parent_narrower"
	// ReasonCycle: a Require that would have closed a cycle (or named the flag as its own parent) was rejected, and the
	// flag is permanently off.
	ReasonCycle = "cycle"
	// ReasonUnknownParent: the flag requires a name the registry does not know, so it is off for everyone.
	ReasonUnknownParent = "unknown_parent"
)

// CouplingWarning is one startup warning about the Require coupling, or about any pair checked with Narrower. It carries
// flag names, modes, a reason and a count only, never a uid (a retired flag reads On, an unknown or invalid one Off).
// Uncovered is how many of Flag's allowlist entries Parent's own spec does not enable (0 when Flag is on or off).
type CouplingWarning struct {
	Flag, Parent         string
	FlagMode, ParentMode Mode
	Reason               string
	Uncovered            int
}

// Require couples name to parents: name is effective for a uid only while its own spec is on for that uid and every
// parent is effective for that uid too (through the parents' own requirements, so a chain composes). Enabled and
// EnabledFeatures report the effective value; GloballyOff keeps reading name's raw mode (the kill switch is the flag's
// own setting, never a consequence of another flag). An unknown parent is off, so name is off for everyone. A parent
// gate still applies to a retired child (NewRetired): it is effective only while its parents are.
//
// A requirement that would close a cycle, or name name as its own parent, is rejected at registration: the edge is not
// added, name is permanently off for everyone (and so is every flag that requires it) while GloballyOff still reads its
// raw mode, and CouplingWarnings reports it with ReasonCycle. The closure of every flag's requirements is recomputed here, so Enabled is linear in the number of flags
// a name needs and never recursive. Call it while building the registry, before it is shared: it is not safe to call
// concurrently with reads. It returns r for chaining; a nil registry stays nil.
func (r *Registry) Require(name string, parents ...string) *Registry {
	if r == nil {
		return nil
	}
	for _, p := range parents {
		if p == name || slices.Contains(r.ancestors[p], name) {
			r.broken[name] = true
			r.rejected = append(r.rejected, CouplingWarning{Flag: name, Parent: p, FlagMode: r.modeOf(name), ParentMode: r.modeOf(p), Reason: ReasonCycle})
			continue
		}
		if !slices.Contains(r.requires[name], p) {
			r.requires[name] = append(r.requires[name], p)
		}
	}
	r.closure()
	return r
}

// closure recomputes ancestors from requires. The accepted edges form a DAG (Require rejects every cycle), so the walk
// ends; each flag is listed once.
func (r *Registry) closure() {
	out := make(map[string][]string, len(r.requires))
	for name := range r.requires {
		seen := map[string]bool{}
		stack := slices.Clone(r.requires[name])
		var list []string
		for len(stack) > 0 {
			p := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if seen[p] {
				continue
			}
			seen[p] = true
			list = append(list, p)
			stack = append(stack, r.requires[p]...)
		}
		slices.Sort(list)
		out[name] = list
	}
	r.ancestors = out
}

// modeOf is name's configured mode for a warning: a retired flag is On; an unknown or invalid one is Off.
func (r *Registry) modeOf(name string) Mode {
	s, ok := r.specs[name]
	switch {
	case !ok:
		return Off
	case s.retired:
		return On
	case !s.Mode.valid():
		return Off
	}
	return s.Mode
}

// Narrower reports whether parent fails to cover everyone flag is on for: by mode (flag not off while parent is off;
// flag on while parent is an allowlist or a percentage; flag a percentage while parent is an allowlist), or by count
// (Uncovered: flag's allowlist entries, in allowlist or percent mode, that parent's own spec does not enable, evaluated
// per uid, percent buckets included). An off flag never warns, and a pair whose modes pass with nothing uncovered
// (two allowlists with the same members, say) is silent. The reason is ReasonUnknownParent when parent is not
// registered, else ReasonParentNarrower. It works for any two names, coupled with Require or not.
func (r *Registry) Narrower(flag, parent string) (CouplingWarning, bool) {
	if r == nil {
		return CouplingWarning{}, false
	}
	fm, pm := r.modeOf(flag), r.modeOf(parent)
	if fm == Off {
		return CouplingWarning{}, false
	}
	byMode := pm == Off || (fm == On && (pm == Allowlist || pm == Percent)) || (fm == Percent && pm == Allowlist)
	uncovered := 0
	if fm == Allowlist || fm == Percent {
		for uid := range r.specs[flag].Allowlist {
			if !r.rawOn(uid, parent) {
				uncovered++
			}
		}
	}
	if !byMode && uncovered == 0 {
		return CouplingWarning{}, false
	}
	reason := ReasonParentNarrower
	if _, ok := r.specs[parent]; !ok {
		reason = ReasonUnknownParent
	}
	return CouplingWarning{Flag: flag, Parent: parent, FlagMode: fm, ParentMode: pm, Reason: reason, Uncovered: uncovered}, true
}

// CouplingWarnings is what the composition root logs at startup: one ReasonParentNarrower warning per accepted Require
// edge whose child is narrowed by its direct parent (Narrower), and one ReasonCycle warning per rejected requirement,
// sorted by flag, parent and reason.
func (r *Registry) CouplingWarnings() []CouplingWarning {
	if r == nil {
		return nil
	}
	out := slices.Clone(r.rejected)
	for name, parents := range r.requires {
		for _, p := range parents {
			if w, ok := r.Narrower(name, p); ok {
				out = append(out, w)
			}
		}
	}
	slices.SortFunc(out, func(a, b CouplingWarning) int {
		return cmp.Or(cmp.Compare(a.Flag, b.Flag), cmp.Compare(a.Parent, b.Parent), cmp.Compare(a.Reason, b.Reason))
	})
	return out
}
