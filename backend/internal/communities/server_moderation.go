package communities

import (
	"context"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// HideCommunityPost is gated by FEATURE_COMMUNITIES (reason=not_moderator for anyone but the owner and moderators; reason=not_owner when a moderator targets the owner's or another moderator's post, W5-53 F16, 0 extra reads, nothing written; a post with `moderation` set is NOT_FOUND). The post leaves the
// community's feed and loses its label; it stays on the author's profile and in Home. Moderators never delete posts. Already hidden is
// success with the idempotency document only.
//
// Firestore (interceptor included): reads 5 cold (interceptor, idempotency, community, actor memberships, post; all fresh) / 4 warm;
// writes 3 (post, community, idempotency) +1 on the actor's first log entry in this community (memberships modlogged) + 1 TTL delete
// later; already hidden 1 write; replay 2 reads, 0 writes; refused 0 writes.
func (s *Server) HideCommunityPost(ctx context.Context, req *connect.Request[communitiesv1.HideCommunityPostRequest]) (*connect.Response[communitiesv1.HideCommunityPostResponse], error) {
	m := req.Msg
	err := s.postAction(ctx, "HideCommunityPost", PostActionInput{Key: m.GetIdempotencyKey(), CommunityID: m.GetCommunityId(), PostID: m.GetPostId()}, Moderation.HideCommunityPost)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.HideCommunityPostResponse{}), nil
}

// RestoreCommunityPost is gated by FEATURE_COMMUNITIES: the reverse of HideCommunityPost, with the same roles, errors and budget.
//
// Firestore (interceptor included): reads 5 cold / 4 warm; writes 3 (+1 on the actor's first log entry), 1 when the post is not hidden,
// + 1 TTL delete later; replay 2 reads, 0 writes.
func (s *Server) RestoreCommunityPost(ctx context.Context, req *connect.Request[communitiesv1.RestoreCommunityPostRequest]) (*connect.Response[communitiesv1.RestoreCommunityPostResponse], error) {
	m := req.Msg
	err := s.postAction(ctx, "RestoreCommunityPost", PostActionInput{Key: m.GetIdempotencyKey(), CommunityID: m.GetCommunityId(), PostID: m.GetPostId()}, Moderation.RestoreCommunityPost)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.RestoreCommunityPostResponse{}), nil
}

func (s *Server) postAction(ctx context.Context, rpc string, in PostActionInput, call func(Moderation, context.Context, string, PostActionInput) error) error {
	ctx, cancel, uid, err := s.entry(ctx, rpc)
	if err != nil {
		return err
	}
	defer cancel()
	return call(s.svc, ctx, uid, in)
}

// SetMemberRole is gated by FEATURE_COMMUNITIES. BAN and UNBAN are for the owner and moderators (reason=not_moderator), MAKE and
// REMOVE_MODERATOR for the owner (reason=not_owner); a ban accepts a non-member and never touches earlier posts.
//
// Firestore (interceptor included): reads 7 cold (interceptor, target profile, idempotency, community, target member doc, target
// memberships, actor memberships) / 6 warm; writes BAN 4, UNBAN 3 + 1 delete, MAKE or REMOVE_MODERATOR 2 to 3, +1 on the actor's first log
// entry in this community, worst 5; a request that changes nothing 1 write; replay 3 reads, 0 writes; refused 0 writes.
func (s *Server) SetMemberRole(ctx context.Context, req *connect.Request[communitiesv1.SetMemberRoleRequest]) (*connect.Response[communitiesv1.SetMemberRoleResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "SetMemberRole")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	res, err := s.svc.SetMemberRole(ctx, uid, RoleInput{
		Key: m.GetIdempotencyKey(), CommunityID: m.GetCommunityId(), UserID: m.GetUserId(), Action: roleActionFromProto(m.GetAction()),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.SetMemberRoleResponse{Role: roleToProto(res.Role), Community: toProtoCommunity(res.View)}), nil
}

func roleActionFromProto(a communitiesv1.MemberRoleAction) RoleAction {
	switch a {
	case communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_BAN:
		return RoleActionBan
	case communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_UNBAN:
		return RoleActionUnban
	case communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_MAKE_MODERATOR:
		return RoleActionMakeModerator
	case communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_REMOVE_MODERATOR:
		return RoleActionRemoveModerator
	}
	return RoleActionNone
}

// ListModerationLog is gated by FEATURE_COMMUNITIES; owner and moderators only (reason=not_moderator after the community read), newest
// first, at most 25 entries a page. A tampered, expired or foreign page_token is VALIDATION "page_token" with 0 reads beyond the
// interceptor.
//
// Firestore (interceptor included): reads 52 cold (interceptor, community, <= 50 actor and target profiles) / 0 warm (profiles come from the directory cache); a
// refused caller 2; writes 0.
func (s *Server) ListModerationLog(ctx context.Context, req *connect.Request[communitiesv1.ListModerationLogRequest]) (*connect.Response[communitiesv1.ListModerationLogResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListModerationLog")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	page, err := s.svc.ListModerationLog(ctx, uid, LogInput{CommunityID: m.GetCommunityId(), PageSize: m.GetPageSize(), PageToken: m.GetPageToken()})
	if err != nil {
		return nil, err
	}
	out := &communitiesv1.ListModerationLogResponse{Entries: make([]*communitiesv1.ModerationLogEntry, len(page.Items)), NextPageToken: page.NextPageToken}
	for i, it := range page.Items {
		out.Entries[i] = &communitiesv1.ModerationLogEntry{
			Seq: it.Entry.Seq, At: timestamppb.New(it.Entry.At), Action: logActionToProto(it.Entry.Action),
			Actor: logPerson(it.Actor), ActorDeleted: it.ActorDeleted, Target: logPerson(it.Target), TargetDeleted: it.TargetDeleted,
		}
	}
	return connect.NewResponse(out), nil
}

// logPerson is the live row of a person in the log: the graph lists' AuthorSnapshot builder, with the lock badge unset (the log shows a
// name, not an account's privacy).
func logPerson(p *identity.Profile) *commonv1.AuthorSnapshot {
	if p == nil {
		return nil
	}
	row := graph.ListItemsToProto([]graph.ListItem{{User: *p}})[0].GetUser()
	row.IsPrivate = false
	return row
}

func logActionToProto(a string) communitiesv1.ModerationLogAction {
	switch a {
	case ActionHide:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_HIDE
	case ActionRestore:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_RESTORE
	case ActionBan:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_BAN
	case ActionUnban:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_UNBAN
	case ActionMakeModerator:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_MAKE_MODERATOR
	case ActionRemoveMod:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_REMOVE_MODERATOR
	case ActionEdit:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_EDIT
	case ActionModeratorLeft:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_MODERATOR_LEFT
	case ActionOwnerHandover:
		return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_OWNER_HANDOVER
	}
	return communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_UNSPECIFIED
}
