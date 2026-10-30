//go:build integration

// send_fresh_integration_test.go: W7-33 (security review L-1, L-3; ADR-0027 note W7-33). The recipient's graph and, for a
// new conversation, the recipient's users document are read INSIDE the send transaction against the real graph and
// identity repos, so a Block, Mute or Unfollow by the recipient, a deletion or a suspension that committed on any
// instance decides the send, and one that commits while the send is in flight conflicts with it.
package messaging

import (
	"context"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// raceSocial wraps the real graph reader. Its first run answers with the real read and then fails with ABORTED (the SDK
// re-runs the body); at the start of the second run, when the first run's locks are released, it commits a competing write
// (the recipient's Block, committed "while the send was in flight") and then reads for real. The send must see it.
type raceSocial struct {
	inner TxSocial
	mu    sync.Mutex
	runs  int
	write func()
}

func (r *raceSocial) SnapshotInTx(ctx context.Context, tx *firestore.Transaction, uid string) (graph.Snapshot, error) {
	r.mu.Lock()
	r.runs++
	run := r.runs
	r.mu.Unlock()
	if run == 2 {
		r.write()
	}
	snap, err := r.inner.SnapshotInTx(ctx, tx, uid)
	if err == nil && run == 1 {
		return snap, status.Error(codes.Aborted, "forced re-run")
	}
	return snap, err
}

// raceProfiles is raceSocial for the recipient's users document (a DeleteAccount that commits mid-send).
type raceProfiles struct {
	inner identity.TxProfiles
	mu    sync.Mutex
	runs  int
	write func()
}

func (r *raceProfiles) ProfileInTx(ctx context.Context, tx *firestore.Transaction, uid string) (identity.Profile, error) {
	r.mu.Lock()
	r.runs++
	run := r.runs
	r.mu.Unlock()
	if run == 2 {
		r.write()
	}
	p, err := r.inner.ProfileInTx(ctx, tx, uid)
	if err == nil && run == 1 {
		return p, status.Error(codes.Aborted, "forced re-run")
	}
	return p, err
}

func wantNothingWritten(t *testing.T, e *itEnv, convID string) {
	t.Helper()
	if _, ok := e.conv(convID); ok {
		t.Error("a conversation was written")
	}
	if n := len(e.msgs(convID)); n != 0 {
		t.Errorf("%d messages were written", n)
	}
	for _, uid := range []string{alice, bob} {
		for _, col := range []string{"dmInbox", "dmRequests"} {
			if _, ok := e.entry(uid, col, convID); ok {
				t.Errorf("an entry was written in %s/%s", uid, col)
			}
		}
	}
	if len(e.events.got) != 0 {
		t.Errorf("%d push events", len(e.events.got))
	}
}

// B blocked A on another instance within the last 60 s: A's instance still caches a Blocked-free snapshot of B, but the send
// reads B's graph in its transaction and is refused, with no message, no entry and no event.
func TestSend_StaleRecipientCacheCannotOutliveABlock(t *testing.T) {
	for _, existing := range []bool{false, true} {
		name := "new conversation"
		if existing {
			name = "existing conversation"
		}
		t.Run(name, func(t *testing.T) {
			e := newIT(t, nil)
			e.mutual(alice, bob)
			convID := ConversationID(alice, bob)
			if existing {
				e.must(alice, toUser(skey(1), bob, "before the block"))
			}
			msgsBefore, eventsBefore := len(e.msgs(convID)), len(e.events.got)
			// The cache (fakeSocial) keeps the old value; only the stored document changes.
			e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Blocked: map[string]bool{alice: true}})
			_, _, err := e.send(alice, toUser(skey(2), bob, "after the block"))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
			if existing {
				if n := len(e.msgs(convID)); n != msgsBefore {
					t.Errorf("messages = %d, want %d", n, msgsBefore)
				}
				if len(e.events.got) != eventsBefore {
					t.Error("a blocked send emitted an event")
				}
			} else {
				wantNothingWritten(t, e, convID)
			}
		})
	}
}

