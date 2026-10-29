package messaging

// ListConversations `since` follows the entry's changedAt (ADR-0027 note 2026-10-29, W7-12): a takedown or an erasure changes
// an entry without moving its lastMessageAt, and only the change stamp can surface it to a cached device.

import (
	"context"
	"testing"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

func TestListConversations_SinceFollowsChangedAt(t *testing.T) {
	rg := newRig(t, nil)
	older := rg.entryAt("peer-a", 0)
	removed := rg.entryAt("peer-b", 1) // a takedown rewrote its preview just now; lastMessageAt is an hour old
	removed.ChangedAt, removed.Last.State, removed.Last.Snippet = rg.now, msgRemoved, removedSnippet
	legacy := rg.entryAt("peer-c", 2) // written before changedAt existed
	legacy.ChangedAt = time.Time{}
	rg.put(alice, dmInboxCollection, older, removed, legacy)

	first := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if got := convIDs(first); len(got) != 3 || got[0] != legacy.ID || got[1] != removed.ID || got[2] != older.ID {
		t.Fatalf("first page = %v, want lastMessageAt order (legacy, removed, older)", got)
	}
	// The first page's token is "now - settle", not the newest row's time: its rows are ordered by lastMessageAt and bound
	// nothing about entries changed further down.
	pos, err := cursor.DecodeAtTTL(testCursorKey, sinceBinding(alice, dmInboxCollection), first.SinceToken, rg.now, RefreshTokenTTL)
	if err != nil || !pos.CreatedAt.Equal(rg.now.Add(-SettleWindow)) || pos.DocID != "-" {
		t.Fatalf("first page since position = %+v (%v), want now - settle with doc id -", pos, err)
	}

	// A refresh returns only the entry changed since, with its preview as rewritten; the old order of the others is not
	// involved, and an entry without changedAt is never returned.
	ref := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if got := convIDs(ref); len(got) != 1 || got[0] != removed.ID {
		t.Fatalf("refresh = %v, want only the changed entry", got)
	}
	c := ref.Conversations[0]
	if c.LastMessage.State != messagingv1.MessageState_MESSAGE_STATE_REMOVED || c.LastMessage.Snippet != "" {
		t.Errorf("preview = %v %q, want REMOVED with no snippet", c.LastMessage.State, c.LastMessage.Snippet)
	}
	if !c.UpdatedAt.AsTime().Equal(removed.LastMessageAt) || !c.LastMessage.CreatedAt.AsTime().Equal(removed.LastMessageAt) {
		t.Errorf("updated_at/preview time = %v / %v, want lastMessageAt %v (the inbox order does not move)", c.UpdatedAt.AsTime(), c.LastMessage.CreatedAt.AsTime(), removed.LastMessageAt)
	}
	// The next position trails the newest changed entry's changedAt by the settle window.
	next, err := cursor.DecodeAtTTL(testCursorKey, sinceBinding(alice, dmInboxCollection), ref.SinceToken, rg.now, RefreshTokenTTL)
	if err != nil || !next.CreatedAt.Equal(removed.ChangedAt.Add(-SettleWindow)) || next.DocID != removed.ID {
		t.Errorf("refresh since position = %+v (%v), want changedAt - settle at %s", next, err, removed.ID)
	}
	// A quiet refresh keeps the position.
	rg.now = rg.now.Add(time.Hour)
	rg.repo.entries = nil
	quiet := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: ref.SinceToken})
	if got, _ := cursor.DecodeAtTTL(testCursorKey, sinceBinding(alice, dmInboxCollection), quiet.SinceToken, rg.now, RefreshTokenTTL); got != next {
		t.Errorf("a quiet refresh moved the position: %+v -> %+v", next, got)
	}
}

// A since token of the earlier kind (the position was a lastMessageAt) is refused with no read; the client cold-opens once.
func TestListConversations_PreChangeSinceTokenIsRetired(t *testing.T) {
	rg := newRig(t, nil)
	for _, folder := range []string{dmInboxCollection, dmRequestsCollection} {
		old := cursor.EncodeAt(testCursorKey, "messaging|conversations|since|"+alice+"|"+folder, cursor.Cursor{CreatedAt: rg.now.Add(-time.Minute), DocID: "-"}, rg.now)
		f := inbox
		if folder == dmRequestsCollection {
			f = requests
		}
		_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: f, SinceToken: old})
		wantField(t, err, "since_token")
	}
	if rg.repo.lists != 0 || rg.social.calls != 0 {
		t.Errorf("reads: lists=%d graph=%d, want 0", rg.repo.lists, rg.social.calls)
	}
}
