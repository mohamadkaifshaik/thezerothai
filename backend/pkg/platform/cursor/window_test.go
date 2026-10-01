package cursor

import (
	"math/rand"
	"strings"
	"testing"
	"time"
)

const (
	homePageBind = "tl|home|uid-a|page"
	// ttl30d is TIMELINE_TOKEN_TTL (720 h, ADR-0010 D14).
	ttl30d = 720 * time.Hour
)

func TestWindow_RoundTrip(t *testing.T) {
	key := []byte("test-key")
	now := time.Now().UTC().Truncate(time.Microsecond)
	upper := Cursor{CreatedAt: now, DocID: "0000000000000000042"}
	lower := Cursor{CreatedAt: now.Add(-time.Hour), DocID: "0000000000000000007"}

	tests := []struct {
		name string
		in   Window
	}{
		{"scroll (no lower bound)", Window{Upper: upper}},
		{"gap (two bounds)", Window{Upper: upper, Lower: &lower}},
		{"watermark-style lower pair", Window{Upper: upper, Lower: &Cursor{CreatedAt: lower.CreatedAt, DocID: "0000000000000000000"}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			tok := EncodeWindow(key, homePageBind, tc.in)
			if tok == "" {
				t.Fatal("EncodeWindow returned an empty token")
			}
			got, err := DecodeWindow(key, homePageBind, tok, ttl30d)
			if err != nil {
				t.Fatalf("DecodeWindow() error = %v", err)
			}
			if !got.Upper.CreatedAt.Equal(tc.in.Upper.CreatedAt) || got.Upper.DocID != tc.in.Upper.DocID {
				t.Fatalf("Upper = %+v, want %+v", got.Upper, tc.in.Upper)
			}
			if (got.Lower == nil) != (tc.in.Lower == nil) {
				t.Fatalf("Lower = %+v, want %+v", got.Lower, tc.in.Lower)
			}
			if tc.in.Lower != nil && (!got.Lower.CreatedAt.Equal(tc.in.Lower.CreatedAt) || got.Lower.DocID != tc.in.Lower.DocID) {
				t.Fatalf("Lower = %+v, want %+v", *got.Lower, *tc.in.Lower)
			}
			if got.IsZero() {
				t.Fatal("a decoded non-empty token must not be the zero Window")
			}
		})
	}
}

func TestWindow_EmptyTokenIsFirstPage(t *testing.T) {
	w, err := DecodeWindow([]byte("k"), homePageBind, "", ttl30d)
	if err != nil || !w.IsZero() {
		t.Fatalf("DecodeWindow(\"\") = %+v, %v; want zero Window, nil", w, err)
	}
}

func TestEncodeWindow_RefusesUnencodable(t *testing.T) {
	now := time.Now()
	ok := Cursor{CreatedAt: now, DocID: "1"}
	tests := []struct {
		name string
		w    Window
	}{
		{"empty upper doc id", Window{Upper: Cursor{CreatedAt: now}}},
		{"upper doc id with separator", Window{Upper: Cursor{CreatedAt: now, DocID: "a|b"}}},
		{"lower with empty doc id", Window{Upper: ok, Lower: &Cursor{CreatedAt: now}}},
		{"lower doc id with separator", Window{Upper: ok, Lower: &Cursor{CreatedAt: now, DocID: "a|b"}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tok := EncodeWindow([]byte("k"), homePageBind, tc.w); tok != "" {
				t.Fatalf("EncodeWindow = %q, want empty", tok)
			}
		})
	}
}

func TestDecodeWindow_Rejects(t *testing.T) {
	now := time.Now()
	key := []byte("key-a")
	lower := Cursor{CreatedAt: now.Add(-time.Minute), DocID: "5"}
	w := Window{Upper: Cursor{CreatedAt: now, DocID: "9"}, Lower: &lower}
	good := EncodeWindowAt(key, homePageBind, w, now)
	mid := len(good) / 2
	flip := "a"
	if good[mid] == 'a' {
		flip = "b"
	}
	cursorTok := EncodeAt(key, homePageBind, Cursor{CreatedAt: now, DocID: "9"}, now)

	tests := []struct {
		name    string
		key     []byte
		binding string
		token   string
		at      time.Time
	}{
		{"wrong key", []byte("key-b"), homePageBind, good, now},
		{"wrong caller", key, "tl|home|uid-b|page", good, now},
		{"home token on user timeline", key, "tl|user|uid-a|uid-t|posts|page", good, now},
		{"page token used as since", key, "tl|home|uid-a|since", good, now},
		{"cursor token used as window (same binding)", key, homePageBind, cursorTok, now},
		{"tampered", key, homePageBind, good[:mid] + flip + good[mid+1:], now},
		{"truncated", key, homePageBind, good[:10], now},
		{"expired at ttl+1s", key, homePageBind, good, now.Add(ttl30d + time.Second)},
		{"issued in the future", key, homePageBind, good, now.Add(-2 * clockSkew)},
		{"garbage", key, homePageBind, "not-base64!!", now},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := DecodeWindowAt(tc.key, tc.binding, tc.token, tc.at, ttl30d); err != ErrInvalid {
				t.Fatalf("err = %v, want ErrInvalid", err)
			}
		})
	}
}

