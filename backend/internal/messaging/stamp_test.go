package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// The send stamp (W7-9 B2): a message and both entries are stamped strictly after either participant's clearedAt, so a
// DeleteConversation that committed between a send's clock read and its transaction cannot hide the message it recreates.
func TestStampAfterClear(t *testing.T) {
	t0 := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	us := time.Microsecond
	tests := []struct {
		name string
		now  time.Time
		conv *ConvDoc
		want time.Time
	}{
		{"new conversation", t0, nil, t0},
		{"nobody cleared", t0, &ConvDoc{}, t0},
		{"cleared long before", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0.Add(-time.Hour)}}, t0},
		{"cleared 1 µs before", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0.Add(-us)}}, t0},
		{"cleared at the same instant", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0}}, t0.Add(us)},
		{"cleared after the clock (a slower instance)", t0, &ConvDoc{ClearedAt: map[string]time.Time{bob: t0.Add(3 * time.Second)}}, t0.Add(3*time.Second + us)},
		{"both cleared, the later one wins", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0.Add(time.Second), bob: t0.Add(2 * time.Second)}}, t0.Add(2*time.Second + us)},
		{"both cleared, only one is ahead", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0.Add(-time.Second), bob: t0.Add(time.Millisecond)}}, t0.Add(time.Millisecond + us)},
		{"both cleared at the same instant", t0, &ConvDoc{ClearedAt: map[string]time.Time{alice: t0, bob: t0}}, t0.Add(us)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// The map is iterated in random order: the result must not depend on it.
			for range 20 {
				got := stampAfterClear(tt.now, tt.conv)
				if !got.Equal(tt.want) {
					t.Fatalf("stampAfterClear = %v, want %v", got, tt.want)
				}
				if tt.conv != nil {
					for uid, c := range tt.conv.ClearedAt {
						if !got.After(c) && c.After(tt.now.Add(-time.Nanosecond)) {
							t.Fatalf("stamp %v is not after %s's clearedAt %v", got, uid, c)
						}
					}
				}
				if got.Before(tt.now) {
					t.Fatalf("stamp %v is before now %v", got, tt.now)
				}
			}
		})
	}
}

// notBefore is the max of the clock and its floors; DeleteConversation uses it so clearedAt covers the newest message the
// caller's entry shows and updatedAt only moves forward.
func TestNotBefore(t *testing.T) {
	t0 := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		now    time.Time
		floors []time.Time
		want   time.Time
	}{
		{"no floors", t0, nil, t0},
		{"zero floors are ignored", t0, []time.Time{{}, {}}, t0},
		{"floors in the past", t0, []time.Time{t0.Add(-time.Second)}, t0},
		{"a floor ahead", t0, []time.Time{t0.Add(time.Second)}, t0.Add(time.Second)},
		{"the latest of several", t0, []time.Time{t0.Add(time.Second), {}, t0.Add(time.Minute), t0.Add(-time.Hour)}, t0.Add(time.Minute)},
		{"equal", t0, []time.Time{t0}, t0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := notBefore(tt.now, tt.floors...); !got.Equal(tt.want) {
				t.Errorf("notBefore = %v, want %v", got, tt.want)
			}
		})
	}
}

