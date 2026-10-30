package moderation

import (
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// A POST report keeps the labels of the reported post's poll as evidence (ADR-0029 D8), so the review shows them; a REPOST
// report keeps the original's labels from its frozen embed; a post without a poll keeps none. Labels only, no counts.
func TestReport_EvidenceCarriesPollChoices(t *testing.T) {
	t.Parallel()
	closes := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	tests := []struct {
		name string
		post *posts.Post
		want []string
	}{
		{"poll post", &posts.Post{ID: okPostID, AuthorID: author, Kind: posts.KindPost, Text: "Which?",
			Author: posts.AuthorSnapshot{Handle: "bob"}, Poll: &posts.Poll{Options: []string{"Yes", "No"}, ClosesAt: closes, Counts: []int64{3, 4}, Total: 7}}, []string{"Yes", "No"}},
		{"plain post", &posts.Post{ID: okPostID, AuthorID: author, Kind: posts.KindPost, Text: "hi", Author: posts.AuthorSnapshot{Handle: "bob"}}, nil},
		{"repost of a poll", &posts.Post{ID: okPostID, AuthorID: author, Kind: posts.KindRepost, Author: posts.AuthorSnapshot{Handle: "bob"},
			Embedded: &posts.Embedded{PostID: "1111111111111111111", Author: posts.AuthorSnapshot{Handle: "carol"}, Text: "Which?",
				Poll: &posts.EmbeddedPoll{Options: []string{"A", "B"}, ClosesAt: closes}}}, []string{"A", "B"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.posts.post = tt.post
			if _, err := f.svc().Report(gctx(), reporter, okInput()); err != nil {
				t.Fatal(err)
			}
			got := f.repo.calls[0].Report.Evidence
			if got == nil || !reflect.DeepEqual(got.PollChoices, tt.want) {
				t.Fatalf("PollChoices = %v, want %v", got, tt.want)
			}
		})
	}
}
