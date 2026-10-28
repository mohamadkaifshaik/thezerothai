package graph

import (
	"context"
	"strings"
	"testing"
)

// TestRequestEraser_UnknownPhase: a corrupt checkpoint fails loudly (and names no uid) instead of silently finishing.
func TestRequestEraser_UnknownPhase(t *testing.T) {
	_, done, err := NewRequestEraser(NewFirestoreRepo(nil)).PurgeUser(context.Background(), "uid-secret", RequestCheckpoint{Phase: 7})
	if err == nil || done {
		t.Fatalf("PurgeUser(phase 7) = done %v, err %v; want an error", done, err)
	}
	if strings.Contains(err.Error(), "uid-secret") {
		t.Errorf("error names the raw uid: %v", err)
	}
}

// TestExportRequests_NeedsProfiles: the export refuses to run without the ProfileReader (it would drop every handle).
func TestExportRequests_NeedsProfiles(t *testing.T) {
	if _, err := NewFirestoreRepo(nil).ExportRequests(context.Background(), "u1"); err == nil {
		t.Error("ExportRequests without SetProfiles succeeded")
	}
}
