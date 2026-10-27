package identity

import (
	"reflect"
	"testing"
	"time"
)

// TestKnownInactive (W3-22 L-5): cache-only. SUSPENDED and DELETING cached profiles and confirmed-missing uids are
// reported; ACTIVE ones, expired entries and uids the cache never saw are absent (unknown, not active); it reads no
// repository (the service here has none, so a read would panic).
func TestKnownInactive(t *testing.T) {
	s := &service{cache: NewCache(time.Minute)}
	s.cache.SetProfile(Profile{UserID: "active", Status: AccountStatusActive})
	s.cache.SetProfile(Profile{UserID: "suspended", Status: AccountStatusSuspended})
	s.cache.SetProfile(Profile{UserID: "deleting", Status: AccountStatusDeleting})
	s.cache.SetProfile(Profile{UserID: "unspecified", Status: AccountStatusUnspecified})
	s.cache.SetNotFound("gone")
	s.cache.SetProfile(Profile{UserID: "evicted", Status: AccountStatusSuspended})
	s.cache.InvalidateProfile("evicted")

	tests := []struct {
		name string
		in   []string
		want map[string]bool
	}{
		{"none asked", nil, nil},
		{"only active", []string{"active"}, nil},
		{"unknown uid is not inactive", []string{"never-seen", "evicted"}, nil},
		{"suspended", []string{"suspended"}, map[string]bool{"suspended": true}},
		{"deleting and missing", []string{"deleting", "gone"}, map[string]bool{"deleting": true, "gone": true}},
		{"a status that is not ACTIVE counts, like LookupProfiles", []string{"unspecified"}, map[string]bool{"unspecified": true}},
		{"mixed", []string{"active", "suspended", "never-seen", "gone"}, map[string]bool{"suspended": true, "gone": true}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := s.KnownInactive(tt.in); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("KnownInactive(%v) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}
