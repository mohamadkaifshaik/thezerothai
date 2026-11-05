package moderation

import (
	"testing"

	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
)

// TestTargetTypeFromProto_BeaconUnsupported: REPORT_TARGET_TYPE_BEACON exists on the wire (docs/beacons-plan.md PR 1)
// but the beacons module has not registered its evidence yet (PR 4), so the server must keep mapping it to the empty
// TargetType, which Report rejects as VALIDATION "target_type". A silent acceptance here would store a report with no
// evidence.
func TestTargetTypeFromProto_BeaconUnsupported(t *testing.T) {
	t.Parallel()
	if got := targetTypeFromProto(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_BEACON); got != "" {
		t.Fatalf("targetTypeFromProto(BEACON) = %q, want \"\" until the beacons evidence ships", got)
	}
}