// B muted A within the last 60 s: the message is delivered silent (no unread increment, no push), whatever A's instance cached.
func TestSend_FreshMuteDeliversSilently(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(alice, toUser(skey(1), bob, "first"))
	pushed := len(e.events.got)
	convID := ConversationID(alice, bob)
	before, _ := e.entry(bob, "dmInbox", convID)
	e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Muted: map[string]bool{alice: true}})
	e.must(alice, toUser(skey(2), bob, "second"))
	after, ok := e.entry(bob, "dmInbox", convID)
	if !ok || after.UnreadCount != before.UnreadCount || !after.Silent {
		t.Errorf("entry after a muted send = %+v (unread before %d), want silent and no increment", after, before.UnreadCount)
	}
	if len(e.events.got) != pushed {
		t.Error("a muted sender pushed")
	}
}

// B unfollowed A within the last 60 s: A's new conversation is a REQUEST in B's dmRequests, not mutual.
func TestSend_FreshUnfollowMakesTheNewConversationARequest(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.writeGraphDoc(bob, graph.Snapshot{})
	e.must(alice, toUser(skey(1), bob, "hello"))
	convID := ConversationID(alice, bob)
	if _, ok := e.entry(bob, "dmRequests", convID); !ok {
		t.Error("bob has no dmRequests entry")
	}
	if _, ok := e.entry(bob, "dmInbox", convID); ok {
		t.Error("the stale Following made the conversation mutual")
	}
	if len(e.events.got) != 0 {
		t.Error("a request pushed")
	}
}

// B's graph is read before every cap: a blocked send is CANNOT_MESSAGE even when the request cap is exhausted.
func TestSend_BlockAnswersBeforeTheRequestCap(t *testing.T) {
	e := newIT(t, nil)
	e.writeGraphDoc(bob, graph.Snapshot{})
	for i := 1; i <= 3; i++ {
		e.must(alice, toUser(skey(i), bob, "request"))
	}
	e.writeGraphDoc(bob, graph.Snapshot{Blocked: map[string]bool{alice: true}})
	_, _, err := e.send(alice, toUser(skey(4), bob, "capped and blocked"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
}

// A Block of A by B that commits while A's send is in flight: the transaction re-runs and refuses. Never a message after the
// Block's commit.
func TestSend_ConcurrentBlockNeverLeavesAMessage(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.svc.d.TxSocial = &raceSocial{inner: e.txSocial, write: func() {
		e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Blocked: map[string]bool{alice: true}})
	}}
	_, _, err := e.send(alice, toUser(skey(1), bob, "racing the block"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
	wantNothingWritten(t, e, ConversationID(alice, bob))
}

// B's DeleteAccount (the users document turns DELETING) commits between A's directory read and A's new-conversation
// commit: the send is CANNOT_MESSAGE, and no conversation, entry or quota is written.
func TestSend_RecipientDeletedMidSendWritesNothing(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.svc.d.TxProfiles = &raceProfiles{inner: e.txProfs, write: func() {
		e.writeUserDoc(bob, "bob", time.Now().Add(-30*24*time.Hour), "DELETING")
	}}
	_, c, err := e.send(alice, toUser(skey(1), bob, "hi"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
	if c.Writes() != 0 {
		t.Errorf("wrote %d", c.Writes())
	}
	wantNothingWritten(t, e, ConversationID(alice, bob))
	if q, err := e.fs.Collection("quotas").Doc(alice).Get(context.Background()); err == nil && q.Exists() {
		t.Error("a quota record was written")
	}
}

// A suspended recipient, seen only in the transaction (the directory's cached copy still says ACTIVE), refuses a new
// conversation; an existing conversation is not re-checked (the accepted 60 s lag).
func TestSend_SuspendedRecipientRefusesNewConversationOnly(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.writeUserDoc(bob, "bob", time.Now().Add(-30*24*time.Hour), "SUSPENDED")
	_, _, err := e.send(alice, toUser(skey(1), bob, "hi"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
	wantNothingWritten(t, e, ConversationID(alice, bob))

	e.writeUserDoc(bob, "bob", time.Now().Add(-30*24*time.Hour), "ACTIVE")
	e.must(alice, toUser(skey(2), bob, "now it works"))
	e.writeUserDoc(bob, "bob", time.Now().Add(-30*24*time.Hour), "SUSPENDED")
	if _, _, err := e.send(alice, toUser(skey(3), bob, "existing conversation")); err != nil {
		t.Errorf("an existing conversation re-checked the recipient's status: %v", err)
	}
}
