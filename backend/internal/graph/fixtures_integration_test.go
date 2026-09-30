//go:build integration

// fixtures_integration_test.go holds the shared emulator fixtures for every graph integration suite
// (T7/T8/T10/T11 tests, T16a, and T16b, which must not grow a second seeding helper): the wired
// identity+graph pair, profile/graph/quota seeding, the budget-measuring call wrapper and the API-error
// assertion. The invariant checker lives next to it in invariants_integration_test.go.
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// Idempotency keys that satisfy the 16-64 char [A-Za-z0-9_-] convention. Distinct keys model "a new key".
const (
	key1 = "0123456789abcdef"
	key2 = "fedcba9876543210"
	key3 = "0123456789fedcba"
)

// alwaysOnFlags implements graph.FlagChecker, always enabled — these tests exercise past-the-flag behavior.
type alwaysOnFlags struct{}

func (alwaysOnFlags) Enabled(string, string) bool { return true }

// flagsOff is a graph.FlagChecker with the graph flag off for everyone (FEATURE_DISABLED tests).
type flagsOff struct{}

func (flagsOff) Enabled(string, string) bool { return false }

// wired is every object a test needs from a fully wired identity+graph pair (apiserver.Build's wiring,
// minus the HTTP layer).
type wired struct {
	client   *firestore.Client
	identity identity.Service
	graph    *graphSvcHandle
	// sweep controls the automatic end-of-test invariant check registered by newWired.
	sweep *invariantSweep
}

// invariantSweep lets a test opt out of the automatic end-of-test invariant sweep (only for tests that
// deliberately seed a state the invariants forbid, e.g. a purge test's half-deleted graph). skipReason is
// mandatory so an opt-out is always documented in the test.
type invariantSweep struct{ skipReason string }

// SkipInvariantSweep disables the automatic end-of-test sweep for this test; reason must say why.
func (w wired) SkipInvariantSweep(reason string) { w.sweep.skipReason = reason }

// graphSvcHandle exposes graph.Service plus the concrete *graph "service" methods tests need
// (SetDirectory already called; Snapshot/IsBlockedBy are reached through identity.Service/graph.Service).
type graphSvcHandle struct {
	graph.Service
	repo *graph.FirestoreRepo
	// setDirectory re-wires the service's identity.Directory (e.g. with a test decorator).
	setDirectory func(identity.Directory)
}

// wiredOption tweaks the graph.Deps newWired builds (flags, quota tiers, new-account window).
type wiredOption func(*graph.Deps)

func withFlags(f graph.FlagChecker) wiredOption { return func(d *graph.Deps) { d.Flags = f } }

// withNewAccountWindow changes how long an account counts as "new" (default 24h; with a 1ns window every
// profile is an established account, which is how tests reach the standard quota tier without a clock seam).
func withNewAccountWindow(w time.Duration) wiredOption {
	return func(d *graph.Deps) { d.NewAccountWindow = w }
}

// withQuotas overrides the four daily quota limits (follows, new follows, blocks, new blocks).
func withQuotas(follows, newFollows, blocks, newBlocks int64) wiredOption {
	return func(d *graph.Deps) {
		d.FollowsPerDay, d.NewAccountFollowsPerDay, d.BlocksPerDay, d.NewAccountBlocksPerDay = follows, newFollows, blocks, newBlocks
	}
}

// newWired wires identity+graph against a fresh emulator project and registers the ADR-0008 D3 invariant
// checker as a t.Cleanup, so EVERY scenario ends with a full sweep of follows/graph/users (opt out with
// w.SkipInvariantSweep(reason)).
func newWired(t *testing.T, opts ...wiredOption) wired {
	t.Helper()
	client := newTestClient(t)
	w := newInstance(client, opts...)
	// Registered after newTestClient's client.Close cleanup, so (LIFO) it runs while the client is still open.
	t.Cleanup(func() {
		if w.sweep.skipReason != "" {
			t.Logf("invariant sweep skipped: %s", w.sweep.skipReason)
			return
		}
		assertGraphInvariants(t, client)
	})
	return w
}

