package graph

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// countingDirectory wraps a Directory and counts GetProfiles calls, so a test can prove a refused path never
// reached it. (fakeDirectory is shared with other tests and stays untouched.)
type countingDirectory struct {
	identity.Directory
	gets int
}

func (c *countingDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	c.gets++
	return c.Directory.GetProfiles(ctx, uids)
}

// activeProfiles is a fakeDirectory holding an ACTIVE profile for every uid given.
func activeProfiles(uids ...string) *fakeDirectory {
	d := &fakeDirectory{profiles: map[string]identity.Profile{}}
	for _, u := range uids {
		d.profiles[u] = identity.Profile{UserID: u, Status: identity.AccountStatusActive}
	}
	return d
}

// snapOf builds a Snapshot from the sets a test cares about.
func snapOf(following, blocked, muted, blockedBy []string) Snapshot {
	set := func(in []string) map[string]bool {
		m := map[string]bool{}
		for _, u := range in {
			m[u] = true
		}
		return m
	}
	return Snapshot{Following: set(following), Blocked: set(blocked), Muted: set(muted), BlockedBy: set(blockedBy), Requested: map[string]bool{}}
}

// relFixture is a service over a fake repo and a counting directory, with uid-a (the caller), uid-b (the target) and
// uid-c ACTIVE and the graph flag on for all of them.
type relFixture struct {
	svc  *service
	repo *fakeRepo
	dir  *countingDirectory
}

func newRelFixture(t *testing.T) relFixture {
	t.Helper()
	repo := newFakeRepo()
	dir := &countingDirectory{Directory: activeProfiles("uid-a", "uid-b", "uid-c")}
	flags := &fakeFlags{on: map[string]bool{"uid-a:graph": true, "uid-b:graph": true, "uid-c:graph": true}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{Flags: flags})
	return relFixture{svc: svc, repo: repo, dir: dir}
}

func (f relFixture) get(caller, target string) (ProfileRelationship, error) {
	return f.svc.GetProfileRelationship(context.Background(), caller, target)
}

