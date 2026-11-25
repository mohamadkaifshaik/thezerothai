package config

import (
	"strings"
	"testing"
)

// TestLoad_ClientFloors (plan 6 Task 3.B): CLIENT_FLOOR_ANDROID, CLIENT_FLOOR_WEB and CLIENT_FLOOR_IOS default to 0 (no
// floor), accept 0..1000 and refuse anything else at startup.
func TestLoad_ClientFloors(t *testing.T) {
	keys := []string{"CLIENT_FLOOR_ANDROID", "CLIENT_FLOOR_WEB", "CLIENT_FLOOR_IOS"}
	reset := func(t *testing.T) {
		clearEnv(t)
		for _, k := range keys {
			t.Setenv(k, "")
		}
	}
	reset(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.ClientFloors != (ClientFloorsConfig{}) {
		t.Errorf("ClientFloors = %+v, want all 0 (no floor)", cfg.ClientFloors)
	}
	for _, key := range keys {
		for _, tc := range []struct {
			value   string
			want    int
			wantErr string
		}{
			{"0", 0, ""},
			{"1", 1, ""},
			{"1000", 1000, ""},
			{"1001", 0, key + " must be between 0 and 1000"},
			{"-1", 0, key + " must be between 0 and 1000"},
			{"one", 0, key},
		} {
			t.Run(key+"="+tc.value, func(t *testing.T) {
				reset(t)
				t.Setenv(key, tc.value)
				cfg, err := Load()
				if tc.wantErr != "" {
					if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
						t.Fatalf("Load() error = %v, want %q", err, tc.wantErr)
					}
					return
				}
				if err != nil {
					t.Fatalf("Load() error = %v", err)
				}
				got := map[string]int{
					"CLIENT_FLOOR_ANDROID": cfg.ClientFloors.Android,
					"CLIENT_FLOOR_WEB":     cfg.ClientFloors.Web,
					"CLIENT_FLOOR_IOS":     cfg.ClientFloors.IOS,
				}
				for k, v := range got {
					want := 0
					if k == key {
						want = tc.want
					}
					if v != want {
						t.Errorf("%s = %d, want %d", k, v, want)
					}
				}
			})
		}
	}
}
