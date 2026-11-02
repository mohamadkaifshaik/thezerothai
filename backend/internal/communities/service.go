package communities

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields (ADR-0031 D13): counts and enums only, never an id, name, description or rule text.
const (
	fieldOp       = "community_op"
	fieldOutcome  = "outcome"
	fieldCacheHit = "cache_hit"

	outcomeDone       = "done"
	outcomeReplay     = "replay"
	outcomeNoop       = "noop"
	outcomeNotFound   = "rejected:not_found"
	outcomeContention = "contention"
)

// notFoundText is the one message of every NOT_FOUND "community not found" (communities.proto: byte-identical for a missing and a
// SUSPENDED community, on every RPC).
const notFoundText = "community not found"

// Limits are the caps from config (rule 11): COMMUNITIES_MAX_OWNED, COMMUNITIES_MAX_JOINED, COMMUNITY_MAX_RULES,
// COMMUNITY_MODLOG_MAX and the two cache sizes.
type Limits struct {
	MaxOwned, MaxJoined, MaxRules, ModlogMax int
	// MaxModerators (COMMUNITY_MAX_MODERATORS, 10) and RecentRemovalsMax (COMMUNITY_RECENT_REMOVALS_MAX, 50) are the W5-28 caps; zero reads as the default.
	MaxModerators, RecentRemovalsMax  int
	CacheEntries, MembersCacheEntries int
	// JoinsPerDay and NewAccountJoinsPerDay are the quota.CommunityJoins daily limits (20, and 5 inside NewAccountWindow; ADR-0031 D11).
	JoinsPerDay, NewAccountJoinsPerDay int64
	NewAccountWindow                   time.Duration
}

// Deps is everything New needs.
type Deps struct {
	Repo Repo
	// Directory serves the owner and moderator rows of GetCommunity (cache-first, up to 60 s stale) and the successor check of the
	// eraser.
	Directory identity.Directory
	// Graph is the caller's social context (cache-first, 60 s): the relationship to each role holder.
	Graph graph.Reader
	IDs   IDSource
	// Creators are the uids that may call CreateCommunity (COMMUNITY_CREATORS, at most 10).
	Creators []string
	// Listing is the directory seam (W5-25b); nil = the Stage 0 shared Firestore entry (5 min).
	Listing Directory
	// Moderation is the storage of the moderation calls (W5-28); nil = Repo when it implements ModerationRepo (FirestoreRepo does).
	Moderation ModerationRepo
	// OnPostRestored, when set, runs once after a RestoreCommunityPost that committed a change (outcome Written; not on a replay, a no-op or an
	// error), with the community id. apiserver hands it timeline.Server.ForgetCommunityFeed so this instance's shared feed entry refills at
	// once (W5-57, ADR-0031 D6). It must be in-process and cheap (0 Firestore ops); communities never imports timeline. A hide needs none.
	OnPostRestored func(communityID string)
	// CursorKey seals ListCommunityMembers page tokens (config.CursorHMACKey).
	CursorKey []byte
	Limits    Limits
}

type service struct {
	d        Deps
	cache    *docCache
	creators map[string]struct{}
	now      func() time.Time
	listing  Directory
	mod      ModerationRepo
}

// New builds the communities service. It never touches Firestore itself; the flag gate is the handler's (Guard), before this runs.
func New(d Deps) Service {
	c := make(map[string]struct{}, len(d.Creators))
	for _, uid := range d.Creators {
		c[uid] = struct{}{}
	}
	s := &service{d: d, cache: newDocCache(d.Limits.CacheEntries, d.Limits.MembersCacheEntries), creators: c, now: time.Now}
	s.listing = d.Listing
	s.mod = d.Moderation
	if s.mod == nil {
		s.mod, _ = d.Repo.(ModerationRepo)
	}
	if s.listing == nil {
		s.listing = &sharedDirectory{repo: d.Repo, now: func() time.Time { return s.now() }}
	}
	return s
}

var _ Service = (*service)(nil)

// NotFoundError is the one NOT_FOUND "community not found" of every RPC here and of CreatePost and GetCommunityTimeline in later
// tickets: byte-identical for a missing and a SUSPENDED community.
func NotFoundError() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, notFoundText)
}