// Given an entry whose last message is ahead of this instance's clock (a send stamped it so), then a delete clears at least
// up to it: the thread the caller saw is gone, not all but its newest message.
func TestDelete_ClearsUpToTheNewestMessageOfTheEntry(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	ahead := rg.now.Add(4 * time.Second)
	rows := rg.repo.entries[entryKey(bob, dmRequestsCollection)]
	rows[0].LastMessageAt = ahead
	if err := rg.del(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	conv := rg.repo.convs[aliceBobConv]
	if !conv.ClearedAt[bob].Equal(ahead) || !conv.UpdatedAt.Equal(ahead) {
		t.Errorf("clearedAt = %v updatedAt = %v, want both %v", conv.ClearedAt[bob], conv.UpdatedAt, ahead)
	}
	// The cache on this instance carries the same stamp.
	if c, ok := rg.svc.convs.Get(aliceBobConv); !ok || !c.ClearedAt[bob].Equal(ahead) {
		t.Errorf("cached conversation = %+v %v", c, ok)
	}
}

// putConv never puts an older document over a newer one (N3): a handler that finishes late, or a Delete whose copy an
// Accept has already superseded on this instance, leaves the newer copy in place; an equal or newer one replaces it.
func TestPutConv_NeverGoesBackwards(t *testing.T) {
	rg := newRig(t, nil)
	t0 := rg.now
	id := aliceBobConv
	doc := func(updated time.Time, state string) ConvDoc {
		return ConvDoc{Participants: sortedPair(alice, bob), State: state, UpdatedAt: updated}
	}
	rg.svc.putConv(id, doc(t0, stateRequest))
	rg.svc.putConv(id, doc(t0.Add(time.Second), stateAccepted)) // newer replaces
	if c, _ := rg.svc.convs.Get(id); c.State != stateAccepted {
		t.Fatalf("newer copy not stored: %+v", c)
	}
	rg.svc.putConv(id, doc(t0, stateRequest)) // older is ignored
	if c, _ := rg.svc.convs.Get(id); c.State != stateAccepted || !c.UpdatedAt.Equal(t0.Add(time.Second)) {
		t.Errorf("an older copy replaced a newer one: %+v", c)
	}
	same := doc(t0.Add(time.Second), stateAccepted)
	same.ClearedAt = map[string]time.Time{bob: t0}
	rg.svc.putConv(id, same) // equal updatedAt replaces (same document, fresher fields)
	if c, _ := rg.svc.convs.Get(id); c.ClearedAt[bob].IsZero() {
		t.Errorf("an equal copy was refused: %+v", c)
	}
}

// The revision only breaks ties (ADR-0027 note 2026-10-29): a late put of a pre-takedown copy (older updatedAt) is refused;
// with an equal updatedAt the lower revision is refused and the higher kept; a newer updatedAt replaces even with a lower
// revision.
func TestPutConv_RevBreaksTiesOnly(t *testing.T) {
	rg := newRig(t, nil)
	t0 := rg.now
	id := aliceBobConv
	doc := func(updated time.Time, rev int64) ConvDoc {
		return ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted, UpdatedAt: updated, Rev: rev}
	}
	rg.svc.putConv(id, doc(t0.Add(time.Second), 1)) // the takedown's copy: strictly later updatedAt, rev 1
	rg.svc.putConv(id, doc(t0, 0))                  // a late pre-takedown copy
	if c, _ := rg.svc.convs.Get(id); c.Rev != 1 {
		t.Fatalf("a pre-takedown copy replaced the takedown's: %+v", c)
	}
	rg.svc.putConv(id, doc(t0.Add(time.Second), 0)) // equal updatedAt, lower rev
	if c, _ := rg.svc.convs.Get(id); c.Rev != 1 {
		t.Errorf("an equal-updatedAt copy with a lower rev replaced the higher: %+v", c)
	}
	rg.svc.putConv(id, doc(t0.Add(time.Second), 2)) // equal updatedAt, higher rev
	if c, _ := rg.svc.convs.Get(id); c.Rev != 2 {
		t.Errorf("an equal-updatedAt copy with a higher rev was refused: %+v", c)
	}
	rg.svc.putConv(id, doc(t0.Add(2*time.Second), 0)) // newer updatedAt, lower rev: replaces
	if c, _ := rg.svc.convs.Get(id); !c.UpdatedAt.Equal(t0.Add(2*time.Second)) || c.Rev != 0 {
		t.Errorf("a newer copy with a lower rev was refused: %+v", c)
	}
}

