//go:build integration

// mutations_integration_test.go is ticket T16a (docs/plans/graph.md): emulator contract tests for the six
// graph mutations (Follow, Unfollow, Block, Unblock, Mute, Unmute) covering every documented ErrorReason
// (ADR-0008), budget assertions (worst case and typical) on every call, replays, quotas (incl. the IST-midnight
// rollover and new-account tiers), caps, races, and degraded mode. Every newWired test ends with the ADR-0008 D3
// invariant sweep (invariants_integration_test.go); race tests also sweep after each iteration.
//
// Budgets (ADR-0008 "Per-RPC budget", worst / typical). The typical figures assume identity's profile cache is
// warm (what a busy instance has); cold worst cases include the 2-doc identity.Directory read Follow does first.
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
)

// Budgets straight from the ADR-0008 table (reads / writes / deletes).
var (
	budFollowWorstCold = budgettest.Budget{Reads: 4, Writes: 5} // cold identity cache: 2 directory + graph + quota
	budFollowTypical   = budgettest.Budget{Reads: 2, Writes: 5} // warm identity cache
	budFollowOverflow  = budgettest.Budget{Reads: 5, Writes: 5} // +1 read for an overflowed caller
	budFollowReplay    = budgettest.Budget{Reads: 2, Writes: 0} // warm replay
	budFollowReplayCld = budgettest.Budget{Reads: 4, Writes: 0} // cold replay
	budUnfollow        = budgettest.Budget{Reads: 0, Writes: 3, Deletes: 1}
	budUnfollowNoop    = budgettest.Budget{Reads: 0, Writes: 0, Deletes: 0}
	budBlockWorst      = budgettest.Budget{Reads: 3, Writes: 5, Deletes: 2} // mutual follow
	budBlockTypical    = budgettest.Budget{Reads: 3, Writes: 3}
	budBlockReplay     = budgettest.Budget{Reads: 3, Writes: 0}
	budUnblock         = budgettest.Budget{Reads: 1, Writes: 2}
	budUnblockNoop     = budgettest.Budget{Reads: 1, Writes: 0}
	budMute            = budgettest.Budget{Reads: 3, Writes: 2} // caller graph + target existence (A1) + quotas
	budMuteReplay      = budgettest.Budget{Reads: 3, Writes: 0}
	budUnmute          = budgettest.Budget{Reads: 1, Writes: 1}
	budUnmuteNoop      = budgettest.Budget{Reads: 1, Writes: 0}
	budRejectedNoIO    = budgettest.Budget{} // validation / flag / self rejections must touch Firestore 0 times
)

type mutationFn func(ctx context.Context, w wired, caller, key, target string) (graph.Relationship, error)

// mutation names one of the six RPCs for table-driven tests.
type mutation struct {
	name string
	call mutationFn
	// selfIsNoop: Unfollow/Unblock/Unmute on yourself return NONE (a no-op); Follow/Block/Mute reject it.
	selfIsNoop bool
}

var allMutations = []mutation{
	{"Follow", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Follow(ctx, c, k, t)
	}, false},
	{"Unfollow", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Unfollow(ctx, c, k, t)
	}, true},
	{"Block", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Block(ctx, c, k, t)
	}, false},
	{"Unblock", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Unblock(ctx, c, k, t)
	}, true},
	{"Mute", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Mute(ctx, c, k, t)
	}, false},
	{"Unmute", func(ctx context.Context, w wired, c, k, t string) (graph.Relationship, error) {
		return w.graph.Unmute(ctx, c, k, t)
	}, true},
}

func must(t *testing.T, what string, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
}

// ---------------------------------------------------------------------------------------------------------
// Happy paths and budgets (worst + typical) for all six RPCs.
// ---------------------------------------------------------------------------------------------------------

func TestT16a_Follow_WarmTypicalAndReplayBudgets(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")

	warmProfiles(t, w, "uid-a", "uid-b", "uid-c")
	measured(t, "Follow (typical, warm)", budFollowTypical, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b")
		must(t, "Follow", err)
		if rel.FollowState != graph.FollowStateFollowing || rel.Blocking || rel.Muting {
			t.Errorf("rel = %+v, want FOLLOWING", rel)
		}
	})

	// Replay (same key) right after a create: Follow evicted both profiles, so this replay is cold (worst).
	measured(t, "Follow (replay, same key, cold)", budFollowReplayCld, func(ctx context.Context) {
		rel, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b")
		must(t, "Follow replay", err)
		if rel.FollowState != graph.FollowStateFollowing {
			t.Errorf("rel = %+v", rel)
		}
	})
	// The cold replay repopulated the cache (replays don't evict): now the documented 2R / 0W typical replay.
	measured(t, "Follow (replay, new key, warm)", budFollowReplay, func(ctx context.Context) {
		if _, err := w.graph.Follow(ctx, "uid-a", key2, "uid-b"); err != nil {
			t.Fatalf("Follow replay: %v", err)
		}
	})

	// Following a second account keeps the same budget (no N+1 in the number of existing edges).
	warmProfiles(t, w, "uid-a", "uid-c")
	measured(t, "Follow (typical, 2nd target)", budFollowTypical, func(ctx context.Context) {
		if _, err := w.graph.Follow(ctx, "uid-a", key3, "uid-c"); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	})
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 2 {
		t.Errorf("quotas.follows = %d, want 2 (replays must not reserve quota)", got)
	}
}

// TestT16a_Follow_ColdWorstBudget: with identity's profile cache empty, Follow pays the 2-doc directory read on
// top of graph + quota (4 reads), and quotas are configuration (withQuotas), not constants.
func TestT16a_Follow_ColdWorstBudget_AndConfigurableQuota(t *testing.T) {
	w := newWired(t, withNewAccountWindow(1), withQuotas(2, 1, 2, 1))
	for _, u := range []string{"a", "b", "c", "d"} {
		mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
	}
	w.identity.(interface{ Forget(...string) }).Forget("uid-a", "uid-b")
	measured(t, "Follow (worst: cold identity cache)", budFollowWorstCold, func(ctx context.Context) {
		if _, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	})
	if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-c"); err != nil {
		t.Fatal(err)
	}
	_, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-d")
	requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "follows")
}

