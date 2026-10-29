package messaging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ErrOwnMessage is a message the caller wrote: it cannot be reported (ADR-0027 D12). moderation turns it into VALIDATION
// target_id; every other "unreportable" cause is ErrNotFound.
var ErrOwnMessage = errors.New("messaging: own message")

// ReportedMessage is the evidence of one message at report time (ADR-0027 D12): that message's text, the sender's handle
// and the time it was sent, and nothing else of the conversation. The text is private content; it is never logged.
type ReportedMessage struct {
	// SenderUID is the peer who wrote it (the report's target owner). It never reaches a client or a log.
	SenderUID string
	// SenderHandle is the sender's handle, or "" when the sender is no longer ACTIVE: the thread still shows their
	// message, so it stays reportable (the report's owner uid names them).
	SenderHandle string
	Text         string
	CreatedAt    time.Time
}

// MessageReporter is the part of the service a message report needs. The apiserver adapts it to moderation.MessageLookup
// (moderation defines the interface and never imports messaging, ADR-0027 D15); the service returned by New implements it.
type MessageReporter interface {
	ReportableMessage(ctx context.Context, callerUID, convID, msgID string) (ReportedMessage, error)
}

var _ MessageReporter = (*service)(nil)

// ReportableMessage implements MessageReporter (ADR-0027 D12; plan W7-12): the caller must be a participant of the
// conversation and the message must be the peer's and VISIBLE. It checks no flag: the report handler has already required
// `reports` on and `messaging` not globally off (F6), so a user dropped from the allowlist can still report. It does not
// look at the caller's graph either: a conversation with a blocked peer stays open so the user can still report it (D4).
//
// Order: the conversation (instance cache for a participant, so membership is checked against a copy at most 60 s old; membership of a 1:1
// conversation never changes, ADR-0027 D14), then the message (never cached). A missing conversation, a conversation the
// caller is not in, a missing message, a message that is no longer VISIBLE (REMOVED, or its sender deleted the account)
// and a message whose sender is not the peer all answer ErrNotFound after at most 2 reads, so the wire answer cannot tell
// them apart. The caller's own message is ErrOwnMessage, checked before the state so a taken-down own message is no
// different. The sender's handle comes from the identity directory (cache-first 60 s); a sender it does not list as ACTIVE
// gives an empty handle, not an error.
//
// Worst-case Firestore cost: conversation 1 (0 warm) + message 1 + sender profile 1 (0 warm) = 3 reads cold, 1 warm;
// writes 0. A refusal costs at most 2 reads; a non-participant always pays
// the conversation read, warm or cold (W7-28).
func (s *service) ReportableMessage(ctx context.Context, uid, convID, msgID string) (ReportedMessage, error) {
	if s.d.Repo == nil || s.d.Profiles == nil {
		return ReportedMessage{}, errors.New("messaging: message reports are not configured")
	}
	if !ValidID(convID) || !ValidID(msgID) {
		return ReportedMessage{}, ErrNotFound // a shaped-wrong id is simply unknown; moderation validates the shape first
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(convID))
	conv, hit, err := s.conversationHit(ctx, uid, convID)
	logger.SetRequestField(ctx, fieldCacheHit, hit)
	if err == nil && !conv.hasParticipant(uid) {
		err = ErrNotFound
	}
	if err != nil {
		return ReportedMessage{}, reportLookupErr(err, uid, convID, msgID)
	}
	peer := peerOf(conv.Participants, uid)

	msg, found, err := s.d.Repo.GetMessage(ctx, convID, msgID)
	if err != nil {
		return ReportedMessage{}, reportLookupErr(err, uid, convID, msgID)
	}
	switch {
	case !found:
		return ReportedMessage{}, ErrNotFound
	case msg.SenderID == uid:
		return ReportedMessage{}, ErrOwnMessage
	case msg.State != msgVisible || peer == "" || peer == DeletedUID || msg.SenderID != peer:
		return ReportedMessage{}, ErrNotFound
	}

	handle := ""
	got, err := s.d.Profiles.GetProfiles(ctx, []string{peer})
	if err != nil {
		return ReportedMessage{}, reportLookupErr(err, uid, convID, msgID, peer)
	}
	if p, ok := got[peer]; ok {
		handle = p.Handle
	}
	return ReportedMessage{SenderUID: peer, SenderHandle: handle, Text: msg.Text, CreatedAt: msg.CreatedAt}, nil
}

// reportLookupErr passes ErrNotFound through and redacts every id from anything else that may reach a log.
func reportLookupErr(err error, ids ...string) error {
	if errors.Is(err, ErrNotFound) {
		return ErrNotFound
	}
	return logger.RedactErr(fmt.Errorf("messaging: report lookup: %w", err), ids...)
}
