// suggestions.go holds the ADR-0024 D8 graph RPC ListSuggestedUsers (W3-12) and the types its config and flag use: the
// flag gate (before any Firestore access), the per-viewer cache lookup, the exclusion matrix over whatever the
// Suggester returns and the single hydration call. The candidate sources are in suggester.go, the cache in
// suggestion_cache.go, the one new query in repo_suggestions.go.
package graph

import (
	"context"
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FollowSuggestionsFlagName is the wire name of FEATURE_FOLLOW_SUGGESTIONS (ADR-0024 D9). ListSuggestedUsers needs it
// on for the caller, and FEATURE_GRAPH.
const FollowSuggestionsFlagName = "follow_suggestions"

// SuggestionLimits are the ListSuggestedUsers limits (ADR-0024 D8, D10), mapped by apiserver from
// config.SuggestionsConfig (config.Load has already bounded them). The graph module does not import platform/config.
type SuggestionLimits struct {
	// SampleFollowees is how many of the caller's newest followees seed the friends-of-friends query (<= 30).
	SampleFollowees int
	// EdgeLimit is the Limit of that query (<= 50; 0 means the config default 20). It sets the cold cap: 2 + EdgeLimit +
	// HydrateMax = 32 reads at the defaults, 42 at 30 (ADR-0024 Amendment 2 B1(b)).
	EdgeLimit int
	// HydrateMax is the most candidates hydrated through identity.Directory (<= 50). The curated path costs 2 + HydrateMax =
	// 12 at the default 10; a warm call costs 1 to 2.
	HydrateMax int
	// MaxResults is the most users one call returns (<= 5, the proto clamp).
	MaxResults int
	// CacheTTL is the per-viewer instance cache bound: a result may be up to this old.
	CacheTTL time.Duration
	// CuratedUIDs is the SUGGESTED_USER_IDS fallback list (validated, <= 20, may be empty).
	CuratedUIDs []string
}

// ListSuggestedUsers is the ADR-0024 D8 "who to follow" RPC: at most maxResults rows (0 => SUGGESTIONS_MAX_RESULTS = 5,
// clamped to 1..5), best first, no cursor, Since unset, possibly none. It needs FEATURE_GRAPH, then
// FEATURE_FOLLOW_SUGGESTIONS on for the caller (FEATURE_DISABLED with metadata feature=follow_suggestions), both before
// any Firestore access.
//
// Order: the per-viewer cache (warm); else the caller's Snapshot (cache-first), the Suggester (friends of friends with
// the curated fallback), the exclusion matrix again, ONE identity.Directory.GetProfiles over at most HydrateMax
// candidates (non-ACTIVE and deleted users drop out), then the cache. The "fewer than 3" decision between friends of
// friends and the curated list is made inside the Suggester, after the exclusion matrix.
//
// Firestore: hard cap 32 reads cold (interceptor 1, caller graph 1, edges <= EdgeLimit 20, hydration <= HydrateMax 10;
// 2 + EdgeLimit + HydrateMax, so 42 only if a project sets EdgeLimit 30, ADR-0024 Amendment 2 B1(b)), 12 on the curated
// path (1 + 1 + 10; the edge query is skipped when the caller follows fewer than 3 accounts), 1 warm (the interceptor;
// the cache holds the hydrated rows) or 2 warm when the viewer's 60 s snapshot has expired (the re-filter loads
// graph/{viewer} once, W3-22 L-1), planning 27.6 per call (0.95 x (0.85 x 32 + 0.15 x 12) + 0.05 x 1.5); 0 writes. This
// method itself accounts for the reads past the interceptor: 31 cold worst, 0 warm with a cached snapshot, 1 warm
// without. Request log: source (fof | curated | none), candidates (uids sent to hydration), suggestions_cache_hit,
// graph_cache_hit.
//
// Staleness: a viewer's rows may be up to SUGGESTIONS_CACHE_TTL (1 h) old as to who is ACTIVE or still exists, but
// never older than the 60 s snapshot cache as to the viewer's follows, blocks, mutes and blockedBy: every warm hit is
// re-filtered against the snapshot (see refilterCached and suggestionCache).
func (s *service) ListSuggestedUsers(ctx context.Context, callerUID string, maxResults int32) (_ []ListItem, err error) {
	defer begin(ctx, "suggested_users")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return nil, err
	}
	if !s.flags.Enabled(callerUID, FollowSuggestionsFlagName) {
		logger.SetRequestField(ctx, "feature", FollowSuggestionsFlagName)
		return nil, flags.DisabledError().WithMeta("feature", FollowSuggestionsFlagName)
	}
	want := clampMaxResults(maxResults, s.suggestions.MaxResults)
	now := s.now()

	if e, ok := s.suggested.get(callerUID, now); ok {
		noteSuggestions(ctx, e.source, e.candidates, true)
		items, err := s.refilterCached(ctx, callerUID, e.items)
		if err != nil {
			return nil, err
		}
		return firstN(items, want), nil
	}

	snap, err := s.Snapshot(ctx, callerUID)
	if err != nil {
		return nil, s.internalErr("suggestions", err, callerUID)
	}
	sug, err := s.suggester.Suggest(ctx, callerUID, snap)
	if err != nil {
		return nil, s.internalErr("suggestions", err, append([]string{callerUID}, snap.RecentFollowing...)...)
	}
	candidates := s.usableCandidates(callerUID, snap, sug.Candidates)

	var items []ListItem
	if len(candidates) > 0 {
		profiles, err := s.directory.GetProfiles(ctx, candidates)
		if err != nil {
			return nil, s.internalErr("suggestions hydrate", err, append([]string{callerUID}, candidates...)...)
		}
		items = make([]ListItem, 0, len(candidates))
		for _, uid := range candidates {
			if p, ok := profiles[uid]; ok {
				items = append(items, ListItem{User: p, Relationship: relationshipFor(snap, uid)})
			}
		}
	}
	s.suggested.put(callerUID, suggestionEntry{items: items, source: sug.Source, candidates: len(candidates)}, now)
	noteSuggestions(ctx, sug.Source, len(candidates), false)
	return firstN(items, want), nil
}