// ValidateCommunityID is the 0-read VALIDATION field=community_id check every community RPC runs before a read: a 19-digit Snowflake.
func ValidateCommunityID(id string) error {
	if !ids.ValidPostID(id) {
		return apierr.Validation("community_id", "community_id must be a 19-digit community id")
	}
	return nil
}

func validateKey(key string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

func validateName(s string) (string, error) {
	n, ok := identity.SingleLineText(s, MinNameRunes, MaxNameRunes)
	if !ok {
		return "", apierr.Validation("name", "name must be 1-30 characters on one line, with a visible character and without control, invisible or direction characters")
	}
	return n, nil
}

func validateDescription(s string) (string, error) {
	n, ok := identity.BioText(s, MaxDescriptionRunes)
	if !ok {
		return "", apierr.Validation("description", "description must be at most 160 characters, without control, invisible or direction characters")
	}
	return n, nil
}

// validateRules applies the rule text rules to every rule and returns the form to store. More than max rules, or any bad title or text,
// is VALIDATION "rules". The result is never nil.
func validateRules(in []Rule, max int) ([]Rule, error) {
	if len(in) > max {
		return nil, apierr.Validation("rules", "a community has at most "+strconv.Itoa(max)+" rules")
	}
	out := make([]Rule, 0, len(in))
	for _, r := range in {
		title, ok := identity.SingleLineText(r.Title, MinRuleTitleRunes, MaxRuleTitleRunes)
		if !ok {
			return nil, apierr.Validation("rules", "a rule title must be 1-60 characters on one line, without control, invisible or direction characters")
		}
		text, ok := identity.BioText(r.Text, MaxRuleTextRunes)
		if !ok {
			return nil, apierr.Validation("rules", "a rule text must be at most 300 characters, without control, invisible or direction characters")
		}
		out = append(out, Rule{Title: title, Text: text})
	}
	return out, nil
}

// canonical request bodies for IDEMPOTENCY_KEY_REUSED: every field as sent, an unset optional distinct from its zero value.
func rulesCanon(rules []Rule) string {
	var b strings.Builder
	b.WriteByte('[')
	for _, r := range rules {
		fmt.Fprintf(&b, "{%q,%q}", r.Title, r.Text)
	}
	b.WriteByte(']')
	return b.String()
}

func createHash(name, description string, rules []Rule) string {
	return idempotency.HashRequest(fmt.Sprintf("name=%q|description=%q|rules=%s", name, description, rulesCanon(rules)))
}

func optString(s *string) string {
	if s == nil {
		return "unset"
	}
	return strconv.Quote(*s)
}

func updateHash(id string, name, description *string, rules *[]Rule) string {
	r := "unset"
	if rules != nil {
		r = rulesCanon(*rules)
	}
	return idempotency.HashRequest(fmt.Sprintf("community_id=%s|name=%s|description=%s|rules=%s", id, optString(name), optString(description), r))
}

func begin(ctx context.Context, op string) { logger.SetRequestField(ctx, fieldOp, op) }

func noteOutcome(ctx context.Context, o Outcome) {
	switch o {
	case Written:
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	case Replayed:
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	default:
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
}

// mapErr turns a repository error into the handler's answer. Known sentinels and already shaped apierrs (validation) pass through; a
// client that left is CANCELED / DEADLINE_EXCEEDED; exhausted contention or the transaction's own timeout is a retryable UNAVAILABLE
// logged at WARN; anything else is a redacted internal error that reaches Error Reporting. The uid and community id are redacted from
// the chain: a Firestore error embeds document paths.
func mapErr(ctx context.Context, op, uid, cid string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return NotFoundError()
	case errors.Is(err, ErrNotOwner):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_owner")
		return Forbidden(ReasonNotOwner)
	case errors.Is(err, ErrArchived):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:community_archived")
		return StateConflict(StateArchived)
	case errors.Is(err, ErrBanned):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:banned")
		return Forbidden(ReasonBanned)
	case errors.Is(err, ErrNotModerator):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_moderator")
		return Forbidden(ReasonNotModerator)
	case errors.Is(err, ErrModeratorTarget):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:moderator")
		return StateConflict(StateModerator)
	case errors.Is(err, ErrBadTarget):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:invalid_target")
		return apierr.Validation("user_id", "that user cannot be the target of this action")
	case errors.Is(err, ErrModeratorCap):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", LimitModerators)
		return LimitReached(LimitModerators)
	case errors.Is(err, ErrPostNotFound):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:post_not_found")
		return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, postNotFound)
	case errors.Is(err, ErrOwnerLeave):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:owner")
		return StateConflict(StateOwner)
	case errors.Is(err, ErrOwnedLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", LimitOwned)
		return LimitReached(LimitOwned)
	case errors.Is(err, ErrJoinedLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", LimitJoined)
		return LimitReached(LimitJoined)
	case errors.Is(err, ErrKeyReused):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:key_reused")
		return apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	case errors.As(err, &ae):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:"+ae.Code.String())
		return err
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldOutcome, outcomeContention)
		slog.WarnContext(ctx, "communities_contention", fieldOp, op, "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("communities: %s: %w", op, err), uid, cid)
}

// CreateCommunity implements Service (ADR-0031 D2, D8, F1). The creators check is first: a caller outside COMMUNITY_CREATORS gets
// FORBIDDEN not_creator with 0 reads, whatever else is wrong with the request. Then the key and the text rules (0 reads), then one
// repository transaction. The new community and the owner's member doc fill the instance caches.
func (s *service) CreateCommunity(ctx context.Context, uid string, in CreateInput) (View, error) {
	begin(ctx, "create")
	if _, ok := s.creators[uid]; !ok {
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_creator")
		return View{}, Forbidden(ReasonNotCreator)
	}
	if err := validateKey(in.Key); err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	name, err := validateName(in.Name)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	description, err := validateDescription(in.Description)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	rules, err := validateRules(in.Rules, s.d.Limits.MaxRules)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	res, err := s.d.Repo.Create(ctx, CreateParams{
		UID: uid, ID: s.d.IDs.Generate(), IdemKey: idempotency.Key(uid, rpcCreateCommunity, in.Key),
		RequestHash: createHash(name, description, rules), Name: name, Description: description, Rules: rules,
		MaxOwned: s.d.Limits.MaxOwned, MaxJoined: s.d.Limits.MaxJoined,
	})
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Outcome == Written {
		s.cache.put(res.Community)
		s.cache.putMember(res.Community.ID, uid, MemberJoined)
		s.cache.forgetMemberships(uid)
	}
	return View{Community: res.Community, Role: res.Community.RoleOf(uid)}, nil
}

// UpdateCommunity implements Service. A replay answers with the community as stored now and leaves the cache alone; a write refreshes
// the entry from the written data.
func (s *service) UpdateCommunity(ctx context.Context, uid string, in UpdateInput) (View, error) {
	begin(ctx, "update")
	if err := validateKey(in.Key); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
	}
	if err := ValidateCommunityID(in.CommunityID); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
	}
	var name, description *string
	if in.Name != nil {
		n, err := validateName(*in.Name)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
		}
		name = &n
	}
	if in.Description != nil {
		d, err := validateDescription(*in.Description)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
		}
		description = &d
	}
	var rules *[]Rule
	if in.Rules != nil {
		rs, err := validateRules(*in.Rules, s.d.Limits.MaxRules)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
		}
		rules = &rs
	}
	res, err := s.d.Repo.Update(ctx, UpdateParams{
		UID: uid, ID: in.CommunityID, IdemKey: idempotency.Key(uid, rpcUpdateCommunity, in.Key),
		RequestHash: updateHash(in.CommunityID, name, description, rules), Name: name, Description: description, Rules: rules,
		ModlogMax: s.d.Limits.ModlogMax,
	})
	if err != nil {
		return View{}, mapErr(ctx, "update", uid, in.CommunityID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Outcome != Replayed {
		s.cache.put(res.Community)
	}
	return View{Community: res.Community, Role: res.Community.RoleOf(uid)}, nil
}

// loadCommunity is the cache-first community read (60 s, D12): a hit costs 0 reads, a miss 1 (charged even when the document is
// missing). A missing document is remembered for 60 s too. ErrNotFound for a missing doc. It does not apply the SUSPENDED rule.
func (s *service) loadCommunity(ctx context.Context, id string) (Community, error) {
	if c, ok := s.cache.get(id); ok {
		logger.SetRequestField(ctx, fieldCacheHit, true)
		return c, nil
	}
	if s.cache.isMissing(id) {
		logger.SetRequestField(ctx, fieldCacheHit, true)
		return Community{}, ErrNotFound
	}
	logger.SetRequestField(ctx, fieldCacheHit, false)
	c, err := s.d.Repo.Get(ctx, id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			s.cache.putMissing(id)
		}
		return Community{}, err
	}
	s.cache.put(c)
	return c, nil
}