// failure is the one tail of the three error mappers. The order matters: an apierr passes through, NOT_FOUND is the one
// byte-identical answer, a finished request context beats a storage error, a lost transaction is UNAVAILABLE with a retry
// hint, and anything else is INTERNAL with the ids replaced.
func TestFailure_SharedTail(t *testing.T) {
	rg := newRig(t, nil)
	s := rg.svc
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	t.Run("apierr passes through unchanged", func(t *testing.T) {
		in := apierr.Validation("x", "y")
		if got := s.failure(context.Background(), "accept", alice, aliceBobConv, fmt.Errorf("wrapped: %w", in)); got == nil || !errors.Is(got, in) {
			t.Errorf("got %v", got)
		}
	})
	t.Run("not found is the one NOT_FOUND", func(t *testing.T) {
		got := s.failure(context.Background(), "list_messages", alice, aliceBobConv, fmt.Errorf("x: %w", ErrNotFound))
		if code, _, _ := reasonOf(t, got); code != connect.CodeNotFound {
			t.Errorf("got %v", got)
		}
	})
	t.Run("a canceled request beats the storage error", func(t *testing.T) {
		got := s.failure(canceled, "delete", alice, aliceBobConv, errors.New("storage"))
		if code, _, _ := reasonOf(t, got); code != connect.CodeCanceled {
			t.Errorf("got %v", got)
		}
	})
	for name, err := range map[string]error{
		"contended":         fmt.Errorf("txn: %w", store.ErrContended),
		"deadline exceeded": fmt.Errorf("read: %w", context.DeadlineExceeded),
	} {
		t.Run(name+" is UNAVAILABLE busy", func(t *testing.T) {
			got := s.failure(context.Background(), "accept", alice, aliceBobConv, err)
			if code, _, _ := reasonOf(t, got); code != connect.CodeUnavailable {
				t.Errorf("got %v", got)
			}
		})
	}
	// A timeout or contention is "busy" only where a transaction ran; a read path (list_messages) keeps INTERNAL so Error
	// Reporting sees it and the client's retry interceptor does not triple the polls (re-review S-a).
	for _, op := range []string{"send", "accept", "delete"} {
		for name, err := range map[string]error{
			"contended":         fmt.Errorf("txn: %w", store.ErrContended),
			"deadline exceeded": fmt.Errorf("read: %w", context.DeadlineExceeded),
			"grpc deadline":     status.Error(codes.DeadlineExceeded, "rpc deadline"),
		} {
			t.Run(op+"/"+name+" is UNAVAILABLE busy", func(t *testing.T) {
				if got := s.failure(context.Background(), op, alice, aliceBobConv, err); apierr.ToConnect(got).Code() != connect.CodeUnavailable {
					t.Errorf("got %v", got)
				}
			})
		}
	}
	for name, err := range map[string]error{
		"contended":         fmt.Errorf("txn: %w", store.ErrContended),
		"deadline exceeded": fmt.Errorf("read: %w", context.DeadlineExceeded),
		"grpc deadline":     status.Error(codes.DeadlineExceeded, "rpc deadline"),
	} {
		t.Run("list_messages/"+name+" stays internal", func(t *testing.T) {
			got := s.failure(context.Background(), "list_messages", alice, aliceBobConv, err)
			if c := apierr.ToConnect(got).Code(); c != connect.CodeInternal {
				t.Errorf("code = %v, want Internal (got %v)", c, got)
			}
		})
	}
	t.Run("anything else is internal and redacted", func(t *testing.T) {
		got := s.failure(context.Background(), "send", alice, aliceBobConv, fmt.Errorf("rpc: users/%s/dmInbox/%s %s", alice, aliceBobConv, "peer-uid-xyz"), "peer-uid-xyz")
		var ae *apierr.Error
		if got == nil || errors.As(got, &ae) {
			t.Fatalf("got %v, want a plain internal error", got)
		}
		if containsAny(got.Error(), alice, aliceBobConv, "peer-uid-xyz") {
			t.Errorf("the error leaks an id: %q", got)
		}
	})
}