// TestT16a_SeedFixtures_ConsistentAndUsable proves the shared seeding fixtures (used by T16b) produce states
// the checker accepts and the RPCs can operate on, at the documented budgets.
func TestT16a_SeedFixtures_ConsistentAndUsable(t *testing.T) {
	w := newWired(t)
	for _, u := range []string{"a", "b", "c", "d"} {
		mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
	}
	seedFollow(t, w, "uid-a", "uid-b", time.Now().UTC())
	seedFollow(t, w, "uid-b", "uid-a", time.Now().UTC())
	seedBlock(t, w.client, "uid-c", "uid-d")
	assertGraphInvariants(t, w.client)
	measured(t, "Unfollow (seeded edge)", budUnfollow, func(ctx context.Context) {
		if _, err := w.graph.Unfollow(ctx, "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("Unfollow: %v", err)
		}
	})
	measured(t, "Block (seeded one-way follow)", budBlockWorst, func(ctx context.Context) {
		if _, err := w.graph.Block(ctx, "uid-a", key2, "uid-b"); err != nil {
			t.Fatalf("Block: %v", err)
		}
	})
	measured(t, "Unblock (seeded block)", budUnblock, func(ctx context.Context) {
		if _, err := w.graph.Unblock(ctx, "uid-c", key3, "uid-d"); err != nil {
			t.Fatalf("Unblock: %v", err)
		}
	})
}

func TestT16a_Unfollow_Budgets(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	_, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b")
	must(t, "Follow", err)

	measured(t, "Unfollow", budUnfollow, func(ctx context.Context) {
		rel, err := w.graph.Unfollow(ctx, "uid-a", key2, "uid-b")
		must(t, "Unfollow", err)
		if rel.FollowState != graph.FollowStateNone {
			t.Errorf("rel = %+v, want NONE", rel)
		}
	})
	measured(t, "Unfollow (no-op replay, same key)", budUnfollowNoop, func(ctx context.Context) {
		_, err := w.graph.Unfollow(ctx, "uid-a", key2, "uid-b")
		must(t, "Unfollow replay", err)
	})
	measured(t, "Unfollow (never followed, new key)", budUnfollowNoop, func(ctx context.Context) {
		_, err := w.graph.Unfollow(ctx, "uid-a", key3, "uid-b")
		must(t, "Unfollow never-followed", err)
	})
	// A no-op must not disturb the (already zero) counters; the end-of-test sweep proves it stays consistent.
}

func TestT16a_Block_WorstAndTypicalBudgets(t *testing.T) {
	w := newWired(t)
	for _, u := range []string{"a", "b", "c"} {
		mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
	}
	// Worst: mutual follow, both edges deleted, combined counter updates.
	ctx0 := context.Background()
	_, err := w.graph.Follow(ctx0, "uid-a", key1, "uid-b")
	must(t, "a follows b", err)
	_, err = w.graph.Follow(ctx0, "uid-b", key1, "uid-a")
	must(t, "b follows a", err)

	measured(t, "Block (worst: mutual follow)", budBlockWorst, func(ctx context.Context) {
		rel, err := w.graph.Block(ctx, "uid-a", key2, "uid-b")
		must(t, "Block", err)
		if !rel.Blocking || rel.FollowState != graph.FollowStateNone {
			t.Errorf("rel = %+v", rel)
		}
	})
	measured(t, "Block (replay, same key)", budBlockReplay, func(ctx context.Context) {
		rel, err := w.graph.Block(ctx, "uid-a", key2, "uid-b")
		must(t, "Block replay", err)
		if !rel.Blocking {
			t.Errorf("rel = %+v, want blocking", rel)
		}
	})
	measured(t, "Block (replay, new key)", budBlockReplay, func(ctx context.Context) {
		if _, err := w.graph.Block(ctx, "uid-a", key3, "uid-b"); err != nil {
			t.Fatalf("Block replay: %v", err)
		}
	})
	measured(t, "Block (typical: no edges)", budBlockTypical, func(ctx context.Context) {
		if _, err := w.graph.Block(ctx, "uid-a", key1, "uid-c"); err != nil {
			t.Fatalf("Block: %v", err)
		}
	})
	if got := quotaUsed(t, w.client, "uid-a", istDay(0), "blocks"); got != 2 {
		t.Errorf("quotas.blocks = %d, want 2 (the replays must not reserve quota)", got)
	}
}

func TestT16a_UnblockMuteUnmute_Budgets(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	_, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b")
	must(t, "Block", err)

	measured(t, "Unblock", budUnblock, func(ctx context.Context) {
		rel, err := w.graph.Unblock(ctx, "uid-a", key2, "uid-b")
		must(t, "Unblock", err)
		if rel.Blocking {
			t.Errorf("rel = %+v, want not blocking", rel)
		}
	})
	measured(t, "Unblock (no-op, same key)", budUnblockNoop, func(ctx context.Context) {
		_, err := w.graph.Unblock(ctx, "uid-a", key2, "uid-b")
		must(t, "Unblock replay", err)
	})
	measured(t, "Unblock (no-op, new key)", budUnblockNoop, func(ctx context.Context) {
		_, err := w.graph.Unblock(ctx, "uid-a", key3, "uid-b")
		must(t, "Unblock replay", err)
	})

	measured(t, "Mute", budMute, func(ctx context.Context) {
		rel, err := w.graph.Mute(ctx, "uid-a", key1, "uid-c")
		must(t, "Mute", err)
		if !rel.Muting {
			t.Errorf("rel = %+v, want muting", rel)
		}
	})
	measured(t, "Mute (replay, same key)", budMuteReplay, func(ctx context.Context) {
		_, err := w.graph.Mute(ctx, "uid-a", key1, "uid-c")
		must(t, "Mute replay", err)
	})
	measured(t, "Mute (replay, new key)", budMuteReplay, func(ctx context.Context) {
		_, err := w.graph.Mute(ctx, "uid-a", key2, "uid-c")
		must(t, "Mute replay", err)
	})
	measured(t, "Unmute", budUnmute, func(ctx context.Context) {
		rel, err := w.graph.Unmute(ctx, "uid-a", key3, "uid-c")
		must(t, "Unmute", err)
		if rel.Muting {
			t.Errorf("rel = %+v, want not muting", rel)
		}
	})
	measured(t, "Unmute (no-op, same key)", budUnmuteNoop, func(ctx context.Context) {
		_, err := w.graph.Unmute(ctx, "uid-a", key3, "uid-c")
		must(t, "Unmute replay", err)
	})
	measured(t, "Unmute (no-op, new key)", budUnmuteNoop, func(ctx context.Context) {
		_, err := w.graph.Unmute(ctx, "uid-a", key1, "uid-c")
		must(t, "Unmute replay", err)
	})
}