// TestGetProfileRelationship_Matrix (ADR-0024 D7): the relationship comes from the caller's snapshot, followed_by from
// the edge follows/{target}_{caller}, and every refusal costs no edge read.
func TestGetProfileRelationship_Matrix(t *testing.T) {
	const a, b = "uid-a", "uid-b" // a is the caller, b the target
	tests := []struct {
		name string
		// caller and target snapshots; edge is whether follows/b_a exists.
		callerSnap, targetSnap Snapshot
		edge                   bool
		status                 identity.AccountStatus // target's status; 0 = missing
		target                 string
		want                   ProfileRelationship
		wantNotFound           bool
		wantEdgeReads          int
		wantDirGets            int
		wantSnapReads          int // fakeRepo.GetSnapshot calls
	}{
		{
			name: "stranger", callerSnap: snapOf(nil, nil, nil, nil), status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateNone}},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "caller follows target, target does not follow back", callerSnap: snapOf([]string{b}, nil, nil, nil), status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateFollowing}},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "target follows caller only", callerSnap: snapOf(nil, nil, nil, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateNone}, FollowedBy: true},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "mutual follow", callerSnap: snapOf([]string{b}, nil, nil, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateFollowing}, FollowedBy: true},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "caller mutes the target, target follows caller", callerSnap: snapOf(nil, nil, []string{b}, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateNone, Muting: true}, FollowedBy: true},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			// Block deleted both edges, so followed_by is false without a read; a stale edge in the fake must not leak.
			name: "caller blocks the target", callerSnap: snapOf(nil, []string{b}, nil, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateNone, Blocking: true}},
			wantEdgeReads: 0, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			// The target blocked the caller: NOT_FOUND before the Directory and the edge; the edge in the fake must not leak.
			name: "target blocked the caller", callerSnap: snapOf(nil, nil, nil, []string{b}), edge: true, status: identity.AccountStatusActive,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 0, wantSnapReads: 1,
		},
		{
			name: "target blocked the caller and the caller blocked it too", callerSnap: snapOf(nil, []string{b}, nil, []string{b}), status: identity.AccountStatusActive,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 0, wantSnapReads: 1,
		},
		{
			name: "target missing", callerSnap: snapOf(nil, nil, nil, nil), edge: true, status: 0,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "target suspended", callerSnap: snapOf(nil, nil, nil, nil), edge: true, status: identity.AccountStatusSuspended,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			name: "target deleting", callerSnap: snapOf(nil, nil, nil, nil), edge: true, status: identity.AccountStatusDeleting,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 1, wantSnapReads: 1,
		},
		{
			// The caller's own id: NONE and false, nothing read at all (the Directory included).
			name: "own id", target: a, callerSnap: snapOf([]string{b}, nil, nil, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: a, FollowState: FollowStateNone}},
			wantEdgeReads: 0, wantDirGets: 0, wantSnapReads: 0,
		},
		{
			// Overflow: the caller's blockedBy may be incomplete, so the target's own graph is read (+1) and says it blocked the caller.
			name: "overflow caller, target blocked it", callerSnap: Snapshot{BlockedByOverflow: true}, targetSnap: snapOf(nil, []string{a}, nil, nil), edge: true, status: identity.AccountStatusActive,
			wantNotFound:  true,
			wantEdgeReads: 0, wantDirGets: 0, wantSnapReads: 2,
		},
		{
			name: "overflow caller, target did not block it", callerSnap: Snapshot{BlockedByOverflow: true}, targetSnap: snapOf(nil, nil, nil, nil), edge: true, status: identity.AccountStatusActive,
			want:          ProfileRelationship{Relationship: Relationship{UserID: b, FollowState: FollowStateNone}, FollowedBy: true},
			wantEdgeReads: 1, wantDirGets: 1, wantSnapReads: 2,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newRelFixture(t)
			target := tt.target
			if target == "" {
				target = b
			}
			f.repo.snapshots[a] = tt.callerSnap
			f.repo.snapshots[b] = tt.targetSnap
			f.repo.followEdges = map[edgeKey]bool{{follower: b, followee: a}: tt.edge}
			if tt.status == 0 {
				delete(f.dir.Directory.(*fakeDirectory).profiles, b)
			} else {
				f.dir.Directory.(*fakeDirectory).profiles[b] = identity.Profile{UserID: b, Status: tt.status}
			}

			got, err := f.get(a, target)
			if tt.wantNotFound {
				assertProfileNotFound(t, err)
				if got != (ProfileRelationship{}) {
					t.Errorf("a refused call returned %+v, want the zero value", got)
				}
			} else {
				if err != nil {
					t.Fatalf("GetProfileRelationship: %v", err)
				}
				if got != tt.want {
					t.Errorf("got %+v, want %+v", got, tt.want)
				}
			}
			if f.repo.edgeExistsCalls != tt.wantEdgeReads {
				t.Errorf("edge reads = %d, want %d", f.repo.edgeExistsCalls, tt.wantEdgeReads)
			}
			if f.dir.gets != tt.wantDirGets {
				t.Errorf("Directory.GetProfiles calls = %d, want %d", f.dir.gets, tt.wantDirGets)
			}
			if f.repo.calls != tt.wantSnapReads {
				t.Errorf("graph snapshot reads = %d, want %d", f.repo.calls, tt.wantSnapReads)
			}
		})
	}
}

// assertProfileNotFound compares err with the exact answer identity.GetProfile gives for a missing user: same code,
// reason, message and metadata, so a blocked-by target cannot be told apart from an absent one (ADR-0008 D9).
func assertProfileNotFound(t *testing.T, err error) {
	t.Helper()
	var got, want *apierr.Error
	if !errors.As(err, &got) {
		t.Fatalf("err = %v, want NOT_FOUND", err)
	}
	if !errors.As(identity.ProfileNotFoundError(), &want) {
		t.Fatal("identity.ProfileNotFoundError is not an apierr.Error")
	}
	if got.Code != want.Code || got.Reason != want.Reason || got.Message != want.Message || !reflect.DeepEqual(got.Metadata, want.Metadata) {
		t.Errorf("not-found answer = %#v, want %#v (byte-identical to GetProfile)", got, want)
	}
	if got.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED || got.Message != "profile not found" {
		t.Errorf("not-found answer = %#v, want UNSPECIFIED / profile not found", got)
	}
}

