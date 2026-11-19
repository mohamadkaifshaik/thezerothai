package apiserver

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// TestMessageReportFlagName_IsMessagingsOwn: moderation checks "messaging" is not globally off under
// the name moderation declares, because it cannot import messaging. The two must stay the same string, or a report would
// be gated on a flag nobody sets.
func TestMessageReportFlagName_IsMessagingsOwn(t *testing.T) {
	if moderation.MessagingFlagName != messaging.FlagName {
		t.Fatalf("moderation.MessagingFlagName = %q, messaging.FlagName = %q", moderation.MessagingFlagName, messaging.FlagName)
	}
}

// TestMessagePayloadLimit_IsTheCiphertextLimit: a payload is the plaintext of one ciphertext, so moderation's bound
// (declared without importing messaging) is the ciphertext's.
func TestMessagePayloadLimit_IsTheCiphertextLimit(t *testing.T) {
	if moderation.MaxMessagePayloadBytes != messaging.MaxCiphertextBytes {
		t.Fatalf("moderation.MaxMessagePayloadBytes = %d, messaging.MaxCiphertextBytes = %d", moderation.MaxMessagePayloadBytes, messaging.MaxCiphertextBytes)
	}
}

type fakeReporter struct {
	m   messaging.ReportedMessage
	err error
}

func (f fakeReporter) ReportableMessage(context.Context, string, string, string) (messaging.ReportedMessage, error) {
	return f.m, f.err
}

// TestLateMessageLookup: messaging's sentinels become moderation's (which builds the one wire answer), the evidence is
// copied field by field, an encrypted message crosses as Encrypted plus the verdict over the payload (never the
// commitment), an unbound adapter is an error and not a panic, and anything else passes through.
func TestLateMessageLookup(t *testing.T) {
	boom := errors.New("boom")
	at := time.Date(2026, 10, 29, 9, 0, 0, 0, time.UTC)
	payload := []byte("\x0a\x02hi")
	sum := messaging.ReportCommitment(payload)
	enc := messaging.ReportedMessage{SenderUID: "u", SenderHandle: "h", CreatedAt: at, Encrypted: true, Commitment: sum[:]}
	swept := enc
	swept.Commitment = nil
	// A plaintext message never verifies, even when a commitment were somehow present.
	plainWithBytes := messaging.ReportedMessage{SenderUID: "u", Text: "t", CreatedAt: at, Commitment: sum[:]}
	tests := []struct {
		name    string
		l       *lateMessageLookup
		payload []byte
		want    moderation.ReportedMessage
		wantErr error
	}{
		{"evidence copied", &lateMessageLookup{r: fakeReporter{m: messaging.ReportedMessage{SenderUID: "u", SenderHandle: "h", Text: "t", CreatedAt: at}}}, nil,
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", Text: "t", CreatedAt: at}, nil},
		{"encrypted, payload matches", &lateMessageLookup{r: fakeReporter{m: enc}}, payload,
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", CreatedAt: at, Encrypted: true, Verified: true}, nil},
		{"encrypted, one byte changed", &lateMessageLookup{r: fakeReporter{m: enc}}, []byte("\x0a\x02hj"),
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", CreatedAt: at, Encrypted: true}, nil},
		{"encrypted, no payload", &lateMessageLookup{r: fakeReporter{m: enc}}, nil,
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", CreatedAt: at, Encrypted: true}, nil},
		{"encrypted, commitment swept", &lateMessageLookup{r: fakeReporter{m: swept}}, payload,
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", CreatedAt: at, Encrypted: true}, nil},
		{"plaintext never verifies", &lateMessageLookup{r: fakeReporter{m: plainWithBytes}}, payload,
			moderation.ReportedMessage{SenderUID: "u", Text: "t", CreatedAt: at}, nil},
		{"not found", &lateMessageLookup{r: fakeReporter{err: messaging.ErrNotFound}}, payload, moderation.ReportedMessage{}, moderation.ErrMessageNotFound},
		{"own message", &lateMessageLookup{r: fakeReporter{err: messaging.ErrOwnMessage}}, payload, moderation.ReportedMessage{}, moderation.ErrOwnMessage},
		{"other error", &lateMessageLookup{r: fakeReporter{err: boom}}, payload, moderation.ReportedMessage{}, boom},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.l.ReportableMessage(context.Background(), "caller", "c", "m", tt.payload)
			if !errors.Is(err, tt.wantErr) || got != tt.want {
				t.Errorf("got %+v, %v; want %+v, %v", got, err, tt.want, tt.wantErr)
			}
		})
	}
	if _, err := (&lateMessageLookup{}).ReportableMessage(context.Background(), "caller", "c", "m", nil); err == nil {
		t.Error("an unbound lookup answered without an error")
	}
}
