package messaging

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Collection names. messaging.Service and the repo behind it are the only readers and writers.
const (
	conversationsCollection = "conversations"
	messagesCollection      = "messages"
	dmInboxCollection       = "dmInbox"
	dmRequestsCollection    = "dmRequests"
	usersCollection         = "users"
	// commitsCollection is conversations/{id}/commits/{commitDocID(gen, epoch)}; dmWelcomesCollection is
	// users/{uid}/dmWelcomes/{welcomeDocID(...)}. Both are written only by mls_init, a commit and a reset.
	commitsCollection    = "commits"
	dmWelcomesCollection = "dmWelcomes"
)

// Stored states. They are the proto enum names without the prefix, so a stored value maps one to one.
const (
	kindDirect = "DIRECT"

	stateRequest  = "REQUEST"
	stateAccepted = "ACCEPTED"

	msgVisible        = "VISIBLE"
	msgDeletedAccount = "DELETED_ACCOUNT"
	msgRemoved        = "REMOVED"

	// Conversation encryption modes (ConvDoc.Encryption). Absent reads as encNone; encMLS never returns to encNone.
	encNone = "NONE"
	encMLS  = "MLS"
)

// SnippetMaxRunes is the longest snippet an inbox entry holds (at most 100 code points).
const SnippetMaxRunes = 100

// Limit names carried in LIMIT_REACHED metadata["limit"] and the request log's limit_name.
const (
	limitRequestUnanswered = "request_unanswered"
	limitDMNewDaily        = "dm_new_daily"
	limitMessagesDaily     = "messages_daily"
)

// DeletedUID is the one fixed value the `messaging` eraser writes in place of a deleted user's uid everywhere it remains in
// a surviving peer's copy of a conversation: the conversation's participants, gone, requestFrom and
// requestTo, the senderId of the user's tombstoned messages and the peer entry's peerId. It can never be a real uid: it begins with "_",
// which ids.ValidUID refuses ("_" is the composite-key separator), so no account can ever take the value (L-2;
// the first value, "deleted", was a valid uid shape and could have been claimed). Nothing resolves it (Firebase
// uids are 28 random characters): readers treat it as "Deleted account".
const DeletedUID = "_deleted"

// Deleted-account placeholders: what the eraser writes into the peer's entry.
const (
	DeletedAccountName = "Deleted account"
	deletedSnippet     = "Message deleted"
)

// hex32 is the shape of a conversation or message id: 32 lower-case hex characters.
var hex32 = regexp.MustCompile(`^[0-9a-f]{32}$`)

// ValidID reports whether s has the shape of a conversation or message id.
func ValidID(s string) bool { return hex32.MatchString(s) }

// ConversationID is the deterministic id of the 1:1 conversation between two users: the first 32 hex
// characters of SHA-256("dm1|" + lowUid + "|" + highUid), the uids in byte order. The id is guessable from two uids, so
// authorization never relies on its secrecy.
func ConversationID(a, b string) string {
	lo, hi := a, b
	if hi < lo {
		lo, hi = hi, lo
	}
	return digest32("dm1|" + lo + "|" + hi)
}

// MessageID is the deterministic id of a message (Option C1): the first 32 hex characters of
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
// note of: DeleteConversation stores the digest of its key next to clearedAt, at no extra read or write).
func keyDigest(uid, op, key string) string {
	return digest32(uid + "|" + op + "|" + key)
}

// requestHash is the one-way digest of a SendMessage request used to tell a replay from a reused key (same key with a different body is VALIDATION).
// It binds the resolved conversation, the normalised text and, for a post share, shared_post_id as sent. Without a post it
// is byte-identical to the digest every stored message carries, so those still replay.
func requestHash(convID, text, sharedPostID string) string {
	if sharedPostID == "" {
		return digest32("send|" + convID + "|" + text)
	}
	return digest32("send|" + convID + "|" + text + "|p|" + sharedPostID)
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

// ConvDoc is conversations/{convId}. Messages are NOT counted here: an accepted conversation
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
	// Rev is the thread revision: incremented by a takedown and by the eraser's RewriteConversation,
	// sealed into ListMessages since tokens; absent = 0. Never touched by send, accept, delete or mark-read.
	Rev int64 `firestore:"rev,omitempty"`
	// Encryption is encMLS once the conversation is end-to-end encrypted; absent = plaintext. MlsGen and MlsEpoch are the
	// current (generation, epoch) pair, written only by mls_init, a commit and a reset (never by an ordinary send).
	Encryption string `firestore:"encryption,omitempty"`
	MlsGen     int64  `firestore:"mlsGen,omitempty"`
	MlsEpoch   int64  `firestore:"mlsEpoch,omitempty"`
}

