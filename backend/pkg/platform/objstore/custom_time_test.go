package objstore

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// patchServer stands in for the Storage JSON API: it records every PATCH and answers with status. STORAGE_EMULATOR_HOST
// points the storage client at it, the same way the Firebase Storage emulator is reached.
func patchServer(t *testing.T, status int) (host string, bodies *[]map[string]any, paths *[]string) {
	t.Helper()
	var gotBodies []map[string]any
	var gotPaths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if r.Method == http.MethodPatch {
			var m map[string]any
			_ = json.Unmarshal(raw, &m)
			gotBodies = append(gotBodies, m)
			gotPaths = append(gotPaths, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"name":"m/x.webp","bucket":"b"}`)
	}))
	t.Cleanup(srv.Close)
	return strings.TrimPrefix(srv.URL, "http://"), &gotBodies, &gotPaths
}

// TestSetCustomTime_PatchesOnlyCustomTime: one PATCH per call, carrying customTime in UTC and nothing else (no cache
// control, content type or metadata change), so the retire step can never alter what the object serves meanwhile.
func TestSetCustomTime_PatchesOnlyCustomTime(t *testing.T) {
	host, bodies, paths := patchServer(t, http.StatusOK)
	t.Setenv("STORAGE_EMULATOR_HOST", host)
	s, err := New("demo-media")
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 10, 27, 15, 30, 0, 0, time.FixedZone("IST", 5*3600+1800))
	if err := s.SetCustomTime(context.Background(), "m/0000000000000000001_t.webp", at); err != nil {
		t.Fatalf("SetCustomTime: %v", err)
	}
	if len(*bodies) != 1 {
		t.Fatalf("PATCH calls = %d, want 1 (1 Class A)", len(*bodies))
	}
	body := (*bodies)[0]
	delete(body, "bucket") // the client names the bucket in every patch body; it is not an attribute change
	if len(body) != 1 || body["customTime"] != "2026-10-27T10:00:00Z" {
		t.Errorf("PATCH body = %v, want only customTime 2026-10-27T10:00:00Z (UTC)", body)
	}
	if !strings.HasSuffix((*paths)[0], "/b/demo-media/o/m%2F0000000000000000001_t.webp") && !strings.HasSuffix((*paths)[0], "/b/demo-media/o/m/0000000000000000001_t.webp") {
		t.Errorf("PATCH path = %q", (*paths)[0])
	}
}

// TestSetCustomTime_Outcomes: a missing object is success (lifecycle or the eraser got there first), the emulator's 501 is
// success because STORAGE_EMULATOR_HOST is set (the negative side, a 501 from GCS itself, cannot be staged here),
// and any other failure is an error the job nacks.
func TestSetCustomTime_Outcomes(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		wantErr bool
	}{
		{"ok", http.StatusOK, false},
		{"missing object", http.StatusNotFound, false},
		{"emulator does not implement patch", http.StatusNotImplemented, false},
		{"forbidden", http.StatusForbidden, true},
		{"server error", http.StatusInternalServerError, true},
		{"bad request", http.StatusBadRequest, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			host, _, _ := patchServer(t, tt.status)
			t.Setenv("STORAGE_EMULATOR_HOST", host)
			s, _ := New("demo-media")
			err := s.SetCustomTime(context.Background(), "m/x.webp", time.Now())
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
