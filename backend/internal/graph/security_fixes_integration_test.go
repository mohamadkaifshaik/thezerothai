//go:build integration

// security_fixes_integration_test.go covers the emulator-visible behaviour of the M4-verification fixes
// (docs/reviews/security-review-graph.md): M1 opaque/bound page tokens, M2 the shared graph_mutation_daily cap,
// L3 reserved ids. M3 (GetProfile of non-ACTIVE accounts) is asserted by TestNotFound_Integration_ByteIdentical,
// D-1 by TestPurge_Integration_ChunkOfOnlyMissingCounterparts, D1 by TestT16a_Race_FollowUnfollowFlapping. It
// reuses the shared fixtures (newWired, seedFollow, seedBlock, the rig) and the invariant sweep newWired registers.
package graph_test

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// M2: one shared daily cap over Follow/Unfollow/Block/Unblock/Mute/Unmute. Replays leave quotas/{uid}
// untouched (they reserve nothing) but count against the cap; the call after the cap is RATE_LIMITED with 0
// Firestore ops; other uids and the list RPCs are unaffected.
func TestSecurity_Integration_MutationDailyCap(t *testing.T) {
	const mutCap = 6
	w := newWired(t, withNewAccountWindow(1))
	for _, u := range [][2]string{{"uid-mca", "mcalice"}, {"uid-mcb", "mcbob"}, {"uid-mcc", "mccarol"}} {
		mustCreateProfile(t, w.identity, u[0], u[1])
	}
	r := newRigWithMutationCap(t, w, 0, mutCap)
	ctx := context.Background()
	a := r.as("uid-mca")
	key := func(n int) string { return t16bKey(900 + n) }

	steps := []struct {
		name string
		call func() error
		// replay calls read at most this many docs (ADR-0008 budgets: Follow replay 2, Block replay 3).
		maxReads int64
	}{
		{"Follow", func() error {
			_, err := a.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key(1), UserId: "uid-mcb"}))
			return err
		}, 4},
		{"Follow replay", func() error {
			_, err := a.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key(2), UserId: "uid-mcb"}))
			return err
		}, 4}, // the create just evicted both profiles from the cache: 2 profile reads + 2 replay reads (ADR-0008 worst case 4)
		{"Follow replay 2", func() error {
			_, err := a.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key(3), UserId: "uid-mcb"}))
			return err
		}, 2},
		{"Block", func() error {
			_, err := a.graph.Block(ctx, connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: key(4), UserId: "uid-mcc"}))
			return err
		}, 3},
		{"Block replay", func() error {
			_, err := a.graph.Block(ctx, connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: key(5), UserId: "uid-mcc"}))
			return err
		}, 3},
		{"Unmute no-op", func() error {
			_, err := a.graph.Unmute(ctx, connect.NewRequest(&graphv1.UnmuteRequest{IdempotencyKey: key(6), UserId: "uid-mcb"}))
			return err
		}, 1},
	}
	for _, s := range steps {
		if err := s.call(); err != nil {
			t.Fatalf("%s within the cap: %v", s.name, err)
		}
		budgettest.Assert(t, s.name, r.lastOps(), budgettest.Budget{Reads: s.maxReads, Writes: 5, Deletes: 2})
	}
	// Replays reserved nothing: exactly one follow and one block were ever charged.
	if got := quotaUsed(t, w.client, "uid-mca", istDay(0), "follows"); got != 1 {
		t.Errorf("quotas.follows = %d after 1 create + 2 replays, want 1", got)
	}
	if got := quotaUsed(t, w.client, "uid-mca", istDay(0), "blocks"); got != 1 {
		t.Errorf("quotas.blocks = %d after 1 create + 1 replay, want 1", got)
	}

	// Cap reached: every mutation, whatever the RPC, is rejected before any Firestore access.
	rejected := map[string]func() error{
		"Follow": func() error {
			_, err := a.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key(7), UserId: "uid-mcb"}))
			return err
		},
		"Unfollow": func() error {
			_, err := a.graph.Unfollow(ctx, connect.NewRequest(&graphv1.UnfollowRequest{IdempotencyKey: key(8), UserId: "uid-mcb"}))
			return err
		},
		"Block": func() error {
			_, err := a.graph.Block(ctx, connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: key(9), UserId: "uid-mcc"}))
			return err
		},
		"Unblock": func() error {
			_, err := a.graph.Unblock(ctx, connect.NewRequest(&graphv1.UnblockRequest{IdempotencyKey: key(10), UserId: "uid-mcc"}))
			return err
		},
		"Mute": func() error {
			_, err := a.graph.Mute(ctx, connect.NewRequest(&graphv1.MuteRequest{IdempotencyKey: key(11), UserId: "uid-mcb"}))
			return err
		},
		"Unmute": func() error {
			_, err := a.graph.Unmute(ctx, connect.NewRequest(&graphv1.UnmuteRequest{IdempotencyKey: key(12), UserId: "uid-mcb"}))
			return err
		},
	}
	for name, call := range rejected {
		info := decodeErr(t, call())
		if info.Code != connect.CodeResourceExhausted || info.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
			t.Errorf("%s after the cap: %v/%v, want ResourceExhausted/RATE_LIMITED", name, info.Code, info.Reason)
		}
		budgettest.Assert(t, name+" (capped)", r.lastOps(), budgettest.Budget{})
	}

	// Not affected: the same uid's list RPCs, and another uid's mutations (own counter).
	if _, err := a.graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{})); err != nil {
		t.Errorf("ListBlockedUsers after the mutation cap: %v", err)
	}
	if _, err := r.as("uid-mcb").graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key(13), UserId: "uid-mcc"})); err != nil {
		t.Errorf("another uid's Follow rejected: %v", err)
	}
}

