package apiserver

import (
	"testing"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
)

// Wiring: ListSuggestedUsers, ListLikedPosts and GetProfileRelationship each draw on their
// own per-user bucket, and none of them has a daily call cap.
var (
	w3SuggestionsProc = graphv1connect.GraphServiceListSuggestedUsersProcedure
	w3LikesListProc   = engagementv1connect.EngagementServiceListLikedPostsProcedure
	w3RelationProc    = graphv1connect.GraphServiceGetProfileRelationshipProcedure
)

func TestProfileGraphBuckets_AreSeparateAndUnexempt(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	sug, likes, rel := rl.PerProcedure[w3SuggestionsProc], rl.PerProcedure[w3LikesListProc], rl.PerProcedure[w3RelationProc]
	if sug == nil || likes == nil || rel == nil {
		t.Fatalf("a W3 procedure has no per-procedure limiter: suggestions=%v likes=%v relationship=%v", sug, likes, rel)
	}
	if sug == likes || sug == rel || likes == rel {
		t.Error("the three W3 RPCs must each have their own limiter instance")
	}
	for _, p := range []string{w3SuggestionsProc, w3LikesListProc, w3RelationProc} {
		if rl.PerProcedure[p] == rl.Default {
			t.Errorf("%s must not share the default bucket", p)
		}
		if _, ok := rl.DailyCaps[p]; ok {
			t.Errorf("%s must not have a daily call cap", p)
		}
	}
}