// TestT16a_Follow_OverflowedCaller_WorstBudget: worst-case Follow (an overflowed caller) is 5 reads and the
// follow still succeeds when nobody blocked them, so the +1 read is the only cost of the fail-closed rule.
func TestT16a_Follow_OverflowedCaller_WorstBudget(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"blockedByOverflow": true})

	measured(t, "Follow (worst: overflowed caller)", budFollowOverflow, func(ctx context.Context) {
		if _, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	})
}

// ---------------------------------------------------------------------------------------------------------
// Every documented ErrorReason, per RPC.
// ---------------------------------------------------------------------------------------------------------

// TestT16a_ErrorReasons_AllRPCs: input validation, self-target and feature-flag rejections for all six RPCs,
// each costing 0 Firestore operations.
func TestT16a_ErrorReasons_AllRPCs(t *testing.T) {
	for _, m := range allMutations {
		m := m
		t.Run(m.name, func(t *testing.T) {
			w := newWired(t)
			mustCreateProfile(t, w.identity, "uid-a", "usera")
			mustCreateProfile(t, w.identity, "uid-b", "userb")

			t.Run("bad idempotency key", func(t *testing.T) {
				measured(t, m.name+" (bad key)", budRejectedNoIO, func(ctx context.Context) {
					_, err := m.call(ctx, w, "uid-a", "short", "uid-b")
					requireAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "idempotency_key")
				})
			})
			t.Run("bad user id", func(t *testing.T) {
				measured(t, m.name+" (bad user_id)", budRejectedNoIO, func(ctx context.Context) {
					_, err := m.call(ctx, w, "uid-a", key1, "not a valid id!")
					requireAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "user_id")
				})
			})
			t.Run("empty user id", func(t *testing.T) {
				measured(t, m.name+" (empty user_id)", budRejectedNoIO, func(ctx context.Context) {
					_, err := m.call(ctx, w, "uid-a", key1, "")
					requireAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "user_id")
				})
			})
			t.Run("self target", func(t *testing.T) {
				measured(t, m.name+" (self)", budRejectedNoIO, func(ctx context.Context) {
					rel, err := m.call(ctx, w, "uid-a", key1, "uid-a")
					if m.selfIsNoop {
						if err != nil || rel.FollowState != graph.FollowStateNone || rel.Blocking || rel.Muting {
							t.Errorf("%s(self) = %+v, %v; want NONE no-op", m.name, rel, err)
						}
						return
					}
					requireAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "user_id")
				})
			})
		})
	}

	// FEATURE_DISABLED: flag off => FAILED_PRECONDITION before any Firestore access, for every RPC.
	for _, m := range allMutations {
		m := m
		t.Run(m.name+"/feature flag off", func(t *testing.T) {
			w := newWired(t, withFlags(flagsOff{}))
			mustCreateProfile(t, w.identity, "uid-a", "usera")
			mustCreateProfile(t, w.identity, "uid-b", "userb")
			measured(t, m.name+" (flag off)", budRejectedNoIO, func(ctx context.Context) {
				_, err := m.call(ctx, w, "uid-a", key1, "uid-b")
				requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "", "")
			})
		})
	}
}

// TestT16a_IdempotencyKeyIsNotStored: ADR-0008 "Idempotency": keys are format-validated only; reusing one key
// for a different target is legitimate (state-setting RPCs), so IDEMPOTENCY_KEY_REUSED never occurs.
func TestT16a_IdempotencyKeyReusedAcrossTargets_IsAllowed(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	for _, target := range []string{"uid-b", "uid-c"} {
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, target); err != nil {
			t.Fatalf("Follow(%s) with a reused key: %v", target, err)
		}
	}
}

func TestT16a_Follow_ErrorReasons(t *testing.T) {
	t.Run("missing target is NOT_FOUND", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		_, err := w.graph.Follow(context.Background(), "uid-a", key1, "ghost")
		requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	})

	t.Run("non-ACTIVE target is NOT_FOUND", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedUserField(t, w, "uid-b", "status", "DELETING")
		_, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b")
		requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	})

	t.Run("blocked-by is byte-identical to a missing user, 0 writes", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil { // b blocks a
			t.Fatal(err)
		}
		var missing, blocked *apierr.Error
		measured(t, "Follow (blocked-by)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-a", key2, "uid-b")
			requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
			blocked = err.(*apierr.Error)
		})
		_, err := w.graph.Follow(context.Background(), "uid-a", key2, "ghost")
		missing = err.(*apierr.Error)
		if missing.Code != blocked.Code || missing.Reason != blocked.Reason || missing.Message != blocked.Message ||
			len(missing.Metadata) != len(blocked.Metadata) {
			t.Errorf("blocked-by error %+v differs from missing-user error %+v (existence leak, ADR-0008 D9)", blocked, missing)
		}
	})

	t.Run("caller blocks target is TARGET_BLOCKED, no auto-unblock", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatal(err)
		}
		_, err := w.graph.Follow(context.Background(), "uid-a", key2, "uid-b")
		requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED, "", "")
		if a := graphArrays(t, w.client, "uid-a"); !contains(a["blocked"], "uid-b") {
			t.Errorf("Follow must not auto-unblock: a = %v", a)
		}
	})

	t.Run("legacy private target is FEATURE_DISABLED", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedUserField(t, w, "uid-b", "isPrivate", true)
		measured(t, "Follow (private target)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "", "")
		})
	})

	t.Run("following cap 5,000: 4,999 ok then LIMIT_REACHED", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"following": padUIDs(4999)})
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 5,000th follow must succeed: %v", err)
		}
		measured(t, "Follow (at cap)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "following")
		})
		// A replay of an existing edge at the cap still succeeds (replay precedes the cap check).
		if _, err := w.graph.Follow(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("replay at the cap must succeed: %v", err)
		}
		// Unfollowing frees a slot.
		if _, err := w.graph.Unfollow(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Fatal(err)
		}
		if _, err := w.graph.Follow(context.Background(), "uid-a", key3, "uid-c"); err != nil {
			t.Errorf("follow after freeing a slot: %v", err)
		}
	})

	t.Run("precedence: blocked-by beats quota and cap", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
			t.Fatal(err)
		}
		seedQuota(t, w.client, "uid-a", istDay(0), "follows", 50)
		_, err := w.graph.Follow(context.Background(), "uid-a", key2, "uid-b")
		requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	})
}