// newInstance wires one identity+graph pair (one "Cloud Run instance": its own caches) on an existing
// Firestore client, without the invariant sweep. Call it twice on one client to model two instances sharing
// a database; newWired is the single-instance form.
func newInstance(client *firestore.Client, opts ...wiredOption) wired {
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)

	deps := graph.Deps{
		Repo:                    graphRepo,
		Cache:                   graph.NewCache(time.Minute),
		Flags:                   alwaysOnFlags{},
		CursorKey:               []byte("test-cursor-key"),
		FollowsPerDay:           200,
		NewAccountFollowsPerDay: 50,
		BlocksPerDay:            200,
		NewAccountBlocksPerDay:  50,
		NewAccountWindow:        24 * time.Hour,
	}
	for _, o := range opts {
		o(&deps)
	}
	graphSvc := graph.New(deps)
	identitySvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour,
		identity.WithBlockChecker(graphSvc),
	)
	graphSvc.SetDirectory(identitySvc.(identity.Directory))

	return wired{client: client, identity: identitySvc, graph: &graphSvcHandle{Service: graphSvc, repo: graphRepo, setDirectory: graphSvc.SetDirectory}, sweep: &invariantSweep{}}
}

func mustCreateProfile(t *testing.T, svc identity.Service, uid, handle string) {
	t.Helper()
	if _, err := svc.CreateProfile(context.Background(), uid, "0123456789abcdef", handle, "Name "+handle); err != nil {
		t.Fatalf("CreateProfile(%s): %v", uid, err)
	}
}

// mustCreateUsers creates n profiles uid-<prefix>0..n-1 (handle user_<prefix><i>) and returns their uids.
func mustCreateUsers(t *testing.T, svc identity.Service, prefix string, n int) []string {
	t.Helper()
	uids := make([]string, n)
	for i := range uids {
		uids[i] = fmt.Sprintf("uid-%s%d", prefix, i)
		mustCreateProfile(t, svc, uids[i], fmt.Sprintf("user_%s%d", prefix, i))
	}
	return uids
}

// padUIDs returns n synthetic uids ("pad-00000"...) for reaching a cap without real users; the invariant
// checker ignores them (seedPadPrefix).
func padUIDs(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%s%05d", seedPadPrefix, i)
	}
	return out
}

// seedGraphArrays directly writes graph/{uid}'s arrays (a full Set: unlisted arrays become empty) so
// mutation logic can be exercised against states that would otherwise need thousands of real calls, or
// against one-sided states. Prefer seedBlock for a consistent block pair.
func seedGraphArrays(t *testing.T, client *firestore.Client, uid string, fields map[string]interface{}) {
	t.Helper()
	base := map[string]interface{}{"following": []string{}, "blocked": []string{}, "muted": []string{}, "requested": []string{}, "blockedBy": []string{}}
	for k, v := range fields {
		base[k] = v
	}
	if _, err := client.Collection("graph").Doc(uid).Set(context.Background(), base); err != nil {
		t.Fatalf("seed graph/%s: %v", uid, err)
	}
}

// seedBlock records "blocker blocks blocked" on both graph docs exactly as Block would (blocked[] +
// blockedBy[]), without going through the RPC (no quota use, no edges touched). Both docs must exist.
func seedBlock(t *testing.T, client *firestore.Client, blocker, blocked string) {
	t.Helper()
	ctx := context.Background()
	if _, err := client.Collection("graph").Doc(blocker).Update(ctx, []firestore.Update{{Path: "blocked", Value: firestore.ArrayUnion(blocked)}}); err != nil {
		t.Fatalf("seed graph/%s.blocked: %v", blocker, err)
	}
	if _, err := client.Collection("graph").Doc(blocked).Update(ctx, []firestore.Update{{Path: "blockedBy", Value: firestore.ArrayUnion(blocker)}}); err != nil {
		t.Fatalf("seed graph/%s.blockedBy: %v", blocked, err)
	}
}

