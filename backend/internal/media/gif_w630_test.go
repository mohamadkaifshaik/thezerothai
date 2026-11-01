package media

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// gifStripCase is one row of testdata/gif_strip.json, the fixture the Dart stripper runs too (W6-30, security L-4).
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
