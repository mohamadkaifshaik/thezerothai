package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The local push log line names the notification by its row hash, never the raw id: notification ids embed the actor's uid
// (follow_<actorUid>, ...). The FCM token is hashed too.
func TestLogSender_HashesNotificationID(t *testing.T) {
	t.Parallel()
	const actor = "ActorUidAbCdEfGhIjKl1234"
	const token = "fcm-token-secret-value"
	tests := []struct {
		name string
		id   string
	}{
		{"follow row embeds the actor uid", "follow_" + actor},
		{"like row", "like_7300000000000000001"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			s := LogSender{Log: slog.New(slog.NewJSONHandler(&buf, nil))}
			if err := s.Send(context.Background(), token, Push{Type: TypeFollow, NotificationID: tt.id}); err != nil {
				t.Fatal(err)
			}
			out := buf.String()
			if strings.Contains(out, tt.id) || strings.Contains(out, actor) || strings.Contains(out, token) {
				t.Fatalf("raw id, uid or token in %s", out)
			}
			var line map[string]any
			if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
				t.Fatalf("not one JSON line: %v: %s", err, out)
			}
			if _, ok := line["notification_id"]; ok {
				t.Errorf("notification_id still logged: %s", out)
			}
			if line["row_hash"] != logger.HashUID(tt.id) {
				t.Errorf("row_hash = %v, want %s", line["row_hash"], logger.HashUID(tt.id))
			}
			if line["token_hash"] != logger.HashUID(token) {
				t.Errorf("token_hash = %v, want %s", line["token_hash"], logger.HashUID(token))
			}
		})
	}
}
