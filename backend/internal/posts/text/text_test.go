package text

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Invisible and combining runes are written as \U0000XXXX escapes so they stay visible in review.
const (
	zwj   = "\U0000200d"
	zwnj  = "\U0000200c"
	acute = "\U00000301" // combining acute accent
	matra = "\U0000093e" // Devanagari vowel sign AA (a mark)
	man   = "\U0001F468"
	woman = "\U0001F469"
	girl  = "\U0001F467"
	grin  = "\U0001F600"
)

// zwjFamily is 5 code points: man ZWJ woman ZWJ girl.
const zwjFamily = man + zwj + woman + zwj + girl

// TestMentions is the ADR-0010 D7 example table, verbatim, plus the grammar edges the prose states.
func TestMentions(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"case-insensitive dedupe", "@Alice @alice", []string{"alice"}},
		{"email is not a mention", "email@example.com", nil},
		{"parenthesised", "(@bob)", []string{"bob"}},
		{"possessive", "@bob's", []string{"bob"}},
		{"double at", "@@bob", nil},
		{"followed by at", "@bob@host", nil},
		{"url path", "https://x.y/@bob", nil},
		{"too short", "@ab", nil},
		{"16 chars is not truncated", "@abcdefghijklmnop", nil},
		{"15 chars is a mention", "@abcdefghijklmno", []string{"abcdefghijklmno"}},
		{"hyphen splits to a too-short run", "@al-ice", nil},
		{"trailing underscore", "hi @carol_", []string{"carol_"}},
		{"start of text and after newline", "@dan\n@erin", []string{"dan", "erin"}},
		{"after a dot is excluded", "x.@bob", nil},
		{"after a plus is excluded", "a+@bob", nil},
		{"after a digit is excluded", "7@bob", nil},
		{"after a combining mark is excluded", "e" + acute + "@bob", nil},
		{"after a devanagari letter is excluded", "भारत@bob", nil},
		{"after an emoji is fine", grin + "@bob", []string{"bob"}},
		{"followed by a non-ascii letter", "@bob\U000000e9", []string{"bob"}},
		{"first occurrence order kept", "@zed @amy @zed", []string{"zed", "amy"}},
		{"none", "no mentions here", nil},
		{"lone at", "@", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Mentions(tc.in); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("Mentions(%q) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func TestMentions_CapAtTen(t *testing.T) {
	var parts []string
	for i := 0; i < 12; i++ {
		parts = append(parts, fmt.Sprintf("@user%02d", i))
	}
	got := Mentions(strings.Join(parts, " "))
	if len(got) != MaxMentions || got[0] != "user00" || got[9] != "user09" {
		t.Fatalf("got %v, want the first 10", got)
	}
}

// TestHashtags is the ADR-0010 D8 example table, verbatim, plus the grammar edges.
func TestHashtags(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"case-insensitive dedupe", "#Go #go #GO", []string{"go"}},
		{"devanagari keeps its vowel signs", "#भारत", []string{"भारत"}},
		{"precomposed accent", "#caf\U000000e9", []string{"caf\U000000e9"}},
		{"underscore", "#go_lang", []string{"go_lang"}},
		{"digits only is not a tag (pinned)", "#123", nil},
		{"devanagari digits only", "#१२३", nil},
		{"mid-word hash", "a#b", nil},
		{"url fragment", "https://x.y/p#frag", nil},
		{"html entity", "&#39;", nil},
		{"lone hash", "#", nil},
		{"hash then space", "# go", nil},
		{"letter plus digits", "#go2", []string{"go2"}},
		{"digit first then letter", "#2go", []string{"2go"}},
		{"underscore only has no letter", "#_", nil},
		{"mark cannot start a tag", "#" + acute + "a", nil},
		{"after at is excluded", "@#go", nil},
		{"double hash", "##go", nil},
		{"after punctuation is fine", "(#go)", []string{"go"}},
		{"after emoji is fine", grin + "#go", []string{"go"}},
		{"zwj and zwnj are body chars", "#a" + zwj + "b" + zwnj + "c", []string{"a" + zwj + "b" + zwnj + "c"}},
		{"exactly 50 code points", "#" + strings.Repeat("a", 50), []string{strings.Repeat("a", 50)}},
		{"51 code points is not truncated", "#" + strings.Repeat("a", 51), nil},
		{"marks count toward 50", "#" + strings.Repeat("क"+matra, 25), []string{strings.Repeat("क"+matra, 25)}},
		{"marks over 50", "#" + strings.Repeat("क"+matra, 26), nil},
		{"upper-case non-ascii lowered", "#\U000000c9COLE", []string{"\U000000e9cole"}},
		{"stops at punctuation", "#go!", []string{"go"}},
		{"first occurrence order kept", "#b #a #b", []string{"b", "a"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Hashtags(tc.in); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("Hashtags(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestHashtags_ElevenTagsStoreTenAndTextUnchanged(t *testing.T) {
	var parts []string
	for i := 0; i < 11; i++ {
		parts = append(parts, fmt.Sprintf("#t%c", 'a'+i))
	}
	in := strings.Join(parts, " ")
	p, err := Parse(in)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Hashtags) != MaxHashtags || p.Hashtags[9] != "tj" {
		t.Fatalf("Hashtags = %v, want the first 10", p.Hashtags)
	}
	if p.Text != in {
		t.Fatalf("text changed: %q", p.Text)
	}
}

func TestNormalize(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"plain", "hello", "hello", false},
		{"CRLF and CR become LF", "a\r\nb\rc", "a\nb\nc", false},
		{"tab becomes one space", "a\tb", "a b", false},
		{"NFC composes", "cafe" + acute, "caf\U000000e9", false},
		{"trims spaces and newlines", " \n\U000000a0 hi \U00002003\n", "hi", false},
		{"empty", "", "", true},
		{"only whitespace", " \t\r\n ", "", true},
		{"invalid utf-8", "a\xffb", "", true},
		{"NUL", "a\x00b", "", true},
		{"DEL", "a\x7fb", "", true},
		{"C1 control", "a\U00000085b", "", true},
		{"U+202E right-to-left override anywhere", "abc \U0000202e def", "", true},
		{"U+202A", "\U0000202aab", "", true},
		{"U+2066", "ab\U00002066", "", true},
		{"U+2069", "a\U00002069b", "", true},
		{"RLM allowed", "a\U0000200fb", "a\U0000200fb", false},
		{"LRM allowed", "a\U0000200eb", "a\U0000200eb", false},
		{"ZWJ emoji sequence allowed", zwjFamily, zwjFamily, false},
		{"internal blank lines kept", "a\n\nb", "a\n\nb", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Normalize(tc.in)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if err == nil && got != tc.want {
				t.Fatalf("Normalize(%q) = %q, want %q", tc.in, got, tc.want)
			}
			if err != nil {
				assertTextValidation(t, err)
			}
		})
	}
}

