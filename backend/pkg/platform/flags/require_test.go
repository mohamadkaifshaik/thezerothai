package flags

import (
	"slices"
	"strconv"
	"strings"
	"testing"
)

func allow(name string, uids ...string) Spec {
	m := map[string]struct{}{}
	for _, u := range uids {
		m[u] = struct{}{}
	}
	return Spec{Name: name, Mode: Allowlist, Allowlist: m}
}

// TestRegistry_Require: a flag that requires another is effective for a uid only while the required flag is effective for
// that uid too, through a chain (c requires b requires a); EnabledFeatures lists the effective values; GloballyOff keeps
// reading the raw mode.
func TestRegistry_Require(t *testing.T) {
	tests := []struct {
		name     string
		a, b, c  Spec
		uid      string
		wantA    bool
		wantB    bool
		wantC    bool
		rawCOff  bool // GloballyOff("c")
		features []string
	}{
		{"all on", Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: On}, "u1", true, true, true, false, []string{"a", "b", "c"}},
		{"parent off turns the chain off", Spec{Name: "a", Mode: Off}, Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: On}, "u1", false, false, false, false, nil},
		{"middle off turns the child off only", Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: Off}, Spec{Name: "c", Mode: On}, "u1", true, false, false, false, []string{"a"}},
		{"child off stays off", Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: Off}, "u1", true, true, false, true, []string{"a", "b"}},
		{"parent allowlist outside", allow("a", "u2"), Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: On}, "u1", false, false, false, false, nil},
		{"parent allowlist inside", allow("a", "u1"), Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: On}, "u1", true, true, true, false, []string{"a", "b", "c"}},
		{"child allowlist outside", Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: On}, allow("c", "u2"), "u1", true, true, false, false, []string{"a", "b"}},
		{"retired child still needs its parent", Spec{Name: "a", Mode: Off}, Spec{Name: "b", Mode: On}, NewRetired("c"), "u1", false, false, false, false, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := NewRegistry(tc.a, tc.b, tc.c).Require("b", "a").Require("c", "b")
			if got := r.Enabled(tc.uid, "a"); got != tc.wantA {
				t.Errorf("a = %v, want %v", got, tc.wantA)
			}
			if got := r.Enabled(tc.uid, "b"); got != tc.wantB {
				t.Errorf("b = %v, want %v", got, tc.wantB)
			}
			if got := r.Enabled(tc.uid, "c"); got != tc.wantC {
				t.Errorf("c = %v, want %v", got, tc.wantC)
			}
			if got := r.GloballyOff("c"); got != tc.rawCOff {
				t.Errorf("GloballyOff(c) = %v, want %v (the raw mode)", got, tc.rawCOff)
			}
			if got := r.EnabledFeatures(tc.uid); !slices.Equal(got, tc.features) {
				t.Errorf("EnabledFeatures = %v, want %v", got, tc.features)
			}
		})
	}
}

// A required flag the registry does not know is off, so the flag requiring it is off for everyone (fail closed).
func TestRegistry_Require_UnknownParentIsOff(t *testing.T) {
	r := NewRegistry(Spec{Name: "c", Mode: On}).Require("c", "missing")
	if r.Enabled("u1", "c") {
		t.Error("c requires an unknown flag and must be off")
	}
	if r.GloballyOff("c") {
		t.Error("GloballyOff reads the raw mode (on)")
	}
}

// A requirement that would close a cycle (a requires b, then b requires a) or a self-parent is rejected at registration:
// the edge is not added, its child is permanently off (and so is everything requiring it), and the rejection is reported.
func TestRegistry_Require_CycleRejectedAtRegistration(t *testing.T) {
	r := NewRegistry(Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: On}, Spec{Name: "c", Mode: On}).
		Require("a", "b").Require("b", "a").Require("c", "c")
	for _, name := range []string{"a", "b", "c"} {
		if r.Enabled("u1", name) {
			t.Errorf("%s must be off (cycle or self-parent)", name)
		}
		if r.GloballyOff(name) {
			t.Errorf("GloballyOff(%s) reads the raw mode (on)", name)
		}
	}
	want := []CouplingWarning{
		{Flag: "b", Parent: "a", FlagMode: On, ParentMode: On, Reason: ReasonCycle},
		{Flag: "c", Parent: "c", FlagMode: On, ParentMode: On, Reason: ReasonCycle},
	}
	if got := r.CouplingWarnings(); !slices.Equal(got, want) {
		t.Errorf("CouplingWarnings = %+v, want %+v", got, want)
	}
}

