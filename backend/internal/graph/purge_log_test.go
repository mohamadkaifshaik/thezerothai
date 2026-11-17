package graph

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The purge_missing_counterpart WARN names the purged user by uid_hash and the counterpart by the keyed target pseudonym, so
// the counterpart cannot be joined to that user's own uid_hash lines and the line cannot confirm an edge between two known uids.
func TestWarnMissingCounterpart(t *testing.T) {
	t.Parallel()
	const uid = "PurgedUserAbCdEfGhIjKl12"
	const other = "CounterpartZyXwVuTsRq98"
	tests := []struct {
		name  string
		extra []any
		want  map[string]string
	}{
		{"edge", nil, nil},
		{"follow request", []any{"collection", followRequestsCollection}, map[string]string{"collection": followRequestsCollection}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			warnMissingCounterpart(slog.New(slog.NewJSONHandler(&buf, nil)), uid, other, tt.extra...)
			out := buf.String()
			if strings.Contains(out, uid) || strings.Contains(out, other) {
				t.Fatalf("raw uid in %s", out)
			}
			var line map[string]any
			if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
				t.Fatalf("not one JSON line: %v: %s", err, out)
			}
			if line["msg"] != "purge_missing_counterpart" || line["level"] != "WARN" {
				t.Errorf("msg/level = %v/%v", line["msg"], line["level"])
			}
			if line["uid_hash"] != logger.HashUID(uid) {
				t.Errorf("uid_hash = %v, want %s", line["uid_hash"], logger.HashUID(uid))
			}
			if line["counterpart_hash"] != logger.HashTarget(other) || line["counterpart_hash"] == logger.HashUID(other) {
				t.Errorf("counterpart_hash = %v, want the target pseudonym %s (not the uid hash %s)", line["counterpart_hash"], logger.HashTarget(other), logger.HashUID(other))
			}
			for k, v := range tt.want {
				if line[k] != v {
					t.Errorf("%s = %v, want %s", k, line[k], v)
				}
			}
		})
	}
}
