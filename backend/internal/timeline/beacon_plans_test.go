package timeline

import (
	"context"
	"errors"
	"testing"
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

type plansStub struct {
	live  map[string]posts.BeaconLive
	err   error
	calls [][]string
}

func (p *plansStub) EmbedTarget(context.Context, string, string) (posts.BeaconLive, error) {
	return posts.BeaconLive{}, errors.New("not used by the timeline")
}

func (p *plansStub) Previews(_ context.Context, _ string, ids []string) (map[string]posts.BeaconLive, error) {
	p.calls = append(p.calls, append([]string(nil), ids...))
	return p.live, p.err
}

type planFlags struct{ off bool }

func (planFlags) Enabled(string, string) bool    { return true }
func (f planFlags) GloballyOff(name string) bool { return f.off && name == posts.PostBeaconFlagName }

// TestToViews_HydratesPlanCards: every feed page renders Post.beacon from one batch Previews call for the whole page; a
// plan the viewer cannot see, a missing reader and the kill switch each fail closed.
func TestToViews_HydratesPlanCards(t *testing.T) {
	const id1, id2 = "0000000000000000555", "0000000000000000556"
	mk := func(pid, beacon string) *posts.Post {
		return &posts.Post{ID: pid, Kind: posts.KindPost, AuthorID: "a", BeaconID: beacon, CreatedAt: time.Now()}
	}
	page := []*posts.Post{mk("0000000000000000101", id1), mk("0000000000000000102", id1), mk("0000000000000000103", id2), mk("0000000000000000104", "")}
	live := map[string]posts.BeaconLive{id1: {BeaconID: id1, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Status: beaconsv1.BeaconStatus_BEACON_STATUS_OPEN}}

	t.Run("one batch, live and unavailable", func(t *testing.T) {
		plans := &plansStub{live: live}
		s := NewServer(Deps{Flags: planFlags{}})
		s.SetBeaconPlans(plans)
		views := s.toViews(context.Background(), "viewer", nil, nil, page, nil)
		if len(plans.calls) != 1 || len(plans.calls[0]) != 2 {
			t.Fatalf("Previews calls = %v, want one batch of the two distinct plans", plans.calls)
		}
		if b := views[0].GetPost().GetBeacon(); b.GetUnavailable() || b.GetTitle() != "Coffee" {
			t.Fatalf("card 0 = %v", b)
		}
		if b := views[2].GetPost().GetBeacon(); !b.GetUnavailable() || b.GetBeaconId() != id2 || b.GetTitle() != "" {
			t.Fatalf("card 2 = %v, want unavailable", b)
		}
		if views[3].GetPost().GetBeacon() != nil {
			t.Fatal("a post without a plan has no card")
		}
	})
	t.Run("no plan on the page: no read", func(t *testing.T) {
		plans := &plansStub{live: live}
		s := NewServer(Deps{Flags: planFlags{}})
		s.SetBeaconPlans(plans)
		s.toViews(context.Background(), "viewer", nil, nil, page[3:], nil)
		if len(plans.calls) != 0 {
			t.Fatal("a page without plans must not read")
		}
	})
	t.Run("failed read or no reader: unavailable", func(t *testing.T) {
		for name, plans := range map[string]posts.BeaconPlans{"error": &plansStub{err: errors.New("boom")}, "unwired": nil} {
			s := NewServer(Deps{Flags: planFlags{}})
			if plans != nil {
				s.SetBeaconPlans(plans)
			}
			if b := s.toViews(context.Background(), "viewer", nil, nil, page[:1], nil)[0].GetPost().GetBeacon(); !b.GetUnavailable() {
				t.Fatalf("%s: card = %v", name, b)
			}
		}
	})
	t.Run("kill switch strips the field with no read", func(t *testing.T) {
		plans := &plansStub{live: live}
		s := NewServer(Deps{Flags: planFlags{off: true}})
		s.SetBeaconPlans(plans)
		views := s.toViews(context.Background(), "viewer", nil, nil, page, nil)
		if len(plans.calls) != 0 || views[0].GetPost().GetBeacon() != nil {
			t.Fatalf("calls = %v, card = %v", plans.calls, views[0].GetPost().GetBeacon())
		}
	})
}
