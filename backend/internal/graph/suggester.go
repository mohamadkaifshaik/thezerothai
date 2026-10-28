package graph

import (
	"cmp"
	"context"
	"hash/fnv"
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Suggestion sources, the request-log field "source" (ADR-0024 D8).
const (
	// SuggestionSourceFriendsOfFriends: at least minSuggestions usable friends of friends, no curated row added.
	SuggestionSourceFriendsOfFriends = "fof"
	// SuggestionSourceCurated: the curated SUGGESTED_USER_IDS list was consulted (the viewer follows fewer than
	// minSuggestions accounts, or friends of friends gave fewer than minSuggestions usable candidates). Any friends of
	// friends found come first, curated rows fill after them.
	SuggestionSourceCurated = "curated"
	// SuggestionSourceNone: nothing is suggested at all, because the viewer's blockedBy list is incomplete
	// (Snapshot.BlockedByOverflow) and a candidate who blocked the viewer could not be ruled out at 0 reads.
	SuggestionSourceNone = "none"
)

// maxCandidatesPerFollowee is how many candidates one sampled followee may contribute to a window (W3-22 L-5): its
// newest three usable edges. Without it one very active account that many people follow (a follow-back bait account
// that follows thirty promotion accounts in a minute) fills the whole EdgeLimit-edge window (20 by default, ADR-0024
// Amendment 2) and picks every row for all of its followers. A constant, not config: it is part of the ranking, like
// minSuggestions. It does not free the window (a flooder's edges are still the newest EdgeLimit the one query
// returns): it bounds the damage to three candidates, which
// shows in the log as source=fof with candidates <= 3 (docs/runbooks/graph.md section 6).
const maxCandidatesPerFollowee = 3

// minSuggestions is the "fewer than 3" of ADR-0024 D8: the viewer needs at least this many followees to seed the
// friends-of-friends query, and at least this many usable friends of friends to skip the curated list.
const minSuggestions = 3

// Suggestion is one Suggester answer.
type Suggestion struct {
	// Source is one of the SuggestionSource values (or a future source's own name); it is only logged.
	Source string
	// Candidates are user ids, best first. A Suggester should leave out the viewer and everyone suggestable() refuses,
	// but ListSuggestedUsers filters, de-duplicates, caps and hydrates whatever comes back, so a faulty source cannot
	// leak a blocked or followed user.
	Candidates []string
}

// Suggester is the candidate source behind ListSuggestedUsers (ADR-0024 D8). The default is friends of friends with
// the curated fallback (option a, c); option (b) or a precomputed list implements this interface and is passed as
// Deps.Suggester, and the RPC, its cache and its read cap do not change. Suggest receives the viewer's cached
// Snapshot (0 reads); the RPC's hard cap (32 reads cold at the default EdgeLimit 20; 42 at 30) assumes it makes at
// most one query of at most SuggestionLimits.EdgeLimit documents and returns at most SuggestionLimits.HydrateMax
// candidates.
type Suggester interface {
	Suggest(ctx context.Context, viewerUID string, snap Snapshot) (Suggestion, error)
}

// inactiveProber is an optional extension of identity.Directory: which of uids its profile cache ALREADY knows are not
// ACTIVE (SUSPENDED, DELETING) or are gone. Cache only: 0 reads, and a uid the cache has not seen is absent, never
// "active". identity's service implements it (KnownInactive); a Directory that does not (a fake, a future source) simply
// reports nothing. It is asserted lazily on service.directory, which is only set after construction (SetDirectory).
type inactiveProber interface {
	KnownInactive(uids []string) map[string]bool
}

// followerEdgeLister is the one storage call the default Suggester makes; Repo satisfies it.
type followerEdgeLister interface {
	ListEdgesByFollowers(ctx context.Context, followers []string, limit int) ([]Edge, error)
}

// friendsOfFriends is the default Suggester: ADR-0024 D8 steps 2 to 4 and the curated fallback.
type friendsOfFriends struct {
	edges  followerEdgeLister
	limits SuggestionLimits // normalized
	now    func() time.Time
	// inactive reports which of the given uids are already known not to be ACTIVE, at 0 reads (see inactiveProber).
	// nil, or a nil result, means nothing is known.
	inactive func(uids []string) map[string]bool
}

func newFriendsOfFriends(edges followerEdgeLister, limits SuggestionLimits, now func() time.Time) *friendsOfFriends {
	return &friendsOfFriends{edges: edges, limits: limits, now: now}
}

// Suggest implements Suggester. Reads: 0 when the viewer follows fewer than minSuggestions accounts (curated only) or
// when every sampled followee is already known to be non-ACTIVE, else one query of at most EdgeLimit follow documents
// (minimum 1). The "fewer than 3 candidates" test is made after
// the exclusion matrix, so a candidate the viewer could not be shown does not count.
func (f *friendsOfFriends) Suggest(ctx context.Context, viewer string, snap Snapshot) (Suggestion, error) {
	if snap.BlockedByOverflow {
		return Suggestion{Source: SuggestionSourceNone}, nil
	}
	var ranked []string
	if len(snap.Following) >= minSuggestions {
		var err error
		if ranked, err = f.rankedFriendsOfFriends(ctx, viewer, snap); err != nil {
			return Suggestion{}, err
		}
	}
	if len(ranked) >= minSuggestions {
		return Suggestion{Source: SuggestionSourceFriendsOfFriends, Candidates: capLen(ranked, f.limits.HydrateMax)}, nil
	}
	seen := make(map[string]struct{}, len(ranked)+len(f.limits.CuratedUIDs))
	for _, uid := range ranked {
		seen[uid] = struct{}{}
	}
	added := 0
	for _, uid := range f.limits.CuratedUIDs {
		if _, dup := seen[uid]; dup || !suggestable(viewer, snap, uid) {
			continue
		}
		seen[uid] = struct{}{}
		ranked = append(ranked, uid)
		added++
	}
	source := SuggestionSourceCurated
	if added == 0 && len(ranked) > 0 {
		source = SuggestionSourceFriendsOfFriends
	}
	return Suggestion{Source: source, Candidates: capLen(ranked, f.limits.HydrateMax)}, nil
}

// rankedFriendsOfFriends runs the one query (the newest follows made by the viewer's newest SampleFollowees
// followees), drops what suggestable() refuses, counts how many sampled followees follow each candidate and orders
// by that count, then by a hash of (viewer, candidate, IST day) so the order is stable within a day and shuffles
// across days. A count of one is the common case with the default 20-edge window, so the hash is the real order.
//
// W3-22 L-5, both at 0 reads: a sampled followee the Directory cache already knows is not ACTIVE is left out of the
// query's follower list (a suspended spam account no longer steers, and its share of the window goes to the others),
// and each remaining followee contributes at most maxCandidatesPerFollowee candidates, its newest usable edges (the
// query returns edges newest first; an edge the exclusion matrix refuses takes no slot).
func (f *friendsOfFriends) rankedFriendsOfFriends(ctx context.Context, viewer string, snap Snapshot) ([]string, error) {
	sample := f.activeSample(capLen(snap.RecentFollowing, f.limits.SampleFollowees))
	if len(sample) == 0 {
		return nil, nil
	}
	edges, err := f.edges.ListEdgesByFollowers(ctx, sample, f.limits.EdgeLimit)
	if err != nil {
		return nil, err
	}
	counts := make(map[string]int, len(edges))
	perFollowee := make(map[string]int, len(sample))
	for _, e := range edges {
		if !suggestable(viewer, snap, e.FolloweeID) || perFollowee[e.FollowerID] >= maxCandidatesPerFollowee {
			continue
		}
		perFollowee[e.FollowerID]++
		counts[e.FolloweeID]++
	}
	day := quota.TodayAt(f.now())
	type rankedUID struct {
		uid  string
		n    int
		hash uint64
	}
	order := make([]rankedUID, 0, len(counts))
	for uid, n := range counts {
		order = append(order, rankedUID{uid: uid, n: n, hash: tieBreak(viewer, uid, day)})
	}
	slices.SortFunc(order, func(a, b rankedUID) int {
		return cmp.Or(cmp.Compare(b.n, a.n), cmp.Compare(a.hash, b.hash), cmp.Compare(a.uid, b.uid))
	})
	out := make([]string, len(order))
	for i, r := range order {
		out[i] = r.uid
	}
	return out, nil
}

// activeSample is sample without the followees the Directory cache already knows are not ACTIVE. It returns sample itself
// (never an edited copy of the snapshot's slice) when nothing is known.
func (f *friendsOfFriends) activeSample(sample []string) []string {
	if f.inactive == nil || len(sample) == 0 {
		return sample
	}
	known := f.inactive(sample)
	if len(known) == 0 {
		return sample
	}
	out := make([]string, 0, len(sample))
	for _, uid := range sample {
		if !known[uid] {
			out = append(out, uid)
		}
	}
	return out
}

// tieBreak is the stable per-day order of equally ranked candidates: FNV-64a over viewer, candidate and the IST day
// (quota.TodayAt), separated by a byte no uid contains. Pure, so a test can recompute it.
func tieBreak(viewer, candidate, day string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(viewer))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(candidate))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(day))
	return h.Sum64()
}

