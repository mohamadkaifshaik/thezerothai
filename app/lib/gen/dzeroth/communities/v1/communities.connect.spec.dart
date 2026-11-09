//
//  Generated code. Do not modify.
//  source: dzeroth/communities/v1/communities.proto
//

import "package:connectrpc/connect.dart" as connect;
import "communities.pb.dart" as dzerothcommunitiesv1communities;

abstract final class CommunityService {
  /// Fully-qualified name of the CommunityService service.
  static const name = 'dzeroth.communities.v1.CommunityService';

  /// Create a community owned by the caller, who becomes its first member. Needs the caller in COMMUNITY_CREATORS,
  /// checked first (FORBIDDEN "not_creator", before any lookup), then the text rules. No daily cap: the
  /// owned cap is exact and lifetime (there is no delete).
  /// One transaction: idempotency doc, the caller's communityMemberships (the owned and joined caps), then Create
  /// communities/{id} with a fresh Snowflake id (status ACTIVE, visibility PUBLIC, memberCount 1), the owner's member
  /// doc (JOINED) and the memberships doc (owned and joined += id). At COMMUNITIES_MAX_OWNED (2) => LIMIT_REACHED
  /// "communities_owned"; at COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined"; both write nothing.
  static const createCommunity = connect.Spec(
    '/$name/CreateCommunity',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.CreateCommunityRequest.new,
    dzerothcommunitiesv1communities.CreateCommunityResponse.new,
  );

  /// Change a community's name, description or rules. While creation is allowlisted (always at Stage 0) the caller must
  /// be in COMMUNITY_CREATORS, checked first: else FORBIDDEN "not_creator", before any lookup and writing nothing,
  /// whoever owns the community (an owner by hand-over keeps every other owner power).
  /// Then owner only: anyone else => FORBIDDEN "not_owner"; ARCHIVED => COMMUNITY_STATE "community_archived". Only the
  /// fields that are set change; the text rules are CreateCommunity's.
  /// A rename does not rewrite the label of earlier posts (Post.community is a snapshot at post time); the community's
  /// own page and feed header show the current name.
  /// One transaction: idempotency doc, the community (fresh), the owner's memberships (modlogged), then the community
  /// with an EDIT moderation-log entry. A request that changes nothing writes only the idempotency doc.
  static const updateCommunity = connect.Spec(
    '/$name/UpdateCommunity',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.UpdateCommunityRequest.new,
    dzerothcommunitiesv1communities.UpdateCommunityResponse.new,
  );