// encrypted reports whether the conversation is end-to-end encrypted.
func (c ConvDoc) encrypted() bool { return c.Encryption == encMLS }

// mlsKey is the equality key ListEpochMessages queries: the (generation, epoch) pair as "gen:epoch".
func mlsKey(gen, epoch int64) string { return fmt.Sprintf("%d:%d", gen, epoch) }

// commitDocID is the id of conversations/{id}/commits/{gen_epoch}: zero-padded so ids sort by generation, then epoch.
func commitDocID(gen, epoch int64) string { return fmt.Sprintf("%010d_%010d", gen, epoch) }

// CommitDoc is conversations/{convId}/commits/{commitDocID(gen, epoch)}: the MLS commit built on (Gen, Epoch), created
// once (first wins) by mls_init (the group creation, (1, 0)), a commit or a reset. Data is opaque to the server. Epoch
// is 0 for the commit of an mls_init or a reset, so it has no omitempty. ExpireAt = CreatedAt + CommitRetention (a TTL
// field once the owner applies the policy).
type CommitDoc struct {
	Data      []byte    `firestore:"data"`
	SenderID  string    `firestore:"senderId"`
	Gen       int64     `firestore:"gen"`
	Epoch     int64     `firestore:"epoch"`
	CreatedAt time.Time `firestore:"createdAt"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

// WelcomeDoc is users/{uid}/dmWelcomes/{welcomeDocID(convId, gen, epoch, deviceId)}: the MLS Welcome for one device of
// uid, accompanying the commit built on (Gen, Epoch). At most one per (conversation, device): a newer one replaces it in
// the same transaction. Data is opaque. ExpireAt = CreatedAt + WelcomeRetention. convId and deviceId stay indexed (the
// replacement query filters on both); data is never queried.
type WelcomeDoc struct {
	DeviceID  string    `firestore:"deviceId"`
	ConvID    string    `firestore:"convId"`
	Gen       int64     `firestore:"gen"`
	Epoch     int64     `firestore:"epoch"`
	Data      []byte    `firestore:"data"`
	CreatedAt time.Time `firestore:"createdAt"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

// welcomeDocID is the id of a welcome document: the first 32 hex characters of the SHA-256 of the length-prefixed parts
// (convId, gen, epoch, deviceId), so no two inputs share an encoding.
func welcomeDocID(convID string, gen, epoch int64, deviceID string) string {
	return digest32(lengthPrefixed("welcome1", convID, strconv.FormatInt(gen, 10), strconv.FormatInt(epoch, 10), deviceID))
}

// lengthPrefixed joins parts as "<len>:<part>" each, an unambiguous encoding of any strings.
func lengthPrefixed(parts ...string) string {
	var b strings.Builder
	for _, p := range parts {
		b.WriteString(strconv.Itoa(len(p)))
		b.WriteByte(':')
		b.WriteString(p)
	}
	return b.String()
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

// MsgDoc is conversations/{convId}/messages/{msgId}. text and requestHash are index-exempt.
type MsgDoc struct {
	SenderID    string    `firestore:"senderId"`
	Text        string    `firestore:"text"`
	State       string    `firestore:"state"`
	RequestHash string    `firestore:"requestHash"`
	CreatedAt   time.Time `firestore:"createdAt"`
	// RemovedAt is the server time of a moderator takedown, set together with State REMOVED (a durable record of the
	// takedown even when it was made without --report).
	RemovedAt time.Time `firestore:"removedAt,omitempty"`
	// SharedPostID is the post this message shares (the original's id; shares design D2): the id only, never a copy of
	// the post. The card is decided for each reader at read time. Cleared with text by a takedown and by the eraser's
	// tombstone. Index-exempt (firebase/firestore.indexes.json): never queried.
	SharedPostID string `firestore:"sharedPostId,omitempty"`
	// Encrypted messages: text stays empty; Ciphertext (the MLS application message) and Commitment (the 32-byte report
	// commitment) are blanked by the retention sweep once CtExpireAt passes (CtRemoved then true). MlsKey is
	// mlsKey(MlsGen, MlsEpoch). The server never parses any of them.
	Ciphertext []byte    `firestore:"ciphertext,omitempty"`
	Commitment []byte    `firestore:"commitment,omitempty"`
	MlsGen     int64     `firestore:"mlsGen,omitempty"`
	MlsEpoch   int64     `firestore:"mlsEpoch,omitempty"`
	MlsKey     string    `firestore:"mlsKey,omitempty"`
	CtExpireAt time.Time `firestore:"ctExpireAt,omitempty"`
	CtRemoved  bool      `firestore:"ctRemoved,omitempty"`
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
	// SharedPost is true when the message shares a post (MessagePreview.shared_post). The snippet stays the sender's own
	// text, never the post's. Absent on older entries (false).
	SharedPost bool `firestore:"sharedPost"`
	// Encrypted is true when the last message is end-to-end encrypted (the snippet is then empty). Always written.
	Encrypted bool `firestore:"encrypted"`
}

// fields is the whole preview map. Every leaf is always written (sharedPost included) because the entry is written with
// MergeAll, which merges nested maps leaf by leaf: a leaf left out would survive from the previous message.
func (l LastDoc) fields() map[string]any {
	return map[string]any{"messageId": l.MessageID, "fromSelf": l.FromSelf, "snippet": l.Snippet, "state": l.State, "sharedPost": l.SharedPost, "encrypted": l.Encrypted}
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
	// ReadReceiptAt is when this entry's owner last marked the conversation read WHILE their read-receipts setting was on
	// (F3). Written only by MarkRead (field-level), so a send, an accept (the raw map is moved whole) and the eraser keep or
	// drop it with the entry. The peer sees it as Conversation.peer_read_at only while both sides have receipts on;
	// LastReadAt is never exposed. Absent = never. Index-exempt in practice: no query reads it.
	ReadReceiptAt time.Time `firestore:"readReceiptAt,omitempty"`
	CreatedAt     time.Time `firestore:"createdAt"`
	// ChangedAt is when the entry last changed in a way a cached device must see: every send (the
	// same stamp as LastMessageAt), a takedown rewriting the preview, the eraser rewriting the peer snapshot, an accepted
	// request moved to the inbox. The ListConversations since query orders by it. It stays on the automatic single-field
	// index; an entry written before it existed has none and never matches a since query.
	ChangedAt time.Time `firestore:"changedAt,omitempty"`
	// RequestPending is true only on the requester's own dmInbox entry while the conversation is REQUEST
	// (their first to third message): ListConversations then reads the row as REQUEST in the INBOX. Absent = false. Send sets it
	// (+0) and clears it on the reply that accepts; Accept and the eraser's MarkGone delete it. Never set on dmRequests. A legacy
	// entry has none and reads ACCEPTED. It stays on the automatic index (no query uses it).
	RequestPending bool `firestore:"requestPending,omitempty"`
}

// redactErr is logger.RedactErr for the ids this module logs: an id in the 32-hex shape (a conversation id, a message id or
// a page cursor, all derived from hashes) is replaced by its keyed hash (logger.HashConversation), so an error line never
// carries the plain SHA-256 of an id that can be guessed from a uid pair (L-7); everything else (uids) by HashUID.
func redactErr(err error, ids ...string) error {
	var convs, uids []string
	for _, id := range ids {
		if ValidID(id) {
			convs = append(convs, id)
		} else {
			uids = append(uids, id)
		}
	}
	return logger.RedactErrKeyed(err, convs, uids...)
}