// The digest behind every stored key (C1): one construction, bound to the user and to the operation, so a message id is
// unchanged by the refactor and the same key reused for another operation or by another user digests differently.
func TestKeyDigest(t *testing.T) {
	if got, want := MessageID(alice, "k-0123456789abcdef"), digest32(alice+"|SendMessage|k-0123456789abcdef"); got != want {
		t.Errorf("MessageID = %s, want the C1 construction %s", got, want)
	}
	base := keyDigest(alice, opDelete, "key-0123456789abcdef")
	if len(base) != 32 {
		t.Errorf("digest length = %d, want 32 hex characters", len(base))
	}
	for name, other := range map[string]string{
		"another user":      keyDigest(bob, opDelete, "key-0123456789abcdef"),
		"another operation": keyDigest(alice, opSend, "key-0123456789abcdef"),
		"another key":       keyDigest(alice, opDelete, "key-0123456789abcdeg"),
	} {
		if other == base {
			t.Errorf("%s digests the same as the base", name)
		}
	}
	if keyDigest(alice, opDelete, "key-0123456789abcdef") != base {
		t.Error("the digest is not deterministic")
	}
}

func TestDeleteIsKeyReplay(t *testing.T) {
	d := keyDigest(bob, opDelete, "key-0123456789abcdef")
	tests := []struct {
		name   string
		conv   ConvDoc
		uid    string
		digest string
		want   bool
	}{
		{"same key", ConvDoc{ClearedKey: map[string]string{bob: d}}, bob, d, true},
		{"another key", ConvDoc{ClearedKey: map[string]string{bob: d}}, bob, keyDigest(bob, opDelete, "key-other-0123456789"), false},
		{"nothing stored", ConvDoc{}, bob, d, false},
		{"the peer's digest is not the caller's", ConvDoc{ClearedKey: map[string]string{alice: d}}, bob, d, false},
		{"an empty digest never matches", ConvDoc{ClearedKey: map[string]string{bob: ""}}, bob, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := deleteIsKeyReplay(tt.conv, tt.uid, tt.digest); got != tt.want {
				t.Errorf("deleteIsKeyReplay = %v, want %v", got, tt.want)
			}
		})
	}
}

// A storage timeout while the request itself is alive (re-review S-a): ListMessages, a read path, stays INTERNAL (the
// error middleware logs it at ERROR for Error Reporting, and the client does not retry it), with no "contention" WARN;
// Send, a transaction, is UNAVAILABLE busy with the WARN. Both keep the cause in the chain.
func TestTimeoutOnReadPathVersusTransaction(t *testing.T) {
	timeout := fmt.Errorf("rpc: %w", context.DeadlineExceeded)

	t.Run("ListMessages is INTERNAL and not contention", func(t *testing.T) {
		var logs bytes.Buffer
		rg := newRig(t, nil)
		rg.svc.d.Log = slog.New(slog.NewJSONHandler(&logs, nil))
		rg.putThread(1, nil)
		rg.repo.msgErr = timeout
		_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if err == nil || apierr.ToConnect(err).Code() != connect.CodeInternal || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("err = %v, want INTERNAL carrying the timeout for the error middleware", err)
		}
		if strings.Contains(logs.String(), "contention") {
			t.Errorf("a read-path timeout logged as contention: %s", logs.String())
		}
	})

	t.Run("Send is UNAVAILABLE busy with the contention WARN", func(t *testing.T) {
		var logs bytes.Buffer
		rg := newRig(t, func(r *rig) { r.repo.sendErr = timeout })
		rg.svc.d.Log = slog.New(slog.NewJSONHandler(&logs, nil))
		_, err := rg.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
		if code, _, _ := reasonOf(t, err); code != connect.CodeUnavailable {
			t.Fatalf("err = %v, want UNAVAILABLE", err)
		}
		if !strings.Contains(logs.String(), "messaging_send_contention") || !strings.Contains(logs.String(), `"level":"WARN"`) {
			t.Errorf("no contention WARN: %s", logs.String())
		}
	})
}
