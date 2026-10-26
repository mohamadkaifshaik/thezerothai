// suggestions.go holds the W3-4 gate of the two ADR-0024 graph RPCs: GetProfileRelationship (D7) and
// ListSuggestedUsers (D8). Both are flag-guarded and Unimplemented until their ticket (W3-11, W3-12): this file runs
// the flag gate before any Firestore access and then answers Unimplemented naming the ticket, so neither path reads or
// writes yet. W3-11 and W3-12 replace the Unimplemented answers; the gate and the types stay.
package graph

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
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
	// EdgeLimit is the Limit of that query (<= 50).
	EdgeLimit int
	// HydrateMax is the most candidates hydrated through identity.Directory (<= 50).
	HydrateMax int
	// MaxResults is the most users one call returns (<= 5, the proto clamp).
	MaxResults int
	// CacheTTL is the per-viewer instance cache bound: a result may be up to this old.
	CacheTTL time.Duration
	// CuratedUIDs is the SUGGESTED_USER_IDS fallback list (validated, <= 20, may be empty).
	CuratedUIDs []string
}

// ProfileRelationship is the GetProfileRelationship answer (ADR-0024 D7): the caller's Relationship to one user, plus
// whether that user follows the caller.
type ProfileRelationship struct {
	Relationship Relationship
	// FollowedBy is true when follows/{target}_{caller} exists ("Follows you").
	FollowedBy bool
}

// GetProfileRelationship is the ADR-0024 D7 header RPC. It needs only FEATURE_GRAPH on for the caller, like every
// GraphService RPC; D9 gives it no flag of its own. Today it runs that gate and answers Unimplemented (ticket W3-11):
// 0 reads, 0 writes. When W3-11 lands: 3 cold reads (interceptor, caller graph, edge doc; +1 on blockedByOverflow),
// 0 warm, planning 1; 0 writes.
func (s *service) GetProfileRelationship(ctx context.Context, callerUID, _ string) (_ ProfileRelationship, err error) {
	defer begin(ctx, "profile_relationship")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return ProfileRelationship{}, err
	}
	return ProfileRelationship{}, unimplemented("GetProfileRelationship", "W3-11")
}

// ListSuggestedUsers is the ADR-0024 D8 "who to follow" RPC. It needs FEATURE_GRAPH, then FEATURE_FOLLOW_SUGGESTIONS
// on for the caller (FEATURE_DISABLED with metadata feature=follow_suggestions). Today it runs that gate and answers
// Unimplemented (ticket W3-12): 0 reads, 0 writes. When W3-12 lands: hard cap 42 reads cold (interceptor 1, caller
// graph 1, edges <= SuggestionLimits.EdgeLimit, hydration <= HydrateMax), 12 on the curated path, 1 warm, planning
// 25; 0 writes.
func (s *service) ListSuggestedUsers(ctx context.Context, callerUID string, _ int32) (_ []ListItem, err error) {
	defer begin(ctx, "suggested_users")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return nil, err
	}
	if !s.flags.Enabled(callerUID, FollowSuggestionsFlagName) {
		logger.SetRequestField(ctx, "feature", FollowSuggestionsFlagName)
		return nil, flags.DisabledError().WithMeta("feature", FollowSuggestionsFlagName)
	}
	return nil, unimplemented("ListSuggestedUsers", "W3-12")
}

// unimplemented is the answer behind a passed gate until the ticket that fills the RPC in lands.
func unimplemented(rpc, ticket string) error {
	return connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not implemented yet (ticket %s)", rpc, ticket))
}
