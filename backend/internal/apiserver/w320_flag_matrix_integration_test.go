//go:build integration

package apiserver

// W3-20: the flag-mode matrix of the four ADR-0024 D9 flags over the real Build chain (Firestore and Auth emulators):
// every mode (off, allowlist with a member and a non-member, an empty allowlist, percent 0, percent 50 on both sides of
// the bucket, percent 50 plus an allowlisted uid, percent 100, on) against every gated RPC of each flag, with a refusal
// asserted as FAILED_PRECONDITION + FEATURE_DISABLED with the right feature= metadata at EXACTLY 0 reads, 0 writes and 0
// deletes (the account-status read is warmed first with GetMe on the same chain), plus the companion-flag precedence
// (media before profile_extras, posts before likes_list, graph before follow_suggestions) and the ungated paths that
// must stay open. The percent bucket is recomputed here (fnv32a(name:uid) % 100) so the cohort is a checked contract.
//
// Already covered, not repeated: TestProfileGraphContract_FlagOff / _AllowlistCohort (off and allowlist for the three
// stub-era RPCs), TestProfileTabsChain_FlagModes (profile_tabs off and allowlist), TestProfileExtras_FlagGateAndKillSwitch
// (allowlist and the pin kill switch). This file adds percent, on, the empty and zero cells, every field kind and every
// companion cell, and the exact-zero cost.

import (
	"context"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	w320RPCCreateUpload  = "/dzeroth.media.v1.MediaService/CreateUpload"
	w320RPCListSuggested = "/dzeroth.graph.v1.GraphService/ListSuggestedUsers"
	w320RPCGetProfileRel = "/dzeroth.graph.v1.GraphService/GetProfileRelationship"
)

var w320FlagNames = []string{"profile_extras", "profile_tabs", "likes_list", "follow_suggestions"}

// w320Gates names the user the flag modes are checked for, per flag: in is on the low side of the 50% bucket, out on the
// high side.
type w320Gates struct {
	in, out map[string]bmUser
}

// w320DrawGates mints users until, for every W3 flag, one lies below and one at or above bucket 50. Users are created on
// the setup chain (every flag on) so each has a profile.
func w320DrawGates(t *testing.T, setup *w320Chain) w320Gates {
	t.Helper()
	g := w320Gates{in: map[string]bmUser{}, out: map[string]bmUser{}}
	complete := func() bool { return len(g.in) == len(w320FlagNames) && len(g.out) == len(w320FlagNames) }
	for i := 0; i < 200 && !complete(); i++ {
		u := setup.user(t)
		for _, f := range w320FlagNames {
			if w320Bucket(f, u.uid) < 50 {
				if _, ok := g.in[f]; !ok {
					g.in[f] = u
				}
			} else if _, ok := g.out[f]; !ok {
				g.out[f] = u
			}
		}
	}
	if !complete() {
		t.Fatal("could not draw a user on each side of the 50% bucket for every flag")
	}
	return g
}

// w320ModeCase is one rollout state applied to all four flags. spec builds the flag's Spec; enabled says whether the flag
// is on for the "in" or "out" user of that flag. offEverywhere marks the kill-switch mode (every caller refused).
type w320ModeCase struct {
	name          string
	spec          func(flag string, g w320Gates) flags.Spec
	enabled       func(inSide bool) bool
	offEverywhere bool
}

