package communities

import (
	"context"
	"fmt"
	"slices"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var _ Reader = (*service)(nil)

// Get implements Reader: the cache-first community (60 s staleness bound, D12), ErrNotFound for a missing one. It does not apply the
// SUSPENDED rule; a caller that must answer NOT_FOUND for everyone checks Status itself (the owner alone may see a SUSPENDED one).
func (s *service) Get(ctx context.Context, communityID string) (Community, error) {
	return s.loadCommunity(ctx, communityID)
}

// Role implements Reader: the D4 role of uid, from the cached community (OWNER, MODERATOR) or the cached member doc (60 s staleness
// bound, absence cached too; 0 reads warm, 1 cold).
func (s *service) Role(ctx context.Context, communityID, uid string) (Role, error) {
	c, err := s.loadCommunity(ctx, communityID)
	if err != nil {
		return RoleNone, err
	}
	return s.roleFor(ctx, c, uid)
}

// Memberships implements Reader: uid's memberships document, never cached (1 read, charged when missing too).
func (s *service) Memberships(ctx context.Context, uid string) (Memberships, error) {
	return s.d.Repo.Memberships(ctx, uid)
}

func errNoProfile() *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
}

// joinQuotaLimit is the caller's daily quota.CommunityJoins limit: the new-account tier inside NewAccountWindow. The caller's profile is
// cache-first (0 reads behind the account-status interceptor, which has just loaded it).
func (s *service) joinQuotaLimit(ctx context.Context, uid string) (int64, error) {
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("communities: load profile: %w", err), uid)
	}
	p, ok := profiles[uid]
	if !ok {
		return 0, errNoProfile()
	}
	if s.isNew(p) {
		return s.d.Limits.NewAccountJoinsPerDay, nil
	}
	return s.d.Limits.JoinsPerDay, nil
}

func (s *service) isNew(p identity.Profile) bool {
	return !p.CreatedAt.IsZero() && s.now().Sub(p.CreatedAt) < s.d.Limits.NewAccountWindow
}

func joinHash(communityID string) string {
	return idempotency.HashRequest("community_id=" + communityID)
}

// roleAfter is the viewer role once the member state is known: a JOINED caller is OWNER or MODERATOR when the community says so,
// otherwise MEMBER; BANNED stays BANNED; anyone else has no role (a moderator who just left is NONE whatever the cached document says).
func roleAfter(c Community, uid string, st MemberState) Role {
	switch st {
	case MemberJoined:
		if r := c.RoleOf(uid); r != RoleNone {
			return r
		}
		return RoleMember
	case MemberBanned:
		return RoleBanned
	}
	return RoleNone
}

// openForMembership loads the community cache-first and applies the shared refusals of Join and Leave: missing or SUSPENDED is the one
// NOT_FOUND (the owner gets no exception here, communities.proto).
func (s *service) openForMembership(ctx context.Context, op, uid, communityID string, in MembershipInput) (Community, error) {
	if err := validateKey(in.Key); err != nil {
		return Community{}, mapErr(ctx, op, uid, communityID, err)
	}
	if err := ValidateCommunityID(communityID); err != nil {
		return Community{}, mapErr(ctx, op, uid, communityID, err)
	}
	c, err := s.loadCommunity(ctx, communityID)
	if err != nil {
		return Community{}, mapErr(ctx, op, uid, communityID, err)
	}
	if c.Status == StatusSuspended {
		return Community{}, mapErr(ctx, op, uid, communityID, ErrNotFound)
	}
	return c, nil
}

