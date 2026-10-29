package messaging

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"time"
)

// Collection names (ADR-0027 D1). messaging.Service and the repo behind it are the only readers and writers.
const (
	conversationsCollection = "conversations"
	messagesCollection      = "messages"
	dmInboxCollection       = "dmInbox"
	dmRequestsCollection    = "dmRequests"
	usersCollection         = "users"
)

// Stored states (ADR-0027 D1). They are the proto enum names without the prefix, so a stored value maps one to one.
const (
	kindDirect = "DIRECT"

	stateRequest  = "REQUEST"
	stateAccepted = "ACCEPTED"

	msgVisible        = "VISIBLE"
	msgDeletedAccount = "DELETED_ACCOUNT"
	msgRemoved        = "REMOVED"
)

// SnippetMaxRunes is the longest snippet an inbox entry holds (ADR-0027 D1: at most 100 code points).
const SnippetMaxRunes = 100

// Limit names carried in LIMIT_REACHED metadata["limit"] and the request log's limit_name (ADR-0027 D13).
const (
	limitRequestUnanswered = "request_unanswered"
	limitDMNewDaily        = "dm_new_daily"
	limitMessagesDaily     = "messages_daily"
)

// DeletedUID is the one fixed value the `messaging` eraser writes in place of a deleted user's uid everywhere it remains in
// a surviving peer's copy of a conversation (ADR-0027 D8, D11): the conversation's participants, gone, requestFrom and
// requestTo, the senderId of the user's tombstoned messages and the peer entry's peerId. It is not a real uid (Firebase
// uids are 28 random characters), and nothing resolves it: readers treat it as "Deleted account".
const DeletedUID = "deleted"

// Deleted-account placeholders (ADR-0027 D8): what the eraser writes into the peer's entry.
const (
	DeletedAccountName = "Deleted account"
	deletedSnippet     = "Message deleted"
)

// hex32 is the shape of a conversation or message id (ADR-0027 D2): 32 lower-case hex characters.
var hex32 = regexp.MustCompile(`^[0-9a-f]{32}$`)

// ValidID reports whether s has the shape of a conversation or message id.
func ValidID(s string) bool { return hex32.MatchString(s) }

// ConversationID is the deterministic id of the 1:1 conversation between two users (ADR-0027 D2): the first 32 hex
// characters of SHA-256("dm1|" + lowUid + "|" + highUid), the uids in byte order. The id is guessable from two uids, so
// authorization never relies on its secrecy.
func ConversationID(a, b string) string {
	lo, hi := a, b
	if hi < lo {
		lo, hi = hi, lo
	}
	return digest32("dm1|" + lo + "|" + hi)
}

// MessageID is the deterministic id of a message (ADR-0027 D2, Option C1): the first 32 hex characters of
// SHA-256(senderUid | "SendMessage" | idempotency_key). The message document is the idempotency record.
func MessageID(senderUID, key string) string {
	return keyDigest(senderUID, opSend, key)
}

// Operation names in a key digest: the same key reused for another operation, or by another user, digests differently.
const (
	opSend   = "SendMessage"
	opDelete = "DeleteConversation"
)

// keyDigest is the one construction behind every stored idempotency key (C1): the first 32 hex characters of
// SHA-256(uid | operation | idempotency_key). A message id is one; so is conversations.clearedKey.{uid} (the 2026-10-29
// note of ADR-0027: DeleteConversation stores the digest of its key next to clearedAt, at no extra read or write).
func keyDigest(uid, op, key string) string {
	return digest32(uid + "|" + op + "|" + key)
}

// requestHash is the one-way digest of a SendMessage request used to tell a replay from a reused key (ADR-0027 D1: same
// key with a different body is VALIDATION). It binds the resolved conversation and the normalised text.
func requestHash(convID, text string) string {
	return digest32("send|" + convID + "|" + text)
}

func digest32(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])[:32]
}

// peerOf returns the participant that is not uid, or "" when uid is not a participant of a two-person conversation.
func peerOf(participants []string, uid string) string {
	if len(participants) != 2 {
		return ""
	}
	switch uid {
	case participants[0]:
		return participants[1]
	case participants[1]:
		return participants[0]
	}
	return ""
}