func TestDecodeWindow_TTLBoundary(t *testing.T) {
	now := time.Now()
	tok := EncodeWindowAt([]byte("k"), homePageBind, Window{Upper: Cursor{CreatedAt: now, DocID: "1"}}, now)
	if _, err := DecodeWindowAt([]byte("k"), homePageBind, tok, now.Add(ttl30d-time.Second), ttl30d); err != nil {
		t.Fatalf("window inside the 30-day TTL rejected: %v", err)
	}
	// The same token is already dead under the 24 h default.
	if _, err := DecodeWindowAt([]byte("k"), homePageBind, tok, now.Add(TTL+time.Second), TTL); err != ErrInvalid {
		t.Fatalf("window past a 24 h ttl: err = %v, want ErrInvalid", err)
	}
	if _, err := DecodeWindowAt([]byte("k"), homePageBind, tok, now, 0); err != ErrInvalid {
		t.Fatalf("ttl 0 must reject: err = %v", err)
	}
}

func TestWindow_TokensAreOpaqueAndRandomised(t *testing.T) {
	now := time.Now()
	w := Window{Upper: Cursor{CreatedAt: now, DocID: "uid-hidden-doc"}}
	a := EncodeWindowAt([]byte("k"), homePageBind, w, now)
	b := EncodeWindowAt([]byte("k"), homePageBind, w, now)
	if a == b {
		t.Fatal("tokens are deterministic")
	}
	for _, s := range []string{"uid-hidden", "doc"} {
		if strings.Contains(a, s) {
			t.Fatalf("token leaks %q", s)
		}
	}
}

// TestDecodeTTL_CursorWithLongerLifetime: the single-position Cursor decode also takes a caller TTL (timeline
// `since` tokens, ADR-0010 D14), while Decode/DecodeAt keep the 24 h default so graph tokens are unchanged.
func TestDecodeTTL_CursorWithLongerLifetime(t *testing.T) {
	now := time.Now()
	key := []byte("k")
	const b = "tl|home|uid-a|since"
	tok := EncodeAt(key, b, Cursor{CreatedAt: now, DocID: "0000000000000000000"}, now)

	later := now.Add(10 * 24 * time.Hour)
	if _, err := DecodeAtTTL(key, b, tok, later, ttl30d); err != nil {
		t.Fatalf("10-day-old since token under a 30-day TTL rejected: %v", err)
	}
	if _, err := DecodeAt(key, b, tok, later); err != ErrInvalid {
		t.Fatalf("default Decode must still expire at 24 h: err = %v", err)
	}
	if _, err := DecodeAtTTL(key, b, tok, now.Add(ttl30d+time.Second), ttl30d); err != ErrInvalid {
		t.Fatalf("30 d + 1 s must expire: err = %v", err)
	}
	if c, err := DecodeTTL(key, b, EncodeAt(key, b, Cursor{CreatedAt: time.Now(), DocID: "1"}, time.Now()), ttl30d); err != nil || c.DocID != "1" {
		t.Fatalf("DecodeTTL = %+v, %v", c, err)
	}
	if c, err := DecodeTTL(key, b, "", ttl30d); err != nil || !IsFirstPage(c) {
		t.Fatalf("DecodeTTL(\"\") = %+v, %v", c, err)
	}
	// A Window token never opens as a Cursor.
	win := EncodeWindowAt(key, b, Window{Upper: Cursor{CreatedAt: now, DocID: "1"}}, now)
	if _, err := DecodeAtTTL(key, b, win, now, ttl30d); err != ErrInvalid {
		t.Fatalf("window token opened as a cursor: err = %v", err)
	}
}

