package posts

import (
	"reflect"
	"testing"
)

// TestBackfillDocOf pins how a projected posts document is read: presence of hasMedia is by key AND bool type, so an
// explicit false is "has the field" and a null or absent key is "missing".
func TestBackfillDocOf(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		data map[string]any
		want backfillDoc
	}{
		{"legacy image post", map[string]any{"kind": "POST", "media": []any{map[string]any{"mediaId": "m1"}}}, backfillDoc{id: "1", kind: KindPost, media: 1}},
		{"legacy text post", map[string]any{"kind": "POST"}, backfillDoc{id: "1", kind: KindPost}},
		{"legacy repost", map[string]any{"kind": "REPOST"}, backfillDoc{id: "1", kind: KindRepost}},
		{"explicit true", map[string]any{"kind": "POST", "media": []any{1, 2}, "hasMedia": true}, backfillDoc{id: "1", kind: KindPost, media: 2, hasField: true}},
		{"explicit false", map[string]any{"kind": "POST", "hasMedia": false}, backfillDoc{id: "1", kind: KindPost, hasField: true}},
		{"null counts as missing", map[string]any{"kind": "POST", "hasMedia": nil}, backfillDoc{id: "1", kind: KindPost}},
		{"non-bool counts as missing", map[string]any{"kind": "POST", "hasMedia": "true"}, backfillDoc{id: "1", kind: KindPost}},
		{"no kind", map[string]any{}, backfillDoc{id: "1"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := backfillDocOf("1", tt.data); got != tt.want {
				t.Fatalf("backfillDocOf = %+v, want %+v", got, tt.want)
			}
		})
	}
}

// TestPlanBackfillPage covers the decision logic: which docs are written with which value, and where the checkpoint
// lands when the write cap ends a page early (the last doc decided, so a resume never skips one).
func TestPlanBackfillPage(t *testing.T) {
	t.Parallel()
	img := func(id string) backfillDoc { return backfillDoc{id: id, kind: KindPost, media: 1} }
	txt := func(id string) backfillDoc { return backfillDoc{id: id, kind: KindPost} }
	repost := func(id string) backfillDoc { return backfillDoc{id: id, kind: KindRepost} }
	has := func(id string, media int) backfillDoc {
		return backfillDoc{id: id, kind: KindPost, media: media, hasField: true}
	}
	tests := []struct {
		name        string
		docs        []backfillDoc
		room        int
		wantWrites  []backfillWrite
		wantDecided int
		wantCapped  bool
	}{
		{name: "empty page", room: 10, wantDecided: 0},
		{
			name: "missing gets the one definition: image true, text false, repost false",
			docs: []backfillDoc{img("1"), txt("2"), repost("3")}, room: 10,
			wantWrites:  []backfillWrite{{"1", true}, {"2", false}, {"3", false}},
			wantDecided: 3,
		},
		{
			name: "explicit true and false are never rewritten, even when they disagree with the media",
			docs: []backfillDoc{has("1", 0), has("2", 3), img("3")}, room: 10,
			wantWrites:  []backfillWrite{{"3", true}},
			wantDecided: 3,
		},
		{
			name: "a repost that stores media of its own is still false",
			docs: []backfillDoc{{id: "1", kind: KindRepost, media: 2}}, room: 10,
			wantWrites: []backfillWrite{{"1", false}}, wantDecided: 1,
		},
		{
			name: "a quote with its own image is true",
			docs: []backfillDoc{{id: "1", kind: KindQuote, media: 1}}, room: 10,
			wantWrites: []backfillWrite{{"1", true}}, wantDecided: 1,
		},
		{
			name: "cap lands mid-page: stop before the third missing doc, checkpoint after the doc before it",
			docs: []backfillDoc{img("1"), has("2", 0), txt("3"), has("4", 0), img("5"), img("6")}, room: 2,
			wantWrites: []backfillWrite{{"1", true}, {"3", false}}, wantDecided: 4, wantCapped: true,
		},
		{
			name: "cap met exactly with only complete docs left: nothing to decide, not capped by this page",
			docs: []backfillDoc{img("1"), has("2", 0), has("3", 1)}, room: 1,
			wantWrites: []backfillWrite{{"1", true}}, wantDecided: 3,
		},
		{
			name: "no room at all: the first missing doc ends the page",
			docs: []backfillDoc{has("1", 0), img("2")}, room: 0,
			wantWrites: nil, wantDecided: 1, wantCapped: true,
		},
		{
			name: "dry run (room -1) has no cap",
			docs: []backfillDoc{img("1"), txt("2"), img("3")}, room: -1,
			wantWrites:  []backfillWrite{{"1", true}, {"2", false}, {"3", true}},
			wantDecided: 3,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			writes, decided, capped := planBackfillPage(tt.docs, tt.room)
			if !reflect.DeepEqual(writes, tt.wantWrites) {
				t.Errorf("writes = %v, want %v", writes, tt.wantWrites)
			}
			if decided != tt.wantDecided || capped != tt.wantCapped {
				t.Errorf("decided=%d capped=%v, want decided=%d capped=%v", decided, capped, tt.wantDecided, tt.wantCapped)
			}
		})
	}
}

