//go:build integration

package apiserver

// ListSuggestedUsers (ADR-0024 D8, ticket W3-12) over the real Build chain on the emulators: the whole-request read cap
// including the account-status interceptor (42 cold, <= 1 warm), the request-log fields, the wire shape and the Follow
// eviction. The measured calls go through a SECOND Build over the same emulator project, so its instance caches
// (identity profiles, graph snapshots) start empty even though the first Build created every profile. Helpers come from
// posts_restricted_test.go.

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// seedFollowEdge writes follows/{follower}_{followee} and appends followee to graph/{follower}.following, the shape a
// Follow commit leaves (counters are irrelevant to the reads under test).
func seedFollowEdge(t *testing.T, fs *firestore.Client, follower, followee string, at time.Time) {
	t.Helper()
	ctx := context.Background()
	if _, err := fs.Collection("follows").Doc(follower+"_"+followee).Set(ctx, map[string]any{"followerId": follower, "followeeId": followee, "createdAt": at}); err != nil {
		t.Fatalf("seed follow edge: %v", err)
	}
	if _, err := fs.Collection("graph").Doc(follower).Update(ctx, []firestore.Update{{Path: "following", Value: firestore.ArrayUnion(followee)}}); err != nil {
		t.Fatalf("seed graph.following: %v", err)
	}
}

func logNum(line map[string]any, key string) float64 {
	v, _ := line[key].(float64)
	return v
}

