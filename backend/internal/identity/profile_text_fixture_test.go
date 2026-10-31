package identity

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The shared profile text fixture (W3-22 L-2/L-3): testdata/profile_text/{location,website,display_name,bio}.json at the
// repo root, one file per field. The Dart client runs the same files (its runner lands in the frontend follow-up), so a
// rule changed on one side fails on the other. See testdata/profile_text/README.md for the schema.

var profileTextDir = filepath.Join("..", "..", "..", "testdata", "profile_text")

type profileTextAccept struct {
	Name   string `json:"name"`
	Raw    string `json:"raw"`
	Stored string `json:"stored"`
	Host   string `json:"host"`
}

type profileTextReject struct {
	Name string `json:"name"`
	Raw  string `json:"raw"`
	Why  string `json:"why"`
}

type profileTextFile struct {
	Field  string              `json:"field"`
	Accept []profileTextAccept `json:"accept"`
	Reject []profileTextReject `json:"reject"`
}

func loadProfileText(t *testing.T, field string) profileTextFile {
	t.Helper()
	path := filepath.Join(profileTextDir, field+".json")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f profileTextFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	if f.Field != field {
		t.Errorf("%s declares field %q, want %q", path, f.Field, field)
	}
	// Every row has exactly one "raw" key: a row dropped by a decoding slip (a renamed key) fails here instead of
	// silently shrinking the suite, as the post text fixture's runners do.
	if want := bytes.Count(b, []byte(`"raw":`)); len(f.Accept)+len(f.Reject) != want || want == 0 || len(f.Accept) == 0 || len(f.Reject) == 0 {
		t.Errorf("%s: decoded %d accept + %d reject rows, file has %d", path, len(f.Accept), len(f.Reject), want)
	}
	return f
}

// runProfileText runs every row of one field's file: accepted rows must be valid and store exactly "stored"; rejected
// rows must be refused. valid reports the stored form and whether the field accepts raw.
func runProfileText(t *testing.T, field string, valid func(raw string) (stored string, ok bool)) profileTextFile {
	t.Helper()
	f := loadProfileText(t, field)
	for _, r := range f.Accept {
		if stored, ok := valid(r.Raw); !ok || stored != r.Stored {
			t.Errorf("accept %q (%q): got %q, ok=%v; want %q", r.Name, r.Raw, stored, ok, r.Stored)
		}
	}
	for _, r := range f.Reject {
		if stored, ok := valid(r.Raw); ok {
			t.Errorf("reject %q (%q): accepted as %q (why it must fail: %s)", r.Name, r.Raw, stored, r.Why)
		}
	}
	t.Logf("%s: %d accepted + %d rejected rows", field, len(f.Accept), len(f.Reject))
	return f
}

func TestSharedProfileText_Location(t *testing.T) {
	t.Parallel()
	runProfileText(t, "location", func(raw string) (string, bool) {
		n := normalizeLocation(raw)
		return n, !locationIssue(n)
	})
}

func TestSharedProfileText_DisplayName(t *testing.T) {
	t.Parallel()
	runProfileText(t, "display_name", func(raw string) (string, bool) {
		return normalizeDisplayName(raw), !displayNameIssue(raw)
	})
}

func TestSharedProfileText_Bio(t *testing.T) {
	t.Parallel()
	runProfileText(t, "bio", func(raw string) (string, bool) {
		return normalizeBio(raw), !bioIssue(raw)
	})
}

func TestSharedProfileText_Website(t *testing.T) {
	t.Parallel()
	f := runProfileText(t, "website", normalizeWebsite)
	// The host the client shows ("shows as") is part of the contract too.
	for _, r := range f.Accept {
		if _, host, ok := parseWebsite(r.Raw); !ok || host != r.Host {
			t.Errorf("accept %q (%q): host %q, ok=%v; want %q", r.Name, r.Raw, host, ok, r.Host)
		}
	}
}

// TestPunycodeEncode pins the ported encoder to RFC 3492 section 7.1 sample strings and the client's own output
// (profile_website.dart punycodeEncode, checked with the Dart parser on the same inputs).
func TestPunycodeEncode(t *testing.T) {
	t.Parallel()
	tests := []struct{ name, in, want string }{
		{"german", "b\u00fccher", "bcher-kva"},
		{"german lower-cased city", "m\u00fcnchen", "mnchen-3ya"},
		{"arabic (RFC 3492 A)", "\u0644\u064a\u0647\u0645\u0627\u0628\u062a\u0643\u0644\u0645\u0648\u0634\u0639\u0631\u0628\u064a\u061f", "egbpdaj6bu4bxfgehfvwxn"},
		{"chinese simplified (RFC 3492 B)", "\u4ed6\u4eec\u4e3a\u4ec0\u4e48\u4e0d\u8bf4\u4e2d\u6587", "ihqwcrb4cv8a8dqg056pqjye"},
		{"japanese with ASCII (RFC 3492 L)", "3\u5e74B\u7d44\u91d1\u516b\u5148\u751f", "3B-ww4c5e180e575a65lsy2b"},
		{"russian (RFC 3492 G)", "\u043f\u043e\u0447\u0435\u043c\u0443\u0436\u0435\u043e\u043d\u0438\u043d\u0435\u0433\u043e\u0432\u043e\u0440\u044f\u0442\u043f\u043e\u0440\u0443\u0441\u0441\u043a\u0438", "b1abfaaepdrnnbgefbadotcwatmq2g4l"},
		{"japanese example", "\u4f8b\u3048", "r8jz45g"},
		{"katakana example", "\u30c6\u30b9\u30c8", "zckzah"},
		{"fullwidth first letter", "\uff45xample", "xample-hy68a"},
		{"only a non-ASCII letter", "\u00fc", "tda"},
	}
	for _, tt := range tests {
		if got := punycodeEncode(tt.in); got != tt.want {
			t.Errorf("%s: punycodeEncode(%q) = %q, want %q", tt.name, tt.in, got, tt.want)
		}
	}
}

// The single-line rules (W5-45, W5-17 L-2): visible rune, format characters, fillers. Run through the shared helper lists
// use and through the display name validator, which must agree.
func TestSharedProfileText_SingleLine(t *testing.T) {
	t.Parallel()
	runProfileText(t, "single_line_text", func(raw string) (string, bool) {
		stored, ok := SingleLineText(raw, 1, 50)
		if dn := !displayNameIssue(raw); dn != ok {
			t.Errorf("%q: SingleLineText ok=%v but displayNameIssue accepts=%v", raw, ok, dn)
		}
		return stored, ok
	})
}

// An empty value is a clear, not a missing visible rune: a list description and a location may be "".
func TestSingleLineText_EmptyIsAllowedWhenMinIsZero(t *testing.T) {
	t.Parallel()
	if got, ok := SingleLineText("  ", 0, 100); !ok || got != "" {
		t.Errorf("blank description = %q, %v; want \"\", true", got, ok)
	}
	if locationIssue("") {
		t.Error("an empty location (a clear) must stay valid")
	}
	if _, ok := SingleLineText(string(rune(0x200b)), 0, 100); ok {
		t.Error("a description of only a zero width space must be refused")
	}
}
