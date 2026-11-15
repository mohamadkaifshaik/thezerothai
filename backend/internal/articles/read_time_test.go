package articles

import (
	"strings"
	"testing"
)

func TestReadMinutes(t *testing.T) {
	for _, tc := range []struct {
		name  string
		words int
		want  int32
	}{
		{"empty is one minute", 0, 1},
		{"negative guard", -5, 1},
		{"one word", 1, 1},
		{"exactly one minute", 230, 1},
		{"one word over rounds up", 231, 2},
		{"exactly two minutes", 460, 2},
		{"just past two", 461, 3},
		{"five minute read", 1150, 5},
		{"long text", 10000, 44},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := readMinutes(tc.words); got != tc.want {
				t.Fatalf("readMinutes(%d) = %d, want %d", tc.words, got, tc.want)
			}
		})
	}
}

func TestInspectContentCountsWords(t *testing.T) {
	long := strings.TrimSpace(strings.Repeat("word ", 1151))
	for _, tc := range []struct {
		name    string
		body    string
		words   int
		minutes int32
	}{
		{"runs inside a block join", `[{"kind":"paragraph","runs":[{"text":"Hel","marks":[]},{"text":"lo there","marks":["bold"]}]}]`, 2, 1},
		{"blocks split words, divider adds none", `[{"kind":"heading1","runs":[{"text":"Title","marks":[]}]},{"kind":"divider","runs":[]},{"kind":"paragraph","runs":[{"text":"two  words","marks":[]}]}]`, 3, 1},
		{"image only reads as one minute", `[{"kind":"image","runs":[],"mediaId":"abcdefghijklmnop0001","altText":"alt words are not counted","caption":"nor captions"}]`, 0, 1},
		{"long body rounds up", `[{"kind":"paragraph","runs":[{"text":"` + long + `","marks":[]}]}]`, 1151, 6},
	} {
		t.Run(tc.name, func(t *testing.T) {
			info, err := inspectContent("Title", tc.body, true)
			if err != nil {
				t.Fatal(err)
			}
			if info.Words != tc.words || readMinutes(info.Words) != tc.minutes {
				t.Fatalf("words = %d (minutes %d), want %d (%d)", info.Words, readMinutes(info.Words), tc.words, tc.minutes)
			}
		})
	}
}
