package messaging

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// The shared post-text grammar fixture (ADR-0010 D21 G1) is the one grammar of message text too (ADR-0027 D3, F8): the
// same rows that pin posts and the Dart parser pin SendMessage's validation.
var fixturePath = filepath.Join("..", "..", "..", "testdata", "post_text_grammar.json")

type sharedFixture struct {
	Grammar []struct {
		Text string `json:"text"`
	} `json:"grammar"`
	Normalise []struct {
		Raw    string  `json:"raw"`
		Stored *string `json:"stored"`
		Error  bool    `json:"error"`
	} `json:"normalise"`
}

func loadSharedFixture(t testing.TB) sharedFixture {
	t.Helper()
	b, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f sharedFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return f
}

func validateText(raw string) (string, error) {
	in, err := validateSend(alice, toUser(key1, bob, raw))
	return in.text, err
}

// Every row of the shared fixture gives the same stored text (or the same VALIDATION error on `text`) through
// SendMessage's validation as through the post parser.
func TestSend_SharedTextFixture(t *testing.T) {
	f := loadSharedFixture(t)
	if len(f.Normalise) == 0 || len(f.Grammar) == 0 {
		t.Fatalf("the fixture is empty: %d normalise rows, %d grammar rows", len(f.Normalise), len(f.Grammar))
	}
	for _, row := range f.Normalise {
		got, err := validateText(row.Raw)
		if row.Error {
			var ae *apierr.Error
			if err == nil || !asAPI(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "text" {
				t.Errorf("raw %q: err = %v, want VALIDATION on text", row.Raw, err)
			}
			continue
		}
		if err != nil || row.Stored == nil || got != *row.Stored {
			t.Errorf("raw %q: stored %q, %v; want %v", row.Raw, got, err, row.Stored)
		}
	}
	for _, row := range f.Grammar {
		if got, err := validateText(row.Text); err != nil || got != row.Text {
			t.Errorf("grammar row %q: stored %q, %v; want it unchanged", row.Text, got, err)
		}
	}
}

func asAPI(err error, target **apierr.Error) bool {
	ae, ok := err.(*apierr.Error) //nolint:errorlint // validateSend returns the concrete type from the parser
	if ok {
		*target = ae
	}
	return ok
}

// FuzzSendText: arbitrary bytes never panic, a rejection is always VALIDATION on `text` and reads nothing, and an
// accepted text satisfies the stored-text invariants (valid UTF-8, NFC, at most 280 code points and 10 lines) and is a
// fixed point of the normalisation (what is stored is what the next send of it would store).
func FuzzSendText(f *testing.F) {
	for _, row := range loadSharedFixture(f).Normalise {
		f.Add(row.Raw)
	}
	for _, s := range []string{"hi", "", "  \t ", "a\x00b", strings.Repeat("a", 281), strings.Repeat("a\n", 12), "e\u0301", "\u202ertl", "\xff\xfe"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		r := newRig(t, nil)
		_, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, s))
		if err != nil {
			var ae *apierr.Error
			if !asAPI(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "text" {
				t.Fatalf("text %q: err = %v, want VALIDATION on text", s, err)
			}
			if r.repo.gets+len(r.repo.sends)+r.social.calls+r.profs.calls != 0 {
				t.Fatalf("text %q: a rejected text read or wrote", s)
			}
			return
		}
		stored := r.repo.sends[0].Text
		if !utf8.ValidString(stored) || !norm.NFC.IsNormalString(stored) || utf8.RuneCountInString(stored) > 280 || strings.Count(stored, "\n") > 9 || stored == "" {
			t.Fatalf("text %q stored as %q breaks the stored-text invariants", s, stored)
		}
		again, err := validateText(stored)
		if err != nil || again != stored {
			t.Fatalf("text %q: stored %q is not a fixed point (%q, %v)", s, stored, again, err)
		}
	})
}