func TestT16a_Block_ErrorReasons(t *testing.T) {
	t.Run("missing target is NOT_FOUND", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		_, err := w.graph.Block(context.Background(), "uid-a", key1, "ghost")
		requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	})

	t.Run("blocked cap 2,000: 1,999 ok then LIMIT_REACHED", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"blocked": padUIDs(1999)})
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 2,000th block must succeed: %v", err)
		}
		measured(t, "Block (at cap)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Block(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "blocked")
		})
		// Replay at the cap still succeeds; Unblock frees a slot.
		if _, err := w.graph.Block(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("replay at the cap must succeed: %v", err)
		}
		if _, err := w.graph.Unblock(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Fatal(err)
		}
		if _, err := w.graph.Block(context.Background(), "uid-a", key3, "uid-c"); err != nil {
			t.Errorf("block after freeing a slot: %v", err)
		}
	})

	t.Run("blockedBy cap 10,000: 9,999 grows normally, at the cap sets overflow and fails closed", func(t *testing.T) {
		w := newWired(t)
		for _, u := range []string{"a", "b", "c"} {
			mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
		}
		// b already has 9,999 blockers: a's block lands normally and fills the array to exactly 10,000.
		seedGraphArrays(t, w.client, "uid-b", map[string]interface{}{"blockedBy": padUIDs(9999)})
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("Block at 9,999 blockedBy: %v", err)
		}
		gb := graphArrays(t, w.client, "uid-b")
		if len(gb["blockedBy"]) != 10000 || !contains(gb["blockedBy"], "uid-a") {
			t.Fatalf("blockedBy len = %d (contains a: %v), want 10,000 including a", len(gb["blockedBy"]), contains(gb["blockedBy"], "uid-a"))
		}
		if v, _ := mustGraphDoc(t, w, "uid-b").DataAt("blockedByOverflow"); v == true {
			t.Errorf("overflow flag set one entry early")
		}

		// Now at the cap: c's block records c.blocked, skips blockedBy, sets the overflow flag.
		measured(t, "Block (target blockedBy at cap)", budBlockTypical, func(ctx context.Context) {
			if _, err := w.graph.Block(ctx, "uid-c", key2, "uid-b"); err != nil {
				t.Fatalf("Block at blockedBy cap: %v", err)
			}
		})
		gb = graphArrays(t, w.client, "uid-b")
		if len(gb["blockedBy"]) != 10000 || contains(gb["blockedBy"], "uid-c") {
			t.Errorf("blockedBy must not grow past its cap; len = %d", len(gb["blockedBy"]))
		}
		if v, _ := mustGraphDoc(t, w, "uid-b").DataAt("blockedByOverflow"); v != true {
			t.Errorf("blockedByOverflow = %v, want true", v)
		}

		// Fail-closed: b (overflowed) can still not follow c even though c is not in b.blockedBy.
		measured(t, "Follow (overflowed caller blocked by target)", budFollowOverflow, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-b", key3, "uid-c")
			requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
		})
		// Unblock removes the entry normally but never clears the overflow flag.
		if _, err := w.graph.Unblock(context.Background(), "uid-c", key3, "uid-b"); err != nil {
			t.Fatal(err)
		}
		if v, _ := mustGraphDoc(t, w, "uid-b").DataAt("blockedByOverflow"); v != true {
			t.Errorf("Unblock must not clear blockedByOverflow (moderation clears it), got %v", v)
		}
	})

	t.Run("mutual blocks are both recorded", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		for _, p := range [][2]string{{"uid-a", "uid-b"}, {"uid-b", "uid-a"}} {
			if _, err := w.graph.Block(context.Background(), p[0], key1, p[1]); err != nil {
				t.Fatalf("Block %s -> %s: %v", p[0], p[1], err)
			}
		}
		if _, err := w.graph.Unblock(context.Background(), "uid-a", key2, "uid-b"); err != nil {
			t.Fatal(err)
		}
		if b := graphArrays(t, w.client, "uid-b"); !contains(b["blocked"], "uid-a") {
			t.Errorf("b's block of a must survive a's Unblock: %v", b)
		}
	})

	t.Run("block keeps an existing mute and reports it", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatal(err)
		}
		rel, err := w.graph.Block(context.Background(), "uid-a", key2, "uid-b")
		must(t, "Block", err)
		if !rel.Blocking || !rel.Muting {
			t.Errorf("rel = %+v, want blocking and muting (ADR-0008 D9: mute kept)", rel)
		}
	})
}

func mustGraphDoc(t *testing.T, w wired, uid string) interface {
	DataAt(string) (interface{}, error)
} {
	t.Helper()
	snap, err := w.client.Collection("graph").Doc(uid).Get(context.Background())
	if err != nil {
		t.Fatalf("get graph/%s: %v", uid, err)
	}
	return snap
}