// A long chain is evaluated without recursion blow-up: every flag of a 64-deep chain with two parents per level (a
// dense diamond) answers at once.
func TestRegistry_Require_DenseChainIsLinear(t *testing.T) {
	const depth = 64
	var specs []Spec
	for i := 0; i < depth; i++ {
		specs = append(specs, Spec{Name: name2(i, 0), Mode: On}, Spec{Name: name2(i, 1), Mode: On})
	}
	r := NewRegistry(specs...)
	for i := 1; i < depth; i++ {
		r.Require(name2(i, 0), name2(i-1, 0), name2(i-1, 1)).Require(name2(i, 1), name2(i-1, 0), name2(i-1, 1))
	}
	if !r.Enabled("u1", name2(depth-1, 0)) {
		t.Fatal("the deepest flag should be on")
	}
}

func name2(level, side int) string { return string(rune('a'+side)) + "-" + strconv.Itoa(level) }

// TestRegistry_CouplingWarnings: one warning per Require edge whose child is not off while the parent is off, or
// obviously narrower (child on with parent allowlist / percent / off; child allowlist or percent with parent off). A
// retired child reads on; an unknown parent reads off. Modes only.
func TestRegistry_CouplingWarnings(t *testing.T) {
	for _, tc := range []struct {
		child, parent Mode
		warn          bool
	}{
		{Off, Off, false}, {Off, Allowlist, false}, {Off, Percent, false}, {Off, On, false},
		{Allowlist, Off, true}, {Allowlist, Allowlist, false}, {Allowlist, Percent, false}, {Allowlist, On, false},
		{Percent, Off, true}, {Percent, Allowlist, true}, {Percent, Percent, false}, {Percent, On, false},
		{On, Off, true}, {On, Allowlist, true}, {On, Percent, true}, {On, On, false},
	} {
		t.Run(string(tc.child)+"/"+string(tc.parent), func(t *testing.T) {
			r := NewRegistry(Spec{Name: "child", Mode: tc.child}, Spec{Name: "parent", Mode: tc.parent}).Require("child", "parent")
			got := r.CouplingWarnings()
			if !tc.warn {
				if len(got) != 0 {
					t.Fatalf("warnings = %+v, want none", got)
				}
				return
			}
			want := []CouplingWarning{{Flag: "child", Parent: "parent", FlagMode: tc.child, ParentMode: tc.parent, Reason: ReasonParentNarrower}}
			if !slices.Equal(got, want) {
				t.Fatalf("warnings = %+v, want %+v", got, want)
			}
			if w, ok := r.Narrower("child", "parent"); !ok || w != want[0] {
				t.Errorf("Narrower = %+v, %v, want %+v", w, ok, want[0])
			}
		})
	}
	t.Run("retired child, off parent", func(t *testing.T) {
		r := NewRegistry(NewRetired("child"), Spec{Name: "parent", Mode: Off}).Require("child", "parent")
		want := []CouplingWarning{{Flag: "child", Parent: "parent", FlagMode: On, ParentMode: Off, Reason: ReasonParentNarrower}}
		if got := r.CouplingWarnings(); !slices.Equal(got, want) {
			t.Errorf("warnings = %+v, want %+v", got, want)
		}
	})
	t.Run("unknown parent", func(t *testing.T) {
		r := NewRegistry(allow("child", "u1", "u2")).Require("child", "missing")
		want := []CouplingWarning{{Flag: "child", Parent: "missing", FlagMode: Allowlist, ParentMode: Off, Reason: ReasonUnknownParent, Uncovered: 2}}
		if got := r.CouplingWarnings(); !slices.Equal(got, want) {
			t.Errorf("warnings = %+v, want %+v", got, want)
		}
	})
	t.Run("no requirement, no warning", func(t *testing.T) {
		if got := NewRegistry(Spec{Name: "child", Mode: On}, Spec{Name: "parent", Mode: Off}).CouplingWarnings(); len(got) != 0 {
			t.Errorf("warnings = %+v, want none", got)
		}
	})
}