// MemberState implements CachedMembers: uid's member-doc state from the 60 s instance cache (absence cached too; staleness bound 60 s, D12),
// 1 read cold and 0 warm, without loading the community document.
func (s *service) MemberState(ctx context.Context, communityID, uid string) (MemberState, error) {
	if st, ok := s.cache.getMember(communityID, uid); ok {
		return st, nil
	}
	st, err := s.d.Repo.Member(ctx, communityID, uid)
	if err != nil {
		return MemberNone, err
	}
	s.cache.putMember(communityID, uid, st)
	return st, nil
}

// roleFor completes the D4 role for uid: the community doc decides OWNER and MODERATOR (0 reads); otherwise the member doc does,
// cache-first (60 s, absence cached too), 1 read when cold.
func (s *service) roleFor(ctx context.Context, c Community, uid string) (Role, error) {
	if r := c.RoleOf(uid); r != RoleNone {
		return r, nil
	}
	st, err := s.MemberState(ctx, c.ID, uid)
	if err != nil {
		return RoleNone, err
	}
	switch st {
	case MemberJoined:
		return RoleMember, nil
	case MemberBanned:
		return RoleBanned, nil
	}
	return RoleNone, nil
}

// GetCommunity implements Service. Order, cheapest first: the community (cache or 1 read), the SUSPENDED rule (the owner alone sees it,
// N3: the one NOT_FOUND for everyone else, before any further read so the bytes and the read count match a missing id), the caller's
// role, then the role holders' rows. Owner and moderators are live profiles (identity.Directory, cache-first) with the caller's
// relationship from the caller's own graph snapshot (0 extra reads); every role holder is shown to every viewer whatever the blocks
// (D7), but one whose account is not ACTIVE is left out for everyone.
func (s *service) GetCommunity(ctx context.Context, uid, communityID string) (Detail, error) {
	begin(ctx, "get")
	if err := ValidateCommunityID(communityID); err != nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, err)
	}
	c, err := s.loadCommunity(ctx, communityID)
	if err != nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, err)
	}
	if c.Status == StatusSuspended && c.OwnerID != uid {
		return Detail{}, mapErr(ctx, "get", uid, communityID, ErrNotFound)
	}
	role, err := s.roleFor(ctx, c, uid)
	if err != nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, err)
	}
	d := Detail{View: View{Community: c, Role: role}}
	holders := make([]string, 0, 1+len(c.ModeratorIDs))
	if c.OwnerID != "" {
		holders = append(holders, c.OwnerID)
	}
	holders = append(holders, c.ModeratorIDs...)
	if len(holders) == 0 {
		return d, nil
	}
	profiles, err := s.d.Directory.GetProfiles(ctx, holders)
	if err != nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, fmt.Errorf("load role holders: %w", err))
	}
	if s.d.Graph == nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, errors.New("graph reader is not wired"))
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return Detail{}, mapErr(ctx, "get", uid, communityID, fmt.Errorf("load graph: %w", err))
	}
	person := func(id string) (Person, bool) {
		p, ok := profiles[id]
		if !ok || p.Status != identity.AccountStatusActive {
			return Person{}, false
		}
		return Person{Profile: p, Relationship: graph.RelationshipFor(snap, id)}, true
	}
	if c.OwnerID != "" {
		if p, ok := person(c.OwnerID); ok {
			d.Owner = &p
		}
	}
	for _, m := range c.ModeratorIDs {
		if p, ok := person(m); ok {
			d.Moderators = append(d.Moderators, p)
		}
	}
	return d, nil
}