func w320ModeCases() []w320ModeCase {
	allow := func(us ...bmUser) map[string]struct{} {
		m := map[string]struct{}{}
		for _, u := range us {
			m[u.uid] = struct{}{}
		}
		return m
	}
	return []w320ModeCase{
		{"off", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.Off} },
			func(bool) bool { return false }, true},
		{"allowlist with the in user only", func(f string, g w320Gates) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Allowlist, Allowlist: allow(g.in[f])}
		}, func(in bool) bool { return in }, false},
		{"allowlist with the out user only", func(f string, g w320Gates) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Allowlist, Allowlist: allow(g.out[f])}
		}, func(in bool) bool { return !in }, false},
		{"allowlist, empty", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.Allowlist} },
			func(bool) bool { return false }, false},
		{"percent 0", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.Percent, Percent: 0} },
			func(bool) bool { return false }, false},
		{"percent 0 plus the out user allowlisted", func(f string, g w320Gates) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Percent, Percent: 0, Allowlist: allow(g.out[f])}
		}, func(in bool) bool { return !in }, false},
		{"percent 50", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.Percent, Percent: 50} },
			func(in bool) bool { return in }, false},
		{"percent 50 plus the out user allowlisted", func(f string, g w320Gates) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Percent, Percent: 50, Allowlist: allow(g.out[f])}
		}, func(bool) bool { return true }, false},
		{"percent 100", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.Percent, Percent: 100} },
			func(bool) bool { return true }, false},
		{"on", func(f string, _ w320Gates) flags.Spec { return flags.Spec{Name: f, Mode: flags.On} },
			func(bool) bool { return true }, false},
	}
}

// w320SetFlags applies a mode case to the four flags.
func w320SetFlags(mc w320ModeCase, g w320Gates) func(*config.Config) {
	return func(c *config.Config) {
		c.FeatureProfileExtras = mc.spec("profile_extras", g)
		c.FeatureProfileTabs = mc.spec("profile_tabs", g)
		c.FeatureLikesList = mc.spec("likes_list", g)
		c.FeatureFollowSuggestions = mc.spec("follow_suggestions", g)
	}
}

// w320GatedCall is one RPC behind one flag. call returns its error; passErr, when set, says what a call that PASSED the
// gate answers (the probes are built to fail fast and write nothing, so "passed" has one deterministic signature).
type w320GatedCall struct {
	name string
	flag string
	call func(e *w320Chain, u bmUser, target string) error
	rpc  string
	// pass checks the answer of a call the gate let through.
	pass func(t *testing.T, what string, err error)
	// clear is true for an UpdateProfile that only sends "" (W3-22 M-1, #354: always allowed from any caller, whatever the flag).
	clear bool
}

