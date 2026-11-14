package search

import (
	"context"
	"errors"
	"sync"
	"testing"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// plansStub is the beacons seam: Previews answers only the plans the given viewer may see (as beacons.Service.Previews
// does for a hidden plan, a blocked organiser or a community plan the viewer is not in), and records every batch.
type plansStub struct {
	mu      sync.Mutex
	visible map[string]map[string]posts.BeaconLive // viewer -> beacon id -> live state
	calls   [][]string
}

func (p *plansStub) EmbedTarget(context.Context, string, string) (posts.BeaconLive, error) {
	return posts.BeaconLive{}, errors.New("not used by search")
}

func (p *plansStub) Previews(_ context.Context, viewer string, ids []string) (map[string]posts.BeaconLive, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls = append(p.calls, append([]string(nil), ids...))
	return p.visible[viewer], nil
}

const (
	planOpen   = "0000000000000000555" // public, visible to "u"
	planHidden = "0000000000000000556" // hidden, or a community plan "u" is not in: Previews leaves it out
)

func withPlans(p posts.BeaconPlans) rigOpt {
	return func(_ *rig, d *PostsDeps, _ flagMap) { d.Plans = p }
}

func newSearchPlans() *plansStub {
	return &plansStub{visible: map[string]map[string]posts.BeaconLive{"u": {planOpen: {
		BeaconID: planOpen, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Status: beaconsv1.BeaconStatus_BEACON_STATUS_OPEN,
	}}}}
}

func byPostID(resp []*postsv1.PostView) map[string]*postsv1.PostView {
	out := map[string]*postsv1.PostView{}
	for _, v := range resp {
		out[v.GetPost().GetPostId()] = v
	}
	return out
}

// TestPosts_HydratePlanCards: SearchPosts decides every plan card for the caller exactly as the timeline does: one batched
// Previews read per page, none for a page without a plan, a plan the caller cannot see stays unavailable, and the kill
// switch strips the field with no read.
func TestPosts_HydratePlanCards(t *testing.T) {
	t.Parallel()
	withBeacons := func(n int, p *posts.Post) {
		switch n {
		case 3, 1:
			p.BeaconID = planOpen
		case 2:
			p.BeaconID = planHidden
		}
	}
	t.Run("one batch: live for the caller, unavailable when hidden", func(t *testing.T) {
		t.Parallel()
		plans := newSearchPlans()
		r := newRig(map[string][]*posts.Post{"go": newestFirst(4, withBeacons)}, withPlans(plans))
		got := byPostID(doPosts(t, r, "u", "go", latest, 0, "").GetPosts())
		if len(plans.calls) != 1 || len(plans.calls[0]) != 2 {
			t.Fatalf("Previews calls = %v, want one batch of the two distinct plans", plans.calls)
		}
		if b := got[idOf(3)].GetPost().GetBeacon(); b.GetUnavailable() || b.GetTitle() != "Coffee" {
			t.Errorf("visible plan card = %v, want the live Coffee plan", b)
		}
		if b := got[idOf(2)].GetPost().GetBeacon(); !b.GetUnavailable() || b.GetBeaconId() != planHidden || b.GetTitle() != "" {
			t.Errorf("hidden plan card = %v, want the bare unavailable form", b)
		}
		if got[idOf(4)].GetPost().GetBeacon() != nil {
			t.Error("a post without a plan has no card")
		}
	})
	t.Run("a stranger gets the unavailable form", func(t *testing.T) {
		t.Parallel()
		plans := newSearchPlans()
		r := newRig(map[string][]*posts.Post{"go": newestFirst(4, withBeacons)}, withPlans(plans))
		got := byPostID(doPosts(t, r, "stranger", "go", latest, 0, "").GetPosts())
		if b := got[idOf(3)].GetPost().GetBeacon(); !b.GetUnavailable() || b.GetTitle() != "" {
			t.Errorf("card = %v, want unavailable for a caller the plan is not shown to", b)
		}
	})
	t.Run("no plan on the page: no read", func(t *testing.T) {
		t.Parallel()
		plans := newSearchPlans()
		r := newRig(map[string][]*posts.Post{"go": newestFirst(4)}, withPlans(plans))
		doPosts(t, r, "u", "go", latest, 0, "")
		if len(plans.calls) != 0 {
			t.Fatalf("Previews calls = %v, want none", plans.calls)
		}
	})
	t.Run("kill switch: no card, no read", func(t *testing.T) {
		t.Parallel()
		plans := newSearchPlans()
		r := newRig(map[string][]*posts.Post{"go": newestFirst(4, withBeacons)}, withPlans(plans), withGloballyOff(posts.PostBeaconFlagName))
		got := byPostID(doPosts(t, r, "u", "go", latest, 0, "").GetPosts())
		if len(plans.calls) != 0 || got[idOf(3)].GetPost().GetBeacon() != nil {
			t.Fatalf("calls = %v, card = %v; want no read and no field", plans.calls, got[idOf(3)].GetPost().GetBeacon())
		}
	})
	t.Run("unwired reader: unavailable", func(t *testing.T) {
		t.Parallel()
		r := newRig(map[string][]*posts.Post{"go": newestFirst(4, withBeacons)})
		if b := byPostID(doPosts(t, r, "u", "go", latest, 0, "").GetPosts())[idOf(3)].GetPost().GetBeacon(); !b.GetUnavailable() {
			t.Errorf("card = %v, want unavailable without a plan reader", b)
		}
	})
}