func TestNormalize_Length(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		wantErr bool
	}{
		{"280 ascii", strings.Repeat("a", 280), false},
		{"281 ascii", strings.Repeat("a", 281), true},
		{"280 emoji", strings.Repeat(grin, 280), false},
		{"281 emoji", strings.Repeat(grin, 281), true},
		// A ZWJ family is 5 code points: 56 of them is 280, 57 is 285.
		{"56 ZWJ families = 280 code points", strings.Repeat(zwjFamily, 56), false},
		{"57 ZWJ families", strings.Repeat(zwjFamily, 57), true},
		// NFC first: 280 decomposed e+acute (560 runes raw) compose to 280 code points.
		{"280 decomposed accents count after NFC", strings.Repeat("e"+acute, 280), false},
		{"281 decomposed accents", strings.Repeat("e"+acute, 281), true},
		{"length is checked after trimming", "  " + strings.Repeat("a", 280) + "  ", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Normalize(tc.in)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v (runes after normalise: %d)", err, tc.wantErr, utf8.RuneCountInString(got))
			}
			if err != nil {
				assertTextValidation(t, err)
			}
		})
	}
}

func TestNormalize_Lines(t *testing.T) {
	ten := strings.Repeat("a\n", 9) + "a"
	if _, err := Normalize(ten); err != nil {
		t.Fatalf("10 lines rejected: %v", err)
	}
	_, err := Normalize(ten + "\na")
	if err == nil {
		t.Fatal("11 lines accepted")
	}
	assertTextValidation(t, err)
	// CRLF counts as one line break.
	if _, err := Normalize(strings.Repeat("a\r\n", 9) + "a"); err != nil {
		t.Fatalf("10 CRLF lines rejected: %v", err)
	}
	// Trailing newlines are trimmed before counting.
	if _, err := Normalize(ten + "\n\n\n"); err != nil {
		t.Fatalf("trailing newlines should be trimmed first: %v", err)
	}
}