// seedEdge writes ONLY the follows/{follower}_{followee} doc (no following[] entry, no counters): a raw
// fixture for read-path tests (lists, purge) that need edges cheaply. It violates invariants I1/I2 by
// design, so a test using it must call w.SkipInvariantSweep("edge-only seeding"). Use seedFollow for a
// consistent edge.
func seedEdge(t *testing.T, w wired, follower, followee string, at time.Time) {
	t.Helper()
	if _, err := w.client.Collection("follows").Doc(follower+"_"+followee).Set(context.Background(), map[string]interface{}{
		"followerId": follower, "followeeId": followee, "createdAt": at,
	}); err != nil {
		t.Fatalf("seed edge: %v", err)
	}
}

// seedFollow writes a follow exactly as Follow would (edge doc + follower's following[] + both counters),
// without using the RPC, so it costs no quota and stays consistent with invariants I1/I2. Both users must
// exist (CreateProfile).
func seedFollow(t *testing.T, w wired, follower, followee string, at time.Time) {
	t.Helper()
	ctx := context.Background()
	if _, err := w.client.Collection("follows").Doc(follower+"_"+followee).Set(ctx, map[string]interface{}{
		"followerId": follower, "followeeId": followee, "createdAt": at,
	}); err != nil {
		t.Fatalf("seed follow edge: %v", err)
	}
	if _, err := w.client.Collection("graph").Doc(follower).Update(ctx, []firestore.Update{{Path: "following", Value: firestore.ArrayUnion(followee)}}); err != nil {
		t.Fatalf("seed graph/%s.following: %v", follower, err)
	}
	if _, err := w.client.Collection("users").Doc(follower).Update(ctx, []firestore.Update{{Path: "followingCount", Value: firestore.Increment(1)}}); err != nil {
		t.Fatalf("seed users/%s.followingCount: %v", follower, err)
	}
	if _, err := w.client.Collection("users").Doc(followee).Update(ctx, []firestore.Update{{Path: "followersCount", Value: firestore.Increment(1)}}); err != nil {
		t.Fatalf("seed users/%s.followersCount: %v", followee, err)
	}
}

// istDay returns the quota day key (IST, ADR-0003) offsetDays from today (-1 = yesterday).
func istDay(offsetDays int) string {
	ist := time.FixedZone("IST", 5*3600+30*60)
	return time.Now().In(ist).AddDate(0, 0, offsetDays).Format("2006-01-02")
}

// seedQuota writes quotas/{uid} for the given IST day with one counter set (kind: "follows" or "blocks").
// A day other than today models the IST-midnight rollover: the quota store treats it as a fresh day.
func seedQuota(t *testing.T, client *firestore.Client, uid, day, kind string, used int) {
	t.Helper()
	if _, err := client.Collection("quotas").Doc(uid).Set(context.Background(), map[string]interface{}{"day": day, kind: used}); err != nil {
		t.Fatalf("seed quotas/%s: %v", uid, err)
	}
}

// seedUserField sets one field on users/{uid} (e.g. isPrivate=true, status="DELETING") for legacy-data
// scenarios, then evicts uid from identity's instance profile cache (CreateProfile populated it) so the
// next read sees the seeded value.
func seedUserField(t *testing.T, w wired, uid, field string, value interface{}) {
	t.Helper()
	if _, err := w.client.Collection("users").Doc(uid).Update(context.Background(), []firestore.Update{{Path: field, Value: value}}); err != nil {
		t.Fatalf("seed users/%s.%s: %v", uid, field, err)
	}
	w.identity.(identity.Directory).Forget(uid)
}

