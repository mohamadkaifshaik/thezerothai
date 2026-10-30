package search

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
)

// fixturePath is the grammar shared with the Dart parser (ADR-0028 D1 step 8).
var fixturePath = filepath.Join("..", "..", "..", "testdata", "search_query_grammar.json")

// wantCases is the row count of the fixture: adding or dropping a row must be a deliberate edit of both sides.
const wantCases = 39

type fixtureCase struct {
	Query  string `json:"query"`
	Note   string `json:"note"`
	People struct {
		Result string `json:"result"`
		Prefix string `json:"prefix"`
	} `json:"people"`
	Posts struct {
		Result string `json:"result"`
		Tag    string `json:"tag"`
	} `json:"posts"`
}

func loadFixture(t *testing.T) []fixtureCase {
	t.Helper()
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read %s: %v", fixturePath, err)
	}
	var f struct {
		Cases []fixtureCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(f.Cases) != wantCases {
		t.Fatalf("fixture has %d cases, want %d (update wantCases and the Dart test together)", len(f.Cases), wantCases)
	}
	return f.Cases
}

func (r peopleResult) String() string {
	return [...]string{"invalid", "too_short", "unsupported", "prefix"}[r]
}

// postsOf is D1 step 5 as SearchPosts (W4-7) will apply it, used here only to prove the fixture's posts half is true to
// the server's own hashtag extractor: the rest must be exactly one ADR-0010 D8 hashtag body.
func postsOf(raw string) (result, tag string) {
	q, ok := normalizeQuery(raw)
	if !ok {
		return "invalid", ""
	}
	if q.sigil == '@' {
		return "unsupported", ""
	}
	if tags := text.Hashtags("#" + q.body); len(tags) == 1 && tags[0] == q.body {
		return "tag", q.body
	}
	return "unsupported", ""
}

// TestQueryGrammarFixture: every row of the shared fixture, people half through parsePeopleQuery and posts half through
// the hashtag extractor.
func TestQueryGrammarFixture(t *testing.T) {
	for _, c := range loadFixture(t) {
		t.Run(c.Note, func(t *testing.T) {
			res, prefix := parsePeopleQuery(c.Query)
			if res.String() != c.People.Result || prefix != c.People.Prefix {
				t.Errorf("people(%q) = %s %q, want %s %q", c.Query, res, prefix, c.People.Result, c.People.Prefix)
			}
			pres, tag := postsOf(c.Query)
			if pres != c.Posts.Result || tag != c.Posts.Tag {
				t.Errorf("posts(%q) = %s %q, want %s %q", c.Query, pres, tag, c.Posts.Result, c.Posts.Tag)
			}
		})
	}
}

// TestQueryGrammarFixtureCoversADR: the examples ADR-0028 D1 step 8 requires are in the file.
func TestQueryGrammarFixtureCoversADR(t *testing.T) {
	var have []string
	for _, c := range loadFixture(t) {
		have = append(have, c.Query)
	}
	for _, q := range []string{"@", "#", "@a", "a", "ab", "@ab", "#a", "@AbC", "#Go", "go", "#123", "#भारत",
		"#café", "go lang", "#go!", "abcdefghijklmnop"} {
		if !slices.Contains(have, q) {
			t.Errorf("fixture lacks the ADR example %q", q)
		}
	}
}

// TestNormalizeQuery: sigil split, case folding and the limits of D1 steps 1 to 3.
func TestNormalizeQuery(t *testing.T) {
	tests := []struct {
		name      string
		in        string
		wantSigil rune
		wantBody  string
		wantOK    bool
	}{
		{"plain", "Ali", 0, "ali", true},
		{"at", " @Ali ", '@', "ali", true},
		{"hash", "#Go", '#', "go", true},
		{"second sigil stays in the body", "##a", '#', "#a", true},
		{"nfc", "café", 0, "café", true},
		{"empty", "", 0, "", false},
		{"sigil only", "@", 0, "", false},
		{"51 after sigil", "#" + strings.Repeat("a", 51), 0, "", false},
		{"nul", "a\x00", 0, "", false},
		{"rlo", "a‮", 0, "", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			q, ok := normalizeQuery(tc.in)
			if ok != tc.wantOK || (ok && (q.sigil != tc.wantSigil || q.body != tc.wantBody)) {
				t.Errorf("normalizeQuery(%q) = %+v, %v; want sigil %q body %q ok %v", tc.in, q, ok, tc.wantSigil, tc.wantBody, tc.wantOK)
			}
		})
	}
}
