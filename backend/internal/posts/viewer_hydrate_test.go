package posts

import (
	"context"
	"testing"
)

// countingViewer is a ViewerFlags that returns a fixed set and counts its (userLikes) reads.
type countingViewer struct {
	set   ViewerSet
	calls int
}

func (c *countingViewer) Viewer(context.Context, string) ViewerSet {
	c.calls++
	return c.set
}

type flagMap map[string]bool

func (f flagMap) Enabled(_, name string) bool { return f[name] }

// TestHydrateViewer (ADR-0023 D5): viewer state is hydrated, with one userLikes read, when FEATURE_ENGAGEMENT or
// FEATURE_BOOKMARKS is on for the viewer; with only bookmarks on, the like and repost flags never reach the response.
func TestHydrateViewer(t *testing.T) {
	post := &Post{ID: "1", Kind: KindPost}
	set := NewViewerSetWithBookmarks([]string{"1"}, []string{"1"}, []string{"1"})
	tests := []struct {
		name                                    string
		flags                                   FlagChecker
		viewer                                  bool
		wantCalls                               int
		wantLiked, wantReposted, wantBookmarked bool
	}{
		{"both off: no read, nothing", flagMap{}, true, 0, false, false, false},
		{"engagement on: liked, reposted and bookmarked", flagMap{EngagementFlagName: true}, true, 1, true, true, true},
		{"bookmarks only: bookmarked, never liked or reposted", flagMap{BookmarksFlagName: true}, true, 1, false, false, true},
		{"both on", flagMap{EngagementFlagName: true, BookmarksFlagName: true}, true, 1, true, true, true},
		{"no viewer wired: nothing", flagMap{EngagementFlagName: true, BookmarksFlagName: true}, false, 0, false, false, false},
		{"no flags wired: nothing", nil, true, 0, false, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cv := &countingViewer{set: set}
			var vf ViewerFlags
			if tt.viewer {
				vf = cv
			}
			vs := HydrateViewer(context.Background(), tt.flags, vf, "u")
			liked, reposted := vs.Flags(post)
			if cv.calls != tt.wantCalls || liked != tt.wantLiked || reposted != tt.wantReposted || vs.Bookmarked(post) != tt.wantBookmarked {
				t.Fatalf("calls %d liked %v reposted %v bookmarked %v, want %d %v %v %v",
					cv.calls, liked, reposted, vs.Bookmarked(post), tt.wantCalls, tt.wantLiked, tt.wantReposted, tt.wantBookmarked)
			}
		})
	}
}

// A REPOST item is keyed by its original for bookmarks as for likes, and NewViewerSet (no bookmarks) is unchanged.
func TestViewerSet_Bookmarked(t *testing.T) {
	vs := NewViewerSetWithBookmarks(nil, nil, []string{"9"})
	repost := &Post{ID: "2", Kind: KindRepost, Embedded: &Embedded{PostID: "9"}}
	if !vs.Bookmarked(repost) || vs.Bookmarked(&Post{ID: "2", Kind: KindPost}) || !vs.Bookmarked(&Post{ID: "9"}) {
		t.Fatal("bookmarked lookup wrong")
	}
	if NewViewerSet([]string{"9"}, nil).Bookmarked(&Post{ID: "9"}) {
		t.Fatal("NewViewerSet must carry no bookmarks")
	}
	if (ViewerSet{}).Bookmarked(&Post{ID: "9"}) {
		t.Fatal("the zero ViewerSet carries nothing")
	}
}
