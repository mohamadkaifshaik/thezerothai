package messaging

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