// TestPlanBackfillPage_ResumeNeverSkips drives the planner page by page the way BackfillHasMedia does and checks that,
// whatever the page size and cap, every missing doc is written exactly once and nothing is skipped across the resumes.
func TestPlanBackfillPage_ResumeNeverSkips(t *testing.T) {
	t.Parallel()
	const n = 23
	docs := make([]backfillDoc, n)
	for i := range docs {
		docs[i] = backfillDoc{id: string(rune('a' + i)), kind: KindPost, media: i % 2, hasField: i%5 == 0}
	}
	wantMissing := 0
	for _, d := range docs {
		if !d.hasField {
			wantMissing++
		}
	}
	for _, page := range []int{1, 2, 3, 7, 23} {
		for _, maxWrites := range []int{1, 2, 5, 100} {
			written := map[string]int{}
			after, runs := 0, 0 // after = index of the first doc not yet decided
			for after < n && runs < 1000 {
				runs++
				// One capped run: pages until the cap, as the opsctl loop does; the next run resumes after the checkpoint.
				updated := 0
				for after < n {
					end := min(after+page, n)
					writes, decided, capped := planBackfillPage(docs[after:end], maxWrites-updated)
					for _, w := range writes {
						written[w.id]++
					}
					updated += len(writes)
					after += decided
					if capped || updated >= maxWrites {
						break
					}
				}
			}
			if len(written) != wantMissing {
				t.Errorf("page=%d cap=%d: wrote %d docs, want %d", page, maxWrites, len(written), wantMissing)
			}
			for id, c := range written {
				if c != 1 {
					t.Errorf("page=%d cap=%d: %s written %d times", page, maxWrites, id, c)
				}
			}
		}
	}
}

func TestNormaliseBackfill(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		in           BackfillOptions
		wantPage     int
		wantMaxWrite int
	}{
		{"zero value is production", BackfillOptions{}, opsPage, BackfillMaxWrites},
		{"negative falls back", BackfillOptions{PageSize: -1, MaxWrites: -1}, opsPage, BackfillMaxWrites},
		{"page above 500 is clamped", BackfillOptions{PageSize: 5000}, opsPage, BackfillMaxWrites},
		{"cap above 5,000 is clamped", BackfillOptions{MaxWrites: 50_000}, opsPage, BackfillMaxWrites},
		{"smaller values are honoured", BackfillOptions{PageSize: 3, MaxWrites: 7}, 3, 7},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			page, maxWrites := normaliseBackfill(tt.in)
			if page != tt.wantPage || maxWrites != tt.wantMaxWrite {
				t.Fatalf("normaliseBackfill = (%d, %d), want (%d, %d)", page, maxWrites, tt.wantPage, tt.wantMaxWrite)
			}
		})
	}
	if BackfillMaxWrites != 5000 {
		t.Fatalf("BackfillMaxWrites = %d, want 5,000 (ADR-0024 D4)", BackfillMaxWrites)
	}
}

func TestBackfillState_String(t *testing.T) {
	t.Parallel()
	for s, want := range map[BackfillState]string{BackfillMore: "more", BackfillDone: "done", BackfillCapped: "capped"} {
		if got := s.String(); got != want {
			t.Errorf("%d.String() = %q, want %q", s, got, want)
		}
	}
}