// TestGetProfileRelationship_InvalidTarget: a malformed target id is VALIDATION user_id before any read.
func TestGetProfileRelationship_InvalidTarget(t *testing.T) {
	for _, target := range []string{"", "a_b", "has space", "x/y"} {
		t.Run(target, func(t *testing.T) {
			f := newRelFixture(t)
			_, err := f.get("uid-a", target)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument || ae.Metadata["field"] != "user_id" {
				t.Fatalf("err = %#v, want INVALID_ARGUMENT field=user_id", err)
			}
			if f.repo.calls != 0 || f.repo.edgeExistsCalls != 0 || f.dir.gets != 0 {
				t.Errorf("reads before validation: snapshots=%d edges=%d directory=%d", f.repo.calls, f.repo.edgeExistsCalls, f.dir.gets)
			}
		})
	}
}

// TestGetProfileRelationship_FlagOff: the graph flag is checked first and nothing is read.
func TestGetProfileRelationship_FlagOff(t *testing.T) {
	f := newRelFixture(t)
	_, err := f.get("uid-not-allowlisted", "uid-b")
	if featureDisabled(err) == nil {
		t.Fatalf("err = %#v, want FEATURE_DISABLED", err)
	}
	if f.repo.calls != 0 || f.repo.edgeExistsCalls != 0 || f.dir.gets != 0 {
		t.Errorf("a refused call read: snapshots=%d edges=%d directory=%d", f.repo.calls, f.repo.edgeExistsCalls, f.dir.gets)
	}
}

// TestGetProfileRelationship_ErrorsAreRedacted: a failing edge read is an internal error that names no uid.
func TestGetProfileRelationship_ErrorsAreRedacted(t *testing.T) {
	f := newRelFixture(t)
	f.repo.edgeExistsErr = errors.New("rpc error: documents/follows/uid-b_uid-a unavailable")
	_, err := f.get("uid-a", "uid-b")
	if err == nil {
		t.Fatal("want an error")
	}
	for _, uid := range []string{"uid-a", "uid-b"} {
		if strings.Contains(err.Error(), uid) {
			t.Errorf("error text %q names %s", err.Error(), uid)
		}
	}
}

// TestGetProfileRelationship_CachesTheEdge (ADR-0024 D7): both answers are cached per pair, so the repeat view is 0
// edge reads whether the target follows the caller or not, and the cache key is (target -> caller).
func TestGetProfileRelationship_CachesTheEdge(t *testing.T) {
	for _, edge := range []bool{true, false} {
		f := newRelFixture(t)
		f.repo.followEdges = map[edgeKey]bool{{follower: "uid-b", followee: "uid-a"}: edge}
		for i := 0; i < 3; i++ {
			got, err := f.get("uid-a", "uid-b")
			if err != nil || got.FollowedBy != edge {
				t.Fatalf("edge=%v call %d: %+v, %v", edge, i, got, err)
			}
		}
		if f.repo.edgeExistsCalls != 1 || f.repo.calls != 1 || f.dir.gets != 3 {
			t.Errorf("edge=%v: edge reads=%d snapshot reads=%d, want 1 and 1 (3 Directory lookups: cache-first inside identity)", edge, f.repo.edgeExistsCalls, f.repo.calls)
		}
	}
}

// TestGetProfileRelationship_CacheKeyIsPerPair: another viewer of the same profile, and the same viewer of another
// profile, each get their own edge read.
func TestGetProfileRelationship_CacheKeyIsPerPair(t *testing.T) {
	f := newRelFixture(t)
	f.repo.followEdges = map[edgeKey]bool{{follower: "uid-b", followee: "uid-a"}: true}
	if got, _ := f.get("uid-a", "uid-b"); !got.FollowedBy {
		t.Fatal("b -> a edge not seen")
	}
	if got, err := f.get("uid-c", "uid-b"); err != nil || got.FollowedBy {
		t.Fatalf("viewer c of b: %+v, %v (c has no edge from b)", got, err)
	}
	if got, err := f.get("uid-a", "uid-c"); err != nil || got.FollowedBy {
		t.Fatalf("viewer a of c: %+v, %v (a has no edge from c)", got, err)
	}
	if f.repo.edgeExistsCalls != 3 {
		t.Errorf("edge reads = %d, want 3 (one per pair)", f.repo.edgeExistsCalls)
	}
}