func TestT16a_Mute_ErrorReasonsAndSemantics(t *testing.T) {
	t.Run("muted cap 2,000: 1,999 ok then LIMIT_REACHED", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"muted": padUIDs(1999)})
		if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 2,000th mute must succeed: %v", err)
		}
		measured(t, "Mute (at cap)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Mute(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "muted")
		})
		if _, err := w.graph.Mute(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("replay at the cap must succeed: %v", err)
		}
	})

	t.Run("muting someone who blocked you is allowed and leaks nothing", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil { // b blocks a
			t.Fatal(err)
		}
		relB, err := w.graph.Mute(context.Background(), "uid-a", key2, "uid-b")
		must(t, "Mute(blocker)", err)
		relC, err := w.graph.Mute(context.Background(), "uid-a", key2, "uid-c")
		must(t, "Mute(stranger)", err)
		if relB.FollowState != relC.FollowState || relB.Blocking != relC.Blocking || relB.Muting != relC.Muting {
			t.Errorf("mute result for a user who blocked the caller %+v differs from a stranger %+v", relB, relC)
		}
	})

	t.Run("mute is silent: target graph untouched", func(t *testing.T) {
		w := newWired(t)
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		before := graphArrays(t, w.client, "uid-b")
		if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatal(err)
		}
		after := graphArrays(t, w.client, "uid-b")
		if fmt.Sprint(before) != fmt.Sprint(after) {
			t.Errorf("target graph changed by Mute: before %v after %v", before, after)
		}
	})
}

// TestT16a_Unblock_DoesNotRestoreFollows and Unfollow-vs-block semantics from the ADR-0008 D9 table.
func TestT16a_BlockThenFollowAndUnfollowSemantics(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx := context.Background()
	_, err := w.graph.Follow(ctx, "uid-a", key1, "uid-b")
	must(t, "Follow", err)
	_, err = w.graph.Block(ctx, "uid-a", key2, "uid-b")
	must(t, "Block", err)

	// Unfollow after Block: NONE, 0 writes (the block already removed the edge).
	measured(t, "Unfollow (after block)", budUnfollowNoop, func(ctx context.Context) {
		rel, err := w.graph.Unfollow(ctx, "uid-a", key3, "uid-b")
		must(t, "Unfollow", err)
		if rel.FollowState != graph.FollowStateNone {
			t.Errorf("rel = %+v", rel)
		}
	})
	// Unblock does not restore the follow.
	rel, err := w.graph.Unblock(ctx, "uid-a", key3, "uid-b")
	must(t, "Unblock", err)
	if rel.FollowState != graph.FollowStateNone {
		t.Errorf("Unblock restored a follow: %+v", rel)
	}
	if docExists(t, w.client, "follows/uid-a_uid-b") {
		t.Error("follows/uid-a_uid-b must stay deleted after Unblock")
	}
}

// ---------------------------------------------------------------------------------------------------------
// Quotas: exhaustion, IST-midnight rollover, new-account tiers.
// ---------------------------------------------------------------------------------------------------------

func TestT16a_Quota_Follows(t *testing.T) {
	// An established account (window shrunk to 1ns: no clock seam needed) gets the standard 200/day tier.
	t.Run("exhausted at 200 (established)", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		seedQuota(t, w.client, "uid-a", istDay(0), "follows", 199)
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 200th follow of the day must succeed: %v", err)
		}
		measured(t, "Follow (quota exhausted)", budgettest.Budget{Reads: 4, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Follow(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "follows")
		})
		// Replay of an existing edge reserves nothing, so it works even when exhausted.
		if _, err := w.graph.Follow(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("replay while exhausted must succeed: %v", err)
		}
		// Unfollow is never quota-gated.
		if _, err := w.graph.Unfollow(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("Unfollow must never be quota-gated: %v", err)
		}
		if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 200 {
			t.Errorf("quotas.follows = %d, want 200 (rejections and replays reserve nothing)", got)
		}
	})

	t.Run("IST-midnight rollover resets the counter", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedQuota(t, w.client, "uid-a", istDay(-1), "follows", 200) // yesterday, fully used
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("a new IST day must reset the quota: %v", err)
		}
		if got := quotaUsed(t, w.client, "uid-a", istDay(0), "follows"); got != 1 {
			t.Errorf("after rollover quotas.follows for today = %d, want 1", got)
		}
	})

	t.Run("new account limited to 50", func(t *testing.T) {
		w := newWired(t) // default 24h window: fresh profiles are new accounts
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		mustCreateProfile(t, w.identity, "uid-c", "userc")
		seedQuota(t, w.client, "uid-a", istDay(0), "follows", 49)
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 50th follow must succeed: %v", err)
		}
		_, err := w.graph.Follow(context.Background(), "uid-a", key2, "uid-c")
		requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "follows")
	})

	t.Run("established account is not held to the new-account 50", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedQuota(t, w.client, "uid-a", istDay(0), "follows", 50)
		if _, err := w.graph.Follow(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Errorf("established account at 50 follows must still succeed: %v", err)
		}
	})
}

