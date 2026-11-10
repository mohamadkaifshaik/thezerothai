package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// postPlans adapts beacons.Service to posts.BeaconPlans: the one seam through which a post embeds a plan (posts imports no
// other module, beacons imports no posts). Both calls go through the beacons service, never its repo.
type postPlans struct{ svc beacons.Service }

var _ posts.BeaconPlans = postPlans{}

func liveOf(p beacons.PlanPreview) posts.BeaconLive {
	return posts.BeaconLive{
		BeaconID: p.BeaconID, Title: p.Title, Activity: beacons.PreviewActivityProto(p.Activity), StartAt: p.StartAt,
		Status: beacons.PreviewStatusProto(p.Status), CommunityID: p.CommunityID,
	}
}

// EmbedTarget implements posts.BeaconPlans, translating the beacons sentinels to the posts ones.
func (a postPlans) EmbedTarget(ctx context.Context, uid, beaconID string) (posts.BeaconLive, error) {
	p, err := a.svc.EmbedTarget(ctx, uid, beaconID)
	switch {
	case err == nil:
		return liveOf(p), nil
	case errors.Is(err, beacons.ErrNotFound):
		return posts.BeaconLive{}, posts.ErrBeaconNotFound
	case errors.Is(err, beacons.ErrEnded):
		return posts.BeaconLive{}, posts.ErrBeaconEnded
	case errors.Is(err, beacons.ErrCancelled):
		return posts.BeaconLive{}, posts.ErrBeaconCancelled
	}
	return posts.BeaconLive{}, err
}

// Previews implements posts.BeaconPlans.
func (a postPlans) Previews(ctx context.Context, viewer string, ids []string) (map[string]posts.BeaconLive, error) {
	m, err := a.svc.Previews(ctx, viewer, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]posts.BeaconLive, len(m))
	for id, p := range m {
		out[id] = liveOf(p)
	}
	return out, nil
}

// wirePostPlans hands the plan reader to the three post producers (CreatePost's service, the posts handler and the timeline
// handler). Called once, after beacons is built, before ListenAndServe.
func wirePostPlans(svc beacons.Service, postsSvc posts.Service, postsServer *posts.Server, timelineServer interface{ SetBeaconPlans(posts.BeaconPlans) }) {
	plans := postPlans{svc: svc}
	if s, ok := postsSvc.(interface{ SetBeaconPlans(posts.BeaconPlans) }); ok {
		s.SetBeaconPlans(plans)
	}
	postsServer.SetBeaconPlans(plans)
	timelineServer.SetBeaconPlans(plans)
}
