package logger

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"sync/atomic"
)

// convHashInfo is the HKDF info label of the conversation-hash key. It is distinct from the cursor module's own label, so
// the two derived keys are unrelated (ADR-0027 W7-34, security review L-7).
const convHashInfo = "dzeroth log conversation_hash v1"

// convHashKey is the process's derived key; nil until SetConversationKey (or the first HashConversation, which then
// installs a random per-process key so a hash is never the plain, guessable SHA-256 of the id). The logger package is the one
// place the code base allows a global.
var convHashKey atomic.Pointer[[]byte]

// SetConversationKey derives the conversation-hash key from secret (CURSOR_HMAC_KEY: HKDF-SHA256, empty salt, info
// convHashInfo, 32 bytes) and installs it. Call it once at startup, before serving. An empty secret is refused, so a
// caller that has no key never silently installs a weak one.
func SetConversationKey(secret []byte) error {
	if len(secret) == 0 {
		return errors.New("logger: empty conversation hash secret")
	}
	k, err := hkdf.Key(sha256.New, secret, nil, convHashInfo, 32)
	if err != nil {
		return err
	}
	convHashKey.Store(&k)
	randomConvKey.Store(false)
	return nil
}

// ConversationKeySet reports whether SetConversationKey installed a real key (a tool that prints a hash for an operator to
// grep for must refuse without one).
func ConversationKeySet() bool {
	k := convHashKey.Load()
	return k != nil && !randomConvKey.Load()
}

var randomConvKey atomic.Bool

// HashConversation is the log pseudonym of a conversation id: the first 8 bytes (16 hex characters) of
// HMAC-SHA256(key, id) with the key from SetConversationKey. A conversation id is the hash of the two uids, so it is
// guessable from a uid pair; the plain SHA-256 of it (HashUID) would let anyone holding a log confirm a guess, the keyed
// hash does not. An operator reproduces it with `opsctl messages loghash`. Without a key it is keyed by a random
// per-process value, so the output is stable inside one process only and never the plain hash. "" in, "" out.
func HashConversation(id string) string {
	if id == "" {
		return ""
	}
	return hashKeyed(id)
}

// hashKeyed is the shared HMAC body of HashConversation and HashPost.
func hashKeyed(s string) string {
	k := convHashKey.Load()
	if k == nil {
		rk := make([]byte, 32)
		_, _ = rand.Read(rk)
		if convHashKey.CompareAndSwap(nil, &rk) {
			randomConvKey.Store(true)
		}
		k = convHashKey.Load()
	}
	m := hmac.New(sha256.New, *k)
	m.Write([]byte(s))
	return hex.EncodeToString(m.Sum(nil)[:8])
}

// HashPost is the log pseudonym of a post id (post_hash on the VotePoll request line and the poll_vote_contention WARN): the
// first 8 bytes of HMAC-SHA256(key, "post|" + id), with the same key as HashConversation (no new secret; the label keeps the two
// domains apart). A post id is public, so an unkeyed hash next to the unkeyed uid_hash would let a log reader rebuild who voted in
// which poll (security review L-1); keyed, a hash cannot be recomputed without CURSOR_HMAC_KEY. `opsctl polls loghash` reproduces it.
// "" in, "" out.
func HashPost(id string) string {
	if id == "" {
		return ""
	}
	return hashKeyed("post|" + id)
}

// RedactErrKeyed is RedactErr for a mix of ids: every occurrence of a uid in ids becomes HashUID(uid) and every occurrence of
// a conversation id in convIDs becomes HashConversation(id), so an error line never carries the plain hash of a guessable id.
// Longer ids are replaced first, so an id that contains another is not half replaced.
func RedactErrKeyed(err error, convIDs []string, ids ...string) error {
	if err == nil {
		return nil
	}
	msg := CauseChain(err)
	for _, id := range convIDs {
		if id != "" {
			msg = strings.ReplaceAll(msg, id, HashConversation(id))
		}
	}
	for _, id := range ids {
		if id != "" {
			msg = strings.ReplaceAll(msg, id, HashUID(id))
		}
	}
	return &redactedError{msg: msg, cause: err}
}
