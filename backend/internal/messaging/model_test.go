package messaging

import (
	"errors"
	"strings"
	"testing"
)

func TestConversationID(t *testing.T) {
	a, b := "uid-aaa", "uid-bbb"
	if ConversationID(a, b) != ConversationID(b, a) {
		t.Error("the id must not depend on the order of the two uids")
	}
	if ConversationID(a, b) == ConversationID(a, "uid-ccc") {
		t.Error("different pairs must give different ids")
	}
	if !ValidID(ConversationID(a, b)) {
		t.Errorf("ConversationID = %q, want 32 lower-case hex", ConversationID(a, b))
	}
	// The derivation is part of the contract (ADR-0027 D2): pin one value so a change of formula fails loudly.
	if got, want := ConversationID("a", "b"), digest32("dm1|a|b"); got != want {
		t.Errorf("ConversationID(a,b) = %q, want %q", got, want)
	}
}

func TestMessageID(t *testing.T) {
	if MessageID("u1", "key-0000000000001") == MessageID("u2", "key-0000000000001") {
		t.Error("two senders with one key must get different message ids")
	}
	if MessageID("u1", "key-0000000000001") == MessageID("u1", "key-0000000000002") {
		t.Error("two keys must give different message ids")
	}
	if !ValidID(MessageID("u1", "k")) {
		t.Error("MessageID is not 32 lower-case hex")
	}
}

func TestValidID(t *testing.T) {
	for id, want := range map[string]bool{
		strings.Repeat("a", 32): true, strings.Repeat("0f", 16): true,
		"": false, strings.Repeat("a", 31): false, strings.Repeat("a", 33): false,
		strings.Repeat("A", 32): false, strings.Repeat("g", 32): false,
	} {
		if got := ValidID(id); got != want {
			t.Errorf("ValidID(%q) = %v, want %v", id, got, want)
		}
	}
}

func TestPeerOf(t *testing.T) {
	tests := []struct {
		name  string
		parts []string
		uid   string
		want  string
	}{
		{"first", []string{"a", "b"}, "a", "b"},
		{"second", []string{"a", "b"}, "b", "a"},
		{"stranger", []string{"a", "b"}, "c", ""},
		{"malformed", []string{"a"}, "a", ""},
	}
	for _, tt := range tests {
		if got := peerOf(tt.parts, tt.uid); got != tt.want {
			t.Errorf("%s: peerOf = %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestSnippetOf(t *testing.T) {
	long := strings.Repeat("é", 150) // 2 bytes per code point: a byte cut would split one
	got := snippetOf(long)
	if n := len([]rune(got)); n != SnippetMaxRunes {
		t.Errorf("snippet has %d code points, want %d", n, SnippetMaxRunes)
	}
	if short := "hello"; snippetOf(short) != short {
		t.Errorf("a short text must pass through, got %q", snippetOf(short))
	}
	if got := snippetOf(strings.Repeat("a", 99) + "  b"); strings.HasSuffix(got, " ") {
		t.Errorf("snippet %q ends in a space", got)
	}
}

func TestRequestHash_BindsConversationAndText(t *testing.T) {
	base := requestHash("c1", "hi")
	if base != requestHash("c1", "hi") {
		t.Error("the digest must be deterministic")
	}
	if base == requestHash("c2", "hi") || base == requestHash("c1", "hi!") {
		t.Error("the digest must change with the conversation and the text")
	}
}

func TestEntryFolder(t *testing.T) {
	req := ConvDoc{State: stateRequest, RequestFrom: "a", RequestTo: "b"}
	if entryFolder(req, "b") != entryRequests {
		t.Error("the recipient of an unaccepted request keeps the entry in dmRequests")
	}
	if entryFolder(req, "a") != entryInbox {
		t.Error("the requester's own entry is in dmInbox")
	}
	req.State = stateAccepted
	if entryFolder(req, "b") != entryInbox {
		t.Error("an accepted conversation is in dmInbox for both")
	}
}

func TestDecideSend(t *testing.T) {
	const max = 3
	conv := func(state string, count int64, gone ...string) *ConvDoc {
		return &ConvDoc{Participants: []string{"a", "b"}, State: state, RequestFrom: "a", RequestTo: "b", RequestCount: count, Gone: gone}
	}
	tests := []struct {
		name    string
		conv    *ConvDoc
		uid     string
		mutual  bool
		want    sendDecision
		wantErr error
	}{
		{"new, mutual", nil, "a", true, sendDecision{CreateConv: true, State: stateAccepted}, nil},
		{"new, not mutual", nil, "a", false, sendDecision{CreateConv: true, State: stateRequest, RecipientInRequests: true}, nil},
		{"accepted continues", conv(stateAccepted, 0), "a", false, sendDecision{State: stateAccepted}, nil},
		{"accepted, the other side", conv(stateAccepted, 0), "b", false, sendDecision{State: stateAccepted}, nil},
		{"request, 1st follow-up", conv(stateRequest, 1), "a", false, sendDecision{State: stateRequest, IncRequest: true, RecipientInRequests: true}, nil},
		{"request, 3rd message is the last allowed", conv(stateRequest, 2), "a", false, sendDecision{State: stateRequest, IncRequest: true, RecipientInRequests: true}, nil},
		{"request, 4th message", conv(stateRequest, max), "a", false, sendDecision{}, ErrRequestLimit},
		{"request, the recipient replies = accepts", conv(stateRequest, max), "b", false, sendDecision{State: stateAccepted, AcceptNow: true}, nil},
		{"gone conversation", conv(stateAccepted, 0, "b"), "a", true, sendDecision{}, ErrCannotMessage},
		{"gone conversation, request", conv(stateRequest, 1, "a"), "b", false, sendDecision{}, ErrCannotMessage},
		{"not a participant", conv(stateAccepted, 0), "z", true, sendDecision{}, ErrNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := decideSend(tt.conv, tt.uid, tt.mutual, max)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("decision = %+v, want %+v", got, tt.want)
			}
		})
	}
}
