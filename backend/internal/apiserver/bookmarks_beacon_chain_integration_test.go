//go:build integration

package apiserver

// F5 plan cards on ListBookmarks over the real Build chain (Firestore, Auth emulators): a post sharing a public plan is
// hydrated for a reader who bookmarked it (the beacons reader is late-bound into the engagement handler by
// wirePostPlans), and once the plan is hidden the same row falls back to the bare unavailable form.
//
// Shard safety: every assertion is scoped to this test's users, post and beacon.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestBookmarksChain_HydratesPlanCard(t *testing.T) {
	ctx := context.Background()
	e := newBMChain(t, func(c *config.Config) {
		c.FeatureBeacons = flags.Spec{Name: "beacons", Mode: flags.On}
		c.FeaturePostBeaconEmbed = flags.Spec{Name: "post_beacon_embed", Mode: flags.On}
	})
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, reader := e.user(t), e.user(t)

	cr, err := bc.CreateBeacon(ctx, authed(org.token, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: contractKey("bmb-create"), Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: "Coffee", Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	beaconID := cr.Msg.GetView().GetBeacon().GetBeaconId()
	pr, err := e.posts.CreatePost(ctx, authed(org.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bmb-post"), Text: "join me", BeaconId: beaconID}))
	if err != nil {
		t.Fatalf("CreatePost with a plan: %v", err)
	}
	pid := pr.Msg.GetPost().GetPost().GetPostId()
	if _, err := e.add(reader, contractKey("bmb-add"), pid); err != nil {
		t.Fatalf("AddBookmark: %v", err)
	}

	card := func(u bmUser) *postsv1.BeaconPreview {
		t.Helper()
		r, err := e.eng.ListBookmarks(ctx, authed(u.token, &engagementv1.ListBookmarksRequest{}))
		if err != nil {
			t.Fatalf("ListBookmarks: %v", err)
		}
		for _, b := range r.Msg.GetBookmarks() {
			if b.GetPost().GetPost().GetPostId() == pid {
				return b.GetPost().GetPost().GetBeacon()
			}
		}
		t.Fatalf("ListBookmarks has no row for %s: %v", pid, r.Msg)
		return nil
	}

	if b := card(reader); b.GetUnavailable() || b.GetBeaconId() != beaconID || b.GetTitle() != "Coffee" ||
		b.GetActivity() != beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE || b.GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN {
		t.Fatalf("bookmarked plan card = %v, want the live Coffee plan", b)
	}

	// A moderator hides the plan: the reader's row keeps the post but the card is the bare unavailable form.
	if _, err := e.fs.Doc("beacons/"+beaconID).Set(ctx, map[string]any{"hidden": true}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	if b := card(reader); !b.GetUnavailable() || b.GetBeaconId() != beaconID || b.GetTitle() != "" {
		t.Fatalf("hidden plan card = %v, want unavailable with no live fields", b)
	}
}
