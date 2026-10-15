package timeline

import (
	"context"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const embViewer, embAuthor = "uid-viewer", "uid-emb"

func embCopy(kind posts.Kind, copier string, e *posts.Embedded, topLevel string) *posts.Post {
	return &posts.Post{ID: "1", AuthorID: copier, Kind: kind, Embedded: e, EmbeddedAuthorID: topLevel}
}

func TestEmbedAllowed(t *testing.T) {
	emb := &posts.Embedded{PostID: "9", Author: posts.AuthorSnapshot{UserID: embAuthor}}
	tests := []struct {
		name string
		snap graph.Snapshot
		post *posts.Post
		want bool
	}{
		{"plain post", graph.Snapshot{}, &posts.Post{AuthorID: "x", Kind: posts.KindPost}, true},
		{"clean repost", graph.Snapshot{}, embCopy(posts.KindRepost, "x", emb, embAuthor), true},
		{"blocked embedded author", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}}, embCopy(posts.KindRepost, "x", emb, embAuthor), false},
		{"muted embedded author", graph.Snapshot{Muted: map[string]bool{embAuthor: true}}, embCopy(posts.KindQuote, "x", emb, embAuthor), false},
		{"embedded author blocks viewer", graph.Snapshot{BlockedBy: map[string]bool{embAuthor: true}}, embCopy(posts.KindQuote, "x", emb, embAuthor), false},
		{"top-level id only", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}}, embCopy(posts.KindRepost, "x", &posts.Embedded{PostID: "9"}, embAuthor), false},
		{"snapshot author only", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}}, embCopy(posts.KindRepost, "x", emb, ""), false},
		{"own copy kept", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}}, embCopy(posts.KindRepost, embViewer, emb, embAuthor), true},
		{"embedded author is the viewer", graph.Snapshot{BlockedBy: map[string]bool{embViewer: true}},
			embCopy(posts.KindQuote, "x", &posts.Embedded{PostID: "9", Author: posts.AuthorSnapshot{UserID: embViewer}}, embViewer), true},
		{"tombstone kept", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}},
			embCopy(posts.KindRepost, "x", &posts.Embedded{PostID: "9", Unavailable: true}, ""), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := embedAllowed(tt.snap, embViewer, tt.post); got != tt.want {
				t.Fatalf("embedAllowed=%v want %v", got, tt.want)
			}
		})
	}
}

// The filter is a privacy rule: it must behave the same with FEATURE_ENGAGEMENT on and off for the viewer.
func TestFilterEmbeds_IndependentOfFlag(t *testing.T) {
	emb := &posts.Embedded{PostID: "9", Author: posts.AuthorSnapshot{UserID: embAuthor}}
	for _, flagOn := range []bool{true, false} {
		for _, tc := range []struct {
			name  string
			snap  graph.Snapshot
			keeps int
		}{
			{"blocked", graph.Snapshot{Blocked: map[string]bool{embAuthor: true}}, 3},
			{"muted", graph.Snapshot{Muted: map[string]bool{embAuthor: true}}, 3},
			{"blocked by", graph.Snapshot{BlockedBy: map[string]bool{embAuthor: true}}, 3},
			{"clear", graph.Snapshot{}, 4},
		} {
			t.Run(tc.name, func(t *testing.T) {
				g := &fakeGraph{snaps: map[string]graph.Snapshot{embViewer: tc.snap}}
				s := NewServer(Deps{Flags: fakeFlags{on: flagOn}, Graph: g})
				in := []*posts.Post{
					{ID: "1", AuthorID: "a", Kind: posts.KindPost},
					embCopy(posts.KindRepost, "a", emb, embAuthor),
					embCopy(posts.KindRepost, embViewer, emb, embAuthor), // own copy
					embCopy(posts.KindRepost, "a", &posts.Embedded{PostID: "9", Unavailable: true}, ""),
				}
				ctx, _ := budget.WithCounter(context.Background())
				got, err := s.filterEmbeds(ctx, embViewer, in)
				if err != nil {
					t.Fatal(err)
				}
				if len(got) != tc.keeps {
					t.Fatalf("flag=%v kept %d want %d", flagOn, len(got), tc.keeps)
				}
			})
		}
	}
	t.Run("no copies skips the graph read", func(t *testing.T) {
		g := &fakeGraph{}
		s := NewServer(Deps{Graph: g})
		if _, err := s.filterEmbeds(context.Background(), embViewer, []*posts.Post{{ID: "1", Kind: posts.KindPost}}); err != nil || len(g.calls) != 0 {
			t.Fatalf("err=%v calls=%v", err, g.calls)
		}
	})
}
