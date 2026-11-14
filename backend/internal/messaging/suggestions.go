package messaging

// suggestions.go is ListMessageSuggestions (F30, FEATURE_DM_SUGGESTIONS): people the caller is likely to message, computed on
// every call from existing data and never stored. The plan and community sources live in other modules and are reached through
// the consumer-side seams below (apiserver adapts beacons and communities to them); the follow-back lookup is graph's batched
// FollowLookup. Every row passes recipientRefusal, the caller-side check SendMessage applies, plus the peer-side rules a send
// applies in its transaction (the peer blocks the caller; FOLLOWING_ONLY), so a suggestion is never a guaranteed refusal.

import (
	"context"
	"errors"
	"fmt"
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// SuggestionsFlagName is the wire name of FEATURE_DM_SUGGESTIONS.
const SuggestionsFlagName = "dm_suggestions"

// The wire names of the source modules' own flags: a source is read only when its module is on for the caller.
const (
	beaconsFlagName     = "beacons"
	communitiesFlagName = "communities"
)

// The per-call bounds (the proto doc comment's figures).
const (
	suggestDefault      = 10
	suggestMax          = 20
	suggestInbox        = 8
	suggestPlans        = 2
	suggestPerPlan      = 4
	suggestMutualPool   = 10
	suggestCommunity    = 6
	suggestMaxCandidate = 20
	suggestPlanLookback = 30 * 24 * time.Hour
)

// Request-line fields (counts only, never a uid).
const (
	fieldSuggestCandidates = "candidates"
	fieldSuggestResults    = "results"
	fieldSuggestDropped    = "rows_dropped"
	fieldSuggestSourceErr  = "source_errors"
)

// PlanMate is one person the caller shared a recent ended plan with (beacons.RecentCoParticipants, adapted by apiserver).
type PlanMate struct {
	UID      string
	Activity beaconsv1.BeaconActivity
}

// CommunityMate is one recent member of the community the caller joined last (communities.RecentCoMembers, adapted).
type CommunityMate struct {
	UID, CommunityID, CommunityName string
}

// PlanSource is the beacons seam: co-participants of the caller's recent ended plans, newest plan first.
type PlanSource interface {
	RecentCoParticipants(ctx context.Context, uid string, since time.Time, maxPlans, perPlan int) ([]PlanMate, error)
}

// CommunitySource is the communities seam: recent members of the community the caller joined last.
type CommunitySource interface {
	RecentCoMembers(ctx context.Context, uid string, maxMembers int) ([]CommunityMate, error)
}

// SuggestionDeps wires ListMessageSuggestions. Follows is required (the mutual and FOLLOWING_ONLY decisions); Plans and
// Communities may be nil (that source is skipped).
type SuggestionDeps struct {
	Follows     graph.FollowLookup
	Plans       PlanSource
	Communities CommunitySource
}

// candidate is one suggestion before the rules: who, why, and the reason's detail.
type candidate struct {
	uid       string
	reason    messagingv1.MessageSuggestionReason
	activity  beaconsv1.BeaconActivity
	community CommunityMate
	// accepted: the caller already has an ACCEPTED conversation with them (the FOLLOWING_ONLY policy does not apply to it).
	accepted bool
	// needsMutual: the reason is MUTUAL_FOLLOW, so they must follow the caller back.
	needsMutual bool
}

// suggestLimit validates and clamps limit: negative => VALIDATION "limit", 0 => 10, above 20 => 20.
func suggestLimit(n int32) (int, error) {
	switch {
	case n < 0:
		return 0, apierr.Validation("limit", "limit must not be negative")
	case n == 0:
		return suggestDefault, nil
	case n > suggestMax:
		return suggestMax, nil
	}
	return int(n), nil
}

// suggestGuard is the dm_suggestions gate after the messaging gate: FEATURE_DISABLED feature=dm_suggestions, before any read.
func (s *service) suggestGuard(ctx context.Context, uid string) error {
	err := flags.Guard(ctx, func(uid, name string) bool { return s.flags != nil && s.flags.Enabled(uid, name) }, uid, SuggestionsFlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", SuggestionsFlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", SuggestionsFlagName)
	}
	return err
}