// usableCandidates is the exclusion matrix applied to whatever a Suggester returned, plus de-duplication, a valid-uid
// check and the HydrateMax cap: the list that is sent to identity.Directory in one call, so the cap of 10 hydration
// reads holds for every source.
func (s *service) usableCandidates(viewer string, snap Snapshot, candidates []string) []string {
	out := make([]string, 0, min(len(candidates), s.suggestions.HydrateMax))
	seen := make(map[string]struct{}, len(candidates))
	for _, uid := range candidates {
		if len(out) == s.suggestions.HydrateMax {
			break
		}
		if _, dup := seen[uid]; dup || !ids.ValidUID(uid) || !suggestable(viewer, snap, uid) {
			continue
		}
		seen[uid] = struct{}{}
		out = append(out, uid)
	}
	return out
}

// refilterCached drops, from a warm hit's rows, whoever the viewer's snapshot now excludes (W3-22 L-1). The snapshot
// comes from s.Snapshot: the 60 s snapshot cache when it holds one (0 reads), else ONE read of graph/{viewer}, which
// is then cached for 60 s like every other read path (ADR-0008 D8). So a user who blocked the viewer on another
// instance, or whom the viewer followed or blocked elsewhere, is gone from the answer within 60 s, never after the
// 1 h entry. The entry itself is not rewritten: it keeps its original expiry.
//
// Fails closed: a snapshot read error is returned (the caller maps it exactly as on the cold path) rather than served
// as an empty list, because the client keeps an OK answer for 24 h and would store "no suggestions"; an overflowed
// blockedBy (a blocker cannot be ruled out at 0 reads) yields no rows. Returns a new slice.
func (s *service) refilterCached(ctx context.Context, viewer string, items []ListItem) ([]ListItem, error) {
	snap, err := s.Snapshot(ctx, viewer)
	if err != nil {
		return nil, s.internalErr("suggestions", err, viewer)
	}
	if snap.BlockedByOverflow {
		return nil, nil
	}
	out := make([]ListItem, 0, len(items))
	for _, it := range items {
		if suggestable(viewer, snap, it.User.UserID) {
			out = append(out, it)
		}
	}
	return out, nil
}

// dropSuggested removes users from the viewer's cached suggestions on this instance: called by the mutations that
// make a user unsuitable at once (Follow, Block, Mute).
func (s *service) dropSuggested(viewer string, uids ...string) {
	s.suggested.remove(viewer, uids...)
}

// clampMaxResults is the request's max_results: 0 (unset) => limit, otherwise 1..limit.
func clampMaxResults(requested int32, limit int) int {
	switch {
	case requested <= 0:
		return limit
	case int(requested) > limit:
		return limit
	}
	return int(requested)
}

// firstN returns a fresh slice of at most n leading rows (never the cache's own backing array).
func firstN(items []ListItem, n int) []ListItem {
	return slices.Clone(items[:min(len(items), n)])
}