  /// One community: the header, its rules, its owner and its moderators. NOT_FOUND for every cause in Status (a SUSPENDED
  /// community is shown to its owner only). viewer_role comes from the community doc and the caller's member doc.
  /// owner and moderators are live rows (identity.Directory, up to 60 s stale) with the caller's relationship to each
  /// (from the caller's graph); every role holder is shown to every viewer whatever the blocks (D7).
  /// A role holder whose account is not ACTIVE is left out for every viewer.
  /// Cached: the community doc 60 s per instance (CACHE_COMMUNITIES_ENTRIES), the member doc 60 s
  /// (CACHE_COMMUNITY_MEMBERS_ENTRIES), profiles through identity.Directory.
  static const getCommunity = connect.Spec(
    '/$name/GetCommunity',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.GetCommunityRequest.new,
    dzerothcommunitiesv1communities.GetCommunityResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The directory (F10): the ACTIVE communities with the most members, at most 50, by member_count descending (ties
  /// by id descending). Query `communities ORDER BY memberCount DESC, __name__ DESC LIMIT 50` on the automatic index;
  /// non-ACTIVE rows are dropped in memory, so the list may hold fewer than 50. No categories, no search. No block
  /// filtering (D7). viewer_role per row comes from the caller's communityMemberships and each doc's moderatorIds.
  /// Not paged at Stage 0: every row comes back in one response, whatever page_size is, and next_page_token is "". A
  /// non-empty page_token => VALIDATION "page_token", before any lookup.
  /// Cached: one shared directory entry per instance, 5 min; the caller's memberships 60 s.
  static const listCommunities = connect.Spec(
    '/$name/ListCommunities',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.ListCommunitiesRequest.new,
    dzerothcommunitiesv1communities.ListCommunitiesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's communities: every community the caller is a JOINED member of (owned and moderated ones included),
  /// most recently joined first, read from communityMemberships/{caller} and the community docs (cache-first). ARCHIVED
  /// ones are included with status ARCHIVED. SUSPENDED ones are left out, except the caller's own (status SUSPENDED).
  /// Communities the caller is banned from are not listed. can_create: the caller is in COMMUNITY_CREATORS (config, no lookup); the owned cap is CreateCommunity's to answer.
  /// Not paged at Stage 0 (at most COMMUNITIES_MAX_JOINED, 50): one response, next_page_token "", whatever page_size
  /// is; a non-empty page_token => VALIDATION "page_token".
  static const listMyCommunities = connect.Spec(
    '/$name/ListMyCommunities',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.ListMyCommunitiesRequest.new,
    dzerothcommunitiesv1communities.ListMyCommunitiesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Join a community. A block in either direction with the owner or a moderator does not refuse it (D7). A protected
  /// account may join (F6). BANNED => FORBIDDEN "banned", writing nothing; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// Already a member (owner and moderators included) => success, the idempotency doc only.
  /// One transaction: idempotency doc, the caller's member doc, the caller's communityMemberships (the joined cap,
  /// exact), then the member doc (JOINED), memberships (joined += id) and a blind Increment
  /// of memberCount. The transaction never reads the community doc (its status comes from the 60 s cache),
  /// so a join burst cannot abort other joins on a read lock; member_count in the response may lag by up to 60 s.
  /// At COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined".
  static const joinCommunity = connect.Spec(
    '/$name/JoinCommunity',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.JoinCommunityRequest.new,
    dzerothcommunitiesv1communities.JoinCommunityResponse.new,
  );

  /// Leave a community. The owner => COMMUNITY_STATE "owner", writing nothing. A moderator also leaves moderator_ids, logged as
  /// MODERATOR_LEFT. Not a member (a banned user included: the ban stays) => success, the idempotency doc only.
  /// Allowed in an ARCHIVED community. Leaving does not unpin a Home tab of the community.
  /// One transaction: idempotency doc, the member doc, the caller's memberships (+ the community fresh for a moderator),
  /// then delete the member doc, memberships (joined -= id), memberCount -1 (for a moderator the community write that
  /// also removes the id and appends the log entry), idempotency.
  static const leaveCommunity = connect.Spec(
    '/$name/LeaveCommunity',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.LeaveCommunityRequest.new,
    dzerothcommunitiesv1communities.LeaveCommunityResponse.new,
  );

  /// A community's member page. filter JOINED (or UNSPECIFIED): its members, owner and moderators included, most recently
  /// joined first (`communityMembers ORDER BY joinedAt DESC, __name__ DESC`, the presence of joinedAt is the filter).
  /// filter BANNED: its banned users, most recently banned first (`ORDER BY bannedAt DESC, __name__ DESC`), for the
  /// owner and moderators only, else FORBIDDEN "not_moderator" after the community read. Both run on the automatic
  /// index (D3). Each row carries the user's role and UserListItem.since = joinedAt (JOINED) or bannedAt (BANNED).
  /// Rows whose account is not ACTIVE are left out, and so are the D7 drops for the caller (header comment: a block
  /// either way drops the row unless the caller is the owner or a moderator, who see every member; a muted member is
  /// shown). A protected member (user.is_private) is left out for a caller who is not the owner, a moderator, that
  /// member or an approved follower of it (a pending request is not approval); a protected owner or moderator is
  /// always listed, and member_count still counts every member. So a page may be
  /// short while next_page_token is set: keep following it. user.is_private is set (live row).
  /// Paging: page_size 0 => 20, max 50 (clamped); page_token is sealed, bound to the caller, the community and the
  /// effective filter (UNSPECIFIED and JOINED bind the same), and expires after 24 h (expired, foreign or tampered =>
  /// VALIDATION "page_token", before any lookup).
  static const listCommunityMembers = connect.Spec(
    '/$name/ListCommunityMembers',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.ListCommunityMembersRequest.new,
    dzerothcommunitiesv1communities.ListCommunityMembersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Find members of one community by handle prefix (F36). Flags: communities, then community_member_search (header).
  /// prefix: one optional leading "@", then 2-15 characters of [A-Za-z0-9_] (matched lower-cased), else VALIDATION
  /// "prefix", before any lookup. limit: 0 => 20, clamped to 1..20 (never a validation error). filter: UNSPECIFIED or
  /// JOINED searches the members (anyone who may list them); BANNED the banned users, for the owner and moderators only,
  /// else FORBIDDEN "not_moderator" after the community read (as on the Banned page); any other value => VALIDATION
  /// "filter". A missing or SUSPENDED community is the one NOT_FOUND.
  /// How: the first `limit` handles of the WHOLE platform that start with the prefix (identity's handle-prefix query,
  /// through the same 60 s per-instance (prefix, limit) cache SearchPeople uses), then one batch read of those users'
  /// member docs in this community, keeping the ones in the filter's state. So it answers at most `limit` rows and a
  /// member whose handle shares a very common prefix with many non-members can be missed: the client says "No members
  /// found for that handle. Try more of their handle.", never "not a member". Display names are not searched. Rows are
  /// built exactly as on ListCommunityMembers (live row, role, since, account not ACTIVE left out, the D7 block drops
  /// for a caller who is not the owner or a moderator), in handle order. There is no page_token: the owner approved this
  /// exception to the cursor rule (2026-11-09), because the answer is a bounded top-N, not a list to page through.
  static const searchCommunityMembers = connect.Spec(
    '/$name/SearchCommunityMembers',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.SearchCommunityMembersRequest.new,
    dzerothcommunitiesv1communities.SearchCommunityMembersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Hide a post from this community's view, or a reply from its conversations.
  /// Owner or moderator, else FORBIDDEN "not_moderator"; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// post_id must be a root post created into this community (Post.community.id == community_id) or a reply at any
  /// depth of a conversation whose root was. Anything else (a reply in another community's conversation or in one with
  /// no community, a REPOST, a missing post) and a post or reply the platform removed (taken down, or hidden with its
  /// suspended author) => NOT_FOUND "post not found", writing nothing; so a hide and restore can never erase a platform
  /// removal (L-2). A moderator who is not the owner cannot act on a post or reply whose author is the owner or
  /// another moderator now => FORBIDDEN "not_owner", writing nothing; the owner acts on every one, a moderator on their own and
  /// on everyone else's (F16).
  /// A root post leaves the community's feed and loses its label on every surface. A reply leaves the community's
  /// threads: GetThread drops it for every caller but its author, and as a parent returns it unavailable. Both stay on
  /// the author's profile, in search and on a direct link (GetPost), with their likes and reposts, and a hide is never
  /// a takedown. Already hidden => success, the idempotency doc only. A block either way does not refuse it
  /// (F14).
  /// One transaction (posts.CommunityModerator): idempotency doc, the community (fresh), the actor's memberships, the
  /// post (fresh), then the post (field-level: communityHidden and the hide time set; a root also loses communityId),
  /// the community (a HIDE log entry, at most 100 kept; for a root also recentRemovals += {post, now}, at most 50 kept;
  /// a reply adds no recentRemovals entry) and idempotency. Feeds on this instance drop a root at once; other devices
  /// drop it at their next refresh (GetCommunityTimeline removed_ids, within 60 s). A device keeps a reply in a thread
  /// it already loaded until it loads the thread again.
  static const hideCommunityPost = connect.Spec(
    '/$name/HideCommunityPost',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.HideCommunityPostRequest.new,
    dzerothcommunitiesv1communities.HideCommunityPostResponse.new,
  );

  /// Restore a post or reply a moderator hid in this community: the reverse of HideCommunityPost, with the same roles,
  /// rules (the F16 "not_owner" and the platform-removal NOT_FOUND included) and errors. A root re-enters the
  /// community's feed and gets its label back; its recentRemovals entry is deleted, so it is never listed in
  /// removed_ids (a device that dropped it gets it back at its next cold open). A reply returns to GetThread for every
  /// caller. A post that is not hidden => success, the idempotency doc only. A RESTORE log entry is appended.
  static const restoreCommunityPost = connect.Spec(
    '/$name/RestoreCommunityPost',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.RestoreCommunityPostRequest.new,
    dzerothcommunitiesv1communities.RestoreCommunityPostResponse.new,
  );

  /// Change one user's standing in a community. user_id: [A-Za-z0-9-]{1,128}; a target that is missing or
  /// not ACTIVE => NOT_FOUND "user not found", whatever the blocks (F14). ARCHIVED => COMMUNITY_STATE
  /// "community_archived".
  /// - BAN, UNBAN: owner or moderator, else FORBIDDEN "not_moderator". The target must be a plain member or a non-member
  ///   (a ban of a raider who already left is allowed): a moderator target => COMMUNITY_STATE "moderator" for the owner
  ///   (remove the role first) and FORBIDDEN "not_owner" for a moderator; the owner as target => FORBIDDEN "not_owner"
  ///   for a moderator and VALIDATION "user_id" for the owner (themselves). A ban makes the member doc BANNED, moves the
  ///   community from the target's joined to banned and lowers memberCount by 1 if the target was JOINED; it never hides
  ///   earlier posts. UNBAN deletes the record; the user may join again.
  /// - MAKE_MODERATOR, REMOVE_MODERATOR: the owner only, else FORBIDDEN "not_owner". The target must be a JOINED member
  ///   other than the owner, else VALIDATION "user_id". At COMMUNITY_MAX_MODERATORS (10) => LIMIT_REACHED
  ///   "community_moderators". Moderators are kept in appointment order (the first is the longest serving, F12).
  /// A request that changes nothing (a repeated ban, an unban of a user not banned, appointing a moderator again)
  /// writes the idempotency doc only. Every change appends one log entry (BAN, UNBAN, MAKE_MODERATOR,
  /// REMOVE_MODERATOR) naming the actor and the target, and adds the community to both users' memberships modlogged.
  /// action UNSPECIFIED => VALIDATION "action".
  /// One transaction: idempotency doc, the community (fresh), the target's member doc and memberships, the actor's
  /// memberships; the target's profile through identity.Directory.
  static const setMemberRole = connect.Spec(
    '/$name/SetMemberRole',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.SetMemberRoleRequest.new,
    dzerothcommunitiesv1communities.SetMemberRoleResponse.new,
  );

  /// The community's moderation log, newest first: what the owner and moderators did. Owner and moderators
  /// only, else FORBIDDEN "not_moderator". The community keeps its newest COMMUNITY_MODLOG_MAX (100) entries, so older
  /// ones are gone. Entries never name a post's author; a user who deleted the account reads as actor_deleted or
  /// target_deleted (the action and time stay); an entry written by the platform has no actor and actor_deleted false
  /// (ModerationLogEntry.actor).
  /// Paging: page_size 0 => 25, max 25 (clamped); page_token is sealed, bound to the caller and the community, carries
  /// the last seq returned, and expires after 24 h (expired, foreign or tampered => VALIDATION "page_token", before any lookup).
  static const listModerationLog = connect.Spec(
    '/$name/ListModerationLog',
    connect.StreamType.unary,
    dzerothcommunitiesv1communities.ListModerationLogRequest.new,
    dzerothcommunitiesv1communities.ListModerationLogResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