// measured runs fn with a fresh budget counter, logs "BUDGET <rpc> reads=.. writes=.. deletes=.." (grep the
// -v output; these numbers feed T21's cost report) and asserts the call stayed within b. On a regression the
// failure names the RPC with the actual vs documented value (budgettest.Assert). Use one call per invocation.
func measured(t *testing.T, rpc string, b budgettest.Budget, fn func(ctx context.Context)) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	fn(ctx)
	t.Logf("BUDGET %s reads=%d writes=%d deletes=%d (budget %dR/%dW/%dD)", rpc, counter.Reads(), counter.Writes(), counter.Deletes(), b.Reads, b.Writes, b.Deletes)
	budgettest.Assert(t, rpc, counter, b)
}

// requireAPIError fails t unless err is an *apierr.Error with the given Connect code and ErrorReason; a
// non-empty metaKey must also match metaVal.
func requireAPIError(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, metaKey, metaVal string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error = %v (%T), want *apierr.Error{%v, %v}", err, err, code, reason)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("error = {%v, %v} %q, want {%v, %v}", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	if metaKey != "" && ae.Metadata[metaKey] != metaVal {
		t.Fatalf("metadata[%s] = %q, want %q", metaKey, ae.Metadata[metaKey], metaVal)
	}
}

func graphArrays(t *testing.T, client *firestore.Client, uid string) map[string][]string {
	t.Helper()
	snap, err := client.Collection("graph").Doc(uid).Get(context.Background())
	if err != nil {
		t.Fatalf("get graph/%s: %v", uid, err)
	}
	out := map[string][]string{}
	for _, f := range []string{"following", "blocked", "muted", "blockedBy"} {
		v, err := snap.DataAt(f)
		if err != nil {
			continue
		}
		for _, x := range v.([]interface{}) {
			out[f] = append(out[f], x.(string))
		}
	}
	return out
}

func docExists(t *testing.T, client *firestore.Client, path string) bool {
	t.Helper()
	_, err := client.Doc(path).Get(context.Background())
	return err == nil
}

func counts(t *testing.T, w wired, uid string) (following, followers int64) {
	t.Helper()
	me, err := w.identity.GetMe(context.Background(), uid)
	if err != nil {
		t.Fatalf("GetMe(%s): %v", uid, err)
	}
	return me.Profile.FollowingCount, me.Profile.FollowersCount
}

func contains(vals []string, v string) bool {
	for _, x := range vals {
		if x == v {
			return true
		}
	}
	return false
}

// warmProfiles loads uids into identity's instance profile cache (what a busy instance has after recent
// traffic), so a following call measures the documented "typical" (warm) read count instead of the cold worst
// case.
func warmProfiles(t *testing.T, w wired, uids ...string) {
	t.Helper()
	if _, err := w.identity.(identity.Directory).GetProfiles(context.Background(), uids); err != nil {
		t.Fatalf("warmProfiles: %v", err)
	}
}

// quotaUsed returns quotas/{uid}.<kind> for the given IST day ("" day = any day), 0 if absent.
func quotaUsed(t *testing.T, client *firestore.Client, uid, day, kind string) int64 {
	t.Helper()
	snap, err := client.Collection("quotas").Doc(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	if day != "" {
		if d, _ := snap.DataAt("day"); d != day {
			return 0
		}
	}
	v, err := snap.DataAt(kind)
	if err != nil {
		return 0
	}
	n, _ := v.(int64)
	return n
}

// runConcurrently starts n goroutines running fn(i), releases them together, and returns each one's error.
func runConcurrently(n int, fn func(i int) error) []error {
	var ready, done sync.WaitGroup
	start := make(chan struct{})
	errs := make([]error, n)
	ready.Add(n)
	done.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer done.Done()
			ready.Done()
			<-start
			errs[i] = fn(i)
		}(i)
	}
	ready.Wait()
	close(start)
	done.Wait()
	return errs
}
