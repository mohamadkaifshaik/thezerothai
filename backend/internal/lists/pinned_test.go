package lists

import (
	"context"
	"errors"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// pinned_by_viewer comes from the viewer's users/{viewer}.homeTabs through identity.Directory (W5-9): true only for a LIST tab
// of this list, false for another list, another kind, no tabs, an unknown viewer and a directory error.
func TestService_Pinned(t *testing.T) {
	t.Parallel()
	const id, other = "0000000000000000101", "0000000000000000102"
	tabs := []identity.HomeTab{
		{Kind: identity.HomeTabKindCommunity, ID: other},
		{Kind: identity.HomeTabKindList, ID: id, Title: "x"},
	}
	tests := []struct {
		name   string
		dir    fakeDirectory
		viewer string
		listID string
		want   bool
	}{
		{"pinned", fakeDirectory{profiles: map[string]identity.Profile{"v": active("v", false).WithHomeTabs(tabs)}}, "v", id, true},
		{"another list", fakeDirectory{profiles: map[string]identity.Profile{"v": active("v", false).WithHomeTabs(tabs)}}, "v", "0000000000000000999", false},
		{"same id, another kind", fakeDirectory{profiles: map[string]identity.Profile{"v": active("v", false).WithHomeTabs(tabs)}}, "v", other, false},
		{"no tabs", fakeDirectory{profiles: map[string]identity.Profile{"v": active("v", false)}}, "v", id, false},
		{"unknown viewer", fakeDirectory{profiles: map[string]identity.Profile{}}, "v", id, false},
		{"directory error", fakeDirectory{err: errors.New("down")}, "v", id, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			s := &service{d: Deps{Directory: tt.dir}}
			if got := s.pinned(context.Background(), tt.viewer, tt.listID); got != tt.want {
				t.Fatalf("pinned = %v, want %v", got, tt.want)
			}
		})
	}
}