// L3: a Firestore-reserved id (__x__) is INVALID_ARGUMENT/VALIDATION on every graph RPC and GetProfile, with
// 0 Firestore ops and 0 ERROR log lines (it used to reach Firestore and surface as INTERNAL).
func TestSecurity_Integration_ReservedIDsAreValidation(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-rsv", "rsvuser")
	r := newRig(t, w, 0)
	c := r.as("uid-rsv")
	ctx := context.Background()
	const bad = "__x__"

	calls := map[string]func() error{
		"Follow": func() error {
			_, err := c.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: t16bKey(1), UserId: bad}))
			return err
		},
		"Unfollow": func() error {
			_, err := c.graph.Unfollow(ctx, connect.NewRequest(&graphv1.UnfollowRequest{IdempotencyKey: t16bKey(2), UserId: bad}))
			return err
		},
		"Block": func() error {
			_, err := c.graph.Block(ctx, connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: t16bKey(3), UserId: bad}))
			return err
		},
		"Unblock": func() error {
			_, err := c.graph.Unblock(ctx, connect.NewRequest(&graphv1.UnblockRequest{IdempotencyKey: t16bKey(4), UserId: bad}))
			return err
		},
		"Mute": func() error {
			_, err := c.graph.Mute(ctx, connect.NewRequest(&graphv1.MuteRequest{IdempotencyKey: t16bKey(5), UserId: bad}))
			return err
		},
		"Unmute": func() error {
			_, err := c.graph.Unmute(ctx, connect.NewRequest(&graphv1.UnmuteRequest{IdempotencyKey: t16bKey(6), UserId: bad}))
			return err
		},
		"ListFollowers": func() error {
			_, err := c.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: bad}))
			return err
		},
		"ListFollowing": func() error {
			_, err := c.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: bad}))
			return err
		},
		"GetRelationships": func() error {
			_, err := c.graph.GetRelationships(ctx, connect.NewRequest(&graphv1.GetRelationshipsRequest{UserIds: []string{bad}}))
			return err
		},
		"GetProfile(user_id)": func() error {
			_, err := c.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: bad}}))
			return err
		},
		"GetProfile(handle)": func() error {
			_, err := c.id.GetProfile(ctx, connect.NewRequest(&identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: bad}}))
			return err
		},
	}
	for name, call := range calls {
		info := decodeErr(t, call())
		if info.Code != connect.CodeInvalidArgument || info.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
			t.Errorf("%s: %v/%v, want InvalidArgument/VALIDATION", name, info.Code, info.Reason)
		}
		budgettest.Assert(t, name, r.lastOps(), budgettest.Budget{})
	}
	if lines := r.errorLines(); len(lines) != 0 {
		t.Errorf("%d ERROR log lines for reserved ids, want 0: %v", len(lines), lines)
	}
}

