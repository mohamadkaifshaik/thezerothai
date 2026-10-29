//go:build integration

package messaging

import (
	"reflect"
	"testing"
	"time"
)

// DeleteConversation stores the digest of its idempotency_key as clearedKey.{caller} in the same update as clearedAt (ADR-0027
// 2026-10-29 note): +0 reads, +0 writes. Given B deletes with K and the response is lost, then A sends a new message, which
// recreates B's entry, then B retries with K: a replay, nothing written, B's entry intact and A's new message visible in
// B's thread. Given B deletes again with a new key K2, then it is a real delete.
func TestDelete_RetryWithTheSameKeyAfterANewerMessage(t *testing.T) {
	const k1, k2 = "delete-retry-key-00000001", "delete-retry-key-00000002"
	e := newIT(t, nil)
	id := e.request(2)
	e.tick(time.Minute)

	c, err := e.delKey(e.newService(), bob, id, k1)
	if err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 3 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Errorf("delete reads/writes/deletes = %d/%d/%d, want 3/1/1 (the key adds no read and no write)", c.Reads(), c.Writes(), c.Deletes())
	}
	conv, _ := e.conv(id)
	if conv.ClearedKey[bob] != keyDigest(bob, opDelete, k1) || len(conv.ClearedKey) != 1 || conv.ClearedAt[bob].IsZero() {
		t.Fatalf("conversation after the delete = %+v, want clearedAt and clearedKey for bob only", conv)
	}

	// The response was lost. A's next message recreates B's request entry.
	e.tick(time.Second)
	e.must(alice, toUser(skey(700), bob, "after the delete"))
	before, ok := e.entry(bob, dmRequestsCollection, id)
	beforeConv, _ := e.conv(id) // A's request message moved requestCount and updatedAt; the retry must not move anything more
	if !ok || before.UnreadCount != 1 {
		t.Fatalf("bob's recreated entry = %+v %v", before, ok)
	}

	// B retries with K from a cold instance.
	e.tick(time.Second)
	retry := e.newService()
	rc, err := e.delKey(retry, bob, id, k1)
	if err != nil {
		t.Fatalf("retry with the same key: %v", err)
	}
	if rc.Reads() > 3 || rc.Writes() != 0 || rc.Deletes() != 0 {
		t.Errorf("retry reads/writes/deletes = %d/%d/%d, want at most 3 reads and nothing written", rc.Reads(), rc.Writes(), rc.Deletes())
	}
	t.Logf("retry with the same key: reads %d writes %d deletes %d", rc.Reads(), rc.Writes(), rc.Deletes())
	after, ok := e.entry(bob, dmRequestsCollection, id)
	if !ok || after != before {
		t.Errorf("bob's entry after the retry = %+v %v, want it intact (%+v)", after, ok, before)
	}
	if again, _ := e.conv(id); !reflect.DeepEqual(again, beforeConv) {
		t.Errorf("the retry changed the conversation: %+v -> %+v", beforeConv, again)
	}
	if got := e.threadTexts(retry, bob, id); len(got) != 1 || got[0] != "after the delete" {
		t.Errorf("bob reads %v on the retrying instance, want the newer message", got)
	}
	if got := e.threadTexts(e.newService(), bob, id); len(got) != 1 || got[0] != "after the delete" {
		t.Errorf("bob reads %v on a cold instance, want the newer message", got)
	}

	// A new key is a real delete: the recreated entry goes, the thread is empty, the stored digest is K2's.
	e.tick(time.Second)
	dc, err := e.delKey(e.newService(), bob, id, k2)
	if err != nil {
		t.Fatal(err)
	}
	if dc.Reads() != 3 || dc.Writes() != 1 || dc.Deletes() != 1 {
		t.Errorf("a delete under a new key: reads/writes/deletes = %d/%d/%d, want 3/1/1", dc.Reads(), dc.Writes(), dc.Deletes())
	}
	if _, ok := e.entry(bob, dmRequestsCollection, id); ok {
		t.Error("the entry survived a delete under a new key")
	}
	if got := e.threadTexts(e.newService(), bob, id); len(got) != 0 {
		t.Errorf("bob reads %v after the second delete", got)
	}
	final, _ := e.conv(id)
	if final.ClearedKey[bob] != keyDigest(bob, opDelete, k2) || !final.ClearedAt[bob].After(conv.ClearedAt[bob]) {
		t.Errorf("after the second delete clearedKey = %v clearedAt = %v, want K2's digest and a later clearedAt", final.ClearedKey, final.ClearedAt)
	}
	if _, has := final.ClearedKey[alice]; has {
		t.Error("bob's delete wrote alice's clearedKey")
	}
	// The retry of the old key K now finds no entry and a clearedAt: a state replay, nothing written.
	oc, err := e.delKey(e.newService(), bob, id, k1)
	if err != nil || oc.Writes() != 0 || oc.Deletes() != 0 {
		t.Errorf("retry of the old key after the second delete: err %v writes/deletes %d/%d, want success and 0/0", err, oc.Writes(), oc.Deletes())
	}
}
