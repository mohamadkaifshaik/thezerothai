package cursor

import (
	"testing"
	"time"
)

func TestEncodeDecode_RoundTrip(t *testing.T) {
	key := []byte("test-key")
	want := Cursor{CreatedAt: time.Now().UTC().Truncate(time.Microsecond), DocID: "0000000000000000001"}

	token := Encode(key, want)
	if token == "" {
		t.Fatal("Encode returned empty token")
	}
	got, err := Decode(key, token)
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if !got.CreatedAt.Equal(want.CreatedAt) || got.DocID != want.DocID {
		t.Fatalf("Decode() = %+v, want %+v", got, want)
	}
}

func TestDecode_EmptyTokenIsFirstPage(t *testing.T) {
	c, err := Decode([]byte("key"), "")
	if err != nil {
		t.Fatalf("Decode(\"\") error = %v", err)
	}
	if !IsFirstPage(c) {
		t.Fatalf("expected empty token to decode to first page, got %+v", c)
	}
}

func TestDecode_WrongKeyFails(t *testing.T) {
	token := Encode([]byte("key-a"), Cursor{CreatedAt: time.Now(), DocID: "1"})
	if _, err := Decode([]byte("key-b"), token); err != ErrInvalid {
		t.Fatalf("Decode with wrong key: err = %v, want ErrInvalid", err)
	}
}

func TestDecode_TamperedTokenFails(t *testing.T) {
	key := []byte("key")
	token := Encode(key, Cursor{CreatedAt: time.Now(), DocID: "1"})
	// Flip a character in the middle of the token rather than the last one: base64's final character
	// can have "don't care" bits that decode to the same bytes, which would make this test flaky.
	mid := len(token) / 2
	flip := byte('a')
	if token[mid] == 'a' {
		flip = 'b'
	}
	tampered := token[:mid] + string(flip) + token[mid+1:]
	if _, err := Decode(key, tampered); err != ErrInvalid {
		t.Fatalf("Decode(tampered): err = %v, want ErrInvalid", err)
	}
}

func TestDecode_GarbageFails(t *testing.T) {
	cases := []string{"not-base64!!", "", "YQ", "!!!"}
	for _, tc := range cases {
		if tc == "" {
			continue // valid "first page" case, tested separately
		}
		if _, err := Decode([]byte("key"), tc); err != ErrInvalid {
			t.Errorf("Decode(%q): err = %v, want ErrInvalid", tc, err)
		}
	}
}

func TestDecode_EmptyDocIDFails(t *testing.T) {
	token := Encode([]byte("key"), Cursor{CreatedAt: time.Now(), DocID: ""})
	if _, err := Decode([]byte("key"), token); err != ErrInvalid {
		t.Fatalf("Decode with empty doc id: err = %v, want ErrInvalid", err)
	}
}