func w320GatedCalls() []w320GatedCall {
	upd := func(req *identityv1.UpdateProfileRequest) func(e *w320Chain, u bmUser, target string) error {
		return func(e *w320Chain, u bmUser, _ string) error {
			_, err := e.w320Update(u, req)
			return err
		}
	}
	wantValidation := func(field string) func(*testing.T, string, error) {
		return func(t *testing.T, what string, err error) {
			w320Reason(t, what, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, field)
		}
	}
	wantOK := func(t *testing.T, what string, err error) {
		if err != nil {
			t.Errorf("%s: err = %v, want success past the gate", what, err)
		}
	}
	tab := func(tb timelinev1.UserTimelineTab) func(e *w320Chain, u bmUser, target string) error {
		return func(e *w320Chain, u bmUser, target string) error {
			_, err := e.tabCall(u, target, tb, 20, "", "")
			return err
		}
	}
	return []w320GatedCall{
		{name: "UpdateProfile banner_media_id (unknown id)", flag: "profile_extras", rpc: rpcUpdateProfile,
			call: upd(&identityv1.UpdateProfileRequest{BannerMediaId: w320Str("0000000000000000042")}),
			pass: func(t *testing.T, what string, err error) {
				w320Reason(t, what, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY, "")
			}},
		{name: "UpdateProfile location (two lines)", flag: "profile_extras", rpc: rpcUpdateProfile,
			call: upd(&identityv1.UpdateProfileRequest{Location: w320Str("one\ntwo")}), pass: wantValidation("location")},
		{name: "UpdateProfile website (javascript:)", flag: "profile_extras", rpc: rpcUpdateProfile,
			call: upd(&identityv1.UpdateProfileRequest{Website: w320Str("javascript:alert(1)")}), pass: wantValidation("website")},
		{name: "UpdateProfile pinned_post_id (malformed)", flag: "profile_extras", rpc: rpcUpdateProfile,
			call: upd(&identityv1.UpdateProfileRequest{PinnedPostId: w320Str("nope")}), pass: wantValidation("pinned_post_id")},
		{name: `UpdateProfile banner_media_id ""`, flag: "profile_extras", rpc: rpcUpdateProfile, clear: true,
			call: upd(&identityv1.UpdateProfileRequest{BannerMediaId: w320Str("")}), pass: wantOK},
		{name: `UpdateProfile location ""`, flag: "profile_extras", rpc: rpcUpdateProfile, clear: true,
			call: upd(&identityv1.UpdateProfileRequest{Location: w320Str("")}), pass: wantOK},
		{name: `UpdateProfile website ""`, flag: "profile_extras", rpc: rpcUpdateProfile, clear: true,
			call: upd(&identityv1.UpdateProfileRequest{Website: w320Str("")}), pass: wantOK},
		{name: `UpdateProfile pinned_post_id ""`, flag: "profile_extras", rpc: rpcUpdateProfile, clear: true,
			call: upd(&identityv1.UpdateProfileRequest{PinnedPostId: w320Str("")}), pass: wantOK},
		{name: "CreateUpload(BANNER) with no items", flag: "profile_extras", rpc: w320RPCCreateUpload,
			call: func(e *w320Chain, u bmUser, _ string) error {
				_, err := e.media.CreateUpload(context.Background(), authed(u.token, &mediav1.CreateUploadRequest{
					IdempotencyKey: contractKey("w320-up"), Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_BANNER,
				}))
				return err
			}, pass: wantValidation("")},
		{name: "GetUserTimeline MEDIA", flag: "profile_tabs", rpc: rpcGetUserTimeline, call: tab(tabMediaPB), pass: wantOK},
		{name: "GetUserTimeline REPOSTS", flag: "profile_tabs", rpc: rpcGetUserTimeline, call: tab(tabRepostsPB), pass: wantOK},
		{name: "ListLikedPosts", flag: "likes_list", rpc: rpcListLikedPosts,
			call: func(e *w320Chain, u bmUser, _ string) error {
				_, err := e.eng.ListLikedPosts(context.Background(), authed(u.token, &engagementv1.ListLikedPostsRequest{}))
				return err
			}, pass: wantOK},
		{name: "ListSuggestedUsers", flag: "follow_suggestions", rpc: w320RPCListSuggested,
			call: func(e *w320Chain, u bmUser, _ string) error {
				_, err := e.graph.ListSuggestedUsers(context.Background(), authed(u.token, &graphv1.ListSuggestedUsersRequest{}))
				return err
			}, pass: wantOK},
	}
}

// TestW320_FlagModeMatrix: ten rollout states x four flags x both sides of the cohort x every gated RPC. A refused call is
// FEATURE_DISABLED with the flag's own name and costs exactly nothing; a call the gate lets through is answered by the
// handler (never FEATURE_DISABLED); GetMe lists the flag exactly for the callers it is on for; the ungated siblings stay
// open in every mode. A second chain with the same spec reaches the same verdicts (the cohort survives a restart).
func TestW320_FlagModeMatrix(t *testing.T) {
	setup := newW320Chain(t, w320AllW3On)
	g := w320DrawGates(t, setup)
	target := setup.user(t)
	calls := w320GatedCalls()

	for _, mc := range w320ModeCases() {
		t.Run(mc.name, func(t *testing.T) {
			verdicts := map[string]bool{} // "<flag>/<side>" -> enabled, compared across two chains
			for pass := 0; pass < 2; pass++ {
				r := newW320Chain(t, w320SetFlags(mc, g))
				for _, f := range w320FlagNames {
					for _, side := range []struct {
						label string
						in    bool
						u     bmUser
					}{{"in", true, g.in[f]}, {"out", false, g.out[f]}} {
						u := side.u
						on := mc.enabled(side.in)
						key := f + "/" + side.label
						if pass == 0 {
							verdicts[key] = on
						} else if verdicts[key] != on {
							t.Fatalf("%s: verdict changed across chains", key)
						}
						// GetMe lists the flag exactly for the callers it is on for (and warms the interceptor).
						if listed := slices.Contains(r.w320Warm(t, u), f); listed != on {
							t.Errorf("%s %s: enabled_features lists it = %v, want %v", f, side.label, listed, on)
						}
						for _, c := range calls {
							if c.flag != f {
								continue
							}
							what := f + " " + side.label + " " + c.name
							err := c.call(r, u, target.uid)
							refused := !on
							if c.clear && !w320ClearsNeedProfileExtras {
								refused = false // W3-22 M-1(b), #354: a clear is always allowed
							}
							if refused {
								w320Disabled(t, what, err, f)
								r.w320AssertNothing(t, what, c.rpc)
								continue
							}
							w320NotDisabled(t, what, err)
							c.pass(t, what, err)
						}
					}
				}
			}
		})
	}
}