// JoinCommunity implements Service (ADR-0031 D2, D4, D8, D11). The community comes from the 60 s cache (the transaction never reads it),
// so a community archived or suspended on another instance in the last 60 s can still take a join; the cap, the ban and the quota are
// always fresh. The caller's member doc is cached from the written state, never the community (a locally adjusted copy would reset its
// TTL), and the response's member_count is the cached count plus this join, which can lag other instances by up to 60 s.
func (s *service) JoinCommunity(ctx context.Context, uid string, in MembershipInput) (View, error) {
	begin(ctx, "join")
	c, err := s.openForMembership(ctx, "join", uid, in.CommunityID, in)
	if err != nil {
		return View{}, err
	}
	if c.Status == StatusArchived {
		return View{}, mapErr(ctx, "join", uid, c.ID, ErrArchived)
	}
	limit, err := s.joinQuotaLimit(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "join", uid, c.ID, err)
	}
	res, err := s.d.Repo.Join(ctx, JoinParams{
		UID: uid, ID: c.ID, IdemKey: idempotency.Key(uid, rpcJoinCommunity, in.Key), RequestHash: joinHash(c.ID),
		MaxJoined: s.d.Limits.MaxJoined, QuotaLimit: limit,
	})
	if err != nil {
		return View{}, mapErr(ctx, "join", uid, c.ID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Outcome == Written {
		s.cache.forgetMemberships(uid)
	}
	switch res.Outcome {
	case Replayed:
		role, rerr := s.roleFor(ctx, c, uid)
		if rerr != nil {
			return View{}, mapErr(ctx, "join", uid, c.ID, rerr)
		}
		return View{Community: c, Role: role}, nil
	case Written:
		c.MemberCount++
	}
	s.cache.putMember(c.ID, uid, res.State)
	return View{Community: c, Role: roleAfter(c, uid, res.State)}, nil
}

// LeaveCommunity implements Service (ADR-0031 D2, D4, D8). Allowed in an ARCHIVED community; a SUSPENDED one is NOT_FOUND. A caller the
// cached community lists as a moderator makes the transaction read the community fresh and leave moderatorIds in the same write; when
// it did, the freshly written document replaces the cache entry (the one time a community is put from a write, so the moderator is gone
// from this instance's GetCommunity at once). Otherwise the cached document is left alone and the response carries the count minus one.
func (s *service) LeaveCommunity(ctx context.Context, uid string, in MembershipInput) (View, error) {
	begin(ctx, "leave")
	c, err := s.openForMembership(ctx, "leave", uid, in.CommunityID, in)
	if err != nil {
		return View{}, err
	}
	if c.RoleOf(uid) == RoleModerator { // only a moderator's leave writes a modlog entry
		noteCommunity(ctx, c.ID)
	}
	res, err := s.d.Repo.Leave(ctx, LeaveParams{
		UID: uid, ID: c.ID, IdemKey: idempotency.Key(uid, rpcLeaveCommunity, in.Key), RequestHash: joinHash(c.ID),
		ModeratorHint: c.RoleOf(uid) == RoleModerator, ModlogMax: s.d.Limits.ModlogMax,
	})
	if err != nil {
		return View{}, mapErr(ctx, "leave", uid, c.ID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Outcome == Written {
		s.cache.forgetMemberships(uid)
	}
	if res.Outcome == Replayed {
		role, rerr := s.roleFor(ctx, c, uid)
		if rerr != nil {
			return View{}, mapErr(ctx, "leave", uid, c.ID, rerr)
		}
		return View{Community: c, Role: role}, nil
	}
	s.cache.putMember(c.ID, uid, res.State)
	if res.Outcome == Written {
		if res.Community != nil {
			c = *res.Community
			s.cache.put(c)
		} else {
			c.MemberCount = max(c.MemberCount-1, 0)
		}
	}
	return View{Community: c, Role: roleAfter(c, uid, res.State)}, nil
}

// ListMyCommunities implements Service (ADR-0031 D2, N3). Not paged at Stage 0: a non-empty page_token is VALIDATION "page_token" with
// 0 reads. The memberships document is read fresh (1 read); its joined array is in join order, so the reverse is newest first. The
// community documents come from the cache, the misses from one GetAll (1 read each, at most COMMUNITIES_MAX_JOINED). A SUSPENDED
// community is left out unless the caller owns it; an ARCHIVED one stays; a document that is gone is skipped.
func (s *service) ListMyCommunities(ctx context.Context, uid, pageToken string) (MyCommunities, error) {
	begin(ctx, "my")
	if pageToken != "" {
		return MyCommunities{}, mapErr(ctx, "my", uid, "", apierr.Validation("page_token", "page_token must be empty: this list is not paged"))
	}
	_, canCreate := s.creators[uid]
	ms, err := s.d.Repo.Memberships(ctx, uid)
	if err != nil {
		return MyCommunities{}, mapErr(ctx, "my", uid, "", err)
	}
	ids := make([]string, 0, len(ms.Joined))
	for _, id := range slices.Backward(ms.Joined) {
		if !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
	}
	docs := make(map[string]Community, len(ids))
	var misses []string
	for _, id := range ids {
		if c, ok := s.cache.get(id); ok {
			docs[id] = c
		} else {
			misses = append(misses, id)
		}
	}
	logger.SetRequestField(ctx, fieldCacheHit, len(misses) == 0)
	if len(misses) > 0 {
		got, err := s.d.Repo.GetMany(ctx, misses)
		if err != nil {
			return MyCommunities{}, mapErr(ctx, "my", uid, "", err)
		}
		for id, c := range got {
			docs[id] = c
			s.cache.put(c)
		}
	}
	out := MyCommunities{CanCreate: canCreate}
	for _, id := range ids {
		c, ok := docs[id]
		if !ok || (c.Status == StatusSuspended && c.OwnerID != uid) {
			continue
		}
		out.Items = append(out.Items, View{Community: c, Role: roleAfter(c, uid, MemberJoined)})
	}
	return out, nil
}
