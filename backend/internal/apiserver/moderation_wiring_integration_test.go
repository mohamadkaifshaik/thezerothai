//go:build integration

package apiserver

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestReportContent_FlagOffAndOnThroughTheRealChain (ADR-0016 D1): with FEATURE_REPORTS off the RPC answers
// FAILED_PRECONDITION + FEATURE_DISABLED and does no work beyond the interceptor's own status read; with it on, an
// unknown post is the generic NOT_FOUND and a malformed request is INVALID_ARGUMENT.
func TestReportContent_FlagOffAndOnThroughTheRealChain(t *testing.T) {
	ctx := context.Background()
	req := func() *moderationv1.ReportContentRequest {
		return &moderationv1.ReportContentRequest{
			IdempotencyKey: "wiring-report-key-00001", TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST,
			TargetId: "0000000000000000001", Reason: moderationv1.ReportReason_REPORT_REASON_SPAM,
		}
	}

	off := newChain(t, nil)
	idToken, _ := mintToken(t, "")
	off.createProfile(t, idToken)
	_, err := off.moderation.ReportContent(ctx, authed(idToken, req()))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Fatalf("flag off: reason = %v, want FEATURE_DISABLED", d.GetReason())
	}
	lines := off.logs.requestLines(moderationv1connect.ModerationServiceReportContentProcedure)
	if len(lines) != 1 {
		t.Fatalf("%d request lines, want 1", len(lines))
	}
	if reads, _ := lines[0]["fs_reads"].(float64); reads > 1 {
		t.Errorf("flag off fs_reads = %v, want <= 1", reads)
	}
	if writes, _ := lines[0]["fs_writes"].(float64); writes != 0 {
		t.Errorf("flag off fs_writes = %v, want 0", writes)
	}

	on := newChain(t, func(c *config.Config) { c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.On} })
	idToken2, _ := mintToken(t, "")
	on.createProfile(t, idToken2)
	if _, err := on.moderation.ReportContent(ctx, authed(idToken2, req())); err == nil {
		t.Fatal("report of an unknown post succeeded")
	} else {
		wireError(t, err, connect.CodeNotFound)
	}
	bad := req()
	bad.IdempotencyKey = "short"
	_, err = on.moderation.ReportContent(ctx, authed(idToken2, bad))
	wireError(t, err, connect.CodeInvalidArgument)
}
