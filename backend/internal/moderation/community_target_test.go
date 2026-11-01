package moderation

import (
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TestReport_CommunityTargetFailsClosedUntilW529: the proto value REPORT_TARGET_TYPE_COMMUNITY (ADR-0031, shipped by W5-21) maps to
// no TargetType yet, so ReportContent answers VALIDATION field=target_type with 0 reads and 0 writes, exactly like UNSPECIFIED, and
// never reaches the post or account paths. W5-29 maps it and adds the evidence and the flag gate.
func TestReport_CommunityTargetFailsClosedUntilW529(t *testing.T) {
	t.Parallel()
	if got := targetTypeFromProto(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_COMMUNITY); got != "" {
		t.Fatalf("targetTypeFromProto(COMMUNITY) = %q, want \"\" (unmapped until W5-29)", got)
	}
	f := newFixture()
	_, err := f.svc().Report(gctx(), reporter, ReportInput{IdempotencyKey: okKey, TargetType: targetTypeFromProto(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_COMMUNITY),
		TargetID: okListID, Reason: ReasonHate})
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "target_type" {
		t.Fatalf("err = %v, want field target_type", err)
	}
	if len(f.repo.calls) != 0 {
		t.Error("a community report touched the repo")
	}
}