func TestParse(t *testing.T) {
	p, err := Parse("  Hi @Bob and #Go\r\n@bob #भारत  ")
	if err != nil {
		t.Fatal(err)
	}
	if want := "Hi @Bob and #Go\n@bob #भारत"; p.Text != want {
		t.Fatalf("Text = %q, want %q", p.Text, want)
	}
	if !reflect.DeepEqual(p.Mentions, []string{"bob"}) {
		t.Fatalf("Mentions = %v", p.Mentions)
	}
	if !reflect.DeepEqual(p.Hashtags, []string{"go", "भारत"}) {
		t.Fatalf("Hashtags = %v", p.Hashtags)
	}
	if _, err := Parse(""); err == nil {
		t.Fatal("empty text accepted")
	}
}

func assertTextValidation(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err %v is not an *apierr.Error", err)
	}
	ce := apierr.ToConnect(err)
	if ce.Code() != connect.CodeInvalidArgument {
		t.Fatalf("code = %v, want InvalidArgument", ce.Code())
	}
	var detail *commonv1.ErrorDetail
	for _, d := range ce.Details() {
		v, derr := d.Value()
		if derr != nil {
			continue
		}
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			detail = ed
		}
	}
	if detail == nil {
		t.Fatal("no ErrorDetail attached")
	}
	if detail.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || detail.GetMetadata()["field"] != "text" {
		t.Fatalf("detail = %v, want VALIDATION field=text", detail)
	}
}

// FuzzParse: arbitrary bytes never panic, and a successful parse satisfies the stored-text invariants.
func FuzzParse(f *testing.F) {
	for _, s := range []string{"", "@a", "#", "@bob #go", "a\r\nb", "\xff", "#" + acute, "@@@###", "\U0000202e", grin + "#x", "e" + acute + "@abc", "https://x.y/?r=@bob #go @carol", "\u200b\ufeff", "a\u2028b"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		p, err := Parse(s)
		if err != nil {
			return
		}
		if n := utf8.RuneCountInString(p.Text); n < 1 || n > MaxRunes {
			t.Fatalf("stored text has %d code points", n)
		}
		if strings.Count(p.Text, "\n") >= MaxLines || strings.ContainsAny(p.Text, "\r\t") {
			t.Fatalf("stored text breaks line rules: %q", p.Text)
		}
		if len(p.Mentions) > MaxMentions || len(p.Hashtags) > MaxHashtags {
			t.Fatalf("too many candidates: %v %v", p.Mentions, p.Hashtags)
		}
		for _, h := range p.Hashtags {
			if utf8.RuneCountInString(h) > maxHashtagLen || h != strings.ToLower(h) {
				t.Fatalf("bad hashtag %q", h)
			}
		}
		rs := []rune(p.Text)
		for _, sp := range urlSpans(rs) {
			for _, m := range p.Mentions {
				if strings.Contains(string(rs[sp.start:sp.end]), "@"+m) && overlapsAny(rs, sp, "@"+m) {
					t.Fatalf("mention %q overlaps a URL span in %q", m, p.Text)
				}
			}
		}
		for _, m := range p.Mentions {
			if len(m) < 3 || len(m) > 15 || m != strings.ToLower(m) {
				t.Fatalf("bad mention %q", m)
			}
		}
	})
}

// overlapsAny reports whether any occurrence of needle (case-insensitive) in rs overlaps span sp.
func overlapsAny(rs []rune, sp span, needle string) bool {
	low := []rune(strings.ToLower(string(rs)))
	n := []rune(strings.ToLower(needle))
	for i := 0; i+len(n) <= len(low); i++ {
		if string(low[i:i+len(n)]) == string(n) && i < sp.end && sp.start < i+len(n) {
			return true
		}
	}
	return false
}
