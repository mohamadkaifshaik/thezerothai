//go:build integration

package e2e

// T17 (docs/plans/graph.md): graph E2E smoke. The same test body runs in two modes:
//
//   - Emulator mode (default, `make test-int`): boots the real handler via newTestServerCfg, mints two
//     Firebase Auth emulator users and creates their profiles. Fully self-contained.
//   - Remote mode (prod `candidate` / dev URL): set E2E_GRAPH_BASE_URL plus E2E_GRAPH_ID_TOKEN_A and
//     E2E_GRAPH_ID_TOKEN_B (fresh ID tokens for two pre-provisioned smoke accounts that already have
//     profiles and, on prod, are on the FEATURE_GRAPH allowlist). No emulator env is needed and nothing
//     is created except graph edges, which are removed again on exit.
//
// Budget: about 15 requests per run (well under the < 100-request prod smoke cap), about 15 reads and 12
// writes. The test always leaves A and B with no follow and no block between them, so it is re-runnable.

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"testing"
	"time"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
)

// graphSmokeEnv is one resolved smoke environment: clients plus the two accounts' tokens and uids.
type graphSmokeEnv struct {
	graph    graphv1connect.GraphServiceClient
	identity identityv1connect.IdentityServiceClient
	tokenA   string
	tokenB   string
	uidA     string
	uidB     string
	handleB  string
	remote   bool
}

func setupGraphSmoke(t *testing.T) graphSmokeEnv {
	t.Helper()
	ctx := context.Background()

	if base := os.Getenv("E2E_GRAPH_BASE_URL"); base != "" {
		tokA, tokB := os.Getenv("E2E_GRAPH_ID_TOKEN_A"), os.Getenv("E2E_GRAPH_ID_TOKEN_B")
		if tokA == "" || tokB == "" {
			t.Fatal("E2E_GRAPH_BASE_URL is set but E2E_GRAPH_ID_TOKEN_A / E2E_GRAPH_ID_TOKEN_B are not")
		}
		env := graphSmokeEnv{
			graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, base),
			identity: identityv1connect.NewIdentityServiceClient(http.DefaultClient, base),
			tokenA:   tokA,
			tokenB:   tokB,
			remote:   true,
		}
		// Existing accounts: resolve uid + handle from GetMe (never from the body, never hard-coded).
		meA, err := env.identity.GetMe(ctx, authedRequest(tokA, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(A): %v", err)
		}
		meB, err := env.identity.GetMe(ctx, authedRequest(tokB, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(B): %v", err)
		}
		env.uidA, env.uidB = meA.Msg.GetProfile().GetUserId(), meB.Msg.GetProfile().GetUserId()
		env.handleB = meB.Msg.GetProfile().GetHandle()
		return env
	}

	skipIfNoEmulators(t)
	_, baseURL := newTestServerCfg(t, nil)
	env := graphSmokeEnv{
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, baseURL),
		identity: identityv1connect.NewIdentityServiceClient(http.DefaultClient, baseURL),
	}
	create := func(label string) (token, uid, handle string) {
		token, uid = newAnonymousIDToken(t)
		handle = uniqueHandle("g17" + label)
		_, err := env.identity.CreateProfile(ctx, authedRequest(token, &identityv1.CreateProfileRequest{
			IdempotencyKey: fmt.Sprintf("e2e-graph-create-%s-%d", label, rand.Int63()),
			Handle:         handle,
			DisplayName:    "Graph Smoke " + label,
		}))
		if err != nil {
			t.Fatalf("CreateProfile(%s): %v", label, err)
		}
		return token, uid, handle
	}
	env.tokenA, env.uidA, _ = create("a")
	env.tokenB, env.uidB, env.handleB = create("b")
	return env
}

// idemKey returns a fresh key per call so re-runs never replay a previous run's cached response.
func idemKey(op string) string { return fmt.Sprintf("e2e-graph-%s-%d", op, rand.Int63()) }

// eventually polls cond until it returns true or the timeout passes. Emulator mode is single-instance and
// read-your-writes, so it passes on the first try; remote mode allows for a peer Cloud Run instance's
// 60 s graph cache (ADR-0008) to expire.
func (e graphSmokeEnv) eventually(t *testing.T, what string, cond func() (bool, string)) {
	t.Helper()
	timeout := 3 * time.Second
	if e.remote {
		timeout = 90 * time.Second
	}
	deadline := time.Now().Add(timeout)
	var last string
	for {
		ok, msg := cond()
		if ok {
			return
		}
		last = msg
		if time.Now().After(deadline) {
			t.Fatalf("%s: not satisfied within %v: %s", what, timeout, last)
		}
		time.Sleep(500 * time.Millisecond) // bounded poll, not a sync sleep: cond re-queries the server
	}
}