func TestT16a_Quota_BlocksAndMutesShareOneCounter(t *testing.T) {
	t.Run("established: 200 shared, Unblock/Unmute never gated", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		for _, u := range []string{"a", "b", "c", "d"} {
			mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
		}
		if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-d"); err != nil { // uses 1
			t.Fatal(err)
		}
		seedQuota(t, w.client, "uid-a", istDay(0), "blocks", 199)
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 200th block/mute of the day must succeed: %v", err)
		}
		measured(t, "Mute (quota exhausted)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Mute(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "blocks")
		})
		measured(t, "Block (quota exhausted)", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
			_, err := w.graph.Block(ctx, "uid-a", key2, "uid-c")
			requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "blocks")
		})
		// Replays reserve nothing.
		if _, err := w.graph.Block(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("Block replay while exhausted: %v", err)
		}
		if _, err := w.graph.Mute(context.Background(), "uid-a", key3, "uid-d"); err != nil {
			t.Errorf("Mute replay while exhausted: %v", err)
		}
		// Never gated.
		if _, err := w.graph.Unblock(context.Background(), "uid-a", key3, "uid-b"); err != nil {
			t.Errorf("Unblock gated: %v", err)
		}
		if _, err := w.graph.Unmute(context.Background(), "uid-a", key3, "uid-d"); err != nil {
			t.Errorf("Unmute gated: %v", err)
		}
	})

	t.Run("IST-midnight rollover", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedQuota(t, w.client, "uid-a", istDay(-1), "blocks", 200)
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("Block after rollover: %v", err)
		}
		if got := quotaUsed(t, w.client, "uid-a", istDay(0), "blocks"); got != 1 {
			t.Errorf("quotas.blocks for today = %d, want 1", got)
		}
	})

	t.Run("new account limited to 50 (Block and Mute)", func(t *testing.T) {
		w := newWired(t)
		for _, u := range []string{"a", "b", "c"} {
			mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
		}
		seedQuota(t, w.client, "uid-a", istDay(0), "blocks", 49)
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Fatalf("the 50th block must succeed: %v", err)
		}
		_, err := w.graph.Mute(context.Background(), "uid-a", key2, "uid-c")
		requireAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "blocks")
	})

	t.Run("established account is not held to the new-account 50", func(t *testing.T) {
		w := newWired(t, withNewAccountWindow(1))
		mustCreateProfile(t, w.identity, "uid-a", "usera")
		mustCreateProfile(t, w.identity, "uid-b", "userb")
		seedQuota(t, w.client, "uid-a", istDay(0), "blocks", 50)
		if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
			t.Errorf("established account at 50 blocks must still succeed: %v", err)
		}
	})
}

// ---------------------------------------------------------------------------------------------------------
// Races against the emulator. Each iteration uses a fresh user pair and sweeps the invariants afterwards.
// ---------------------------------------------------------------------------------------------------------

func isAPIErr(err error, code connect.Code, reason commonv1.ErrorReason) bool {
	ae, ok := err.(*apierr.Error)
	return ok && ae.Code == code && ae.Reason == reason
}

func TestT16a_Race_ConcurrentDuplicateFollows(t *testing.T) {
	w := newWired(t, withNewAccountWindow(1))
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	const n = 12
	for name, keyFor := range map[string]func(i int) string{
		"same key":      func(int) string { return key1 },
		"distinct keys": func(i int) string { return fmt.Sprintf("%016d", i) },
	} {
		t.Run(name, func(t *testing.T) {
			// Fresh pair per subtest so the assertions are absolute.
			a, b := "uid-a-"+name[:4], "uid-b-"+name[:4]
			mustCreateProfile(t, w.identity, a, "ua"+name[:4])
			mustCreateProfile(t, w.identity, b, "ub"+name[:4])
			errs := runConcurrently(n, func(i int) error {
				_, err := w.graph.Follow(context.Background(), a, keyFor(i), b)
				return err
			})
			for i, err := range errs {
				if err != nil {
					t.Errorf("Follow goroutine %d: %v", i, err)
				}
			}
			if !docExists(t, w.client, "follows/"+a+"_"+b) {
				t.Error("edge missing after concurrent follows")
			}
			if got := quotaUsed(t, w.client, a, istDay(0), "follows"); got != 1 {
				t.Errorf("quotas.follows = %d, want exactly 1 (a duplicate must not reserve quota twice)", got)
			}
			assertGraphInvariants(t, w.client) // counters = 1/1, no double increment
		})
	}
}

func TestT16a_Race_ConcurrentDuplicateBlocksAndMutes(t *testing.T) {
	w := newWired(t, withNewAccountWindow(1))
	// A double-click or client retry is 2-3 duplicates; 12 per kind piles more onto one pair of docs than
	// the emulator's lock timeout tolerates (in CI nearly every call timed out).
	const n = 3
	// Racing on the emulator can legitimately make every call of one kind answer with the retryable
	// UNAVAILABLE (ADR-0008 D1: exhausted retries). Such a phase proves nothing about concurrency, so it is
	// retried ONCE on a fresh pair; a second all-UNAVAILABLE kind fails the test instead of being papered
	// over by a sequential replay that would create the entry uncontended.
	const maxPhases = 2
	var a, b string
	for phase := 0; phase < maxPhases; phase++ {
		a, b = fmt.Sprintf("uid-a%d", phase), fmt.Sprintf("uid-b%d", phase)
		mustCreateProfile(t, w.identity, a, fmt.Sprintf("usera%d", phase))
		mustCreateProfile(t, w.identity, b, fmt.Sprintf("userb%d", phase))
		errs := runConcurrently(2*n, func(i int) error {
			if i%2 == 0 {
				_, err := w.graph.Block(context.Background(), a, fmt.Sprintf("%016d", i), b)
				return err
			}
			_, err := w.graph.Mute(context.Background(), a, fmt.Sprintf("%016d", i), b)
			return err
		})
		// Calls contend on the same two graph docs; UNAVAILABLE is a correct outcome, any other error is not.
		var blockOK, muteOK int
		for i, err := range errs {
			if err == nil {
				if i%2 == 0 {
					blockOK++
				} else {
					muteOK++
				}
				continue
			}
			var ae *apierr.Error
			if errors.As(err, &ae) && ae.Code == connect.CodeUnavailable {
				t.Logf("phase %d goroutine %d: retryable UNAVAILABLE after exhausted retries: %v", phase, i, err)
				continue
			}
			t.Errorf("phase %d goroutine %d: %v", phase, i, err)
		}
		if blockOK > 0 && muteOK > 0 {
			break
		}
		if phase == maxPhases-1 {
			t.Fatalf("concurrent phase never succeeded for every kind in %d attempts (last: Block %d/%d, Mute %d/%d ok); "+
				"the test cannot prove duplicate handling under contention", maxPhases, blockOK, n, muteOK, n)
		}
		t.Logf("phase %d: Block %d/%d, Mute %d/%d succeeded; retrying once on a fresh pair", phase, blockOK, n, muteOK, n)
	}
	// Assert on the concurrent phase alone, BEFORE any further call: Block and Mute share one counter, so the
	// n duplicates of each kind must have reserved exactly two quota units (one Block, one Mute), never 2n.
	if got := quotaUsed(t, w.client, a, istDay(0), "blocks"); got != 2 {
		t.Errorf("after the concurrent phase quotas.blocks = %d, want exactly 2", got)
	}
	as, bs := graphArrays(t, w.client, a), graphArrays(t, w.client, b)
	if len(as["blocked"]) != 1 || len(as["muted"]) != 1 || len(bs["blockedBy"]) != 1 {
		t.Errorf("after the concurrent phase a = %v, b = %v; want exactly one blocked/muted/blockedBy entry", as, bs)
	}
	// Idempotency replay (not part of the race): repeating each op with fresh keys is a no-op that neither
	// changes state nor reserves quota again.
	if _, err := w.graph.Block(context.Background(), a, fmt.Sprintf("%016d", 100), b); err != nil {
		t.Errorf("idempotency replay Block: %v", err)
	}
	if _, err := w.graph.Mute(context.Background(), a, fmt.Sprintf("%016d", 101), b); err != nil {
		t.Errorf("idempotency replay Mute: %v", err)
	}
	if got := quotaUsed(t, w.client, a, istDay(0), "blocks"); got != 2 {
		t.Errorf("after the replay quotas.blocks = %d, want still 2", got)
	}
	as, bs = graphArrays(t, w.client, a), graphArrays(t, w.client, b)
	if len(as["blocked"]) != 1 || len(as["muted"]) != 1 || len(bs["blockedBy"]) != 1 {
		t.Errorf("after the replay a = %v, b = %v; want exactly one blocked/muted/blockedBy entry", as, bs)
	}
}

