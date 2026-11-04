package posts

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// GetThread and a reply a community moderator hid: the drop is for every viewer but the reply's author,
// costs no read, never touches the root slot and never changes who may reply.
func TestGetThread_CommunityHiddenReply(t *testing.T) {
	tests := []struct {
		name        string
		hide        []string // posts that carry communityHidden
		focal       string
		wantReplies []string
		wantParent  string // "" = the parent slot is empty and ParentUnavailable
		wantNoCtx   bool   // a root-level focal has no parent slot at all
	}{
		{"viewer is not the author: dropped, the replies under it stay", []string{rReply1}, rRoot, []string{rReply4, rReply5, rReply6}, "", true},
		{"the author sees their own hidden reply", []string{rReply4}, rRoot, []string{rReply1, rReply4, rReply5, rReply6}, "", true},
		{"nothing hidden", nil, rRoot, []string{rReply1, rReply4, rReply5, rReply6}, "", true},
		{"hidden parent is an unavailable parent", []string{rReply1}, rReply6, []string{rReply4, rReply5}, "", false},
		{"the author's own hidden parent stays", []string{rReply4}, rReply5, []string{rReply1, rReply6}, rReply4, false},
		{"a hidden focal reply is still served", []string{rReply1}, rReply1, []string{rReply4, rReply5, rReply6}, rRoot, false},
		{"a hidden root keeps its thread and its slot", []string{rRoot}, rReply1, []string{rReply4, rReply5, rReply6}, rRoot, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newThreadEnv()
			for _, id := range tc.hide {
				e.repo.docs[id].CommunityHidden = true
			}
			th, _, err := e.thread(ThreadInput{PostID: tc.focal})
			if err != nil {
				t.Fatal(err)
			}
			got := idsOf(th.Replies)
			// the muted and blocked authors' replies are never in the want lists, so compare as sets
			slices.Sort(got)
			want := slices.Clone(tc.wantReplies)
			slices.Sort(want)
			if tc.focal != rRoot {
				want = slices.DeleteFunc(want, func(id string) bool { return id == tc.focal })
			}
			if !slices.Equal(got, want) {
				t.Errorf("replies = %v, want %v", got, want)
			}
			if !tc.wantNoCtx {
				if tc.wantParent == "" {
					if th.Parent != nil || !th.ParentUnavailable {
						t.Errorf("parent = %+v unavailable=%v, want an unavailable parent", th.Parent, th.ParentUnavailable)
					}
				} else if th.Parent == nil || th.Parent.ID != tc.wantParent || th.ParentUnavailable {
					t.Errorf("parent = %+v unavailable=%v, want %s", th.Parent, th.ParentUnavailable, tc.wantParent)
				}
			}
			if th.Focal.ID != tc.focal && tc.focal != rReply1 {
				t.Errorf("focal = %s", th.Focal.ID)
			}
		})
	}
	// +0 reads: the same thread with and without a hidden reply costs the same
	for _, focal := range []string{rRoot, rReply6} {
		plain, hidden := newThreadEnv(), newThreadEnv()
		hidden.repo.docs[rReply1].CommunityHidden = true
		_, c0, err0 := plain.thread(ThreadInput{PostID: focal})
		_, c1, err1 := hidden.thread(ThreadInput{PostID: focal})
		if err0 != nil || err1 != nil {
			t.Errorf("focal %s: reads %d vs %d, writes %d/%d, errs %v %v, want equal reads and 0 writes", focal, c0.Reads(), c1.Reads(), c0.Writes(), c1.Writes(), err0, err1)
		}
	}
}

// The drop is counted under its own cause on the request line, counts only, and the page token still follows the query.
func TestGetThread_CommunityHiddenReply_LogsCause(t *testing.T) {
	e := newThreadEnv()
	e.repo.docs[rReply1].CommunityHidden = true
	e.repo.docs[rReply6].CommunityHidden = true
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), testUID))
	ctx, _ = budget.WithCounter(ctx)
	if _, err := e.svc.GetThread(ctx, testUID, ThreadInput{PostID: rRoot}); err != nil {
		t.Fatal(err)
	}
	if v, _ := info.Get("audience_dropped_community_hidden"); fmt.Sprint(v) != "2" {
		t.Errorf("audience_dropped_community_hidden = %v, want 2", v)
	}
	if v, _ := info.Get("audience_dropped_hidden"); fmt.Sprint(v) != "0" {
		t.Errorf("audience_dropped_hidden = %v, want 0", v)
	}
}

// Replying to a hidden reply stays allowed (R4): the flag does not reach contextUsable, which reply enforcement shares.
func TestCommunityHiddenFor_Table(t *testing.T) {
	tests := []struct {
		name string
		p    *Post
		want bool
	}{
		{"nil", nil, false},
		{"hidden reply by another", &Post{IsReply: true, CommunityHidden: true, AuthorID: "x"}, true},
		{"hidden reply by the viewer", &Post{IsReply: true, CommunityHidden: true, AuthorID: "v"}, false},
		{"hidden root", &Post{CommunityHidden: true, AuthorID: "x"}, false},
		{"visible reply", &Post{IsReply: true, AuthorID: "x"}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := communityHiddenFor(tc.p, "v"); got != tc.want {
				t.Errorf("got %v", got)
			}
		})
	}
	if !contextUsable(&Post{ID: rReply1, AuthorID: uCarol, Visibility: "PUBLIC", IsReply: true, CommunityHidden: true}, true, testUID, newThreadEnv().graph.snap) {
		t.Error("a community-hidden reply must stay a usable reply parent (replying to it stays allowed)")
	}
}