// TestW320_UngatedSiblingsStayOpenInEveryMode: with all four flags off, the surfaces that must NOT depend on them keep
// working for an ordinary caller: the name and bio edit, the Posts / Replies / unset tabs, GetProfile, and (graph alone)
// GetProfileRelationship. A flag-off rollout therefore never strands an old client.
func TestW320_UngatedSiblingsStayOpenInEveryMode(t *testing.T) {
	r := newW320Chain(t, nil) // all four W3 flags off (the default), media/engagement/graph on
	a, b := r.user(t), r.user(t)
	postID := r.post(t, b, "a post to read")
	r.w320Warm(t, a)

	if _, err := r.w320Update(a, &identityv1.UpdateProfileRequest{Bio: w320Str("still editable"), DisplayName: w320Str("Still Editable")}); err != nil {
		t.Errorf("name and bio edit with every W3 flag off: %v", err)
	}
	for name, tb := range map[string]timelinev1.UserTimelineTab{
		"UNSPECIFIED": timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED, "POSTS": tabPostsPB, "REPLIES": timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES,
	} {
		resp, err := r.tabCall(a, b.uid, tb, 20, "", "")
		if err != nil || !slices.Contains(tabPostIDs(resp), postID) {
			t.Errorf("tab %s with profile_tabs off: err=%v rows=%v, want the post", name, err, tabPostIDs(resp))
		}
	}
	if p := r.w320Profile(t, a, b.uid); p.GetUserId() != b.uid {
		t.Errorf("GetProfile = %v", p)
	}
	if _, err := r.graph.GetProfileRelationship(context.Background(), authed(a.token, &graphv1.GetProfileRelationshipRequest{UserId: b.uid})); err != nil {
		t.Errorf("GetProfileRelationship needs graph only: %v", err)
	}
	// Every W3 flag is absent from the capabilities of a caller it is off for.
	for _, f := range w320FlagNames {
		if slices.Contains(r.enabledFeatures(t, a), f) {
			t.Errorf("enabled_features lists %s with the flag off", f)
		}
	}
}

