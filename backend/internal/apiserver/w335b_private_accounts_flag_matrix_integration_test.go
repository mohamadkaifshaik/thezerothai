//go:build integration

package apiserver

// W3-35b: the ADR-0025 D12 flag matrix for FEATURE_PRIVATE_ACCOUNTS (private_accounts) in the ten rollout states of
// TestW320_FlagModeMatrix (off, allowlist with the in user, with the out user, empty, percent 0, percent 0 plus the out
// user, percent 50, percent 50 plus the out user, percent 100, on), over the real Build chain.
//
// Two gate shapes (D12), asserted separately:
//
//	"on for the caller": UpdateProfile(is_private=true) and GetMe.enabled_features. Refused as FEATURE_DISABLED
//	    feature=private_accounts at exactly 0 reads, 0 writes and 0 deletes once the caller's account-status read is warm.
//	"not globally off, or the caller is protected now": ListFollowRequests and RespondToFollowRequest. A public caller is
//	    refused ONLY in mode off (an empty allowlist or percent 0 is a rollout, not the kill switch); a protected caller
//	    passes in all ten states.
//
// Never gated, checked in every state: Follow of a protected account answers REQUESTED, withdraw works, is_private=false
// (the owner of a protected account can unprotect even with the flag off), and a protected author's posts stay hidden from
// a stranger (the D3 predicate is not behind the flag). The privacy_public job, the eraser and the export are never
// gated either; graph's own suites run them with the flag lookups off (follow_requests_gate_test.go, privacy_public
// has no flag lookup at all), and the lifecycle suites do not consult the flag.
//
// Each rollout state draws fresh users (a toggle spends the 4 per day quota and the protected set is shared by the
// emulator project), and the per-state protected account is unprotected at the end of its state so the set does not grow.