func TestListSuggestedUsers_ChainReadCapAndWire(t *testing.T) {
	viewerToken, viewerUID := mintToken(t, "")
	type user struct{ token, uid string }
	mint := func(n int) []user {
		out := make([]user, n)
		for i := range out {
			out[i].token, out[i].uid = mintToken(t, "")
		}
		return out
	}
	followees, candidates := mint(4), mint(14)

	configure := func(c *config.Config) {
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		c.FeatureFollowSuggestions = flags.Spec{Name: "follow_suggestions", Mode: flags.Allowlist, Allowlist: map[string]struct{}{viewerUID: {}}}
	}
	setup := newChain(t, configure)
	for _, u := range append(append([]user{{viewerToken, viewerUID}}, followees...), candidates...) {
		setup.createProfile(t, u.token)
	}

	// The viewer follows the four followees; followee f follows every candidate c at a time that makes the newest 30
	// edges cover all 14 candidates (more than the 10 that get hydrated).
	base := time.Now().Add(-48 * time.Hour).UTC()
	for i, f := range followees {
		seedFollowEdge(t, setup.fs, viewerUID, f.uid, base.Add(time.Duration(i)*time.Second))
	}
	for fi, f := range followees {
		for ci, c := range candidates {
			seedFollowEdge(t, setup.fs, f.uid, c.uid, base.Add(time.Hour+time.Duration(fi*len(candidates)+ci)*time.Minute))
		}
	}

	env := newChain(t, configure) // a second instance: empty caches
	g := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url)
	rpc := graphv1connect.GraphServiceListSuggestedUsersProcedure
	ctx := context.Background()

	cold, err := g.ListSuggestedUsers(ctx, authed(viewerToken, &graphv1.ListSuggestedUsersRequest{}))
	if err != nil {
		t.Fatalf("cold ListSuggestedUsers: %v", err)
	}
	if len(cold.Msg.GetUsers()) != 5 {
		t.Fatalf("users = %d, want 5", len(cold.Msg.GetUsers()))
	}
	var coldUIDs []string
	for _, it := range cold.Msg.GetUsers() {
		uid := it.GetUser().GetUserId()
		coldUIDs = append(coldUIDs, uid)
		if !slices.ContainsFunc(candidates, func(c user) bool { return c.uid == uid }) {
			t.Errorf("row %s is not one of the candidates", uid)
		}
		if it.GetUser().GetHandle() == "" || it.GetSince() != nil {
			t.Errorf("row %s: handle %q since %v, want a hydrated user and no since", uid, it.GetUser().GetHandle(), it.GetSince())
		}
		if r := it.GetRelationship(); r == nil || r.GetFollowState() != graphv1.FollowState_FOLLOW_STATE_NONE || r.GetBlocking() || r.GetMuting() {
			t.Errorf("row %s: relationship = %v, want NONE", uid, r)
		}
	}

	lines := env.logs.requestLines(rpc)
	if len(lines) != 1 {
		t.Fatalf("request lines = %d, want 1", len(lines))
	}
	coldLine := lines[0]
	t.Logf("BUDGET ListSuggestedUsers chain cold fs_reads=%v fs_writes=%v (documented hard cap 42)", coldLine["fs_reads"], coldLine["fs_writes"])
	if reads := logNum(coldLine, "fs_reads"); reads > 42 || reads < 41 {
		t.Errorf("cold fs_reads = %v, want 41 or 42 (interceptor 0-1 + graph 1 + 30 edges + 10 profiles)", reads)
	}
	if logNum(coldLine, "fs_writes") != 0 || logNum(coldLine, "fs_deletes") != 0 {
		t.Errorf("cold writes/deletes = %v/%v, want 0/0", coldLine["fs_writes"], coldLine["fs_deletes"])
	}
	if coldLine["source"] != "fof" || logNum(coldLine, "candidates") != 10 || coldLine["suggestions_cache_hit"] != false {
		t.Errorf("cold log fields: source=%v candidates=%v suggestions_cache_hit=%v, want fof, 10, false", coldLine["source"], coldLine["candidates"], coldLine["suggestions_cache_hit"])
	}

	warm, err := g.ListSuggestedUsers(ctx, authed(viewerToken, &graphv1.ListSuggestedUsersRequest{}))
	if err != nil {
		t.Fatalf("warm ListSuggestedUsers: %v", err)
	}
	warmLine := env.logs.requestLines(rpc)[1]
	t.Logf("BUDGET ListSuggestedUsers chain warm fs_reads=%v (documented 1, the interceptor)", warmLine["fs_reads"])
	if logNum(warmLine, "fs_reads") > 1 || logNum(warmLine, "fs_writes") != 0 {
		t.Errorf("warm fs_reads/fs_writes = %v/%v, want <= 1 (the interceptor) and 0", warmLine["fs_reads"], warmLine["fs_writes"])
	}
	if warmLine["suggestions_cache_hit"] != true || warmLine["source"] != "fof" {
		t.Errorf("warm log fields: suggestions_cache_hit=%v source=%v, want true and fof", warmLine["suggestions_cache_hit"], warmLine["source"])
	}
	var warmUIDs []string
	for _, it := range warm.Msg.GetUsers() {
		warmUIDs = append(warmUIDs, it.GetUser().GetUserId())
	}
	if !slices.Equal(warmUIDs, coldUIDs) {
		t.Errorf("warm rows %v differ from cold rows %v", warmUIDs, coldUIDs)
	}

	// max_results is honoured on the wire (clamped server side) and costs nothing from the cache.
	two, err := g.ListSuggestedUsers(ctx, authed(viewerToken, &graphv1.ListSuggestedUsersRequest{MaxResults: 2}))
	if err != nil || len(two.Msg.GetUsers()) != 2 {
		t.Errorf("max_results 2: %v rows, err %v", len(two.Msg.GetUsers()), err)
	}

	// Follow on this instance removes the user from the cached rows; the next call is still a cache hit.
	first := coldUIDs[0]
	if _, err := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url).Follow(ctx, authed(viewerToken, &graphv1.FollowRequest{
		IdempotencyKey: fmt.Sprintf("w312-follow-%d", time.Now().UnixNano()), UserId: first,
	})); err != nil {
		t.Fatalf("Follow: %v", err)
	}
	after, err := g.ListSuggestedUsers(ctx, authed(viewerToken, &graphv1.ListSuggestedUsersRequest{}))
	if err != nil {
		t.Fatalf("ListSuggestedUsers after Follow: %v", err)
	}
	for _, it := range after.Msg.GetUsers() {
		if it.GetUser().GetUserId() == first {
			t.Errorf("followed user %s is still suggested", first)
		}
	}
	if len(after.Msg.GetUsers()) != 5 {
		t.Errorf("rows after Follow = %d, want 5 (the cached tail refills)", len(after.Msg.GetUsers()))
	}
	last := env.logs.requestLines(rpc)
	if got := last[len(last)-1]; got["suggestions_cache_hit"] != true || logNum(got, "fs_reads") > 1 {
		t.Errorf("after Follow: suggestions_cache_hit=%v fs_reads=%v, want a cache hit and <= 1 read", got["suggestions_cache_hit"], got["fs_reads"])
	}
}
