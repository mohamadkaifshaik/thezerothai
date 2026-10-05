package text

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// fixturePath is the repo-root shared fixture (ADR-0010 D21 G1); the Dart parser tests run the same rows.
var fixturePath = filepath.Join("..", "..", "..", "..", "testdata", "post_text_grammar.json")

type grammarRow struct {
	Text          string   `json:"text"`
	Mentions      []string `json:"mentions"`
	Hashtags      []string `json:"hashtags"`
	URLSpans      []string `json:"url_spans"`
	TappableLinks []string `json:"tappable_links"`
}

type normaliseRow struct {
	Raw    string  `json:"raw"`
	Stored *string `json:"stored"`
	Error  bool    `json:"error"`
}

type fixture struct {
	Grammar   []grammarRow   `json:"grammar"`
	Normalise []normaliseRow `json:"normalise"`
}

func loadFixture(t *testing.T) (fixture, []byte) {
	t.Helper()
	b, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f fixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return f, b
}

func nilToEmpty(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func TestSharedFixture_Grammar(t *testing.T) {
	t.Parallel()
	f, raw := loadFixture(t)
	ran := 0
	for _, row := range f.Grammar {
		ran++
		got, err := Normalize(row.Text)
		if err != nil || got != row.Text {
			t.Errorf("row %q: Normalize = %q, %v; want unchanged", row.Text, got, err)
			continue
		}
		if m := nilToEmpty(Mentions(row.Text)); !reflect.DeepEqual(m, nilToEmpty(row.Mentions)) {
			t.Errorf("row %q: mentions = %v, want %v", row.Text, m, row.Mentions)
		}
		if h := nilToEmpty(Hashtags(row.Text)); !reflect.DeepEqual(h, nilToEmpty(row.Hashtags)) {
			t.Errorf("row %q: hashtags = %v, want %v", row.Text, h, row.Hashtags)
		}
		rs := []rune(row.Text)
		var spans []string
		for _, sp := range urlSpans(rs) {
			spans = append(spans, string(rs[sp.start:sp.end]))
		}
		if !reflect.DeepEqual(nilToEmpty(spans), nilToEmpty(row.URLSpans)) {
			t.Errorf("row %q: url spans = %v, want %v", row.Text, spans, row.URLSpans)
		}
	}
	if want := bytes.Count(raw, []byte(`"mentions":`)); ran != want || ran == 0 {
		t.Errorf("ran %d grammar rows, file has %d", ran, want)
	}
}

func TestSharedFixture_Normalise(t *testing.T) {
	t.Parallel()
	f, raw := loadFixture(t)
	ran := 0
	for _, row := range f.Normalise {
		ran++
		got, err := Normalize(row.Raw)
		switch {
		case row.Error && err == nil:
			t.Errorf("raw %q: want VALIDATION, got %q", row.Raw, got)
		case row.Error:
			assertTextValidation(t, err)
		case err != nil || row.Stored == nil || got != *row.Stored:
			t.Errorf("raw %q: got %q, %v; want %v", row.Raw, got, err, row.Stored)
		}
	}
	if want := bytes.Count(raw, []byte(`"raw":`)); ran != want || ran == 0 {
		t.Errorf("ran %d normalise rows, file has %d", ran, want)
	}
}

// TestURLSpanAcceptance covers the T6 D21 delta criteria beyond the fixture rows.
func TestURLSpanAcceptance(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		in           string
		wantMentions []string
		wantTags     []string
	}{
		{"query mention", "https://ex.com/?ref=@bob", nil, nil},
		{"mention after link", "see https://ex.com/?ref=@bob and @carol", []string{"carol"}, nil},
		{"fragment tag then tag", "https://ex.com/?a=1&b=#go #rust", nil, []string{"rust"}},
		{"x-prefixed is no link", "xhttps://ex.com/?r=@bob", []string{"bob"}, nil},
		{"BOM ends the span", "https://ex.com/?r=@bob\ufeff@carol", []string{"carol"}, nil},
		{"excluded candidate takes no slot", "https://a.b/?x=@aaa @b01 @b02 @b03 @b04 @b05 @b06 @b07 @b08 @b09 @b10", []string{"b01", "b02", "b03", "b04", "b05", "b06", "b07", "b08", "b09", "b10"}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := Mentions(tt.in); !reflect.DeepEqual(got, tt.wantMentions) {
				t.Errorf("Mentions = %v, want %v", got, tt.wantMentions)
			}
			if got := Hashtags(tt.in); !reflect.DeepEqual(got, tt.wantTags) {
				t.Errorf("Hashtags = %v, want %v", got, tt.wantTags)
			}
		})
	}
}

func TestNormalize_LineSeparators(t *testing.T) {
	t.Parallel()
	ten := strings.Repeat("x\u2028", 9) + "x"
	if got, err := Normalize(ten); err != nil || strings.Count(got, "\n") != 9 || strings.ContainsAny(got, "\u2028\u2029") {
		t.Errorf("10 U+2028 lines: %q, %v", got, err)
	}
	if _, err := Normalize(ten + "\u2029x"); err == nil {
		t.Error("11 lines via U+2029 must be rejected")
	}
}