// suggestable is ADR-0024 D8 step 4, at 0 reads from the viewer's snapshot: never the viewer, anyone the viewer
// follows or has requested, blocks or mutes, or is blocked by. blockedBy is never serialized to a client; here it only
// removes a row (a user who blocked the viewer must not appear, while GetProfile says NOT_FOUND for them).
func suggestable(viewer string, snap Snapshot, uid string) bool {
	return uid != "" && uid != viewer &&
		!snap.isFollowing(uid) && !snap.Requested[uid] &&
		!snap.isBlocked(uid) && !snap.isBlockedBy(uid) && !snap.isMuted(uid)
}

// capLen returns at most n leading entries of s.
func capLen(s []string, n int) []string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// normalized returns l with every zero or out-of-range value replaced by the config default or clamped to the config
// bound (config.loadSuggestions has already enforced these in production; this keeps a zero SuggestionLimits, as in
// unit tests, safe and the read cap hard even if a caller builds the struct by hand).
func (l SuggestionLimits) normalized() SuggestionLimits {
	l.SampleFollowees = boundedOr(l.SampleFollowees, 30, recentFollowingMax)
	l.EdgeLimit = boundedOr(l.EdgeLimit, 20, maxEdgesLimit)
	l.HydrateMax = boundedOr(l.HydrateMax, 10, 50)
	l.MaxResults = boundedOr(l.MaxResults, 5, 5)
	if l.CacheTTL <= 0 {
		l.CacheTTL = time.Hour
	}
	l.CuratedUIDs = slices.Clone(l.CuratedUIDs)
	return l
}

// boundedOr is def when v <= 0, hi when v > hi, else v.
func boundedOr(v, def, hi int) int {
	switch {
	case v <= 0:
		return def
	case v > hi:
		return hi
	}
	return v
}
