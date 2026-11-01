package timeline

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TestGetCommunityTimeline_Stub: the W5-22 stub gates on FEATURE_COMMUNITIES first, then FEATURE_POSTS, both FEATURE_DISABLED with 0
// reads; past them it is Unimplemented (W5-27 implements the feed). The flag matrix: off, allowlist (listed, unlisted), on, a nil
// checker (off for everyone) and posts off.
func TestGetCommunityTimeline_Stub(t *testing.T) {
	every := map[string]bool(nil)
	cases := []struct {
		name        string
		flags       allowFlags
		uid         string
		wantFeature string // "" = past the gates (Unimplemented); "-" = FEATURE_DISABLED for posts (no feature metadata)
	}{
		{"communities off", allowFlags{"posts": every}, "me", "communities"},
		{"communities off and posts off", allowFlags{}, "me", "communities"},
		{"posts off", allowFlags{"communities": every}, "me", "-"},
		{"allowlist, caller on it", allowFlags{"posts": every, "communities": {"me": true}}, "me", ""},
		{"allowlist, caller not on it", allowFlags{"posts": every, "communities": {"someone": true}}, "me", "communities"},
		{"on", allowFlags{"posts": every, "communities": every}, "me", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx, counter := budget.WithCounter(ctxFor(c.uid))
			s := NewServer(Deps{Flags: c.flags})
			_, err := s.GetCommunityTimeline(ctx, connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{}))
			if c.wantFeature == "" {
				if connect.CodeOf(err) != connect.CodeUnimplemented {
					t.Fatalf("err = %v, want Unimplemented past the gates", err)
				}
			} else {
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Code != connect.CodeFailedPrecondition {
					t.Fatalf("err = %#v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
				}
				if c.wantFeature != "-" && ae.Metadata["feature"] != c.wantFeature { // posts off carries no feature metadata (GuardFeature)
					t.Fatalf("metadata = %v, want feature=%s", ae.Metadata, c.wantFeature)
				}
			}
			if counter.Reads() != 0 {
				t.Fatalf("the stub read %d docs", counter.Reads())
			}
		})
	}
	t.Run("nil flags", func(t *testing.T) {
		_, err := NewServer(Deps{}).GetCommunityTimeline(ctxFor("me"), connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{}))
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "communities" {
			t.Fatalf("err = %v, want FEATURE_DISABLED feature=communities (off for everyone)", err)
		}
	})
	t.Run("no uid", func(t *testing.T) {
		s := NewServer(Deps{Flags: allowFlags{"posts": every, "communities": every}})
		_, err := s.GetCommunityTimeline(context.Background(), connect.NewRequest(&timelinev1.GetCommunityTimelineRequest{}))
		if connect.CodeOf(apierr.ToConnect(err)) != connect.CodeUnauthenticated {
			t.Fatalf("err = %v, want Unauthenticated", err)
		}
	})
}
