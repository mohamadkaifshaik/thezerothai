package messaging

import (
	"context"
	"fmt"
	"testing"
)

// UnreadBadge (ADR-0027 D10, W7-11): the count of inbox entries with unreadCount > 0, capped at 100; requests and read
// entries never count; one repo call (1 read) each.
func TestUnreadBadge(t *testing.T) {
	t.Parallel()
	mk := func(n, unread int) []EntryRow {
		rows := make([]EntryRow, n)
		for i := range rows {
			rows[i].ID = fmt.Sprintf("%032d", i)
			if i < unread {
				rows[i].UnreadCount = 1 + int64(i%3)
			}
		}
		return rows
	}
	tests := []struct {
		name     string
		inbox    []EntryRow
		requests []EntryRow
		want     int64
	}{
		{name: "none", want: 0},
		{name: "three unread of five", inbox: mk(5, 3), want: 3},
		{name: "150 unread caps at 100", inbox: mk(150, 150), want: 100},
		{name: "requests do not count", inbox: mk(2, 1), requests: mk(4, 4), want: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := &fakeRepo{entries: map[string][]EntryRow{
				entryKey(alice, dmInboxCollection):    tt.inbox,
				entryKey(alice, dmRequestsCollection): tt.requests,
			}}
			got, err := NewUnreadBadge(repo).UnreadConversations(context.Background(), alice)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want || repo.unreads != 1 {
				t.Errorf("count = %d (want %d), repo calls = %d (want 1)", got, tt.want, repo.unreads)
			}
		})
	}
}
