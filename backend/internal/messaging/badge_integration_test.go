//go:build integration

package messaging

import (
	"context"
	"fmt"
	"testing"
)

// on the emulator: count of dmInbox where unreadCount > 0, Limit 100; 3 -> 3, 150 -> 100, requests and
// read entries never count.
func TestIntegration_UnreadConversationsCount(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	seed := func(uid, folder string, i int, unread int64) {
		t.Helper()
		doc := EntryDoc{PeerID: fmt.Sprintf("peer-%d", i), UnreadCount: unread}
		if _, err := e.fs.Collection("users").Doc(uid).Collection(folder).Doc(fmt.Sprintf("%032x", i)).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	count := func(uid string) int64 {
		t.Helper()
		n, err := NewUnreadBadge(e.repo).UnreadConversations(ctx, uid)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}

	if n := count(carol); n != 0 {
		t.Errorf("no entries: count = %d, want 0", n)
	}

	for i := 0; i < 3; i++ {
		seed(alice, dmInboxCollection, i, int64(i+1))
	}
	seed(alice, dmInboxCollection, 50, 0) // read: not counted
	for i := 60; i < 64; i++ {
		seed(alice, dmRequestsCollection, i, 2) // requests: not counted
	}
	n := count(alice)
	if n != 3 {
		t.Errorf("3 unread: count = %d, want 3", n)
	}

	for i := 0; i < 150; i++ {
		seed(bob, dmInboxCollection, i, 1)
	}
	n = count(bob)
	if n != 100 {
		t.Errorf("150 unread: count = %d, want the cap 100", n)
	}
}
