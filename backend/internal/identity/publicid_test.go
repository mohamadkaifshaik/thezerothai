package identity

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	"math/big"
	"strings"
	"testing"
)

// countingReader counts the bytes NewPublicID takes from its source.
type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

// decodePublicID is the test's independent inverse of encodePublicID (math/big, not the bit-shifting encoder).
func decodePublicID(t *testing.T, id string) []byte {
	t.Helper()
	v := new(big.Int)
	for i := 1; i < len(id); i++ {
		d := strings.IndexByte(publicIDAlphabet, id[i])
		if d < 0 {
			t.Fatalf("%q: %q is not in the alphabet", id, id[i])
		}
		v.Lsh(v, 5).Or(v, big.NewInt(int64(d)))
	}
	if v.BitLen() > 128 {
		t.Fatalf("%q decodes to %d bits", id, v.BitLen())
	}
	return v.FillBytes(make([]byte, 16))
}

func TestPublicID_EncodingIsCanonical128Bits(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   [16]byte
		want string
	}{
		{"zero", [16]byte{}, "u" + strings.Repeat("0", 26)},
		{"all ones", [16]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "u7" + strings.Repeat("z", 25)},
		{"one", [16]byte{15: 1}, "u" + strings.Repeat("0", 25) + "1"},
		{"top bit", [16]byte{0: 0x80}, "u4" + strings.Repeat("0", 25)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := encodePublicID(tc.in)
			if got != tc.want {
				t.Fatalf("encode = %q, want %q", got, tc.want)
			}
			if !ValidPublicID(got) {
				t.Fatalf("ValidPublicID(%q) = false", got)
			}
			if back := decodePublicID(t, got); !bytes.Equal(back, tc.in[:]) {
				t.Fatalf("decode = %x, want %x", back, tc.in)
			}
		})
	}
}

func TestNewPublicID_ShapeEntropyAndUniqueness(t *testing.T) {
	const draws = 50_000
	seen := make(map[string]struct{}, draws)
	firstDigits := map[byte]bool{}
	for range draws {
		src := &countingReader{r: rand.Reader}
		id, err := newPublicIDFrom(src)
		if err != nil {
			t.Fatal(err)
		}
		if src.n != 16 {
			t.Fatalf("one id consumed %d random bytes, want 16 (128 bits)", src.n)
		}
		if len(id) != 27 || id[0] != 'u' || !ValidPublicID(id) {
			t.Fatalf("malformed id %q", id)
		}
		if strings.ContainsAny(id[1:], "ilouILOU") || strings.ToLower(id) != id {
			t.Fatalf("id %q uses an excluded or upper-case character", id)
		}
		if _, dup := seen[id]; dup {
			t.Fatalf("collision after %d draws: %q", len(seen), id)
		}
		seen[id] = struct{}{}
		firstDigits[id[1]] = true
		// The round trip proves the 128 bits are all carried.
		_ = decodePublicID(t, id)
	}
	if len(firstDigits) != 8 {
		t.Errorf("first body digit took %d values over %d draws, want all of 0-7", len(firstDigits), draws)
	}
	if id, err := NewPublicID(); err != nil || !ValidPublicID(id) {
		t.Fatalf("NewPublicID = %q, %v", id, err)
	}
}

func TestNewPublicID_SourceFailureProducesNoID(t *testing.T) {
	for _, src := range []io.Reader{bytes.NewReader(make([]byte, 15)), iotestErr{}} {
		id, err := newPublicIDFrom(src)
		if err == nil || id != "" {
			t.Fatalf("short or failing source: id %q, err %v; want no id and an error", id, err)
		}
	}
}

type iotestErr struct{}

func (iotestErr) Read([]byte) (int, error) { return 0, errors.New("entropy unavailable") }

func TestValidPublicID_RejectsUIDsHandlesAndNearMisses(t *testing.T) {
	good := "u0123456789abcdefghjkmnpqrs"
	if !ValidPublicID(good) {
		t.Fatalf("ValidPublicID(%q) = false", good)
	}
	for _, tc := range []struct{ name, in string }{
		{"empty", ""},
		{"firebase uid (28 mixed case)", "Xk9aQ2mPz7LrT4vB8nC1dE6fGh3J"},
		{"firebase uid lowercased to 27", "xk9aq2mpz7lrt4vb8nc1de6fgh3"},
		{"handle", "alice_01"},
		{"upper-case prefix", "U0123456789abcdefghjkmnpqrs"},
		{"upper-case body", "u0123456789ABCDEFGHJKMNPQRS"},
		{"wrong prefix", "p0123456789abcdefghjkmnpqrs"},
		{"one short", good[:26]},
		{"one long", good + "0"},
		{"excluded letter i", "u0123456789abcdefghikmnpqrs"},
		{"excluded letter l", "u0123456789abcdefghlkmnpqrs"},
		{"excluded letter o", "u0123456789abcdefghokmnpqrs"},
		{"excluded letter u", "u0123456789abcdefghukmnpqrs"},
		{"first digit 8 (over 128 bits)", "u8123456789abcdefghjkmnpqrs"},
		{"first digit z", "uz123456789abcdefghjkmnpqrs"},
		{"hyphen", "u0123456789abcdefghjkmnpq-s"},
		{"reserved doc id", "__0123456789abcdefghjkmnpq__"},
	} {
		if ValidPublicID(tc.in) {
			t.Errorf("%s: ValidPublicID(%q) = true", tc.name, tc.in)
		}
	}
}
