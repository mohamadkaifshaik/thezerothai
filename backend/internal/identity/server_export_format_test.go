package identity

import (
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// TestServer_RequestAccountExport_Format: ZIP is honoured only while export_zip is on for the caller; otherwise (and for
// UNSPECIFIED) the request is the JSON object, and the response's format says which one came back.
func TestServer_RequestAccountExport_Format(t *testing.T) {
	tests := []struct {
		name       string
		zipOn      bool
		asked      identityv1.ExportFormat
		wantFormat ExportFormat
		wantProto  identityv1.ExportFormat
	}{
		{"unspecified is JSON", true, identityv1.ExportFormat_EXPORT_FORMAT_UNSPECIFIED, ExportFormatJSON, identityv1.ExportFormat_EXPORT_FORMAT_JSON},
		{"json is JSON", true, identityv1.ExportFormat_EXPORT_FORMAT_JSON, ExportFormatJSON, identityv1.ExportFormat_EXPORT_FORMAT_JSON},
		{"zip with the flag on is ZIP", true, identityv1.ExportFormat_EXPORT_FORMAT_ZIP, ExportFormatZIP, identityv1.ExportFormat_EXPORT_FORMAT_ZIP},
		{"zip with the flag off falls back to JSON", false, identityv1.ExportFormat_EXPORT_FORMAT_ZIP, ExportFormatJSON, identityv1.ExportFormat_EXPORT_FORMAT_JSON},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lc := &fakeLifecycle{view: ExportView{ID: "exp-1", Status: ExportPending, Format: tt.wantFormat}}
			s, ctx := lifecycleServer(t, authn.Claims{UID: "uid-1", AuthTime: serverNow.Add(-time.Minute)}, lc, 5*time.Minute)
			if tt.zipOn {
				s = NewServer(&fakeService{}, WithFlagChecker(fakeFlagChecker{
					"uid-1/" + AccountLifecycleFlag: true,
					"uid-1/" + ExportZipFlag:        true,
				}), WithLifecycle(lc), WithReauthMaxAge(5*time.Minute), WithClock(func() time.Time { return serverNow }))
			}
			resp, err := s.RequestAccountExport(ctx, connect.NewRequest(&identityv1.RequestAccountExportRequest{IdempotencyKey: "k-0123456789abcdef", Format: tt.asked}))
			if err != nil {
				t.Fatal(err)
			}
			if lc.lastFormat != tt.wantFormat {
				t.Errorf("lifecycle format = %q, want %q", lc.lastFormat, tt.wantFormat)
			}
			if resp.Msg.GetFormat() != tt.wantProto {
				t.Errorf("response format = %v, want %v", resp.Msg.GetFormat(), tt.wantProto)
			}
		})
	}
}
