package posts

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
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

// TestToView_BookmarkedByViewer (ADR-0023 D3): ToView puts ViewerSet.Bookmarked on the wire as bookmarked_by_viewer,
// keyed like liked_by_viewer (a REPOST row describes its original), independently of the like and repost flags.
func TestToView_BookmarkedByViewer(t *testing.T) {
	t.Parallel()
	repost := &Post{ID: "2", Kind: KindRepost, Embedded: &Embedded{PostID: "9"}}
	tests := []struct {
		name                                    string
		vs                                      ViewerSet
		p                                       *Post
		wantBookmarked, wantLiked, wantReposted bool
	}{
		{"zero set: false", ViewerSet{}, &Post{ID: "9"}, false, false, false},
		{"bookmarked post: true, not liked", NewViewerSetWithBookmarks(nil, nil, []string{"9"}), &Post{ID: "9"}, true, false, false},
		{"another post: false", NewViewerSetWithBookmarks(nil, nil, []string{"9"}), &Post{ID: "8"}, false, false, false},
		{"REPOST row follows its original", NewViewerSetWithBookmarks(nil, nil, []string{"9"}), repost, true, false, false},
		{"the repost's own id does not count", NewViewerSetWithBookmarks(nil, nil, []string{"2"}), repost, false, false, false},
		{"liked and reposted, not bookmarked", NewViewerSet([]string{"9"}, []string{"9"}), &Post{ID: "9"}, false, true, true},
		{"all three", NewViewerSetWithBookmarks([]string{"9"}, []string{"9"}, []string{"9"}), &Post{ID: "9"}, true, true, true},
		{"bookmarks only: liked and reposted stripped", NewViewerSetWithBookmarks([]string{"9"}, []string{"9"}, []string{"9"}).BookmarksOnly(), &Post{ID: "9"}, true, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			v := ToView(tt.p, tt.vs, "viewer")
			if v.GetBookmarkedByViewer() != tt.wantBookmarked || v.GetLikedByViewer() != tt.wantLiked || v.GetRepostedByViewer() != tt.wantReposted {
				t.Fatalf("bookmarked/liked/reposted = %v/%v/%v, want %v/%v/%v",
					v.GetBookmarkedByViewer(), v.GetLikedByViewer(), v.GetRepostedByViewer(), tt.wantBookmarked, tt.wantLiked, tt.wantReposted)
			}
		})
	}
}

// GetPost end to end through the handler, one case per flag mode (off / bookmarks only / engagement only / both):
// bookmarked_by_viewer is set for the bookmarked post only, the like and repost flags never leak with only bookmarks
// on, and with both flags off Firestore's userLikes seam is never called (0 reads).
func TestServer_GetPost_BookmarkedByViewer(t *testing.T) {
	t.Parallel()
	set := NewViewerSetWithBookmarks([]string{pidOther}, []string{pidOther}, []string{pidOther})
	tests := []struct {
		name                      string
		flags                     flagMap
		wantCalls                 int
		wantBookmarked, wantLiked bool
		wantReposted              bool
	}{
		{"both off", flagMap{FlagName: true}, 0, false, false, false},
		{"bookmarks only", flagMap{FlagName: true, BookmarksFlagName: true}, 1, true, false, false},
		{"engagement only", flagMap{FlagName: true, EngagementFlagName: true}, 1, true, true, true},
		{"both on", flagMap{FlagName: true, EngagementFlagName: true, BookmarksFlagName: true}, 1, true, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newDeleteEnv()
			cv := &countingViewer{set: set}
			srv := NewServer(e.svc, tt.flags, WithViewerFlags(cv))
			got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
			if err != nil {
				t.Fatal(err)
			}
			v := got.Msg.GetPost()
			if v.GetBookmarkedByViewer() != tt.wantBookmarked || v.GetLikedByViewer() != tt.wantLiked || v.GetRepostedByViewer() != tt.wantReposted {
				t.Fatalf("bookmarked/liked/reposted = %v/%v/%v, want %v/%v/%v",
					v.GetBookmarkedByViewer(), v.GetLikedByViewer(), v.GetRepostedByViewer(), tt.wantBookmarked, tt.wantLiked, tt.wantReposted)
			}
			if cv.calls != tt.wantCalls {
				t.Fatalf("userLikes seam called %d times, want %d", cv.calls, tt.wantCalls)
			}
			// Another post of the same author is not in the set: false in every mode.
			other, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidMine}))
			if err != nil {
				t.Fatal(err)
			}
			if other.Msg.GetPost().GetBookmarkedByViewer() {
				t.Fatalf("bookmarked_by_viewer on a post outside the set = true")
			}
		})
	}
}
