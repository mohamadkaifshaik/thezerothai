package apiserver

import (
	"context"
	"errors"
	"testing"
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// fakeBeaconSvc answers the two plan calls; the embedded nil interface panics on any other method.
type fakeBeaconSvc struct {
	beacons.Service
	target  beacons.PlanPreview
	err     error
	preview map[string]beacons.PlanPreview
}

func (f fakeBeaconSvc) EmbedTarget(context.Context, string, string) (beacons.PlanPreview, error) {
	return f.target, f.err
}

func (f fakeBeaconSvc) Previews(context.Context, string, []string) (map[string]beacons.PlanPreview, error) {
	return f.preview, f.err
}

// TestPostPlans_MapsBeaconsToPosts: the adapter converts the live fields and the beacons sentinels to the posts ones.
func TestPostPlans_MapsBeaconsToPosts(t *testing.T) {
	start := time.Date(2026, 11, 20, 16, 0, 0, 0, time.UTC)
	p := beacons.PlanPreview{BeaconID: "0000000000000000555", Title: "Coffee", Activity: beacons.ActivityCoffee, StartAt: start, Status: beacons.StatusFull, CommunityID: "c1"}
	live, err := postPlans{svc: fakeBeaconSvc{target: p}}.EmbedTarget(context.Background(), "u", p.BeaconID)
	if err != nil || live.Title != "Coffee" || live.Activity != beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE || live.Status != beaconsv1.BeaconStatus_BEACON_STATUS_FULL ||
		!live.StartAt.Equal(start) || live.CommunityID != "c1" {
		t.Fatalf("live = %+v, %v", live, err)
	}
	for in, want := range map[error]error{
		beacons.ErrNotFound: posts.ErrBeaconNotFound, beacons.ErrEnded: posts.ErrBeaconEnded, beacons.ErrCancelled: posts.ErrBeaconCancelled,
	} {
		if _, err := (postPlans{svc: fakeBeaconSvc{err: in}}).EmbedTarget(context.Background(), "u", "x"); !errors.Is(err, want) {
			t.Fatalf("%v mapped to %v, want %v", in, err, want)
		}
	}
	boom := errors.New("boom")
	if _, err := (postPlans{svc: fakeBeaconSvc{err: boom}}).EmbedTarget(context.Background(), "u", "x"); !errors.Is(err, boom) {
		t.Fatalf("an unknown error must pass through, got %v", err)
	}
	m, err := postPlans{svc: fakeBeaconSvc{preview: map[string]beacons.PlanPreview{p.BeaconID: p}}}.Previews(context.Background(), "u", []string{p.BeaconID})
	if err != nil || len(m) != 1 || m[p.BeaconID].Title != "Coffee" {
		t.Fatalf("previews = %+v, %v", m, err)
	}
	if _, err := (postPlans{svc: fakeBeaconSvc{err: boom}}).Previews(context.Background(), "u", nil); !errors.Is(err, boom) {
		t.Fatalf("previews error = %v", err)
	}
}

// TestFeatureRegistry_IncludesPostBeaconEmbed: default off; on for an allowlisted caller only; a spec left out of
// featureRegistry would be silently off for everyone.
func TestFeatureRegistry_IncludesPostBeaconEmbed(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if featureRegistry(cfg).Enabled("uid-a", posts.PostBeaconFlagName) {
		t.Error("post_beacon_embed must default off")
	}
	t.Setenv("FEATURE_POST_BEACON_EMBED", "allowlist")
	t.Setenv("FEATURE_POST_BEACON_EMBED_ALLOWLIST", "uid-a")
	cfg, err = config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !reg.Enabled("uid-a", posts.PostBeaconFlagName) || reg.Enabled("uid-z", posts.PostBeaconFlagName) {
		t.Error("post_beacon_embed should be on for uid-a only")
	}
	if cfg.FeaturePostBeaconEmbed.Name != posts.PostBeaconFlagName {
		t.Errorf("config flag name %q != posts.PostBeaconFlagName", cfg.FeaturePostBeaconEmbed.Name)
	}
}
