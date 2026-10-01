package cursor

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

const bind = "uid-a|followers|uid-b"

func TestEncodeDecode_RoundTrip(t *testing.T) {
	key := []byte("test-key")
	want := Cursor{CreatedAt: time.Now().UTC().Truncate(time.Microsecond), DocID: "0000000000000000001"}

	token := Encode(key, bind, want)
	if token == "" {
		t.Fatal("Encode returned empty token")
	}
	got, err := Decode(key, bind, token)
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if !got.CreatedAt.Equal(want.CreatedAt) || got.DocID != want.DocID {
		t.Fatalf("Decode() = %+v, want %+v", got, want)
	}
}

func TestDecode_EmptyTokenIsFirstPage(t *testing.T) {
	c, err := Decode([]byte("key"), bind, "")
	if err != nil {
		t.Fatalf("Decode(\"\") error = %v", err)
	}
	if !IsFirstPage(c) {
		t.Fatalf("expected empty token to decode to first page, got %+v", c)
	}
}

func TestDecode_Rejects(t *testing.T) {
	now := time.Now()
	c := Cursor{CreatedAt: now, DocID: "uid-c_uid-b"}
	key := []byte("key-a")
	good := EncodeAt(key, bind, c, now)
	mid := len(good) / 2
	flip := "a"
	if good[mid] == 'a' {
		flip = "b"
	}

	tests := []struct {
		name    string
		key     []byte
		binding string
		token   string
		at      time.Time
	}{
		{"wrong key", []byte("key-b"), bind, good, now},
		{"wrong caller", key, "uid-x|followers|uid-b", good, now},
		{"wrong list", key, "uid-a|following|uid-b", good, now},
		{"wrong target", key, "uid-a|followers|uid-y", good, now},
		{"tampered", key, bind, good[:mid] + flip + good[mid+1:], now},
		{"truncated", key, bind, good[:10], now},
		{"expired", key, bind, good, now.Add(TTL + time.Second)},
		{"issued in the future", key, bind, good, now.Add(-2 * clockSkew)},
		{"garbage", key, bind, "not-base64!!", now},
		{"short", key, bind, "YQ", now},
		{"v1 format", key, bind, base64.RawURLEncoding.EncodeToString([]byte("123|uid|c2ln")), now},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := DecodeAt(tc.key, tc.binding, tc.token, tc.at); err != ErrInvalid {
				t.Fatalf("err = %v, want ErrInvalid", err)
			}
		})
	}
}

// TestDecode_GoldenGraphToken is the T28 compatibility guard: this token was minted by the PRE-T28 Encode
// (origin/main's cursor.go: EncodeAt with key "golden-key", binding "uid-a|followers|uid-b", issue time
// 1_700_000_000 s, createdAt 1_699_999_000_123_456 us, doc id "uid-c_uid-b") and must keep decoding through
// DecodeAt, so graph tokens in clients' hands survive this change.
func TestDecode_GoldenGraphToken(t *testing.T) {
	const golden = "lqqbb8soedExB3QThIrJQ1MaNZverT_bWOeSlwSVbqMOn4LzXEr4StQuHMP58bdNsmv2zuHfI0S68gbeTKtGOjbzH1gNB9oWDQ"
	issue := time.Unix(1_700_000_000, 0)
	got, err := DecodeAt([]byte("golden-key"), "uid-a|followers|uid-b", golden, issue.Add(time.Hour))
	if err != nil {
		t.Fatalf("DecodeAt(golden) error = %v", err)
	}
	if want := time.UnixMicro(1_699_999_000_123_456).UTC(); !got.CreatedAt.Equal(want) || got.DocID != "uid-c_uid-b" {
		t.Fatalf("DecodeAt(golden) = %+v, want createdAt %v doc uid-c_uid-b", got, want)
	}
	// And it still expires on the 24 h graph TTL.
	if _, err := DecodeAt([]byte("golden-key"), "uid-a|followers|uid-b", golden, issue.Add(TTL+time.Second)); err != ErrInvalid {
		t.Fatalf("golden token past 24 h: err = %v, want ErrInvalid", err)
	}
}

func TestDecode_ValidUntilTTL(t *testing.T) {
	now := time.Now()
	tok := EncodeAt([]byte("k"), bind, Cursor{CreatedAt: now, DocID: "1"}, now)
	if _, err := DecodeAt([]byte("k"), bind, tok, now.Add(TTL-time.Second)); err != nil {
		t.Fatalf("token inside TTL rejected: %v", err)
	}
}

// TestToken_IsOpaque is the M1 regression: neither the raw token nor its base64 decoding contains the doc id
// or a readable structure.
func TestToken_IsOpaque(t *testing.T) {
	const doc = "uid-hidden_uid-target"
	tok := EncodeAt([]byte("k"), bind, Cursor{CreatedAt: time.Now(), DocID: doc}, time.Now())
	if strings.Contains(tok, "uid-hidden") {
		t.Fatal("token contains the doc id")
	}
	raw, err := base64.RawURLEncoding.DecodeString(tok)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "uid-hidden") || strings.Contains(string(raw), "uid-target") {
		t.Fatal("decoded token is readable")
	}
	// Two tokens for the same cursor differ (random nonce).
	if tok == EncodeAt([]byte("k"), bind, Cursor{CreatedAt: time.Now(), DocID: doc}, time.Now()) {
		t.Fatal("tokens are deterministic")
	}
}

func TestDecode_EmptyDocIDFails(t *testing.T) {
	token := Encode([]byte("key"), bind, Cursor{CreatedAt: time.Now(), DocID: ""})
	if _, err := Decode([]byte("key"), bind, token); err != ErrInvalid {
		t.Fatalf("Decode with empty doc id: err = %v, want ErrInvalid", err)
	}
}
