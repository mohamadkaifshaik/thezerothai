//go:build integration

package apiserver

// Shared helpers of the W3-20 matrix (ticket W3-20 of docs/plans/ui-w3-profile-graph-completion.md, ADR-0024). Every
// package-level name here carries the w320 / W320 prefix so a symbol added by a parallel W3-22 fix branch can never
// collide with it. The chain, the clients, the budget-from-log helper, rawRPC, tabCall, listLiked, like, unlike and the
// rest are reused from the earlier files of this package.
//
// The one open gap named by a constant is w320LikesRepeatsAfterLastGoneAndNextRelike beside its only reader (defect D-1
// of this ticket, in the likes test file): it carries the value the code has TODAY and the author of the fix flips it in
// the same change. The W3-22 fixes that HAVE landed (L-1, L-2, L-3, L-4, L-5, M-3, and M-1 with #354) assert the fixed
// behaviour; the two M-1 switches at the bottom of this file are already false and only label what two tests check. The
// report lists the open gaps under "known open gaps".

import (
	"context"
	"errors"
	"hash/fnv"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w320Chain is a Build chain with every client the matrix needs: the bookmarks-chain clients (identity, posts, timeline,
// moderation, engagement, graph) plus media.
type w320Chain struct {
	*bmChain
	media mediav1connect.MediaServiceClient
}

// w320Base is the config every W3-20 chain starts from: the abuse limits relaxed for loopback seeding (the limits
// themselves have their own tests), media, engagement and graph on, and the four W3 flags at their default (off). A
// test sets the flag under test after it.
func w320Base(c *config.Config) {
	relaxLimits(c)
	mediaOn(c)
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	c.RateLimit.LikesPerUserPerMinute = 1_000_000
	c.RateLimit.UserTimelinePerMinute = 1_000_000
	c.RateLimit.LikesListPerUserPerMinute = 1_000_000
	c.RateLimit.SuggestionsPerUserPerMinute = 1_000_000
	c.RateLimit.SuggestionsCallsPerDay = 1_000_000
	c.RateLimit.ProfileRelationshipPerUserPerMinute = 1_000_000
	// W3-22 L-4: UpdateProfile's per-uid daily call cap (default 100) must never be what a matrix row measures; its own
	// test (TestW320_UpdateProfileDailyCapAndNoOpWrites) sets it low.
	c.RateLimit.ProfileUpdatesPerDay = 1_000_000
}

// w320AllW3On turns the four W3 Part A flags on for everyone.
func w320AllW3On(c *config.Config) {
	c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.On}
	c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.On}
	c.FeatureLikesList = flags.Spec{Name: "likes_list", Mode: flags.On}
	c.FeatureFollowSuggestions = flags.Spec{Name: "follow_suggestions", Mode: flags.On}
}

// newW320Chain boots a chain with w320Base then mutate.
func newW320Chain(t *testing.T, mutate func(*config.Config)) *w320Chain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		w320Base(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &w320Chain{
		bmChain: newW320BM(env),
		media:   mediav1connect.NewMediaServiceClient(http.DefaultClient, env.url),
	}
}

func newW320BM(env *chainEnv) *bmChain {
	return &bmChain{
		chainEnv: env,
		eng:      engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

// w320Warm makes the account-status read of u warm on this chain (GetMe is ungated and reads the same profile), so a
// refused call that follows can be asserted at exactly 0 reads.
func (e *w320Chain) w320Warm(t *testing.T, u bmUser) []string {
	t.Helper()
	return e.enabledFeatures(t, u)
}

// w320Counter is the last request line of rpc as a budget counter (logs a BUDGET line for the report).
func (e *w320Chain) w320Counter(t *testing.T, rpc string) *budget.Counter {
	return e.lineBudget(t, rpc)
}

// w320AssertNothing asserts the last request line of rpc cost 0 reads, 0 writes and 0 deletes.
func (e *w320Chain) w320AssertNothing(t *testing.T, what, rpc string) {
	t.Helper()
	budgettest.Assert(t, what, e.w320Counter(t, rpc), budgettest.Budget{})
}

// w320Bucket is flags' percent bucket (unexported there): fnv32a(name + ":" + uid) % 100.
func w320Bucket(name, uid string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(name + ":" + uid))
	return int(h.Sum32() % 100)
}

// w320Disabled asserts err is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=want ("" = the whole-service
// answer, which carries no feature metadata).
func w320Disabled(t *testing.T, what string, err error, want string) {
	t.Helper()
	if err == nil {
		t.Errorf("%s: no error, want FEATURE_DISABLED feature=%q", what, want)
		return
	}
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Errorf("%s: err = %v, want FAILED_PRECONDITION FEATURE_DISABLED feature=%q", what, err, want)
		return
	}
	d := wireError(t, err, connect.CodeFailedPrecondition)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Errorf("%s: reason = %v, want FEATURE_DISABLED", what, d.GetReason())
	}
	if got := d.GetMetadata()["feature"]; got != want {
		t.Errorf("%s: metadata feature = %q, want %q (%v)", what, got, want, d.GetMetadata())
	}
}