// M1: with page_size 1 over a list whose newest row is hidden by a block, the page comes back empty but carries
// a token; no token (raw or decoded) contains any uid, and a token issued to one caller is rejected for another
// at 0 reads. Own-list tokens are bound too.
func TestSecurity_Integration_PageTokensOpaqueAndBound(t *testing.T) {
	w := newWired(t)
	const viewer, other, target, hidden, vis1, vis2 = "uid-tkviewer", "uid-tkother", "uid-tktarget", "uid-tkhidden", "uid-tkvis1", "uid-tkvis2"
	for _, u := range []string{viewer, other, target, hidden, vis1, vis2} {
		mustCreateProfile(t, w.identity, u, strings.TrimPrefix(u, "uid-"))
	}
	now := time.Now().UTC()
	seedFollow(t, w, hidden, target, now)                   // newest: scanned first
	seedFollow(t, w, vis1, target, now.Add(-time.Minute))   //
	seedFollow(t, w, vis2, target, now.Add(-2*time.Minute)) //
	seedBlock(t, w.client, hidden, viewer)                  // hidden blocked the viewer: its row is filtered
	seedBlock(t, w.client, viewer, vis1)                    // own blocked list has an entry to page
	seedBlock(t, w.client, viewer, vis2)
	r := newRig(t, w, 0)
	ctx := context.Background()
	v := r.as(viewer)

	var tokens []string
	token := ""
	sawEmptyWithToken := false
	for i := 0; i < 6; i++ {
		resp, err := v.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: target, PageSize: 1, PageToken: token}))
		if err != nil {
			t.Fatalf("page %d: %v", i, err)
		}
		next := resp.Msg.GetNextPageToken()
		if len(resp.Msg.GetUsers()) == 0 && next != "" {
			sawEmptyWithToken = true
		}
		if next == "" {
			break
		}
		tokens = append(tokens, next)
		token = next
	}
	if !sawEmptyWithToken {
		t.Fatal("setup: expected a hidden row to produce an empty page that still carries a token")
	}
	own, err := v.graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: 1}))
	if err != nil || own.Msg.GetNextPageToken() == "" {
		t.Fatalf("own list page 1: %v token=%q", err, own.Msg.GetNextPageToken())
	}
	ownTok := own.Msg.GetNextPageToken()
	tokens = append(tokens, ownTok)

	for _, tok := range tokens {
		raw, err := base64.RawURLEncoding.DecodeString(tok)
		if err != nil {
			t.Fatalf("token is not base64url: %v", err)
		}
		for _, hay := range []string{tok, string(raw)} {
			for _, id := range []string{"uid-", hidden, target, viewer} {
				if strings.Contains(hay, id) {
					t.Errorf("token %q exposes %q", tok, id)
				}
			}
		}
	}

	// Bound to the caller (and list): another user, or another list, cannot use the token.
	edgeTok := tokens[0]
	rejects := map[string]func() error{
		"other caller, same list": func() error {
			_, err := r.as(other).graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: target, PageSize: 1, PageToken: edgeTok}))
			return err
		},
		"same caller, following instead of followers": func() error {
			_, err := v.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: target, PageSize: 1, PageToken: edgeTok}))
			return err
		},
		"own blocked token used by another caller": func() error {
			_, err := r.as(other).graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: 1, PageToken: ownTok}))
			return err
		},
		"own blocked token on the muted list": func() error {
			_, err := v.graph.ListMutedUsers(ctx, connect.NewRequest(&graphv1.ListMutedUsersRequest{PageSize: 1, PageToken: ownTok}))
			return err
		},
	}
	for name, call := range rejects {
		info := decodeErr(t, call())
		if info.Code != connect.CodeInvalidArgument || info.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || info.Meta["field"] != "page_token" {
			t.Errorf("%s: %+v, want InvalidArgument/VALIDATION/field=page_token", name, info)
		}
		budgettest.Assert(t, fmt.Sprintf("rejected token (%s)", name), r.lastOps(), budgettest.Budget{})
	}
	// The owner's own tokens still work.
	if _, err := v.graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: 1, PageToken: ownTok})); err != nil {
		t.Errorf("owner's own-list token rejected: %v", err)
	}
}