// TestT16a_Race_FollowVsBlock covers all four pairings of (Follow direction) x (Block direction) plus the
// Unfollow-vs-Block pairings. Whatever order Firestore serializes them in, every outcome must satisfy the
// invariants and the block must win (no edge survives, blocker records the block).
func TestT16a_Race_FollowAndUnfollowVsBlock(t *testing.T) {
	const iterations = 4
	w := newWired(t, withNewAccountWindow(1))
	users := mustCreateUsers(t, w.identity, "r", 2*iterations*5)
	next := 0
	pair := func() (a, b string) { a, b = users[next], users[next+1]; next += 2; return }
	ctx := context.Background()

	cases := []struct {
		name string
		// setup runs before the race; run returns the errors of the racing calls.
		setup func(a, b string)
		race  func(a, b string) (blocker, blocked string, errs []error)
		// okErr reports whether err is an acceptable outcome for the racing call at index i.
		okErr func(i int, err error) bool
	}{
		{
			name:  "Follow(a->b) vs Block(a->b)",
			setup: func(a, b string) {},
			race: func(a, b string) (string, string, []error) {
				return a, b, runConcurrently(2, func(i int) error {
					var err error
					if i == 0 {
						_, err = w.graph.Follow(ctx, a, key1, b)
					} else {
						_, err = w.graph.Block(ctx, a, key2, b)
					}
					return err
				})
			},
			okErr: func(i int, err error) bool {
				return err == nil || (i == 0 && isAPIErr(err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED))
			},
		},
		{
			name:  "Follow(a->b) vs Block(b->a)",
			setup: func(a, b string) {},
			race: func(a, b string) (string, string, []error) {
				return b, a, runConcurrently(2, func(i int) error {
					var err error
					if i == 0 {
						_, err = w.graph.Follow(ctx, a, key1, b)
					} else {
						_, err = w.graph.Block(ctx, b, key2, a)
					}
					return err
				})
			},
			okErr: func(i int, err error) bool {
				return err == nil || (i == 0 && isAPIErr(err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED))
			},
		},
		{
			name: "Unfollow(a->b) vs Block(a->b)",
			setup: func(a, b string) {
				_, err := w.graph.Follow(ctx, a, key3, b)
				must(t, "setup follow", err)
			},
			race: func(a, b string) (string, string, []error) {
				return a, b, runConcurrently(2, func(i int) error {
					var err error
					if i == 0 {
						_, err = w.graph.Unfollow(ctx, a, key1, b)
					} else {
						_, err = w.graph.Block(ctx, a, key2, b)
					}
					return err
				})
			},
			okErr: func(int, error) bool { return false }, // both must succeed
		},
		{
			name: "Unfollow(b->a) vs Block(a->b), mutual follow",
			setup: func(a, b string) {
				_, err := w.graph.Follow(ctx, a, key3, b)
				must(t, "setup follow a->b", err)
				_, err = w.graph.Follow(ctx, b, key3, a)
				must(t, "setup follow b->a", err)
			},
			race: func(a, b string) (string, string, []error) {
				return a, b, runConcurrently(2, func(i int) error {
					var err error
					if i == 0 {
						_, err = w.graph.Unfollow(ctx, b, key1, a)
					} else {
						_, err = w.graph.Block(ctx, a, key2, b)
					}
					return err
				})
			},
			okErr: func(int, error) bool { return false },
		},
		{
			name: "Unblock(a->b) vs Block(b->a)",
			setup: func(a, b string) {
				_, err := w.graph.Block(ctx, a, key3, b)
				must(t, "setup block", err)
			},
			race: func(a, b string) (string, string, []error) {
				return "", "", runConcurrently(2, func(i int) error {
					var err error
					if i == 0 {
						_, err = w.graph.Unblock(ctx, a, key1, b)
					} else {
						_, err = w.graph.Block(ctx, b, key2, a)
					}
					return err
				})
			},
			okErr: func(int, error) bool { return false },
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			for it := 0; it < iterations; it++ {
				a, b := pair()
				tc.setup(a, b)
				blocker, blocked, errs := tc.race(a, b)
				for i, err := range errs {
					if err != nil && !tc.okErr(i, err) {
						t.Errorf("iteration %d call %d: unexpected error %v", it, i, err)
					}
				}
				if blocker != "" {
					if g := graphArrays(t, w.client, blocker); !contains(g["blocked"], blocked) {
						t.Errorf("iteration %d: %s must have blocked %s: %v", it, blocker, blocked, g)
					}
				}
				assertGraphInvariants(t, w.client)
				if t.Failed() {
					return
				}
			}
		})
	}
}