// w320NotDisabled asserts err is not a FEATURE_DISABLED answer (the gate let the call through).
func w320NotDisabled(t *testing.T, what string, err error) {
	t.Helper()
	if err != nil && connect.CodeOf(err) == connect.CodeFailedPrecondition {
		if d := w320Detail(err); d != nil && d.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Errorf("%s: refused by a flag gate: %v", what, d.GetMetadata())
		}
	}
}

// w320Detail is the ErrorDetail of err, or nil.
func w320Detail(err error) *commonv1.ErrorDetail {
	var cerr *connect.Error
	if err == nil || !errors.As(err, &cerr) {
		return nil
	}
	for _, d := range cerr.Details() {
		if msg, derr := d.Value(); derr == nil {
			if detail, ok := msg.(*commonv1.ErrorDetail); ok {
				return detail
			}
		}
	}
	return nil
}

// w320Reason asserts err is a Connect error with code and ErrorDetail reason (and, when field != "", metadata field).
func w320Reason(t *testing.T, what string, err error, code connect.Code, reason commonv1.ErrorReason, field string) {
	t.Helper()
	if err == nil {
		t.Errorf("%s: no error, want %v %v", what, code, reason)
		return
	}
	if connect.CodeOf(err) != code {
		t.Errorf("%s: code = %v (%v), want %v %v", what, connect.CodeOf(err), err, code, reason)
		return
	}
	d := w320Detail(err)
	if d == nil {
		t.Errorf("%s: no ErrorDetail on %v", what, err)
		return
	}
	if d.GetReason() != reason {
		t.Errorf("%s: reason = %v, want %v", what, d.GetReason(), reason)
	}
	if field != "" && d.GetMetadata()["field"] != field {
		t.Errorf("%s: metadata = %v, want field=%s", what, d.GetMetadata(), field)
	}
}

// w320Update sends one UpdateProfile as u and returns the profile.
func (e *w320Chain) w320Update(u bmUser, req *identityv1.UpdateProfileRequest) (*identityv1.Profile, error) {
	if req.IdempotencyKey == "" {
		req.IdempotencyKey = contractKey("w320-upd")
	}
	r, err := e.identity.UpdateProfile(context.Background(), authed(u.token, req))
	if err != nil {
		return nil, err
	}
	return r.Msg.GetProfile(), nil
}

// w320Profile is GetProfile(viewer -> uid).
func (e *w320Chain) w320Profile(t *testing.T, viewer bmUser, uid string) *identityv1.Profile {
	t.Helper()
	r, err := e.identity.GetProfile(context.Background(), authed(viewer.token, &identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uid},
	}))
	if err != nil {
		t.Fatalf("GetProfile(%s): %v", uid, err)
	}
	return r.Msg.GetProfile()
}

// w320Str is a *string literal helper.
func w320Str(s string) *string { return &s }

// -----------------------------------------------------------------------------------------------------------------
// W3-22 M-1 (merged: #349 the ADR amendment, #354 the code). Both values were "pre-fix" (true) until #354 landed on main;
// W3-20 flipped them to false, the behaviour ADR-0024 Amendment 1 A1 and A2 describe and the tests below assert. They are
// kept as named switches only so the two places that read them say what they check; they can be deleted with their
// conditionals. TestW320_M1KillSwitchWebsiteAndClears asserts the same rules directly.
// -----------------------------------------------------------------------------------------------------------------

const (
	// w320ClearsNeedProfileExtras is W3-22 M-1(b) (Amendment 1 A2). false (after #354): the exact value "" for banner,
	// location, website or pin is accepted from any authenticated caller whatever the flag, globally off included (1 read,
	// 1 write); only SETTING a value (whitespace-only included) stays gated, and a request that mixes a clear with a set is
	// refused whole. (Before the fix: every one of these was FEATURE_DISABLED outside the cohort.)
	w320ClearsNeedProfileExtras = false

	// w320WebsiteShownWhileExtrasGloballyOff is W3-22 M-1(a) (Amendment 1 A1). false (after #354): with profile_extras
	// globally off (mode off only) present() blanks the website together with the pin in every Profile identity returns,
	// 0 reads, so the kill switch also kills the link; the banner and the location keep rendering. (Before the fix only the
	// pin was blanked.)
	w320WebsiteShownWhileExtrasGloballyOff = false
)

// newW320Media is the media client of a chain.
func newW320Media(env *chainEnv) mediav1connect.MediaServiceClient {
	return mediav1connect.NewMediaServiceClient(http.DefaultClient, env.url)
}

// w320RPCGetUserTimeline is the GetUserTimeline procedure (the W3-9 file's rpcGetUserTimeline under a w320 name).
const w320RPCGetUserTimeline = "/dzeroth.timeline.v1.TimelineService/GetUserTimeline"

// w320Field reads one field of a Firestore document of the chain's project.
func (e *chainEnv) w320Field(t *testing.T, path, field string) any {
	t.Helper()
	snap, err := e.fs.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	return snap.Data()[field]
}