// TestGetProfileRelationship_EvictionByWrites (ADR-0024 D7): the pair is evicted on this instance by exactly the writes
// that change the edge it names. For each write, `evicted` is the viewer->profile views whose cached answer must go and
// `kept` the views that must survive. A flipped key fails the row: (viewer a, profile b) names the edge b->a.
func TestGetProfileRelationship_EvictionByWrites(t *testing.T) {
	type view struct{ viewer, profile string }
	aOfB := view{"uid-a", "uid-b"} // edge b -> a: "b follows a"
	bOfA := view{"uid-b", "uid-a"} // edge a -> b: "a follows b"
	cOfB := view{"uid-c", "uid-b"} // edge b -> c: an unrelated pair
	tests := []struct {
		name    string
		write   func(t *testing.T, f relFixture)
		evicted []view
		kept    []view
	}{
		{
			name: "the target follows the caller (b follows a)",
			write: func(t *testing.T, f relFixture) {
				f.repo.followOutcome = OutcomeCreated
				if _, err := f.svc.Follow(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB}, kept: []view{bOfA, cOfB},
		},
		{
			name: "the caller follows the target (a follows b): the caller's own Follow never changes b -> a",
			write: func(t *testing.T, f relFixture) {
				f.repo.followOutcome = OutcomeCreated
				if _, err := f.svc.Follow(context.Background(), "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{bOfA}, kept: []view{aOfB, cOfB},
		},
		{
			name: "a replayed Follow by the target",
			write: func(t *testing.T, f relFixture) {
				f.repo.followOutcome = OutcomeReplay
				if _, err := f.svc.Follow(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB}, kept: []view{bOfA, cOfB},
		},
		{
			name: "a failed Follow by the target changes nothing",
			write: func(t *testing.T, f relFixture) {
				f.repo.followErr = ErrNotFoundOrBlocked
				if _, err := f.svc.Follow(context.Background(), "uid-b", validKey, "uid-a"); err == nil {
					t.Fatal("want an error")
				}
			},
			kept: []view{aOfB, bOfA, cOfB},
		},
		{
			name: "the target unfollows the caller (b unfollows a)",
			write: func(t *testing.T, f relFixture) {
				f.repo.unfollowChanged = true
				if _, err := f.svc.Unfollow(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB}, kept: []view{bOfA, cOfB},
		},
		{
			name: "the caller unfollows the target (a unfollows b): never changes b -> a",
			write: func(t *testing.T, f relFixture) {
				f.repo.unfollowChanged = true
				if _, err := f.svc.Unfollow(context.Background(), "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{bOfA}, kept: []view{aOfB, cOfB},
		},
		{
			name: "a no-op Unfollow by the target (the edge was already gone, perhaps on another instance)",
			write: func(t *testing.T, f relFixture) {
				f.repo.unfollowChanged = false
				if _, err := f.svc.Unfollow(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB}, kept: []view{bOfA, cOfB},
		},
		{
			name: "the caller blocks the target: both edges go",
			write: func(t *testing.T, f relFixture) {
				f.repo.blockResult = BlockResult{Outcome: OutcomeCreated}
				if _, err := f.svc.Block(context.Background(), "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB, bOfA}, kept: []view{cOfB},
		},
		{
			name: "the target blocks the caller: both edges go",
			write: func(t *testing.T, f relFixture) {
				f.repo.blockResult = BlockResult{Outcome: OutcomeCreated}
				if _, err := f.svc.Block(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
					t.Fatal(err)
				}
			},
			evicted: []view{aOfB, bOfA}, kept: []view{cOfB},
		},
		{
			name: "a Block that failed (quota) changes nothing",
			write: func(t *testing.T, f relFixture) {
				f.repo.blockErr = &LimitReachedError{Limit: "blocks_per_day"}
				if _, err := f.svc.Block(context.Background(), "uid-a", validKey, "uid-b"); err == nil {
					t.Fatal("want an error")
				}
			},
			kept: []view{aOfB, bOfA, cOfB},
		},
		{
			name: "Unblock, Mute and Unmute never touch an edge",
			write: func(t *testing.T, f relFixture) {
				f.repo.unblockChanged, f.repo.muteOutcome, f.repo.unmuteChanged = true, OutcomeCreated, true
				ctx := context.Background()
				if _, err := f.svc.Unblock(ctx, "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
				if _, err := f.svc.Mute(ctx, "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
				if _, err := f.svc.Unmute(ctx, "uid-a", validKey, "uid-b"); err != nil {
					t.Fatal(err)
				}
			},
			kept: []view{aOfB, bOfA, cOfB},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newRelFixture(t)
			f.repo.followResult = Relationship{FollowState: FollowStateFollowing}
			// Every view is cached: the edge answers are all "false" so a later re-read is visible as a flip to true.
			for _, v := range []view{aOfB, bOfA, cOfB} {
				if _, err := f.get(v.viewer, v.profile); err != nil {
					t.Fatalf("warm %v: %v", v, err)
				}
			}
			if f.repo.edgeExistsCalls != 3 {
				t.Fatalf("warm-up edge reads = %d, want 3", f.repo.edgeExistsCalls)
			}
			// Now all three edges "exist" in Firestore; only an evicted view can notice.
			f.repo.followEdges = map[edgeKey]bool{
				{follower: "uid-b", followee: "uid-a"}: true, {follower: "uid-a", followee: "uid-b"}: true, {follower: "uid-b", followee: "uid-c"}: true,
			}
			tt.write(t, f)
			// A Block made the viewer-blocks-profile views Blocking (no edge read); read the cache state directly too.
			for _, v := range tt.evicted {
				if _, ok := f.svc.cache.Edge(v.profile, v.viewer); ok {
					t.Errorf("view %v (edge %s -> %s) is still cached after the write", v, v.profile, v.viewer)
				}
			}
			for _, v := range tt.kept {
				if got, ok := f.svc.cache.Edge(v.profile, v.viewer); !ok || got {
					t.Errorf("view %v (edge %s -> %s): cached = (%v, %v), want the untouched (false, true)", v, v.profile, v.viewer, got, ok)
				}
			}
		})
	}
}

// TestGetProfileRelationship_FollowedByAfterTheTargetFollows is the user-visible form of the eviction: a viewer who saw
// "does not follow you" sees "Follows you" on the next view after the target's Follow lands on this instance, and still
// sees the old answer after their own Follow.
func TestGetProfileRelationship_FollowedByAfterTheTargetFollows(t *testing.T) {
	f := newRelFixture(t)
	f.repo.followOutcome = OutcomeCreated
	if got, err := f.get("uid-a", "uid-b"); err != nil || got.FollowedBy {
		t.Fatalf("before: %+v, %v", got, err)
	}
	f.repo.followEdges = map[edgeKey]bool{{follower: "uid-b", followee: "uid-a"}: true}

	// a's own Follow of b leaves b -> a alone: a still sees the cached false (staleness bound: the cache TTL).
	if _, err := f.svc.Follow(context.Background(), "uid-a", validKey, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if got, _ := f.get("uid-a", "uid-b"); got.FollowedBy {
		t.Error("the caller's own Follow evicted the pair: followed_by flipped")
	}
	if f.repo.edgeExistsCalls != 1 {
		t.Errorf("edge reads after the caller's own Follow = %d, want 1 (cache hit)", f.repo.edgeExistsCalls)
	}

	// b follows a: the pair is evicted on this instance and the next view re-reads and sees true.
	if _, err := f.svc.Follow(context.Background(), "uid-b", validKey, "uid-a"); err != nil {
		t.Fatal(err)
	}
	got, err := f.get("uid-a", "uid-b")
	if err != nil || !got.FollowedBy {
		t.Fatalf("after the target's Follow: %+v, %v, want followed_by", got, err)
	}
	if f.repo.edgeExistsCalls != 2 {
		t.Errorf("edge reads = %d, want 2", f.repo.edgeExistsCalls)
	}
}

// TestGetProfileRelationship_FlagMatrix (ADR-0024 D7, D9): the RPC is gated by FEATURE_GRAPH only, in every mode
// (off, allowlist in and out, percent in and out, on, not registered, retired); no W3 flag changes the answer. A
// refusal is FEATURE_DISABLED for the whole service (no feature metadata) and reads nothing; a pass answers through the
// handler with the relationship and followed_by.
func TestGetProfileRelationship_FlagMatrix(t *testing.T) {
	const in, out, target = "in-cohort", "out-of-cohort", "uid-t"
	pct := flags.Spec{Name: graphFlagName, Mode: flags.Percent, Percent: 50}
	var pIn, pOut string
	for i := 0; i < 1000 && (pIn == "" || pOut == ""); i++ {
		uid := "p" + string(rune('a'+i%26)) + string(rune('a'+(i/26)%26)) + string(rune('a'+(i/676)%26))
		if flags.NewRegistry(pct).Enabled(uid, graphFlagName) {
			pIn = uid
		} else {
			pOut = uid
		}
	}
	if pIn == "" || pOut == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	allow := map[string]struct{}{in: {}}
	sug := func(m flags.Mode) flags.Spec {
		return flags.Spec{Name: FollowSuggestionsFlagName, Mode: m, Allowlist: allow}
	}
	tests := []struct {
		name     string
		reg      []flags.Spec
		uid      string
		wantPass bool
	}{
		{"graph on", []flags.Spec{{Name: graphFlagName, Mode: flags.On}}, out, true},
		{"graph on, suggestions off", []flags.Spec{{Name: graphFlagName, Mode: flags.On}, sug(flags.Off)}, out, true},
		{"graph on, suggestions on", []flags.Spec{{Name: graphFlagName, Mode: flags.On}, sug(flags.On)}, out, true},
		{"graph allowlist, caller in", []flags.Spec{{Name: graphFlagName, Mode: flags.Allowlist, Allowlist: allow}}, in, true},
		{"graph allowlist, caller out", []flags.Spec{{Name: graphFlagName, Mode: flags.Allowlist, Allowlist: allow}}, out, false},
		{"graph allowlist, empty list", []flags.Spec{{Name: graphFlagName, Mode: flags.Allowlist}}, in, false},
		{"graph percent, caller in the bucket", []flags.Spec{pct}, pIn, true},
		{"graph percent, caller outside", []flags.Spec{pct}, pOut, false},
		{"graph percent 0", []flags.Spec{{Name: graphFlagName, Mode: flags.Percent}}, in, false},
		{"graph off", []flags.Spec{{Name: graphFlagName, Mode: flags.Off}}, in, false},
		{"graph off, suggestions on", []flags.Spec{{Name: graphFlagName, Mode: flags.Off}, sug(flags.On)}, in, false},
		{"graph not registered", nil, in, false},
		{"graph retired (on forever)", []flags.Spec{flags.NewRetired(graphFlagName)}, out, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.snapshots[tt.uid] = snapOf([]string{target}, nil, nil, nil)
			repo.followEdges = map[edgeKey]bool{{follower: target, followee: tt.uid}: true}
			svc := New(Deps{Repo: repo, Cache: NewCache(time.Minute), Flags: flags.NewRegistry(tt.reg...)})
			dir := &countingDirectory{Directory: activeProfiles(target)}
			svc.SetDirectory(dir)
			ctx, counter := budget.WithCounter(w3Ctx(tt.uid))

			resp, err := NewServer(svc).GetProfileRelationship(ctx, connect.NewRequest(&graphv1.GetProfileRelationshipRequest{UserId: target}))
			if tt.wantPass {
				if err != nil {
					t.Fatalf("err = %v, want a pass", err)
				}
				rel := resp.Msg.GetRelationship()
				if rel.GetUserId() != target || rel.GetFollowState() != graphv1.FollowState_FOLLOW_STATE_FOLLOWING || !resp.Msg.GetFollowedBy() {
					t.Errorf("response = %v, want FOLLOWING %s with followed_by", resp.Msg, target)
				}
				return
			}
			if ae := featureDisabled(err); ae == nil || ae.Metadata["feature"] != "" {
				t.Fatalf("err = %#v, want FEATURE_DISABLED without a feature (the whole service)", err)
			}
			if repo.calls != 0 || repo.edgeExistsCalls != 0 || dir.gets != 0 {
				t.Errorf("a refused call read: snapshots=%d edges=%d directory=%d", repo.calls, repo.edgeExistsCalls, dir.gets)
			}
			budgettest.Assert(t, "GetProfileRelationship (refused)", counter, budgettest.Budget{})
		})
	}
}
