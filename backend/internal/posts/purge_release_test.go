package posts

import (
	"fmt"
	"slices"
	"testing"
)

func TestReleaseDeltas(t *testing.T) {
	tests := []struct {
		name string
		rows []ownRow
		skip map[string]bool
		want []counterDelta
	}{
		{name: "no targets", rows: []ownRow{{}, {}}, want: []counterDelta{}},
		{name: "replies to one parent sum", rows: []ownRow{{replyTo: "p1"}, {replyTo: "p1"}, {replyTo: "p1"}},
			want: []counterDelta{{postID: "p1", field: fieldReplyCount, delta: -3}}},
		{name: "quotes and replies split per field and sorted",
			rows: []ownRow{{quoteOf: "p2"}, {replyTo: "p2"}, {replyTo: "p1"}, {quoteOf: "p2"}},
			want: []counterDelta{
				{postID: "p1", field: fieldReplyCount, delta: -1},
				{postID: "p2", field: fieldQuoteCount, delta: -2},
				{postID: "p2", field: fieldReplyCount, delta: -1},
			}},
		{name: "a target deleted in the same page is skipped (self-thread)",
			rows: []ownRow{{replyTo: "own"}, {quoteOf: "own"}, {replyTo: "other"}},
			skip: map[string]bool{"own": true},
			want: []counterDelta{{postID: "other", field: fieldReplyCount, delta: -1}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := releaseDeltas(tt.rows, tt.skip)
			if !slices.Equal(got, tt.want) {
				t.Fatalf("releaseDeltas = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestPurgeOwnPageFitsOneBatch: a full page of replies or quotes, each to a distinct post, is one delete and one
// counter update per doc, and must fit Firestore's 500-write batch.
func TestPurgeOwnPageFitsOneBatch(t *testing.T) {
	rows := make([]ownRow, purgeOwnPage)
	for i := range rows {
		if i%2 == 0 {
			rows[i].replyTo = fmt.Sprintf("%019d", i)
		} else {
			rows[i].quoteOf = fmt.Sprintf("%019d", i)
		}
	}
	if w := pageWrites(len(rows), releaseDeltas(rows, nil)); w > maxBatchWrites {
		t.Fatalf("a full page takes %d writes, over the %d batch limit", w, maxBatchWrites)
	}
	if purgeOwnPage*2 > maxBatchWrites || purgeOwnPage < 1 {
		t.Fatalf("purgeOwnPage = %d does not fit a delete plus one counter per doc", purgeOwnPage)
	}
	// Malformed rows carrying both fields could exceed the bound; purgeOwn then skips the page batch.
	for i := range rows {
		rows[i].replyTo, rows[i].quoteOf = fmt.Sprintf("%019d", i), fmt.Sprintf("%019d", i+1000)
	}
	if w := pageWrites(len(rows), releaseDeltas(rows, nil)); w <= maxBatchWrites {
		t.Fatalf("both-field rows take %d writes; the per-doc guard is never exercised", w)
	}
}
