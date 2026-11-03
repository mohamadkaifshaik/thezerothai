package media

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// gifStripCase is one row of testdata/gif_strip.json, the fixture the Dart stripper runs too (security L-4).
type gifStripCase struct {
	Name     string `json:"name"`
	Gif      string `json:"gif"`
	Stripped string `json:"stripped"`
	Dirty    bool   `json:"dirty"`
}

func loadGifStripCases(t *testing.T) []gifStripCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "gif_strip.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []gifStripCase `json:"cases"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) < 6 {
		t.Fatalf("fixture has %d cases, want at least 6", len(f.Cases))
	}
	return f.Cases
}

// TestW630_SharedFixture: every dirty GIF is refused as invalid; every clean one and every stripped output (what the
// Dart client sends) passes the pre-scan and samples to a sheet.
func TestW630_SharedFixture(t *testing.T) {
	t.Parallel()
	dirty := 0
	for _, c := range loadGifStripCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			t.Parallel()
			in, err := base64.StdEncoding.DecodeString(c.Gif)
			if err != nil {
				t.Fatal(err)
			}
			want, err := base64.StdEncoding.DecodeString(c.Stripped)
			if err != nil {
				t.Fatal(err)
			}
			sc, err := scanGIF(in, s0Limits)
			if c.Dirty {
				var ref *gifRefusal
				if !errors.As(err, &ref) || ref.reason != reasonInvalid {
					t.Fatalf("dirty GIF: err = %v, want a refusal with reason invalid", err)
				}
			} else if err != nil || len(sc.frames) != 2 {
				t.Fatalf("clean GIF: scan = %+v, err = %v", sc, err)
			}
			sc, err = scanGIF(want, s0Limits)
			if err != nil || len(sc.frames) != 2 {
				t.Fatalf("stripped GIF: scan = %+v, err = %v", sc, err)
			}
			if _, _, err := sampleGIF(t.Context(), want, sc); err != nil {
				t.Fatalf("stripped GIF does not sample: %v", err)
			}
		})
		if c.Dirty {
			dirty++
		}
	}
	if dirty < 6 {
		t.Fatalf("fixture has %d dirty cases, want at least 6", dirty)
	}
}

// loopBlockWithExtra inserts, right after the global colour table of gif, a NETSCAPE2.0 loop block that carries the loop
// count AND a second sub-block of arbitrary bytes (the re-review N-1 probe). gif must have a global table.
func loopBlockWithExtra(gif []byte) []byte {
	at := 13 + 3<<((gif[10]&7)+1)
	blk := append([]byte{0x21, 0xFF, 11}, "NETSCAPE2.0"...)
	blk = append(blk, 3, 1, 0, 0, 4, 0xDE, 0xAD, 0xBE, 0xEF, 0)
	return append(append(append([]byte{}, gif[:at]...), blk...), gif[at:]...)
}

// TestW658_LoopBlockRefusals: a loop block must be exactly 03 01 LL LL 00 and there may be one. The reason is
// the same invalid refusal as the other structure rules, with its own why; the probe is the 25 KB smuggling case.
func TestW658_LoopBlockRefusals(t *testing.T) {
	t.Parallel()
	base := gifBytes("w658")
	canonical := func(sub ...byte) []byte {
		at := 13 + 3<<((base[10]&7)+1)
		blk := append([]byte{0x21, 0xFF, 11}, "NETSCAPE2.0"...)
		blk = append(append(blk, sub...), 0)
		return append(append(append([]byte{}, base[:at]...), blk...), base[at:]...)
	}
	big := []byte{3, 1, 0, 0}
	for range 100 {
		big = append(big, 255)
		big = append(big, make([]byte, 255)...)
	}
	tests := []struct {
		name string
		gif  []byte
		ok   bool
	}{
		{"canonical", canonical(3, 1, 7, 0), true},
		{"extra sub-block", loopBlockWithExtra(base), false},
		{"25 KB of extra sub-blocks", canonical(big...), false},
		{"id 2", canonical(3, 2, 0, 0), false},
		{"length 2", canonical(2, 1, 0), false},
		{"empty", canonical(), false},
		{"id-1 sub-block second", canonical(1, 9, 3, 1, 0, 0), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := scanGIF(tt.gif, s0Limits)
			var ref *gifRefusal
			switch {
			case tt.ok && err != nil:
				t.Fatalf("scan: %v", err)
			case !tt.ok && (!errors.As(err, &ref) || ref.reason != reasonInvalid || ref.why != "loop_block"):
				t.Fatalf("err = %v, want an invalid refusal with why loop_block", err)
			}
		})
	}
	two := canonical(3, 1, 0, 0)
	at := 13 + 3<<((two[10]&7)+1)
	two = append(append(append([]byte{}, two[:at]...), two[at:at+19]...), two[at:]...)
	var ref *gifRefusal
	if _, err := scanGIF(two, s0Limits); !errors.As(err, &ref) || ref.why != "loop_block" {
		t.Fatalf("second loop block: err = %v", err)
	}
}