func TestE2E_GraphSmoke_FollowListBlockUnblock(t *testing.T) {
	env := setupGraphSmoke(t)
	ctx := context.Background()

	// Cleanup always runs, even on failure, and uses its own fresh keys: leave no block and no follow.
	t.Cleanup(func() {
		if _, err := env.graph.Unblock(ctx, authedRequest(env.tokenB, &graphv1.UnblockRequest{IdempotencyKey: idemKey("cleanup-unblock"), UserId: env.uidA})); err != nil {
			t.Errorf("cleanup Unblock(B->A): %v", err)
		}
		if _, err := env.graph.Unfollow(ctx, authedRequest(env.tokenA, &graphv1.UnfollowRequest{IdempotencyKey: idemKey("cleanup-unfollow"), UserId: env.uidB})); err != nil {
			t.Errorf("cleanup Unfollow(A->B): %v", err)
		}
	})

	// Pre-clean a leftover from an aborted earlier run (both calls are no-ops on a clean state).
	if _, err := env.graph.Unblock(ctx, authedRequest(env.tokenB, &graphv1.UnblockRequest{IdempotencyKey: idemKey("pre-unblock"), UserId: env.uidA})); err != nil {
		t.Fatalf("pre-clean Unblock: %v", err)
	}
	if _, err := env.graph.Unfollow(ctx, authedRequest(env.tokenA, &graphv1.UnfollowRequest{IdempotencyKey: idemKey("pre-unfollow"), UserId: env.uidB})); err != nil {
		t.Fatalf("pre-clean Unfollow: %v", err)
	}

	// 1. A follows B -> GetRelationships(A, [B]) reports FOLLOWING.
	followResp, err := env.graph.Follow(ctx, authedRequest(env.tokenA, &graphv1.FollowRequest{IdempotencyKey: idemKey("follow"), UserId: env.uidB}))
	if err != nil {
		t.Fatalf("Follow(A->B): %v", err)
	}
	if got := followResp.Msg.GetRelationship().GetFollowState(); got != graphv1.FollowState_FOLLOW_STATE_FOLLOWING {
		t.Fatalf("Follow response follow_state = %v, want FOLLOWING", got)
	}
	env.eventually(t, "GetRelationships(A,[B]) FOLLOWING", func() (bool, string) {
		resp, err := env.graph.GetRelationships(ctx, authedRequest(env.tokenA, &graphv1.GetRelationshipsRequest{UserIds: []string{env.uidB}}))
		if err != nil {
			t.Fatalf("GetRelationships: %v", err)
		}
		rels := resp.Msg.GetRelationships()
		if len(rels) != 1 {
			return false, fmt.Sprintf("got %d relationships, want 1", len(rels))
		}
		return rels[0].GetUserId() == env.uidB && rels[0].GetFollowState() == graphv1.FollowState_FOLLOW_STATE_FOLLOWING && !rels[0].GetBlocking(),
			fmt.Sprintf("relationship = %v", rels[0])
	})

	// 2. ListFollowers(B) contains A.
	env.eventually(t, "ListFollowers(B) contains A", func() (bool, string) {
		resp, err := env.graph.ListFollowers(ctx, authedRequest(env.tokenA, &graphv1.ListFollowersRequest{UserId: env.uidB, PageSize: 20}))
		if err != nil {
			t.Fatalf("ListFollowers(B): %v", err)
		}
		for _, u := range resp.Msg.GetUsers() {
			if u.GetUser().GetUserId() == env.uidA {
				return true, ""
			}
		}
		return false, fmt.Sprintf("A (%s) not among %d followers", env.uidA, len(resp.Msg.GetUsers()))
	})

	// Sanity: before the block, A can read B's profile.
	if _, err := env.identity.GetProfile(ctx, authedRequest(env.tokenA, &identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: env.uidB},
	})); err != nil {
		t.Fatalf("GetProfile(B) as A before block: %v", err)
	}

	// 3. B blocks A -> A's GetProfile(B) is NOT_FOUND (byte-identical to a missing profile, ADR-0008 D9).
	if _, err := env.graph.Block(ctx, authedRequest(env.tokenB, &graphv1.BlockRequest{IdempotencyKey: idemKey("block"), UserId: env.uidA})); err != nil {
		t.Fatalf("Block(B->A): %v", err)
	}
	env.eventually(t, "GetProfile(B) as A is NOT_FOUND after block", func() (bool, string) {
		_, err := env.identity.GetProfile(ctx, authedRequest(env.tokenA, &identityv1.GetProfileRequest{
			Target: &identityv1.GetProfileRequest_UserId{UserId: env.uidB},
		}))
		if err == nil {
			return false, "GetProfile succeeded while blocked"
		}
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("GetProfile(B) as A while blocked: code %v (%v), want NOT_FOUND", connect.CodeOf(err), err)
		}
		return true, ""
	})
	// Same by handle: a block must not be bypassable via the other lookup path.
	_, err = env.identity.GetProfile(ctx, authedRequest(env.tokenA, &identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_Handle{Handle: env.handleB},
	}))
	assertCode(t, err, connect.CodeNotFound)

	// B's own view: blocking A is reported, and Block removed A's follow of B (ADR-0008 Q3).
	relB, err := env.graph.GetRelationships(ctx, authedRequest(env.tokenB, &graphv1.GetRelationshipsRequest{UserIds: []string{env.uidA}}))
	if err != nil {
		t.Fatalf("GetRelationships(B,[A]): %v", err)
	}
	if rels := relB.Msg.GetRelationships(); len(rels) != 1 || !rels[0].GetBlocking() {
		t.Fatalf("GetRelationships(B,[A]) = %v, want blocking=true", rels)
	}

	// 4. B unblocks A -> A can read B's profile again.
	if _, err := env.graph.Unblock(ctx, authedRequest(env.tokenB, &graphv1.UnblockRequest{IdempotencyKey: idemKey("unblock"), UserId: env.uidA})); err != nil {
		t.Fatalf("Unblock(B->A): %v", err)
	}
	env.eventually(t, "GetProfile(B) as A succeeds after unblock", func() (bool, string) {
		_, err := env.identity.GetProfile(ctx, authedRequest(env.tokenA, &identityv1.GetProfileRequest{
			Target: &identityv1.GetProfileRequest_UserId{UserId: env.uidB},
		}))
		if err != nil {
			return false, err.Error()
		}
		return true, ""
	})

	// 5. Clean-up runs in t.Cleanup (Unblock + Unfollow, both idempotent no-ops here after the block
	// already removed the follow edge).
}