// TestRegistry_Narrower_UncoveredAllowlist: two allowlists (or an allowlist child under a percentage) are silent by mode,
// so the warning counts the child's allowlist entries the parent's own spec does not enable (deterministic, percent
// buckets included). No warning when the count is 0.
func TestRegistry_Narrower_UncoveredAllowlist(t *testing.T) {
	// Percent 100 enables everyone, percent 0 no one outside its own allowlist: deterministic whatever the bucket.
	pct := func(name string, p int, uids ...string) Spec {
		s := allow(name, uids...)
		s.Mode, s.Percent = Percent, p
		return s
	}
	for _, tc := range []struct {
		name          string
		child, parent Spec
		want          *CouplingWarning
	}{
		{"same members", allow("child", "u1", "u2"), allow("parent", "u2", "u1"), nil},
		{"child inside a larger parent", allow("child", "u1"), allow("parent", "u1", "u2"), nil},
		{"one member missing", allow("child", "u1", "u2", "u3"), allow("parent", "u1", "u2"),
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: Allowlist, ParentMode: Allowlist, Reason: ReasonParentNarrower, Uncovered: 1}},
		{"disjoint", allow("child", "u1", "u2"), allow("parent", "u3"),
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: Allowlist, ParentMode: Allowlist, Reason: ReasonParentNarrower, Uncovered: 2}},
		{"allowlist under percent 100", allow("child", "u1", "u2"), pct("parent", 100), nil},
		{"allowlist under percent 0", allow("child", "u1", "u2"), pct("parent", 0, "u2"),
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: Allowlist, ParentMode: Percent, Reason: ReasonParentNarrower, Uncovered: 1}},
		{"percent child's allowlist under a parent allowlist", pct("child", 0, "u1", "u9"), allow("parent", "u1"),
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: Percent, ParentMode: Allowlist, Reason: ReasonParentNarrower, Uncovered: 1}},
		{"mode-narrower with a count", allow("child", "u1", "u2"), Spec{Name: "parent", Mode: Off},
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: Allowlist, ParentMode: Off, Reason: ReasonParentNarrower, Uncovered: 2}},
		{"on child counts nothing", Spec{Name: "child", Mode: On, Allowlist: map[string]struct{}{"u1": {}}}, allow("parent", "u2"),
			&CouplingWarning{Flag: "child", Parent: "parent", FlagMode: On, ParentMode: Allowlist, Reason: ReasonParentNarrower}},
		{"off child never warns", Spec{Name: "child", Mode: Off, Allowlist: map[string]struct{}{"u1": {}}}, allow("parent"), nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := NewRegistry(tc.child, tc.parent).Require("child", "parent")
			got := r.CouplingWarnings()
			switch {
			case tc.want == nil && len(got) != 0:
				t.Fatalf("warnings = %+v, want none", got)
			case tc.want != nil && !slices.Equal(got, []CouplingWarning{*tc.want}):
				t.Fatalf("warnings = %+v, want %+v", got, *tc.want)
			}
			// Narrower answers the same for an uncoupled pair.
			w, ok := NewRegistry(tc.child, tc.parent).Narrower("child", "parent")
			if ok != (tc.want != nil) || (ok && w != *tc.want) {
				t.Errorf("Narrower = %+v, %v, want %+v", w, ok, tc.want)
			}
		})
	}
}

// No warning field ever carries a uid: names, modes, a reason and a count only.
func TestRegistry_CouplingWarnings_NoUIDs(t *testing.T) {
	uids := []string{"uid-secret-1", "uid-secret-2", "uid-secret-3"}
	r := NewRegistry(allow("child", uids...), allow("parent", uids[0]), allow("orphan", uids[1])).
		Require("child", "parent").Require("orphan", "missing").Require("parent", "child")
	got := r.CouplingWarnings()
	if len(got) == 0 {
		t.Fatal("want warnings to inspect")
	}
	for _, w := range got {
		for _, field := range []string{w.Flag, w.Parent, string(w.FlagMode), string(w.ParentMode), w.Reason} {
			for _, u := range uids {
				if strings.Contains(field, u) {
					t.Errorf("warning %+v carries uid %q", w, u)
				}
			}
		}
	}
}

// Several parents: all must be on.
func TestRegistry_Require_AllParents(t *testing.T) {
	r := NewRegistry(Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: Off}, Spec{Name: "c", Mode: On}).Require("c", "a", "b")
	if r.Enabled("u1", "c") {
		t.Error("c requires a and b; b is off")
	}
}

// A nil registry stays off for everyone, Require included.
func TestRegistry_Require_Nil(t *testing.T) {
	var r *Registry
	if r.Require("a", "b") != nil || r.Enabled("u1", "a") {
		t.Error("a nil registry must stay nil and off")
	}
}
