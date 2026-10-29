package messaging

import "time"

// sendDecision is what one SendMessage does to the conversation, decided from the conversation document the send
// transaction read (ADR-0027 D4 step 5). It is pure so the table of cases is unit-tested without Firestore.
type sendDecision struct {
	// CreateConv: the conversation document did not exist and is created with State.
	CreateConv bool
	// State is the conversation state after this message.
	State string
	// IncRequest: an existing REQUEST conversation and the caller is the requester: requestCount +1.
	IncRequest bool
	// AcceptNow: an existing REQUEST conversation and the caller is the recipient of the request: the reply accepts it
	// (as on X), so the caller's dmRequests entry moves to dmInbox.
	AcceptNow bool
	// RecipientInRequests: the other participant's entry for this message lives in dmRequests (a request they have not
	// accepted); otherwise in dmInbox.
	RecipientInRequests bool
}

// decideSend applies the D4 routing rules. conv is nil when the document is missing. mutual says both follow each
// other (only used when the conversation is created). Errors: ErrCannotMessage (the conversation is gone),
// ErrNotFound (the caller is not a participant), ErrRequestLimit (the requester sent maxUnanswered messages already).
func decideSend(conv *ConvDoc, uid string, mutual bool, maxUnanswered int64) (sendDecision, error) {
	if conv == nil {
		if mutual {
			return sendDecision{CreateConv: true, State: stateAccepted}, nil
		}
		return sendDecision{CreateConv: true, State: stateRequest, RecipientInRequests: true}, nil
	}
	if !conv.hasParticipant(uid) {
		return sendDecision{}, ErrNotFound
	}
	if len(conv.Gone) > 0 {
		return sendDecision{}, ErrCannotMessage
	}
	if conv.State != stateRequest {
		return sendDecision{State: stateAccepted}, nil
	}
	if uid == conv.RequestTo {
		return sendDecision{State: stateAccepted, AcceptNow: true}, nil
	}
	if conv.RequestCount >= maxUnanswered {
		return sendDecision{}, ErrRequestLimit
	}
	return sendDecision{State: stateRequest, IncRequest: true, RecipientInRequests: true}, nil
}

// decideAccept applies the AcceptMessageRequest rules to the conversation document the accept transaction read (ADR-0027
// D4, D11; plan W7-9). conv is nil when the document is missing. Only the recipient of the request (requestTo) may accept:
// an unknown id, a non-participant, the requester and a conversation that never was a request (mutual follows, no
// requestTo) are all ErrNotFound, so they share one wire answer. A conversation that is already ACCEPTED is success
// with nothing to write (Already), whatever its gone list says. A request whose peer deleted the account is
// ErrCannotMessage: there is nobody to talk to.
func decideAccept(conv *ConvDoc, uid string) (acceptDecision, error) {
	if conv == nil || !conv.hasParticipant(uid) || conv.RequestTo != uid {
		return acceptDecision{}, ErrNotFound
	}
	if conv.State != stateRequest {
		return acceptDecision{Already: true}, nil
	}
	if len(conv.Gone) > 0 {
		return acceptDecision{}, ErrCannotMessage
	}
	return acceptDecision{}, nil
}

// acceptDecision is what one AcceptMessageRequest does.
type acceptDecision struct {
	// Already: the conversation is ACCEPTED, so there is nothing to write.
	Already bool
}

// decideDelete returns the folder of the caller's own entry for DeleteConversation, from the conversation document the
// transaction read: dmRequests only for the recipient of a request that has not been accepted, dmInbox otherwise (the
// same rule the eraser uses, entryFolder). A missing document and a non-participant are ErrNotFound. A conversation
// whose peer is gone can still be deleted: clean-up must stay possible.
func decideDelete(conv *ConvDoc, uid string) (folder string, err error) {
	if conv == nil || !conv.hasParticipant(uid) {
		return "", ErrNotFound
	}
	return entryFolder(*conv, uid), nil
}

// deleteIsReplay reports whether a DeleteConversation has nothing left to do: the caller's entry is gone and the
// conversation was cleared for the caller before, which is what a retry of a delete that succeeded finds. A later message
// of the peer recreates the entry, so a delete that finds an entry is a new delete and moves clearedAt forward.
func deleteIsReplay(conv ConvDoc, uid string, entryExists bool) bool {
	return !entryExists && !conv.ClearedAt[uid].IsZero()
}

// stampAfterClear returns the time a send stamps its message and both entries with: now, unless a participant's clearedAt
// (conv is the document the send transaction read; nil for a new conversation) is not before it, in which case one
// microsecond (the resolution of a Firestore timestamp) after that clearedAt. ListMessages hides every message at or
// before the reader's clearedAt, so a message stamped with a clock that a concurrent DeleteConversation already passed
// (the handler reads the clock before the transaction runs, and instances' clocks differ) would be invisible to the
// participant who deleted while still counting as unread. The result is strictly after every clearedAt and never before now.
func stampAfterClear(now time.Time, conv *ConvDoc) time.Time {
	if conv == nil {
		return now
	}
	for _, cleared := range conv.ClearedAt {
		if !now.After(cleared) {
			now = cleared.Add(time.Microsecond)
		}
	}
	return now
}

// notBefore returns now, or the latest of floors when one is after it. Accept and Delete stamp updatedAt with it so the
// document's updatedAt only moves forward whatever the clock skew between instances (the cached copy of the document is
// replaced only by one that is not older, putConv), and Delete stamps clearedAt with it: never before the newest message the
// caller's entry shows (lastMessageAt), so a message stamped ahead of this instance's clock by stampAfterClear is still
// deleted with the thread.
func notBefore(now time.Time, floors ...time.Time) time.Time {
	for _, t := range floors {
		if t.After(now) {
			now = t
		}
	}
	return now
}

// deleteIsKeyReplay reports whether a DeleteConversation is a retry of the caller's last delete: the digest of its
// idempotency_key equals the one stored in clearedKey.{caller} by that delete. It is checked before deleteIsReplay and
// answers success with nothing written whatever happened since: a newer message of the peer stays visible and its
// recreated entry stays, because the retry is the old delete, not a new one. An empty digest never matches.
func deleteIsKeyReplay(conv ConvDoc, uid, digest string) bool {
	return digest != "" && conv.ClearedKey[uid] == digest
}