// TestW320_CompanionFlagPrecedence: where an RPC needs a second flag, the FIRST guard in the code is the one that answers
// when both are off, and the answer names it (or, for the whole-service flags, carries no feature metadata). Read from
// the handlers: CreateUpload checks media, then (BANNER only) profile_extras; ListLikedPosts checks posts, then
// likes_list (engagement is NOT needed); GetUserTimeline checks posts, then profile_tabs; ListSuggestedUsers checks
// graph, then follow_suggestions.
func TestW320_CompanionFlagPrecedence(t *testing.T) {
	setup := newW320Chain(t, w320AllW3On)
	u, target := setup.user(t), setup.user(t)
	off := func(name string) flags.Spec { return flags.Spec{Name: name, Mode: flags.Off} }
	on := func(name string) flags.Spec { return flags.Spec{Name: name, Mode: flags.On} }

	t.Run("CreateUpload(BANNER): media off wins over profile_extras off, and over profile_extras on", func(t *testing.T) {
		for _, extras := range []flags.Spec{off("profile_extras"), on("profile_extras")} {
			r := newW320Chain(t, func(c *config.Config) { c.FeatureMedia = off("media"); c.FeatureProfileExtras = extras })
			r.w320Warm(t, u)
			_, err := r.media.CreateUpload(context.Background(), authed(u.token, &mediav1.CreateUploadRequest{
				IdempotencyKey: contractKey("w320-up"), Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_BANNER,
			}))
			w320Disabled(t, "media off, profile_extras "+string(extras.Mode), err, "") // whole-service answer
			r.w320AssertNothing(t, "CreateUpload refused by media", w320RPCCreateUpload)
		}
	})
	t.Run("CreateUpload(POST) is not gated by profile_extras", func(t *testing.T) {
		r := newW320Chain(t, func(c *config.Config) { c.FeatureProfileExtras = off("profile_extras") })
		_, err := r.media.CreateUpload(context.Background(), authed(u.token, &mediav1.CreateUploadRequest{
			IdempotencyKey: contractKey("w320-up"), Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_POST,
		}))
		w320NotDisabled(t, "CreateUpload(POST) with profile_extras off", err)
	})
	t.Run("ListLikedPosts: posts off wins over likes_list; engagement off does not matter", func(t *testing.T) {
		r := newW320Chain(t, func(c *config.Config) { c.FeaturePosts = off("posts"); c.FeatureLikesList = off("likes_list") })
		r.w320Warm(t, u)
		_, err := r.eng.ListLikedPosts(context.Background(), authed(u.token, &engagementv1.ListLikedPostsRequest{}))
		w320Disabled(t, "posts off", err, "")
		r2 := newW320Chain(t, func(c *config.Config) {
			c.FeatureEngagement = off("engagement")
			c.FeatureLikesList = on("likes_list")
		})
		if _, err := r2.eng.ListLikedPosts(context.Background(), authed(u.token, &engagementv1.ListLikedPostsRequest{})); err != nil {
			t.Errorf("likes_list on, engagement off: %v (the list needs posts and likes_list only)", err)
		}
	})
	t.Run("GetUserTimeline tabs: posts off wins over profile_tabs on", func(t *testing.T) {
		r := newW320Chain(t, func(c *config.Config) { c.FeaturePosts = off("posts"); c.FeatureProfileTabs = on("profile_tabs") })
		r.w320Warm(t, u)
		_, err := r.tabCall(u, target.uid, tabMediaPB, 20, "", "")
		w320Disabled(t, "posts off, profile_tabs on", err, "")
	})
	t.Run("ListSuggestedUsers: graph off wins over follow_suggestions on", func(t *testing.T) {
		r := newW320Chain(t, func(c *config.Config) {
			c.FeatureGraph = off("graph")
			c.FeatureFollowSuggestions = on("follow_suggestions")
		})
		r.w320Warm(t, u)
		_, err := r.graph.ListSuggestedUsers(context.Background(), authed(u.token, &graphv1.ListSuggestedUsersRequest{}))
		w320Disabled(t, "graph off, follow_suggestions on", err, "")
		r.w320AssertNothing(t, "ListSuggestedUsers refused by graph", w320RPCListSuggested)
		_, err = r.graph.GetProfileRelationship(context.Background(), authed(u.token, &graphv1.GetProfileRelationshipRequest{UserId: target.uid}))
		w320Disabled(t, "GetProfileRelationship with graph off", err, "")
		r.w320AssertNothing(t, "GetProfileRelationship refused by graph", w320RPCGetProfileRel)
	})
}

