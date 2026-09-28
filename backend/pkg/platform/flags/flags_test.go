package flags

import (
	"strconv"
	"testing"
)

func withEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

func TestLoadSpec_ModeParsing(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    Mode
		wantErr bool
	}{
		{name: "default when unset", env: nil, want: Off},
		{name: "off", env: map[string]string{"FEATURE_GRAPH": "off"}, want: Off},
		{name: "allowlist", env: map[string]string{"FEATURE_GRAPH": "allowlist"}, want: Allowlist},
		{name: "percent", env: map[string]string{"FEATURE_GRAPH": "percent"}, want: Percent},
		{name: "on", env: map[string]string{"FEATURE_GRAPH": "on"}, want: On},
		{name: "invalid fails fast", env: map[string]string{"FEATURE_GRAPH": "maybe"}, wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			withEnv(t, tc.env)
			spec, err := LoadSpec("GRAPH", "graph", Off)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected an error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("LoadSpec() error = %v", err)
			}
			if spec.Mode != tc.want {
				t.Errorf("Mode = %q, want %q", spec.Mode, tc.want)
			}
		})
	}
}

func TestLoadSpec_InvalidPercentFailsFast(t *testing.T) {
	withEnv(t, map[string]string{"FEATURE_GRAPH": "percent", "FEATURE_GRAPH_PERCENT": "150"})
	if _, err := LoadSpec("GRAPH", "graph", Off); err == nil {
		t.Fatal("expected an error for out-of-range percent, got nil")
	}
	withEnv(t, map[string]string{"FEATURE_GRAPH": "percent", "FEATURE_GRAPH_PERCENT": "not-a-number"})
	if _, err := LoadSpec("GRAPH", "graph", Off); err == nil {
		t.Fatal("expected an error for non-numeric percent, got nil")
	}
}

func TestLoadSpec_Allowlist(t *testing.T) {
	withEnv(t, map[string]string{"FEATURE_GRAPH": "allowlist", "FEATURE_GRAPH_ALLOWLIST": "uid-a, uid-b ,uid-c"})
	spec, err := LoadSpec("GRAPH", "graph", Off)
	if err != nil {
		t.Fatalf("LoadSpec() error = %v", err)
	}
	for _, uid := range []string{"uid-a", "uid-b", "uid-c"} {
		if _, ok := spec.Allowlist[uid]; !ok {
			t.Errorf("expected %q in allowlist", uid)
		}
	}
	if len(spec.Allowlist) != 3 {
		t.Errorf("len(Allowlist) = %d, want 3", len(spec.Allowlist))
	}
}

func TestRegistry_Enabled(t *testing.T) {
	tests := []struct {
		name string
		spec Spec
		uid  string
		want bool
	}{
		{name: "off", spec: Spec{Name: "graph", Mode: Off}, uid: "any", want: false},
		{name: "on", spec: Spec{Name: "graph", Mode: On}, uid: "any", want: true},
		{
			name: "allowlist hit",
			spec: Spec{Name: "graph", Mode: Allowlist, Allowlist: map[string]struct{}{"uid-a": {}}},
			uid:  "uid-a", want: true,
		},
		{
			name: "allowlist miss",
			spec: Spec{Name: "graph", Mode: Allowlist, Allowlist: map[string]struct{}{"uid-a": {}}},
			uid:  "uid-b", want: false,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := NewRegistry(tc.spec)
			if got := r.Enabled(tc.uid, "graph"); got != tc.want {
				t.Errorf("Enabled(%q) = %v, want %v", tc.uid, got, tc.want)
			}
		})
	}
}

func TestRegistry_Enabled_UnknownNameIsOff(t *testing.T) {
	r := NewRegistry(Spec{Name: "graph", Mode: On})
	if r.Enabled("uid-a", "does_not_exist") {
		t.Error("expected an unregistered flag name to be off")
	}
	var nilRegistry *Registry
	if nilRegistry.Enabled("uid-a", "graph") {
		t.Error("expected a nil *Registry to report every flag off")
	}
}

// TestRegistry_Percent_Distribution is the plan's acceptance criterion: given percent=10, 10,000 random
// uids bucket 10% +/- 1.5%, and each uid gets the same result every time (deterministic).
func TestRegistry_Percent_Distribution(t *testing.T) {
	spec := Spec{Name: "graph", Mode: Percent, Percent: 10, Allowlist: map[string]struct{}{}}
	r := NewRegistry(spec)

	const n = 10_000
	enabled := 0
	for i := 0; i < n; i++ {
		uid := "uid-" + strconv.Itoa(i)
		if r.Enabled(uid, "graph") {
			enabled++
		}
		// Determinism: same uid always yields the same result.
		if r.Enabled(uid, "graph") != r.Enabled(uid, "graph") {
			t.Fatalf("Enabled(%q) is not deterministic", uid)
		}
	}
	got := float64(enabled) / float64(n) * 100
	if got < 8.5 || got > 11.5 {
		t.Errorf("percent enabled = %.2f%%, want 10%% +/- 1.5%%", got)
	}
}

// TestRegistry_Percent_IndependentCohorts (ADR-0008 D6 "changed vs plan"): two flags at the same percent
// must not always agree for the same uid — salting with the flag name gives each an independent cohort.
func TestRegistry_Percent_IndependentCohorts(t *testing.T) {
	specA := Spec{Name: "flag_a", Mode: Percent, Percent: 50}
	specB := Spec{Name: "flag_b", Mode: Percent, Percent: 50}
	r := NewRegistry(specA, specB)

	disagreements := 0
	const n = 2000
	for i := 0; i < n; i++ {
		uid := "uid-" + strconv.Itoa(i)
		if r.Enabled(uid, "flag_a") != r.Enabled(uid, "flag_b") {
			disagreements++
		}
	}
	if disagreements == 0 {
		t.Error("expected flag_a and flag_b to disagree for at least some uids (independent cohorts)")
	}
}

func TestSpec_Retired_AlwaysEnabled(t *testing.T) {
	r := NewRegistry(NewRetired("graph"))
	if !r.Enabled("anyone", "graph") {
		t.Error("expected a retired flag to always report enabled")
	}
	if got := r.EnabledFeatures("anyone"); len(got) != 1 || got[0] != "graph" {
		t.Errorf("EnabledFeatures() = %v, want [graph]", got)
	}
}

func TestRegistry_EnabledFeatures_Sorted(t *testing.T) {
	r := NewRegistry(
		Spec{Name: "zzz", Mode: On},
		Spec{Name: "aaa", Mode: On},
		Spec{Name: "off_one", Mode: Off},
	)
	got := r.EnabledFeatures("uid-1")
	want := []string{"aaa", "zzz"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("EnabledFeatures() = %v, want %v", got, want)
	}
}