// snippetOf is the inbox preview of text: at most SnippetMaxRunes code points.
func snippetOf(text string) string {
	r := []rune(text)
	if len(r) <= SnippetMaxRunes {
		return text
	}
	return strings.TrimRight(string(r[:SnippetMaxRunes]), " \n")
}

// wireTime is the instant as Firestore stores it: UTC at microsecond precision, so a value read back equals the one
// the response carried.
func wireTime(t time.Time) time.Time { return t.UTC().Truncate(time.Microsecond) }

// ConvDoc is conversations/{convId} (ADR-0027 D1). Messages are NOT counted here: an accepted conversation
// document is not written per message (no hot document).
type ConvDoc struct {
	Kind         string               `firestore:"kind"`
	Participants []string             `firestore:"participants"`
	State        string               `firestore:"state"`
	RequestFrom  string               `firestore:"requestFrom,omitempty"`
	RequestTo    string               `firestore:"requestTo,omitempty"`
	RequestCount int64                `firestore:"requestCount"`
	ClearedAt    map[string]time.Time `firestore:"clearedAt,omitempty"`
	// ClearedKey is the digest (keyDigest) of the idempotency_key of each participant's last DeleteConversation, written in the
	// same update as ClearedAt[uid] and erased with it. Like ClearedAt it has no index exemption: no query uses it.
	ClearedKey map[string]string `firestore:"clearedKey,omitempty"`
	Gone       []string          `firestore:"gone,omitempty"`
	CreatedAt  time.Time         `firestore:"createdAt"`
	UpdatedAt  time.Time         `firestore:"updatedAt"`
}

func (c ConvDoc) hasParticipant(uid string) bool {
	for _, p := range c.Participants {
		if p == uid {
			return true
		}
	}
	return false
}

func (c ConvDoc) isGone(uid string) bool {
	for _, g := range c.Gone {
		if g == uid {
			return true
		}
	}
	return false
}

// MsgDoc is conversations/{convId}/messages/{msgId}. text and requestHash are index-exempt (W7-3).
type MsgDoc struct {
	SenderID    string    `firestore:"senderId"`
	Text        string    `firestore:"text"`
	State       string    `firestore:"state"`
	RequestHash string    `firestore:"requestHash"`
	CreatedAt   time.Time `firestore:"createdAt"`
}

// PeerDoc is the peer snapshot an inbox entry holds (index-exempt).
type PeerDoc struct {
	Handle         string `firestore:"handle"`
	DisplayName    string `firestore:"displayName"`
	AvatarThumbURL string `firestore:"avatarThumbUrl"`
	Verified       bool   `firestore:"verified"`
}

func (p PeerDoc) fields() map[string]any {
	return map[string]any{"handle": p.Handle, "displayName": p.DisplayName, "avatarThumbUrl": p.AvatarThumbURL, "verified": p.Verified}
}

// LastDoc is the last-message preview of an inbox entry (index-exempt).
type LastDoc struct {
	MessageID string `firestore:"messageId"`
	FromSelf  bool   `firestore:"fromSelf"`
	Snippet   string `firestore:"snippet"`
	State     string `firestore:"state"`
}

func (l LastDoc) fields() map[string]any {
	return map[string]any{"messageId": l.MessageID, "fromSelf": l.FromSelf, "snippet": l.Snippet, "state": l.State}
}

// EntryDoc is users/{uid}/dmInbox/{convId} and users/{uid}/dmRequests/{convId} (same shape).
type EntryDoc struct {
	PeerID        string    `firestore:"peerId"`
	Peer          PeerDoc   `firestore:"peer"`
	LastMessageAt time.Time `firestore:"lastMessageAt"`
	Last          LastDoc   `firestore:"last"`
	UnreadCount   int64     `firestore:"unreadCount"`
	Silent        bool      `firestore:"silent"`
	LastReadAt    time.Time `firestore:"lastReadAt"`
	CreatedAt     time.Time `firestore:"createdAt"`
}
