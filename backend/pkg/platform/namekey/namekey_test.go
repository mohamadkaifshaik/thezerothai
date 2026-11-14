package namekey

import (
	"encoding/json"
	"errors"
	"os"
	"sort"
	"testing"
)

type fixture struct {
	Fold []struct {
		Name, In, Out string
	} `json:"fold"`
	Query []struct {
		Name, In, Out, Err string
	} `json:"query"`
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	raw, err := os.ReadFile("testdata/fold.json")
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Fold) == 0 || len(f.Query) == 0 {
		t.Fatal("empty fixture")
	}
	return f
}

func TestFold_Fixture(t *testing.T) {
	for _, tc := range loadFixture(t).Fold {
		t.Run(tc.Name, func(t *testing.T) {
			if got := Fold(tc.In); got != tc.Out {
				t.Fatalf("Fold(%q) = %q, want %q", tc.In, got, tc.Out)
			}
			if again := Fold(Fold(tc.In)); again != tc.Out {
				t.Fatalf("Fold is not idempotent on %q: %q", tc.In, again)
			}
		})
	}
}

func TestFold_InvalidUTF8IsTotal(t *testing.T) {
	if got := Fold("A\xffB"); got != "a\ufffdb" {
		t.Fatalf("Fold = %q", got)
	}
}

func TestQuery_Fixture(t *testing.T) {
	errs := map[string]error{"empty": ErrEmpty, "too_long": ErrTooLong, "bad_chars": ErrBadChars}
	for _, tc := range loadFixture(t).Query {
		t.Run(tc.Name, func(t *testing.T) {
			got, err := Query(tc.In)
			if tc.Err != "" {
				want, ok := errs[tc.Err]
				if !ok {
					t.Fatalf("unknown fixture error %q", tc.Err)
				}
				if !errors.Is(err, want) {
					t.Fatalf("Query(%q) err = %v, want %v", tc.In, err, want)
				}
				return
			}
			if err != nil || got != tc.Out {
				t.Fatalf("Query(%q) = %q, %v; want %q", tc.In, got, err, tc.Out)
			}
		})
	}
}

func TestQuery_InvalidUTF8(t *testing.T) {
	if _, err := Query("a\xff"); !errors.Is(err, ErrBadUTF8) {
		t.Fatalf("err = %v", err)
	}
}

// TestBounds_ByteOrder proves the range is the prefix set under Firestore's byte order, astral-plane names included, and
// that the "\uf8ff" sentinel would have missed the emoji row.
func TestBounds_ByteOrder(t *testing.T) {
	keys := []string{"ab", "ab club", "ab\U0001F600", "ab\uffff", "abc", "aa", "ac", "b", "a", ""}
	sort.Strings(keys) // Go compares strings by bytes, as Firestore does
	tests := []struct {
		prefix string
		want   []string
	}{
		{"ab", []string{"ab", "ab club", "abc", "ab\uffff", "ab\U0001F600"}},
		{"a", []string{"a", "aa", "ab", "ab club", "abc", "ab\uffff", "ab\U0001F600", "ac"}},
		{"zz", nil},
	}
	for _, tc := range tests {
		t.Run(tc.prefix, func(t *testing.T) {
			var got []string
			for _, k := range keys {
				if HasPrefix(k, tc.prefix) {
					got = append(got, k)
				}
			}
			want := append([]string(nil), tc.want...)
			sort.Strings(want)
			if len(got) != len(want) {
				t.Fatalf("got %q, want %q", got, want)
			}
			for i := range got {
				if got[i] != want[i] {
					t.Fatalf("got %q, want %q", got, want)
				}
			}
		})
	}
	if k := "ab\U0001F600"; k < "ab\uf8ff" {
		t.Fatal("the emoji row unexpectedly sorts below the \\uf8ff sentinel; the regression this guards is gone")
	}
	lo, hi := Bounds("x")
	if lo != "x" || hi != "x\U0010FFFF" {
		t.Fatalf("Bounds = %q, %q", lo, hi)
	}
}

func TestBackfillPage_AddAndStale(t *testing.T) {
	var total BackfillPage
	total.Add(BackfillPage{Scanned: 3, Stale: 2, Written: 1, Skipped: 1, Last: "a"})
	total.Add(BackfillPage{Scanned: 1, Last: "b", Done: true})
	if total != (BackfillPage{Scanned: 4, Stale: 2, Written: 1, Skipped: 1, Last: "b", Done: true}) {
		t.Fatalf("total = %+v", total)
	}
	if !Stale("", "Go") || Stale("go", "Go") || !Stale("go", "Gopher") {
		t.Fatal("Stale is wrong")
	}
}
