package engagement

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// plansStub is the beacons seam: Previews answers only the plans the given viewer may see (as beacons.Service.Previews
// does for a hidden plan, a blocked organiser or a community plan the viewer is not in), and records every batch.
type plansStub struct {
	visible map[string]map[string]posts.BeaconLive // viewer -> beacon id -> live state
	calls   [][]string
}

func (p *plansStub) EmbedTarget(context.Context, string, string) (posts.BeaconLive, error) {
	return posts.BeaconLive{}, errors.New("not used by the owner lists")
}

func (p *plansStub) Previews(_ context.Context, viewer string, ids []string) (map[string]posts.BeaconLive, error) {
	p.calls = append(p.calls, append([]string(nil), ids...))
	return p.visible[viewer], nil
}

const (
	planOpen   = "0000000000000000555" // public, visible to the caller
	planHidden = "0000000000000000556" // hidden, or a community plan the caller is not in: Previews leaves it out
)

func beaconPost(id, beacon string) *posts.Post {
	return &posts.Post{ID: id, AuthorID: "organiser", Kind: posts.KindPost, Visibility: posts.VisibilityPublic, BeaconID: beacon, CreatedAt: time.Now()}
}

func newPlansStub() *plansStub {
	return &plansStub{visible: map[string]map[string]posts.BeaconLive{"caller": {planOpen: {
		BeaconID: planOpen, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Status: beaconsv1.BeaconStatus_BEACON_STATUS_OPEN,
	}}}}
}

// ownerListRegistry turns the two owner lists on; embed toggles FEATURE_POST_BEACON_EMBED (absent is globally off).
func ownerListRegistry(embed bool) *flags.Registry {
	specs := []flags.Spec{
		{Name: "posts", Mode: flags.On}, {Name: "bookmarks", Mode: flags.On}, {Name: LikesListFlagName, Mode: flags.On},
	}
	if embed {
		specs = append(specs, flags.Spec{Name: posts.PostBeaconFlagName, Mode: flags.On})
	}
	return flags.NewRegistry(specs...)
}

// ownerList runs one of the two lists over the same rows and returns the rendered posts.
type ownerList struct {
	name string
	run  func(t *testing.T, fc posts.FlagChecker, plans posts.BeaconPlans, rows []*posts.Post, withheld []bool) []*postsv1.PostView
}

func ownerLists() []ownerList {
	return []ownerList{
		{"ListBookmarks", func(t *testing.T, fc posts.FlagChecker, plans posts.BeaconPlans, rows []*posts.Post, withheld []bool) []*postsv1.PostView {
			t.Helper()
			page := BookmarkPage{}
			for i, p := range rows {
				page.Rows = append(page.Rows, BookmarkRow{Post: p, BookmarkedAt: time.Now(), Hint: RowHint{Withheld: withheld[i]}})
			}
			srv := NewServer(&stubSvc{}, fc, WithBookmarks(&stubBookmarks{page: page}))
			if plans != nil {
				srv.SetBeaconPlans(plans)
			}
			resp, err := srv.ListBookmarks(uidCtx("caller"), connect.NewRequest(&engagementv1.ListBookmarksRequest{}))
			if err != nil {
				t.Fatal(err)
			}
			out := make([]*postsv1.PostView, 0, len(resp.Msg.GetBookmarks()))
			for _, b := range resp.Msg.GetBookmarks() {
				out = append(out, b.GetPost())
			}
			return out
		}},
		{"ListLikedPosts", func(t *testing.T, fc posts.FlagChecker, plans posts.BeaconPlans, rows []*posts.Post, withheld []bool) []*postsv1.PostView {
			t.Helper()
			page := LikesPage{Posts: rows}
			for _, w := range withheld {
				page.Hints = append(page.Hints, RowHint{Withheld: w})
			}
			srv := NewServer(&stubSvc{}, fc, WithLikesList(&stubLikes{page: page}))
			if plans != nil {
				srv.SetBeaconPlans(plans)
			}
			resp, err := srv.ListLikedPosts(uidCtx("caller"), connect.NewRequest(&engagementv1.ListLikedPostsRequest{}))
			if err != nil {
				t.Fatal(err)
			}
			return resp.Msg.GetPosts()
		}},
	}
}

