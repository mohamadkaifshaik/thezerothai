package messaging

// The thread revision in ListMessages since tokens (ADR-0027 note 2026-10-29, W7-12): a takedown or an erasure increments
// conversations/{id}.rev, a since token carries the revision its issuer saw, and a poll whose token is behind is retired
// with the answer of an expired token.

import (
	"bytes"
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func (r *rig) sinceRevOf(t *testing.T, uid, token string) int64 {
	t.Helper()
	_, rev, err := cursor.DecodeRevAtTTL(testCursorKey, messagesSinceBinding(uid, aliceBobConv), token, r.now, RefreshTokenTTL)
	if err != nil {
		t.Fatalf("token does not decode: %v", err)
	}
	return rev
}

func (r *rig) sinceTokenWith(uid string, rev int64, at time.Time) string {
	return cursor.EncodeRevAt(testCursorKey, messagesSinceBinding(uid, aliceBobConv), cursor.Cursor{CreatedAt: r.now.Add(-time.Minute), DocID: "-"}, rev, at)
}

func TestListMessages_ThreadRevision(t *testing.T) {
	t.Run("token behind the conversation is retired like an expired one, after one read", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 2 })
		for name, tok := range map[string]string{"rev 0": rg.sinceTokenWith(alice, 0, rg.now), "rev 1": rg.sinceTokenWith(alice, 1, rg.now),
			"legacy token": cursor.EncodeAt(testCursorKey, messagesSinceBinding(alice, aliceBobConv), cursor.Cursor{CreatedAt: rg.now.Add(-time.Minute), DocID: "-"}, rg.now)} {
			rg.repo.gets, rg.repo.msgQueries = 0, nil
			_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tok})
			wantField(t, err, "since_token")
			if rg.repo.gets > 1 || len(rg.repo.msgQueries) != 0 {
				t.Errorf("%s: conversation reads %d, message queries %d, want at most 1 and 0", name, rg.repo.gets, len(rg.repo.msgQueries))
			}
			rg.svc.convs.Delete(aliceBobConv)
		}
		// The very bytes of an expired token (no oracle on why the token was refused).
		expired := rg.sinceTokenWith(alice, 2, rg.now.Add(-31*24*time.Hour))
		_, errExpired := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: expired})
		_, errRetired := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: rg.sinceTokenWith(alice, 1, rg.now)})
		if !bytes.Equal(wireBytes(t, errExpired), wireBytes(t, errRetired)) {
			t.Errorf("retired %q differs from expired %q", wireBytes(t, errRetired), wireBytes(t, errExpired))
		}
	})

	t.Run("a legacy token is accepted while the conversation has no revision", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, nil)
		legacy := cursor.EncodeAt(testCursorKey, messagesSinceBinding(alice, aliceBobConv), cursor.Cursor{CreatedAt: rg.now.Add(-time.Minute), DocID: "-"}, rg.now)
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: legacy})
		if rev := rg.sinceRevOf(t, alice, resp.SinceToken); rev != 0 {
			t.Errorf("re-sealed revision = %d, want 0", rev)
		}
	})

	t.Run("equal revision is accepted and kept", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 4 })
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: rg.sinceTokenWith(alice, 4, rg.now)})
		if rev := rg.sinceRevOf(t, alice, resp.SinceToken); rev != 4 {
			t.Errorf("re-sealed revision = %d, want 4", rev)
		}
	})

	t.Run("higher revision: this instance's copy is stale, it is dropped and the higher revision sealed", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, nil) // the instance (and storage, for this rig) still says rev 0
		first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if _, ok := rg.svc.convs.Get(aliceBobConv); !ok {
			t.Fatal("setup: the conversation is not cached")
		}
		reads := rg.repo.gets
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: rg.sinceTokenWith(alice, 3, rg.now)})
		if rev := rg.sinceRevOf(t, alice, resp.SinceToken); rev != 3 {
			t.Errorf("sealed revision = %d, want max(token 3, conversation 0) = 3 (never backwards)", rev)
		}
		if _, ok := rg.svc.convs.Get(aliceBobConv); ok {
			t.Error("the stale cached conversation was kept")
		}
		if rg.repo.gets != reads {
			t.Errorf("conversation reads %d -> %d: accepting a higher revision costs no read", reads, rg.repo.gets)
		}
		if rev := rg.sinceRevOf(t, alice, first.SinceToken); rev != 0 {
			t.Errorf("first page token revision = %d, want 0", rev)
		}
	})

	t.Run("a first page seals the conversation's revision", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 5 })
		first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if rev := rg.sinceRevOf(t, alice, first.SinceToken); rev != 5 {
			t.Errorf("first page token revision = %d, want 5", rev)
		}
		// ...and the poll with it is accepted, and the new token keeps it.
		poll := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken})
		if rev := rg.sinceRevOf(t, alice, poll.SinceToken); rev != 5 {
			t.Errorf("poll token revision = %d, want 5", rev)
		}
	})

	t.Run("a tampered or foreign token costs no read", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 1 })
		good := rg.sinceTokenWith(alice, 1, rg.now)
		flipped := []byte(good)
		flipped[len(flipped)/2] ^= 1
		for name, tc := range map[string]struct{ uid, tok string }{
			"tampered":     {alice, string(flipped)},
			"another user": {bob, good},
		} {
			rg.repo.gets = 0
			_, err := rg.svc.ListMessages(context.Background(), tc.uid, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tc.tok})
			wantField(t, err, "since_token")
			if rg.repo.gets != 0 {
				t.Errorf("%s: %d conversation reads, want 0", name, rg.repo.gets)
			}
		}
	})

	t.Run("a non-participant is NOT_FOUND before the revision is looked at", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 9 })
		tok := cursor.EncodeRevAt(testCursorKey, messagesSinceBinding("uid-mallory", aliceBobConv), cursor.Cursor{CreatedAt: rg.now, DocID: "-"}, 0, rg.now)
		_, err := rg.svc.ListMessages(context.Background(), "uid-mallory", &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tok})
		if code, _, _ := reasonOf(t, err); code != connect.CodeNotFound {
			t.Fatalf("err = %v, want NOT_FOUND", err)
		}
	})

	t.Run("the retirement is logged as a boolean and nothing else", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, func(c *ConvDoc) { c.Rev = 1 })
		ctx, info := logger.WithRequestInfo(context.Background())
		_, _ = rg.svc.ListMessages(ctx, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: rg.sinceTokenWith(alice, 0, rg.now)})
		if got, _ := info.Get(fieldSinceRetire); got != true {
			t.Errorf("since_retired = %v, want true", got)
		}
	})
}