func (s *service) enabledFor(uid, name string) bool {
	return s.flags != nil && s.flags.Enabled(uid, name)
}

// ListSuggestions implements ListMessageSuggestions. Order: the messaging flag (on for the caller) and dm_suggestions, the limit
// (0 reads); the caller's graph (cached 60 s; past the blockedBy cap the answer is empty, fail closed); the sources in order
// (inbox entries, plans, the newest followees, the community), deduped, the free drops applied (self, blocks either way, mutes,
// malformed ids), at most suggestMaxCandidate kept; one cache-first profile batch (non-ACTIVE accounts are absent); the
// caller-side send check (recipientRefusal: messaging off for them); one batched follow-back lookup for the MUTUAL_FOLLOW rows
// and the FOLLOWING_ONLY ones (a failed lookup drops exactly those rows: fail closed). The plan and community sources are best
// effort: a failure is counted on the request line and that source contributes nothing; the inbox and the graph are required.
func (s *service) ListSuggestions(ctx context.Context, uid string, req *messagingv1.ListMessageSuggestionsRequest) (*messagingv1.ListMessageSuggestionsResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	if err := s.suggestGuard(ctx, uid); err != nil {
		return nil, err
	}
	limit, err := suggestLimit(req.GetLimit())
	if err != nil {
		return nil, err
	}
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil || s.d.Suggestions.Follows == nil {
		return nil, errors.New("messaging: suggestions are not configured")
	}
	mine, err := s.d.Social.Snapshot(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("messaging: suggestions: caller graph: %w", err), uid)
	}
	out := &messagingv1.ListMessageSuggestionsResponse{}
	if mine.BlockedByOverflow {
		logger.SetRequestField(ctx, fieldSuggestResults, 0)
		return out, nil
	}
	cands, err := s.suggestionCandidates(ctx, uid, mine)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldSuggestCandidates, len(cands))
	if len(cands) == 0 {
		logger.SetRequestField(ctx, fieldSuggestResults, 0)
		return out, nil
	}
	uids := make([]string, len(cands))
	for i, c := range cands {
		uids[i] = c.uid
	}
	profiles, err := s.d.Profiles.GetProfiles(ctx, uids)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("messaging: suggestions: profiles: %w", err), uid)
	}
	// Who needs the follow-back answer: MUTUAL_FOLLOW rows, and peers whose FOLLOWING_ONLY policy applies to a new message.
	var ask []string
	for _, c := range cands {
		p, ok := profiles[c.uid]
		if ok && (c.needsMutual || s.followingOnly(c, p)) {
			ask = append(ask, c.uid)
		}
	}
	followsBack := map[string]bool{}
	lookupFailed := false
	if len(ask) > 0 {
		if followsBack, err = s.d.Suggestions.Follows.FollowersAmong(ctx, uid, ask); err != nil {
			lookupFailed, followsBack = true, map[string]bool{} // unknown: every row that needs it is dropped
			logger.SetRequestField(ctx, fieldSuggestSourceErr, "follow_lookup")
		}
	}
	dropped := 0
	for _, c := range cands {
		if len(out.Suggestions) == limit {
			break
		}
		p, active := profiles[c.uid]
		if s.recipientRefusal(mine, c.uid, active) != "" {
			dropped++
			continue
		}
		if (c.needsMutual || s.followingOnly(c, p)) && (lookupFailed || !followsBack[c.uid]) {
			dropped++
			continue
		}
		out.Suggestions = append(out.Suggestions, suggestionRow(c, p))
	}
	logger.SetRequestField(ctx, fieldSuggestDropped, dropped)
	logger.SetRequestField(ctx, fieldSuggestResults, len(out.Suggestions))
	return out, nil
}

