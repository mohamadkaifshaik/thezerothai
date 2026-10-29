package apiserver

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// TestMessageReportFlagName_IsMessagingsOwn (W7-12, ADR-0027 F6): moderation checks "messaging" is not globally off under
// the name moderation declares, because it cannot import messaging. The two must stay the same string, or a report would
// be gated on a flag nobody sets.
func TestMessageReportFlagName_IsMessagingsOwn(t *testing.T) {
	if moderation.MessagingFlagName != messaging.FlagName {
		t.Fatalf("moderation.MessagingFlagName = %q, messaging.FlagName = %q", moderation.MessagingFlagName, messaging.FlagName)
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
// copied field by field, an unbound adapter is an error and not a panic, and anything else passes through.
func TestLateMessageLookup(t *testing.T) {
	boom := errors.New("boom")
	at := time.Date(2026, 10, 29, 9, 0, 0, 0, time.UTC)
	tests := []struct {
		name    string
		l       *lateMessageLookup
		want    moderation.ReportedMessage
		wantErr error
	}{
		{"evidence copied", &lateMessageLookup{r: fakeReporter{m: messaging.ReportedMessage{SenderUID: "u", SenderHandle: "h", Text: "t", CreatedAt: at}}},
			moderation.ReportedMessage{SenderUID: "u", SenderHandle: "h", Text: "t", CreatedAt: at}, nil},
		{"not found", &lateMessageLookup{r: fakeReporter{err: messaging.ErrNotFound}}, moderation.ReportedMessage{}, moderation.ErrMessageNotFound},
		{"own message", &lateMessageLookup{r: fakeReporter{err: messaging.ErrOwnMessage}}, moderation.ReportedMessage{}, moderation.ErrOwnMessage},
		{"other error", &lateMessageLookup{r: fakeReporter{err: boom}}, moderation.ReportedMessage{}, boom},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.l.ReportableMessage(context.Background(), "caller", "c", "m")
			if !errors.Is(err, tt.wantErr) || got != tt.want {
				t.Errorf("got %+v, %v; want %+v, %v", got, err, tt.want, tt.wantErr)
			}
		})
	}
	if _, err := (&lateMessageLookup{}).ReportableMessage(context.Background(), "caller", "c", "m"); err == nil {
		t.Error("an unbound lookup answered without an error")
	}
}
