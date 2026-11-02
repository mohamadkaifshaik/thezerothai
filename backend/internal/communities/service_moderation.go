package communities

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"strconv"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var _ Moderation = (*service)(nil)

// Request-line names of the moderation calls (ADR-0031 D13). fieldModAction is an enum: hide, restore, ban, unban, make_moderator,
// remove_moderator or log. Never an id.
const (
	fieldModAction  = "mod_action"
	logBindingLabel = "community_modlog"
	userNotFound    = "user not found"
	postNotFound    = "post not found"
)

func (s *service) modRepo() (ModerationRepo, error) {
	if s.mod == nil {
		return nil, errors.New("moderation repository is not wired")
	}
	return s.mod, nil
}

func postActionHash(cid, postID string) string {
	return idempotency.HashRequest("community_id=" + cid + "|post_id=" + postID)
}

// HideCommunityPost implements Moderation. The role, the status and the post are all decided inside the repository transaction on fresh
// reads (no cache-first read here: a removed moderator must not act from a stale entry). On a write the community cache entry is replaced
// by the written document, so this instance's feed drops the post at once through Reader.Get; other instances within 60 s (D12).
func (s *service) HideCommunityPost(ctx context.Context, uid string, in PostActionInput) error {
	return s.moderatePost(ctx, "hide", uid, in, false)
}

// RestoreCommunityPost implements Moderation: the reverse of HideCommunityPost.
func (s *service) RestoreCommunityPost(ctx context.Context, uid string, in PostActionInput) error {
	return s.moderatePost(ctx, "restore", uid, in, true)
}

func (s *service) moderatePost(ctx context.Context, op, uid string, in PostActionInput, restore bool) error {
	begin(ctx, op)
	logger.SetRequestField(ctx, fieldModAction, op)
	if err := validateKey(in.Key); err != nil {
		return mapErr(ctx, op, uid, in.CommunityID, err)
	}
	if err := ValidateCommunityID(in.CommunityID); err != nil {
		return mapErr(ctx, op, uid, in.CommunityID, err)
	}
	if !ids.ValidPostID(in.PostID) {
		return mapErr(ctx, op, uid, in.CommunityID, apierr.Validation("post_id", "post_id must be a 19-digit post id"))
	}
	repo, err := s.modRepo()
	if err != nil {
		return mapErr(ctx, op, uid, in.CommunityID, err)
	}
	rpc := rpcHideCommunityPost
	if restore {
		rpc = rpcRestoreCommunityPost
	}
	res, err := repo.ModeratePost(ctx, ModeratePostParams{
		UID: uid, ID: in.CommunityID, PostID: in.PostID, IdemKey: idempotency.Key(uid, rpc, in.Key),
		RequestHash: postActionHash(in.CommunityID, in.PostID), Restore: restore,
		RemovalsMax: s.d.Limits.RecentRemovalsMax, ModlogMax: s.d.Limits.ModlogMax,
	})
	if err != nil {
		return mapErr(ctx, op, uid, in.CommunityID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Outcome == Written {
		s.cache.put(res.Community)
		if restore && s.d.OnPostRestored != nil {
			s.d.OnPostRestored(in.CommunityID)
		}
	}
	return nil
}

func roleHash(cid, target string, a RoleAction) string {
	return idempotency.HashRequest("community_id=" + cid + "|user_id=" + target + "|action=" + a.String())
}

func errUserNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, userNotFound)
}

// SetMemberRole implements Moderation (ADR-0031 D4). The 0-read checks come first (key, ids, action), then the target's profile through
// the directory (cache-first, up to 60 s stale; missing or not ACTIVE is NOT_FOUND "user not found", whatever the blocks), then one
// repository transaction. A write fills the caches from the written data: the community, the target's member state, and drops both
// users' memberships entries.
func (s *service) SetMemberRole(ctx context.Context, uid string, in RoleInput) (RoleResult, error) {
	const op = "role"
	begin(ctx, op)
	logger.SetRequestField(ctx, fieldModAction, in.Action.String())
	if err := validateKey(in.Key); err != nil {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, err)
	}
	if err := ValidateCommunityID(in.CommunityID); err != nil {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, err)
	}
	if !ids.ValidUID(in.UserID) {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, apierr.Validation("user_id", "user_id is not a valid user id"))
	}
	if in.Action == RoleActionNone {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, apierr.Validation("action", "action must be BAN, UNBAN, MAKE_MODERATOR or REMOVE_MODERATOR"))
	}
	repo, err := s.modRepo()
	if err != nil {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, err)
	}
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{in.UserID})
	if err != nil {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, fmt.Errorf("load target: %w", err))
	}
	if p, ok := profiles[in.UserID]; !ok || p.Status != identity.AccountStatusActive {
		logger.SetRequestField(ctx, fieldOutcome, "rejected:user_not_found")
		return RoleResult{}, errUserNotFound()
	}
	res, err := repo.SetRole(ctx, SetRoleParams{
		UID: uid, ID: in.CommunityID, Target: in.UserID, Action: in.Action,
		IdemKey: idempotency.Key(uid, rpcSetMemberRole, in.Key), RequestHash: roleHash(in.CommunityID, in.UserID, in.Action),
		ModlogMax: s.d.Limits.ModlogMax, MaxModerators: cmp.Or(s.d.Limits.MaxModerators, defaultMaxModerators),
	})
	if err != nil {
		return RoleResult{}, mapErr(ctx, op, uid, in.CommunityID, err)
	}
	noteOutcome(ctx, res.Outcome)
	c := res.Community
	if res.Outcome == Written {
		s.cache.put(c)
		s.cache.putMember(c.ID, in.UserID, res.TargetState)
		s.cache.forgetMemberships(in.UserID)
		s.cache.forgetMemberships(uid)
	}
	return RoleResult{Role: roleAfter(c, in.UserID, res.TargetState), View: View{Community: c, Role: c.RoleOf(uid)}}, nil
}

