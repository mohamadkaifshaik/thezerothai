package flags

import (
	"slices"
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

// A cycle (a requires b requires a) never loops: both are off.
func TestRegistry_Require_CycleFailsClosed(t *testing.T) {
	r := NewRegistry(Spec{Name: "a", Mode: On}, Spec{Name: "b", Mode: On}).Require("a", "b").Require("b", "a")
	if r.Enabled("u1", "a") || r.Enabled("u1", "b") {
		t.Error("a requirement cycle must fail closed")
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
