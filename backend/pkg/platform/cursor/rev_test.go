package cursor

import (
	"errors"
	"testing"
	"time"
)

func TestRevToken_RoundTripAndLegacy(t *testing.T) {
	key := []byte("test-key")
	now := time.Date(2026, 10, 29, 10, 0, 0, 0, time.UTC)
	want := Cursor{CreatedAt: now.Add(-time.Minute), DocID: "abc123"}

	tests := []struct {
		name    string
		token   string
		wantRev int64
	}{
		{"revision 0", EncodeRevAt(key, bind, want, 0, now), 0},
		{"revision 7", EncodeRevAt(key, bind, want, 7, now), 7},
		{"legacy position-only token reads as revision 0", EncodeAt(key, bind, want, now), 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, rev, err := DecodeRevAtTTL(key, bind, tt.token, now, time.Hour)
			if err != nil || rev != tt.wantRev || !got.CreatedAt.Equal(want.CreatedAt) || got.DocID != want.DocID {
				t.Fatalf("got %+v rev %d err %v, want %+v rev %d", got, rev, err, want, tt.wantRev)
			}
		})
	}
	if _, rev, err := DecodeRevAtTTL(key, bind, "", now, time.Hour); err != nil || rev != 0 {
		t.Errorf("empty token: rev %d err %v", rev, err)
	}
}

func TestRevToken_DomainsAreSeparate(t *testing.T) {
	key := []byte("test-key")
	now := time.Date(2026, 10, 29, 10, 0, 0, 0, time.UTC)
	c := Cursor{CreatedAt: now, DocID: "abc"}
	rev := EncodeRevAt(key, bind, c, 3, now)
	if _, err := DecodeAtTTL(key, bind, rev, now, time.Hour); !errors.Is(err, ErrInvalid) {
		t.Errorf("a revision token opened through DecodeAtTTL: %v", err)
	}
	if _, err := DecodeWindowAt(key, bind, rev, now, time.Hour); err == nil {
		t.Error("a revision token opened as a window")
	}
}

func TestRevToken_Rejects(t *testing.T) {
	key := []byte("test-key")
	now := time.Date(2026, 10, 29, 10, 0, 0, 0, time.UTC)
	c := Cursor{CreatedAt: now, DocID: "abc"}
	good := EncodeRevAt(key, bind, c, 2, now)
	// A middle character carries six full bits, so the sealed bytes always change; the last characters may not (the
	// token has a random nonce, so replacing them flaked about once in a thousand runs).
	mid := len(good) / 2
	flip := "a"
	if good[mid] == 'a' {
		flip = "b"
	}
	tampered := good[:mid] + flip + good[mid+1:]

	tests := []struct {
		name  string
		token string
		key   []byte
		bind  string
		at    time.Time
	}{
		{"tampered", tampered, key, bind, now},
		{"another binding", good, key, "someone-else", now},
		{"another key", good, []byte("other"), bind, now},
		{"expired (does not fall back)", good, key, bind, now.Add(2 * time.Hour)},
		{"issued in the future", EncodeRevAt(key, bind, c, 2, now.Add(time.Hour)), key, bind, now},
		{"garbage", "!!not-base64!!", key, bind, now},
		{"expired legacy", EncodeAt(key, bind, c, now), key, bind, now.Add(2 * time.Hour)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, _, err := DecodeRevAtTTL(tt.key, tt.bind, tt.token, tt.at, time.Hour); !errors.Is(err, ErrInvalid) {
				t.Errorf("err = %v, want ErrInvalid", err)
			}
		})
	}
}
