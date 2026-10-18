package notifications

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestExportRowLeaksNoUID: row ids (follow_{actorUid}, repost_{postId}_{actorUid}) and the actor snapshot's user id
// are other accounts' identifiers; the exported row must carry none of them (N-3).
func TestExportRowLeaksNoUID(t *testing.T) {
	t.Parallel()
	const actorUID = "Zq8vK2mXr1TnB4yHc7LdPw3sEaGf" // 28 characters, Firebase-uid shaped
	at := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name string
		doc  notificationDoc
	}{
		{"follow", notificationDoc{Type: "follow", Actor: actorDoc{UserID: actorUID, Handle: "bob"}, ActorIDs: []string{actorUID}, CreatedAt: at}},
		{"repost", notificationDoc{Type: "repost", Actor: actorDoc{UserID: actorUID, Handle: "bob"}, ActorIDs: []string{actorUID}, PostID: postA, CreatedAt: at}},
		{"collapsed like", notificationDoc{Type: "like", Actor: actorDoc{UserID: actorUID, Handle: "bob"}, ActorIDs: []string{actorUID, "other"}, ActorCount: 2, PostID: postA, CreatedAt: at}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			b, err := json.Marshal(exportRow(tt.doc))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(b), actorUID) {
				t.Errorf("export row leaks the actor uid: %s", b)
			}
			var m map[string]any
			if err := json.Unmarshal(b, &m); err != nil {
				t.Fatal(err)
			}
			if _, has := m["id"]; has {
				t.Errorf("export row has an id: %s", b)
			}
			if m["type"] != tt.doc.Type || m["actorHandle"] != "bob" {
				t.Errorf("row = %s", b)
			}
		})
	}
}