import (
	"slices"
	"testing"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

func TestW335b_PrivateAccountsFlagMatrix(t *testing.T) {
	yes, no := true, false
	allOn := func(c *config.Config) {
		w320AllW3On(c)
		w328On(c)
		w320TabsOn(c)
		c.Quota.PrivacyTogglesPerDay = 100
	}
	setup := newW320Chain(t, allOn)

	for _, mc := range w320ModeCases() {
		t.Run(mc.name, func(t *testing.T) {
			g := w320DrawGatesFor(t, setup, []string{privateAccountsFeature})
			// Q is protected before the rollout state under test (the state a revision rolled back to inherits).
			q := setup.user(t)
			if _, err := setup.w320Update(q, &identityv1.UpdateProfileRequest{IsPrivate: &yes}); err != nil {
				t.Fatalf("protect Q: %v", err)
			}
			setup.post(t, q, "a post only Q's followers may read")

			r := newW320Chain(t, func(c *config.Config) {
				allOn(c)
				c.FeaturePrivateAccounts = mc.spec(privateAccountsFeature, g)
			})

			for _, side := range []struct {
				label string
				in    bool
				u     bmUser
			}{{"in", true, g.in[privateAccountsFeature]}, {"out", false, g.out[privateAccountsFeature]}} {
				u, on := side.u, mc.enabled(side.in)
				what := side.label + " user"

				// enabled_features is exact, and the same call warms the account-status read for the 0-read refusals.
				if listed := slices.Contains(r.w320Warm(t, u), privateAccountsFeature); listed != on {
					t.Errorf("%s: enabled_features lists %s = %v, want %v", what, privateAccountsFeature, listed, on)
				}

				// Never gated: a request to a protected account, its withdrawal, the stranger's view, is_private=false.
				r.w328Request(t, u, q.uid)
				if rel, err := r.w320Rel(u, q.uid); err != nil || rel.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_REQUESTED {
					t.Errorf("%s: relationship after the request = %v, %v, want REQUESTED", what, rel, err)
				}
				r.w320Unfollow(t, u, q.uid)
				if rel, err := r.w320Rel(u, q.uid); err != nil || rel.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_NONE {
					t.Errorf("%s: relationship after the withdraw = %v, %v, want NONE", what, rel, err)
				}
				if page, err := r.tabCall(u, q.uid, tabPostsPB, 20, "", ""); err != nil || !page.GetAuthorProtected() || len(page.GetPosts()) != 0 {
					t.Errorf("%s: stranger's view of Q's posts = %v, %v, want author_protected and no rows in every state", what, page, err)
				}
				if _, err := r.w320Update(u, &identityv1.UpdateProfileRequest{IsPrivate: &no}); err != nil {
					t.Errorf("%s: is_private=false = %v, want accepted in every state", what, err)
				}

				// Gate shape 1: UpdateProfile(is_private=true) follows "on for the caller".
				r.w320Warm(t, u)
				_, err := r.w320Update(u, &identityv1.UpdateProfileRequest{IsPrivate: &yes})
				if on {
					if err != nil {
						t.Fatalf("%s: protect with the flag on for the caller: %v", what, err)
					}
					// A protected caller passes the List/Respond gate in this state, and can always undo.
					if _, err := r.w328List(u); err != nil {
						t.Errorf("%s protected: ListFollowRequests: %v", what, err)
					}
					if _, err := r.w328Respond(u, q.uid, false); err != nil {
						t.Errorf("%s protected: RespondToFollowRequest: %v", what, err)
					}
					if _, err := r.w320Update(u, &identityv1.UpdateProfileRequest{IsPrivate: &no}); err != nil {
						t.Errorf("%s: unprotect after protecting: %v", what, err)
					}
				} else {
					w320Disabled(t, what+" UpdateProfile(is_private=true)", err, privateAccountsFeature)
					r.w320AssertNothing(t, what+" UpdateProfile(is_private=true) refused", rpcUpdateProfile)
					if me := r.w326bGetMe(t, u); me.GetProfile().GetIsPrivate() {
						t.Errorf("%s: a refused protect left the account protected", what)
					}
				}

				// Gate shape 2: a PUBLIC caller is refused only while the flag is off for everyone.
				r.w320Warm(t, u)
				_, listErr := r.w328List(u)
				if mc.offEverywhere {
					w320Disabled(t, what+" public ListFollowRequests", listErr, privateAccountsFeature)
					r.w320AssertNothing(t, what+" public ListFollowRequests refused", rpcListFollowRequests)
				} else if listErr != nil {
					t.Errorf("%s public ListFollowRequests = %v, want an empty page (a rollout is not the kill switch)", what, listErr)
				}
				r.w320Warm(t, u)
				_, respErr := r.w328Respond(u, q.uid, false)
				if mc.offEverywhere {
					w320Disabled(t, what+" public RespondToFollowRequest", respErr, privateAccountsFeature)
					r.w320AssertNothing(t, what+" public RespondToFollowRequest refused", rpcRespondToFollowReq)
				} else if respErr != nil {
					t.Errorf("%s public RespondToFollowRequest = %v, want a replay (nobody asked)", what, respErr)
				}
			}

			// A protected account is never stranded: Q lists, answers and unprotects in every state, flag off included.
			if _, err := r.w328List(q); err != nil {
				t.Errorf("protected Q: ListFollowRequests: %v", err)
			}
			if _, err := r.w328Respond(q, g.in[privateAccountsFeature].uid, false); err != nil {
				t.Errorf("protected Q: RespondToFollowRequest: %v", err)
			}
			if _, err := r.w320Update(q, &identityv1.UpdateProfileRequest{IsPrivate: &no}); err != nil {
				t.Errorf("protected Q: unprotect in this state: %v", err)
			}
			if me := r.w326bGetMe(t, q); me.GetProfile().GetIsPrivate() {
				t.Error("Q is still protected after is_private=false")
			}
			// And the refusal is not an unexpected code anywhere else: a gated call is never UNAUTHENTICATED or INTERNAL.
			if _, err := r.w328List(g.in[privateAccountsFeature]); err != nil && connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Errorf("a refused call must be FAILED_PRECONDITION, got %v", connect.CodeOf(err))
			}
		})
	}
}