// TestWindow_RoundTripProperty: random (createdAt, docId) pairs, with and without a lower bound, including
// zero, negative (pre-1970) and far-future times, survive EncodeWindow/DecodeWindow exactly (microseconds).
func TestWindow_RoundTripProperty(t *testing.T) {
	rng := rand.New(rand.NewSource(28))
	key := []byte("prop-key")
	now := time.Unix(1_700_000_000, 0)
	randTime := func() time.Time {
		switch rng.Intn(6) {
		case 0:
			return time.UnixMicro(0)
		case 1:
			return time.UnixMicro(-rng.Int63n(1 << 50)) // before 1970
		case 2:
			return time.UnixMicro(rng.Int63n(1 << 55)) // far future
		default:
			return time.UnixMicro(rng.Int63n(2_000_000_000_000_000))
		}
	}
	randID := func() string {
		const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:."
		b := make([]byte, 1+rng.Intn(40))
		for i := range b {
			b[i] = alphabet[rng.Intn(len(alphabet))]
		}
		return string(b)
	}
	for i := 0; i < 500; i++ {
		w := Window{Upper: Cursor{CreatedAt: randTime(), DocID: randID()}}
		if rng.Intn(2) == 0 {
			w.Lower = &Cursor{CreatedAt: randTime(), DocID: randID()}
		}
		tok := EncodeWindowAt(key, homePageBind, w, now)
		if tok == "" {
			t.Fatalf("case %d: %+v not encodable", i, w)
		}
		got, err := DecodeWindowAt(key, homePageBind, tok, now, ttl30d)
		if err != nil {
			t.Fatalf("case %d: %v", i, err)
		}
		if !got.Upper.CreatedAt.Equal(w.Upper.CreatedAt) || got.Upper.DocID != w.Upper.DocID || (got.Lower == nil) != (w.Lower == nil) {
			t.Fatalf("case %d: got %+v want %+v", i, got, w)
		}
		if w.Lower != nil && (!got.Lower.CreatedAt.Equal(w.Lower.CreatedAt) || got.Lower.DocID != w.Lower.DocID) {
			t.Fatalf("case %d: lower got %+v want %+v", i, *got.Lower, *w.Lower)
		}
	}
}

// TestDecode_ExactBoundaries pins the TTL and clock-skew edges for both codecs: age == ttl is accepted and
// ttl+1ns is rejected; an issue time exactly one minute in the future is accepted and +1ns is rejected.
func TestDecode_ExactBoundaries(t *testing.T) {
	issue := time.UnixMicro(1_700_000_000_000_000)
	key := []byte("k")
	curTok := EncodeAt(key, homePageBind, Cursor{CreatedAt: issue, DocID: "1"}, issue)
	winTok := EncodeWindowAt(key, homePageBind, Window{Upper: Cursor{CreatedAt: issue, DocID: "1"}}, issue)

	tests := []struct {
		name string
		now  time.Time
		ok   bool
	}{
		{"age == ttl", issue.Add(ttl30d), true},
		{"age == ttl + 1ns", issue.Add(ttl30d + time.Nanosecond), false},
		{"issued exactly skew in the future", issue.Add(-clockSkew), true},
		{"issued skew + 1ns in the future", issue.Add(-clockSkew - time.Nanosecond), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, cerr := DecodeAtTTL(key, homePageBind, curTok, tc.now, ttl30d)
			_, werr := DecodeWindowAt(key, homePageBind, winTok, tc.now, ttl30d)
			if (cerr == nil) != tc.ok || (werr == nil) != tc.ok {
				t.Fatalf("cursor err=%v window err=%v, want ok=%v", cerr, werr, tc.ok)
			}
		})
	}
}

func FuzzDecodeWindow(f *testing.F) {
	now := time.Now()
	f.Add(EncodeWindowAt([]byte("k"), homePageBind, Window{Upper: Cursor{CreatedAt: now, DocID: "1"}}, now))
	f.Add("")
	f.Add("AAAA")
	f.Fuzz(func(t *testing.T, tok string) {
		// Must never panic; anything that is not one of our tokens is ErrInvalid.
		if _, err := DecodeWindow([]byte("k"), homePageBind, tok, ttl30d); err != nil && err != ErrInvalid {
			t.Fatalf("unexpected error type: %v", err)
		}
	})
}