func logBinding(uid, cid string) string { return logBindingLabel + "|" + uid + "|" + cid }

// ListModerationLog implements Moderation. Order, cheapest first: the community id and the sealed page token (0 reads), the community
// (cache or 1 read; missing and SUSPENDED are the one NOT_FOUND), the role (owner and moderators only; staleness bound 60 s, so a
// moderator removed on another instance reads the log for at most a minute), then the live profiles of the people on the page. ARCHIVED
// is readable. The token carries the last seq returned.
func (s *service) ListModerationLog(ctx context.Context, uid string, in LogInput) (LogPage, error) {
	const op = "log"
	begin(ctx, op)
	logger.SetRequestField(ctx, fieldModAction, "log")
	cid := in.CommunityID
	if err := ValidateCommunityID(cid); err != nil {
		return LogPage{}, mapErr(ctx, op, uid, cid, err)
	}
	size := int(in.PageSize)
	if size <= 0 || size > LogPageMax {
		size = LogPageMax
	}
	binding := logBinding(uid, cid)
	lastSeq := int64(-1)
	if in.PageToken != "" {
		cur, err := cursor.Decode(s.d.CursorKey, binding, in.PageToken)
		seq, perr := strconv.ParseInt(cur.DocID, 10, 64)
		if err != nil || perr != nil || seq < 1 {
			return LogPage{}, mapErr(ctx, op, uid, cid, errPageToken())
		}
		lastSeq = seq
	}
	c, err := s.loadCommunity(ctx, cid)
	if err != nil {
		return LogPage{}, mapErr(ctx, op, uid, cid, err)
	}
	if c.Status == StatusSuspended {
		return LogPage{}, mapErr(ctx, op, uid, cid, ErrNotFound)
	}
	if c.RoleOf(uid) == RoleNone {
		return LogPage{}, mapErr(ctx, op, uid, cid, ErrNotModerator)
	}
	var rows []LogEntry
	more := false
	for i := len(c.Modlog) - 1; i >= 0; i-- { // newest first
		e := c.Modlog[i]
		if lastSeq >= 0 && e.Seq >= lastSeq {
			continue
		}
		if len(rows) == size {
			more = true
			break
		}
		rows = append(rows, e)
	}
	if len(rows) == 0 {
		return LogPage{}, nil
	}
	var uids []string
	seen := map[string]bool{}
	for _, e := range rows {
		for _, u := range []string{e.Actor, e.Target} {
			if u != "" && u != DeletedMarker && !seen[u] {
				seen[u] = true
				uids = append(uids, u)
			}
		}
	}
	profiles := map[string]identity.Profile{}
	if len(uids) > 0 {
		if profiles, err = s.d.Directory.GetProfiles(ctx, uids); err != nil {
			return LogPage{}, mapErr(ctx, op, uid, cid, fmt.Errorf("load log people: %w", err))
		}
	}
	// A person is shown only while the account is ACTIVE; the deleted marker, a missing profile and any other status read as deleted.
	resolve := func(u string) (*identity.Profile, bool) {
		if u == "" {
			return nil, false
		}
		if p, ok := profiles[u]; ok && p.Status == identity.AccountStatusActive {
			return &p, false
		}
		return nil, true
	}
	page := LogPage{Items: make([]LogItem, 0, len(rows))}
	for _, e := range rows {
		it := LogItem{Entry: e}
		it.Actor, it.ActorDeleted = resolve(e.Actor)
		it.Target, it.TargetDeleted = resolve(e.Target)
		page.Items = append(page.Items, it)
	}
	if more {
		last := rows[len(rows)-1]
		page.NextPageToken = cursor.Encode(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: last.At, DocID: strconv.FormatInt(last.Seq, 10)})
	}
	return page, nil
}