// TestOwnerLists_HydratePlanCards: ListBookmarks and ListLikedPosts decide every plan card for the caller exactly as the
// timeline does: one batched Previews read per page for the kept rows with a plan, none for a page without one, a plan
// the caller cannot see stays unavailable, a withheld row is neither read nor carded, and the kill switch strips the
// field with no read.
func TestOwnerLists_HydratePlanCards(t *testing.T) {
	for _, l := range ownerLists() {
		t.Run(l.name, func(t *testing.T) {
			t.Run("one batch: live for the caller, unavailable when hidden", func(t *testing.T) {
				plans := newPlansStub()
				rows := []*posts.Post{beaconPost(pid(9), planOpen), beaconPost(pid(8), planHidden), beaconPost(pid(7), planOpen), beaconPost(pid(6), "")}
				views := l.run(t, ownerListRegistry(true), plans, rows, make([]bool, len(rows)))
				if len(plans.calls) != 1 || len(plans.calls[0]) != 2 {
					t.Fatalf("Previews calls = %v, want one batch of the two distinct plans", plans.calls)
				}
				if b := views[0].GetPost().GetBeacon(); b.GetUnavailable() || b.GetTitle() != "Coffee" || b.GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN {
					t.Errorf("visible plan card = %v, want the live Coffee plan", b)
				}
				if b := views[1].GetPost().GetBeacon(); !b.GetUnavailable() || b.GetBeaconId() != planHidden || b.GetTitle() != "" {
					t.Errorf("hidden plan card = %v, want the bare unavailable form", b)
				}
				if views[3].GetPost().GetBeacon() != nil {
					t.Error("a post without a plan has no card")
				}
			})
			t.Run("a stranger gets the unavailable form", func(t *testing.T) {
				plans := newPlansStub()
				plans.visible = map[string]map[string]posts.BeaconLive{"someone-else": plans.visible["caller"]}
				views := l.run(t, ownerListRegistry(true), plans, []*posts.Post{beaconPost(pid(9), planOpen)}, []bool{false})
				if b := views[0].GetPost().GetBeacon(); !b.GetUnavailable() || b.GetTitle() != "" {
					t.Errorf("card = %v, want unavailable for a caller the plan is not shown to", b)
				}
			})
			t.Run("no plan on the page: no read", func(t *testing.T) {
				plans := newPlansStub()
				l.run(t, ownerListRegistry(true), plans, []*posts.Post{beaconPost(pid(9), ""), beaconPost(pid(8), "")}, []bool{false, false})
				if len(plans.calls) != 0 {
					t.Fatalf("Previews calls = %v, want none", plans.calls)
				}
			})
			t.Run("withheld rows are not read and carry no card", func(t *testing.T) {
				plans := newPlansStub()
				views := l.run(t, ownerListRegistry(true), plans, []*posts.Post{beaconPost(pid(9), planOpen)}, []bool{true})
				if len(plans.calls) != 0 {
					t.Fatalf("Previews calls = %v, want none for a withheld row", plans.calls)
				}
				if !views[0].GetWithheld() || views[0].GetPost().GetBeacon() != nil {
					t.Errorf("withheld row = %v, want the placeholder without a card", views[0])
				}
			})
			t.Run("kill switch: no card, no read", func(t *testing.T) {
				plans := newPlansStub()
				views := l.run(t, ownerListRegistry(false), plans, []*posts.Post{beaconPost(pid(9), planOpen)}, []bool{false})
				if len(plans.calls) != 0 || views[0].GetPost().GetBeacon() != nil {
					t.Fatalf("calls = %v, card = %v; want no read and no field", plans.calls, views[0].GetPost().GetBeacon())
				}
			})
			t.Run("unwired reader: unavailable", func(t *testing.T) {
				views := l.run(t, ownerListRegistry(true), nil, []*posts.Post{beaconPost(pid(9), planOpen)}, []bool{false})
				if b := views[0].GetPost().GetBeacon(); !b.GetUnavailable() {
					t.Errorf("card = %v, want unavailable without a plan reader", b)
				}
			})
		})
	}
}
