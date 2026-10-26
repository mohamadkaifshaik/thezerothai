package timeline

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// stubViewer counts Viewer calls: with FEATURE_ENGAGEMENT off for the caller it must never be reached.
type stubViewer struct{ calls int }

func (v *stubViewer) Viewer(_ context.Context, _ string) posts.ViewerSet {
	v.calls++
	return posts.ViewerSet{}
}

// offFor enables every flag except the named ones.
type offFor struct{ names []string }

func (o offFor) Enabled(_, flag string) bool { return !slices.Contains(o.names, flag) }

// flagOffRig is a rig whose server has FEATURE_ENGAGEMENT off for everyone but a non-nil Viewer wired in, so a
// regression that gates the privacy filter on the flag (or on a nil Viewer) is caught at the RPC.
func flagOffRig(t *testing.T) (*rig, *stubViewer) {
	t.Helper()
	r := newRig(t)
	v := &stubViewer{}
	r.srv = NewServer(Deps{
		Flags: offFor{[]string{posts.EngagementFlagName, posts.BookmarksFlagName}}, Viewer: v, Posts: r.posts, Graph: r.graph, Directory: r.dir,
		CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now,
	})
	return r, v
}

// makeCopy turns p into a kind copy of a post by embAuthor.
func makeCopy(p *posts.Post, kind posts.Kind) {
	p.Kind = kind
	p.Embedded = &posts.Embedded{PostID: "9", Author: posts.AuthorSnapshot{UserID: embAuthor, Handle: "emb"}, Text: "secret"}
	p.EmbeddedAuthorID = embAuthor
}

// D13 at the RPC with FEATURE_ENGAGEMENT off: a REPOST or QUOTE of a blocked, muted or blocking author is absent
// from the home and the profile timeline, while the control post and a clean copy are kept.
func TestTimelines_EmbedFilterAppliesWithFlagOff(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		snap graph.Snapshot
		kept bool // whether the copy of embAuthor survives
	}{
		{"embedded author blocked by viewer", graph.Snapshot{Blocked: following(embAuthor)}, false},
		{"embedded author muted by viewer", graph.Snapshot{Muted: following(embAuthor)}, false},
		{"embedded author blocks viewer", graph.Snapshot{BlockedBy: following(embAuthor)}, false},
		{"blockedBy overflow fails closed", graph.Snapshot{BlockedByOverflow: true}, false},
		{"unrelated graph keeps the copy", graph.Snapshot{}, true},
	}
	for _, kind := range []posts.Kind{posts.KindRepost, posts.KindQuote} {
		for _, tc := range tests {
			t.Run("home/"+string(kind)+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				r, v := flagOffRig(t)
				authors := r.follow("me", 1)
				snap := tc.snap
				snap.Following = following(authors...)
				r.graph.snaps["me"] = snap
				ctl := r.posts.add(authors[0], r.ms(-3*time.Second))
				cp := r.posts.add(authors[0], r.ms(-2*time.Second))
				makeCopy(cp, kind)
				resp := r.mustHome("", "", 20)
				assertCopy(t, homeIDs(resp), ctl.ID, cp.ID, tc.kept)
				if v.calls != 0 {
					t.Fatalf("Viewer called %d times with the flag off", v.calls)
				}
			})
			t.Run("user/"+string(kind)+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				r, v := flagOffRig(t)
				ps := r.seedUser("bob", 1)
				cp := r.posts.add("bob", r.ms(-2*time.Second))
				makeCopy(cp, kind)
				r.graph.snaps["me"] = tc.snap
				resp := r.mustUser("me", "bob", false, "", "", 20)
				assertCopy(t, userIDs(resp), ps[0].ID, cp.ID, tc.kept)
				if v.calls != 0 {
					t.Fatalf("Viewer called %d times with the flag off", v.calls)
				}
			})
		}
	}
}

func assertCopy(t *testing.T, got []string, control, copyID string, kept bool) {
	t.Helper()
	has := map[string]bool{}
	for _, id := range got {
		has[id] = true
	}
	if !has[control] {
		t.Fatalf("control post missing from %v", got)
	}
	if has[copyID] != kept {
		t.Fatalf("copy present = %v, want %v (got %v)", has[copyID], kept, got)
	}
}

// A caller's own copy of a blocked author's post stays on their own profile (D13), at 0 graph reads beyond the
// visibility check.
func TestUser_OwnProfileKeepsOwnCopyWithoutGraphRead(t *testing.T) {
	t.Parallel()
	r, _ := flagOffRig(t)
	r.dir.profiles["me"] = identity.Profile{UserID: "me", Status: identity.AccountStatusActive}
	cp := r.posts.add("me", r.ms(-2*time.Second))
	makeCopy(cp, posts.KindRepost)
	r.graph.snaps["me"] = graph.Snapshot{Blocked: following(embAuthor)}
	resp, counter, err := r.user("me", "me", false, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := userIDs(resp); len(got) != 1 || got[0] != cp.ID {
		t.Fatalf("own copy dropped: %v", got)
	}
	// users 1 (target) + posts query 1; the embed filter adds no graph read for the own tab.
	if counter.Reads() > 2 {
		t.Fatalf("reads = %d, want <= 2", counter.Reads())
	}
}