// TestW320_M1KillSwitchWebsiteAndClears: W3-22 M-1 (ADR-0024 Amendment 1 A1 and A2, #354) through the production chain.
//
//	A1: while profile_extras is globally off (mode off ONLY) the website and the pin are blanked in every Profile identity
//	    returns, the owner's own view included, at no extra read; the location stays; a rollout (an allowlist, even an empty
//	    one, or a percent, even 0) is not the switch and shows both; the stored document keeps the values.
//	A2: the exact value "" for any of the four fields is a clear and is accepted from any authenticated caller whatever the
//	    flag (1 read, 1 write); whitespace-only is a SET and stays gated; a request that mixes a clear with a set is refused
//	    whole (FEATURE_DISABLED for a caller outside the cohort, and nothing is cleared).
func TestW320_M1KillSwitchWebsiteAndClears(t *testing.T) {
	const site = "https://example.com/m1"
	setup := newW320Chain(t, w320AllW3On)
	viewer := setup.user(t)
	// seed builds an owner with a location, a website and a pin, written while the flag is on for everyone.
	seed := func() (bmUser, string) {
		o := setup.user(t)
		pid := setup.post(t, o, "m1 pin")
		if _, err := setup.w320Update(o, &identityv1.UpdateProfileRequest{Location: w320Str("Pune"), Website: w320Str(site), PinnedPostId: &pid}); err != nil {
			t.Fatalf("seed: %v", err)
		}
		return o, pid
	}
	spec := func(mode flags.Mode, allow ...bmUser) flags.Spec {
		s := flags.Spec{Name: "profile_extras", Mode: mode}
		if len(allow) > 0 {
			s.Allowlist = map[string]struct{}{}
			for _, u := range allow {
				s.Allowlist[u.uid] = struct{}{}
			}
		}
		return s
	}

	t.Run("A1: website and pin are blanked only while the flag is globally off", func(t *testing.T) {
		o, pid := seed()
		for _, tc := range []struct {
			name  string
			spec  flags.Spec
			shown bool // website and pin visible
		}{
			{"mode off (the kill switch)", spec(flags.Off), false},
			{"allowlist, empty (a rollout, not the switch)", spec(flags.Allowlist), true},
			{"percent 0 (a rollout, not the switch)", flags.Spec{Name: "profile_extras", Mode: flags.Percent, Percent: 0}, true},
			{"allowlist with someone else", spec(flags.Allowlist, viewer), true},
			{"on", spec(flags.On), true},
		} {
			r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = tc.spec })
			for who, v := range map[string]bmUser{"a viewer": viewer, "the owner": o} {
				p := r.w320Profile(t, v, o.uid)
				wantSite, wantPin := "", ""
				if tc.shown {
					wantSite, wantPin = site, pid
				}
				if p.GetWebsite() != wantSite || p.GetPinnedPostId() != wantPin || p.GetLocation() != "Pune" {
					t.Errorf("%s, %s: website=%q pin=%q location=%q, want website=%q pin=%q and location Pune", tc.name, who, p.GetWebsite(), p.GetPinnedPostId(), p.GetLocation(), wantSite, wantPin)
				}
			}
			// The stored document is untouched by the kill switch: it only hides.
			if got := r.w320Field(t, "users/"+o.uid, "website"); got != site {
				t.Errorf("%s: stored website = %v, want %q (the switch hides, it never writes)", tc.name, got, site)
			}
		}
		// Off also blanks the website in the response to the owner's own UpdateProfile.
		r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = spec(flags.Off) })
		got, err := r.w320Update(o, &identityv1.UpdateProfileRequest{Bio: w320Str("bio edit while the flag is off")})
		if err != nil || got.GetWebsite() != "" || got.GetPinnedPostId() != "" || got.GetLocation() != "Pune" {
			t.Errorf("UpdateProfile response with the flag off: %v, %v; want website and pin blanked, location kept", got, err)
		}
		if after := r.w320Field(t, "users/"+o.uid, "website"); after != site {
			t.Errorf("a bio edit with the flag off changed the stored website to %v", after)
		}
	})

	t.Run("A2: the exact empty string clears from any caller whatever the flag", func(t *testing.T) {
		for _, tc := range []struct {
			name string
			spec flags.Spec
		}{
			{"flag globally off", spec(flags.Off)},
			{"owner outside the allowlist", spec(flags.Allowlist, viewer)},
			{"owner outside the cohort at percent 0", flags.Spec{Name: "profile_extras", Mode: flags.Percent, Percent: 0}},
			{"flag on (control)", spec(flags.On)},
		} {
			o, _ := seed()
			r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = tc.spec })
			got, err := r.w320Update(o, &identityv1.UpdateProfileRequest{
				BannerMediaId: w320Str(""), Location: w320Str(""), Website: w320Str(""), PinnedPostId: w320Str(""),
			})
			if err != nil {
				t.Errorf("%s: clearing all four with \"\": %v, want it accepted", tc.name, err)
				continue
			}
			if got.GetLocation() != "" || got.GetWebsite() != "" || got.GetPinnedPostId() != "" || got.GetBannerUrl() != "" {
				t.Errorf("%s: response after the clear = %v, want every field empty", tc.name, got)
			}
			// 1 read (the users doc) + 1 for the cold interceptor = 2; 1 write: the cost of any UpdateProfile.
			budgettest.Assert(t, tc.name+": UpdateProfile clearing all four, cold interceptor", r.lineBudget(t, rpcUpdateProfile), budgettest.Budget{Reads: 2, Writes: 1})
			for _, f := range []string{"location", "website", "pinnedPostId"} {
				if v := r.w320Field(t, "users/"+o.uid, f); v != "" && v != nil {
					t.Errorf("%s: stored %s = %v after the clear", tc.name, f, v)
				}
			}
		}
	})

	t.Run("A2: whitespace-only is a set and stays gated", func(t *testing.T) {
		o, pid := seed()
		r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = spec(flags.Allowlist, viewer) })
		r.w320Warm(t, o)
		for name, req := range map[string]*identityv1.UpdateProfileRequest{
			"location":       {Location: w320Str("   ")},
			"website":        {Website: w320Str(" ")},
			"pinned_post_id": {PinnedPostId: w320Str("  ")},
			"banner":         {BannerMediaId: w320Str(" ")},
			"tab":            {Location: w320Str("\t")},
		} {
			_, err := r.w320Update(o, req)
			w320Disabled(t, "whitespace-only "+name+" outside the cohort", err, "profile_extras")
			r.w320AssertNothing(t, "whitespace-only "+name, rpcUpdateProfile)
		}
		for f, want := range map[string]string{"location": "Pune", "website": site, "pinnedPostId": pid} {
			if v := r.w320Field(t, "users/"+o.uid, f); v != want {
				t.Errorf("a refused whitespace-only request changed %s: %v, want %q", f, v, want)
			}
		}
	})

	t.Run("A2: a request that mixes a clear with a set is refused whole", func(t *testing.T) {
		o, _ := seed()
		for _, tc := range []struct {
			name string
			spec flags.Spec
		}{
			{"flag globally off", spec(flags.Off)},
			{"owner outside the allowlist", spec(flags.Allowlist, viewer)},
		} {
			r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = tc.spec })
			r.w320Warm(t, o)
			_, err := r.w320Update(o, &identityv1.UpdateProfileRequest{Location: w320Str(""), Website: w320Str("https://example.com/new")})
			w320Disabled(t, tc.name+": clear location + set website", err, "profile_extras")
			r.w320AssertNothing(t, tc.name+": mixed request", rpcUpdateProfile)
			if v := r.w320Field(t, "users/"+o.uid, "location"); v != "Pune" {
				t.Errorf("%s: the clear half of a refused mixed request was applied: location = %v", tc.name, v)
			}
			// A bio edit next to a clear is not a mix: only the four extras count, and a clear passes.
			if got, err := r.w320Update(o, &identityv1.UpdateProfileRequest{Bio: w320Str("bio next to a clear " + tc.name), Location: w320Str("")}); err != nil || got.GetLocation() != "" {
				t.Errorf("%s: bio plus clearing location: %v, %v; want it accepted", tc.name, got, err)
			}
			if _, err := r.w320Update(o, &identityv1.UpdateProfileRequest{Location: w320Str("Pune")}); err == nil {
				t.Errorf("%s: setting a location was accepted outside the cohort", tc.name)
			}
			// restore the location for the next row (written while the flag is on for everyone)
			if _, err := setup.w320Update(o, &identityv1.UpdateProfileRequest{Location: w320Str("Pune")}); err != nil {
				t.Fatal(err)
			}
		}
		// Control: for a caller inside the cohort the same mixed request is accepted.
		r := newW320Chain(t, func(c *config.Config) { w320AllW3On(c); c.FeatureProfileExtras = spec(flags.On) })
		if got, err := r.w320Update(o, &identityv1.UpdateProfileRequest{Location: w320Str(""), Website: w320Str("https://example.com/new")}); err != nil || got.GetWebsite() != "https://example.com/new" || got.GetLocation() != "" {
			t.Errorf("mixed request inside the cohort: %v, %v; want it accepted", got, err)
		}
	})
}