// followingOnly reports whether p's FOLLOWING_ONLY policy (with FEATURE_DM_POLICY on for them, the send rule) applies to a
// message from the caller: not for an ACCEPTED conversation, which a send continues whatever the policy.
func (s *service) followingOnly(c candidate, p identity.Profile) bool {
	return !c.accepted && p.DMPolicy == identity.DMPolicyFollowingOnly && s.enabledFor(c.uid, identity.DMPolicyFlag)
}

// suggestionCandidates gathers the sources in order with the free drops applied, deduped (the first reason wins), at most
// suggestMaxCandidate.
func (s *service) suggestionCandidates(ctx context.Context, uid string, mine graph.Snapshot) ([]candidate, error) {
	seen := map[string]int{} // uid -> index in out
	var out []candidate
	add := func(c candidate) {
		if len(out) >= suggestMaxCandidate || c.uid == uid || !ids.ValidUID(c.uid) ||
			mine.Blocked[c.uid] || mine.BlockedBy[c.uid] || mine.Muted[c.uid] {
			return
		}
		if i, ok := seen[c.uid]; ok {
			out[i].accepted = out[i].accepted || c.accepted
			return
		}
		seen[c.uid] = len(out)
		out = append(out, c)
	}
	var sourceErrs []string

	// 1. The newest INBOX entries (accepted conversations and requests the caller sent).
	entries, err := s.d.Repo.ListEntries(ctx, uid, dmInboxCollection, ListQuery{Limit: suggestInbox})
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("messaging: suggestions: inbox: %w", err), uid)
	}
	for _, e := range entries {
		add(candidate{uid: e.PeerID, reason: messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION, accepted: !e.RequestPending})
	}

	// 2. Recent plans (FEATURE_BEACONS on for the caller).
	if s.d.Suggestions.Plans != nil && s.enabledFor(uid, beaconsFlagName) {
		mates, err := s.d.Suggestions.Plans.RecentCoParticipants(ctx, uid, s.d.Now().Add(-suggestPlanLookback), suggestPlans, suggestPerPlan)
		if err != nil {
			sourceErrs = append(sourceErrs, "plans")
		}
		for _, m := range mates {
			add(candidate{uid: m.UID, reason: messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MET_ON_PLAN, activity: m.Activity})
		}
	}

	// 3. The newest followees, kept only when they follow back.
	for i, f := range mine.RecentFollowing {
		if i == suggestMutualPool {
			break
		}
		add(candidate{uid: f, reason: messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW, needsMutual: true})
	}

	// 4. The community the caller joined last (FEATURE_COMMUNITIES on for the caller).
	if s.d.Suggestions.Communities != nil && s.enabledFor(uid, communitiesFlagName) {
		mates, err := s.d.Suggestions.Communities.RecentCoMembers(ctx, uid, suggestCommunity)
		if err != nil {
			sourceErrs = append(sourceErrs, "communities")
		}
		for _, m := range mates {
			add(candidate{uid: m.UID, reason: messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER, community: m})
		}
	}
	if len(sourceErrs) > 0 {
		logger.SetRequestField(ctx, fieldSuggestSourceErr, sourceErrs)
	}
	return out, nil
}

func suggestionRow(c candidate, p identity.Profile) *messagingv1.MessageSuggestion {
	row := &messagingv1.MessageSuggestion{
		User: &commonv1.AuthorSnapshot{
			UserId: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarUrl: p.AvatarThumbURL,
			Verified: p.Verified, IsPrivate: p.IsPrivate,
		},
		Reason: c.reason,
	}
	switch c.reason {
	case messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MET_ON_PLAN:
		row.PlanActivity = c.activity
	case messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER:
		row.CommunityId, row.CommunityName = c.community.CommunityID, c.community.CommunityName
	}
	return row
}