// TestT16a_Race_FollowUnfollowFlapping is the like/unlike-style race: many interleaved Follow and Unfollow
// calls on one edge (with fresh keys) must leave counters equal to the surviving edge count.
func TestT16a_Race_FollowUnfollowFlapping(t *testing.T) {
	w := newWired(t, withNewAccountWindow(1))
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	errs := runConcurrently(8, func(i int) error {
		key := fmt.Sprintf("%016d", i)
		var err error
		if i%2 == 0 {
			_, err = w.graph.Follow(context.Background(), "uid-a", key, "uid-b")
		} else {
			_, err = w.graph.Unfollow(context.Background(), "uid-a", key, "uid-b")
		}
		return err
	})
	// D1 fixed: a lost lock race is retried, and if the (emulator's slow, coarse) locks still beat every retry
	// the call answers the documented retryable UNAVAILABLE. Anything else, INTERNAL above all, is a failure.
	for i, err := range errs {
		if err == nil {
			continue
		}
		var ae *apierr.Error
		if errors.As(err, &ae) && ae.Code == connect.CodeUnavailable {
			t.Logf("call %d: retryable UNAVAILABLE after exhausted retries: %v", i, err)
			continue
		}
		t.Errorf("call %d: %v", i, err)
	}
	assertGraphInvariants(t, w.client)
}

// ---------------------------------------------------------------------------------------------------------
// Degraded mode (DEGRADED_MODE=readonly) through the real Connect handler + degraded.Interceptor.
// ---------------------------------------------------------------------------------------------------------

func TestT16a_DegradedReadonly_RejectsEveryMutation(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	newClient := func(mode config.DegradedMode) graphv1connect.GraphServiceClient {
		injectUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
				return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
			}
		})
		path, handler := graphv1connect.NewGraphServiceHandler(graph.NewServer(w.graph.Service),
			connect.WithInterceptors(injectUID, degraded.Interceptor(mode, degraded.ProcedureSet{})))
		mux := http.NewServeMux()
		mux.Handle(path, handler)
		srv := httptest.NewServer(mux)
		t.Cleanup(srv.Close)
		return graphv1connect.NewGraphServiceClient(srv.Client(), srv.URL)
	}
	asA := func(req interface{ Header() http.Header }) { req.Header().Set("X-Test-Uid", "uid-a") }

	ro := newClient(config.DegradedReadonly)
	ctx := context.Background()
	calls := map[string]func() error{
		"Follow": func() error {
			r := connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Follow(ctx, r)
			return err
		},
		"Unfollow": func() error {
			r := connect.NewRequest(&graphv1.UnfollowRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Unfollow(ctx, r)
			return err
		},
		"Block": func() error {
			r := connect.NewRequest(&graphv1.BlockRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Block(ctx, r)
			return err
		},
		"Unblock": func() error {
			r := connect.NewRequest(&graphv1.UnblockRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Unblock(ctx, r)
			return err
		},
		"Mute": func() error {
			r := connect.NewRequest(&graphv1.MuteRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Mute(ctx, r)
			return err
		},
		"Unmute": func() error {
			r := connect.NewRequest(&graphv1.UnmuteRequest{IdempotencyKey: key1, UserId: "uid-b"})
			asA(r)
			_, err := ro.Unmute(ctx, r)
			return err
		},
		"RespondToFollowRequest": func() error {
			r := connect.NewRequest(&graphv1.RespondToFollowRequestRequest{IdempotencyKey: key1, RequesterUserId: "uid-b", Accept: true})
			asA(r)
			_, err := ro.RespondToFollowRequest(ctx, r)
			return err
		},
	}
	for name, call := range calls {
		err := call()
		var cerr *connect.Error
		if !asConnectErr(err, &cerr) || cerr.Code() != connect.CodeUnavailable {
			t.Errorf("%s in readonly mode = %v, want CodeUnavailable", name, err)
			continue
		}
		reason := commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED
		for _, d := range cerr.Details() {
			if msg, verr := d.Value(); verr == nil {
				if ed, ok := msg.(*commonv1.ErrorDetail); ok {
					reason = ed.Reason
				}
			}
		}
		if reason != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
			t.Errorf("%s in readonly mode: reason = %v, want DEGRADED_MODE", name, reason)
		}
	}

	// Nothing was written: no edge, no block, no mute, no quota doc.
	if docExists(t, w.client, "follows/uid-a_uid-b") || docExists(t, w.client, "quotas/uid-a") {
		t.Error("a rejected mutation left state behind")
	}
	if a := graphArrays(t, w.client, "uid-a"); len(a["blocked"])+len(a["muted"])+len(a["following"]) != 0 {
		t.Errorf("graph/uid-a changed in readonly mode: %v", a)
	}

	// Reads keep working in readonly mode, and the same stack with the switch off accepts the write.
	rr := connect.NewRequest(&graphv1.GetRelationshipsRequest{UserIds: []string{"uid-b"}})
	asA(rr)
	if _, err := ro.GetRelationships(ctx, rr); err != nil {
		t.Errorf("GetRelationships must keep working in readonly mode: %v", err)
	}
	off := newClient(config.DegradedOff)
	fr := connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: key1, UserId: "uid-b"})
	asA(fr)
	if _, err := off.Follow(ctx, fr); err != nil {
		t.Errorf("control: Follow with degraded mode off: %v", err)
	}
}

func asConnectErr(err error, target **connect.Error) bool {
	if err == nil {
		return false
	}
	ce, ok := err.(*connect.Error)
	if ok {
		*target = ce
	}
	return ok
}
