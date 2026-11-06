package moderation

import (
	"testing"

	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
)

// TestTargetTypeFromProto_Beacon: REPORT_TARGET_TYPE_BEACON maps to TargetBeacon now that the beacons module provides its
// evidence (docs/beacons-plan.md PR 4); an unknown value still maps to "" and is rejected as VALIDATION "target_type".
func TestTargetTypeFromProto_Beacon(t *testing.T) {
	t.Parallel()
	if got := targetTypeFromProto(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_BEACON); got != TargetBeacon {
		t.Fatalf("targetTypeFromProto(BEACON) = %q, want %q", got, TargetBeacon)
	}
	if got := targetTypeFromProto(moderationv1.ReportTargetType(99)); got != "" {
		t.Fatalf("targetTypeFromProto(99) = %q, want \"\"", got)
	}
}
