//
//  Generated code. Do not modify.
//  source: dzeroth/communities/v1/communities.proto
//

import "package:connectrpc/connect.dart" as connect;
import "communities.pb.dart" as dzerothcommunitiesv1communities;
import "communities.connect.spec.dart" as specs;

extension type CommunityServiceClient (connect.Transport _transport) {
  /// Create a community owned by the caller, who becomes its first member. Needs the caller in COMMUNITY_CREATORS,
  /// checked first (FORBIDDEN "not_creator", 0 reads beyond the interceptor), then the text rules. No daily quota: the
  /// owned cap is exact and lifetime (there is no delete).
  /// One transaction: idempotency doc, the caller's communityMemberships (the owned and joined caps), then Create
  /// communities/{id} with a fresh Snowflake id (status ACTIVE, visibility PUBLIC, memberCount 1), the owner's member
  /// doc (JOINED) and the memberships doc (owned and joined += id). At COMMUNITIES_MAX_OWNED (2) => LIMIT_REACHED
  /// "communities_owned"; at COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined"; both 0 writes.
  /// Firestore: reads 3 cold (interceptor, idempotency, memberships) / 2 warm; writes 4 (community, owner member doc,
  /// memberships, idempotency) + 1 TTL delete of the idempotency doc 24 h later; replay reads 3 (interceptor,
  /// idempotency, the community), writes 0; refused 0 writes.
  Future<dzerothcommunitiesv1communities.CreateCommunityResponse> createCommunity(
    dzerothcommunitiesv1communities.CreateCommunityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.createCommunity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Change a community's name, description or rules. While creation is allowlisted (always at Stage 0) the caller must
  /// be in COMMUNITY_CREATORS, checked first: else FORBIDDEN "not_creator", 0 reads beyond the interceptor, 0 writes,
  /// whoever owns the community (an owner by hand-over keeps every other owner power).
  /// Then owner only: anyone else => FORBIDDEN "not_owner"; ARCHIVED => COMMUNITY_STATE "community_archived". Only the
  /// fields that are set change; the text rules are CreateCommunity's.
  /// A rename does not rewrite the label of earlier posts (Post.community is a snapshot at post time); the community's
  /// own page and feed header show the current name.
  /// One transaction: idempotency doc, the community (fresh), the owner's memberships (modlogged), then the community
  /// with an EDIT moderation-log entry. A request that changes nothing writes only the idempotency doc.
  /// Firestore: reads 4 cold (interceptor, idempotency, community, owner memberships) / 3 warm; writes 2 (community,
  /// idempotency), +1 for the first log entry that names the owner in this community (memberships modlogged), 1 when
  /// nothing changes, + 1 TTL delete later; replay 0 writes; "not_creator" 0 reads beyond the interceptor, 0 writes.
  Future<dzerothcommunitiesv1communities.UpdateCommunityResponse> updateCommunity(
    dzerothcommunitiesv1communities.UpdateCommunityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.updateCommunity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// One community: the header, its rules, its owner and its moderators. NOT_FOUND for every cause in Status (a SUSPENDED
  /// community is shown to its owner only). viewer_role comes from the community doc and the caller's member doc.
  /// owner and moderators are live rows (identity.Directory, up to 60 s stale) with the caller's relationship to each
  /// (0 extra reads, from the caller's graph); every role holder is shown to every viewer whatever the blocks (D7).
  /// A role holder whose account is not ACTIVE is left out for every viewer.
  /// Cached: the community doc 60 s per instance (CACHE_COMMUNITIES_ENTRIES), the member doc 60 s
  /// (CACHE_COMMUNITY_MEMBERS_ENTRIES), profiles through identity.Directory.
  /// Firestore: reads 15 cold (interceptor, community, caller member doc, caller graph, owner + <= 10 moderator
  /// profiles) / 0 warm, planning 4; writes 0.
  Future<dzerothcommunitiesv1communities.GetCommunityResponse> getCommunity(
    dzerothcommunitiesv1communities.GetCommunityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.getCommunity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The directory (F10): the ACTIVE communities with the most members, at most 50, by member_count descending (ties
  /// by id descending). Query `communities ORDER BY memberCount DESC, __name__ DESC LIMIT 50` on the automatic index;
  /// non-ACTIVE rows are dropped in memory, so the list may hold fewer than 50. No categories, no search. No block
  /// filtering (D7). viewer_role per row comes from the caller's communityMemberships and each doc's moderatorIds.
  /// Not paged at Stage 0: every row comes back in one response, whatever page_size is, and next_page_token is "". A
  /// non-empty page_token => VALIDATION "page_token", 0 reads beyond the interceptor.
  /// Cached: one shared directory entry per instance, 5 min; the caller's memberships 60 s.
  /// Firestore: reads 52 cold (interceptor, <= 50 for the shared refill, caller memberships), <= 22 at Stage 0
  /// (<= 20 communities) / 0-2 warm, planning 22; writes 0.
  Future<dzerothcommunitiesv1communities.ListCommunitiesResponse> listCommunities(
    dzerothcommunitiesv1communities.ListCommunitiesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.listCommunities,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's communities: every community the caller is a JOINED member of (owned and moderated ones included),
  /// most recently joined first, read from communityMemberships/{caller} and the community docs (cache-first). ARCHIVED
  /// ones are included with status ARCHIVED. SUSPENDED ones are left out, except the caller's own (status SUSPENDED).
  /// Communities the caller is banned from are not listed. can_create: the caller is in COMMUNITY_CREATORS (config,
  /// 0 reads); the owned cap is CreateCommunity's to answer.
  /// Not paged at Stage 0 (at most COMMUNITIES_MAX_JOINED, 50): one response, next_page_token "", whatever page_size
  /// is; a non-empty page_token => VALIDATION "page_token".
  /// Firestore: reads 52 cold (interceptor, memberships, <= 50 community docs) / 1 warm, planning 4; writes 0.
  Future<dzerothcommunitiesv1communities.ListMyCommunitiesResponse> listMyCommunities(
    dzerothcommunitiesv1communities.ListMyCommunitiesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.listMyCommunities,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Join a community. A block in either direction with the owner or a moderator does not refuse it (D7). A protected
  /// account may join (F6). BANNED => FORBIDDEN "banned", 0 writes; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// Already a member (owner and moderators included) => success, the idempotency doc only (1 write), no quota spent.
  /// One transaction: idempotency doc, the caller's member doc, the caller's communityMemberships (the joined cap,
  /// exact), quotas/{uid} (community_joins), then the member doc (JOINED), memberships (joined += id), a blind Increment
  /// of memberCount and quotas. The transaction never reads the community doc (its status comes from the 60 s cache),
  /// so a join burst cannot abort other joins on a read lock; member_count in the response may lag by up to 60 s.
  /// At COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined"; over the quota => QUOTA_EXCEEDED
  /// "community_joins".
  /// Firestore: reads 6 cold (interceptor, community via the cache, idempotency, member doc, memberships, quotas) /
  /// 4 warm; writes 5 (member doc, memberships, memberCount, quotas, idempotency), 1 when already a member, + 1 TTL
  /// delete later; replay 0 writes; refused 0 writes.
  Future<dzerothcommunitiesv1communities.JoinCommunityResponse> joinCommunity(
    dzerothcommunitiesv1communities.JoinCommunityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.joinCommunity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Leave a community. The owner => COMMUNITY_STATE "owner", 0 writes. A moderator also leaves moderator_ids, logged as
  /// MODERATOR_LEFT. Not a member (a banned user included: the ban stays) => success, the idempotency doc only (1
  /// write). Allowed in an ARCHIVED community. Leaving does not unpin a Home tab of the community.
  /// One transaction: idempotency doc, the member doc, the caller's memberships (+ the community fresh for a moderator),
  /// then delete the member doc, memberships (joined -= id), memberCount -1 (for a moderator the community write that
  /// also removes the id and appends the log entry), idempotency.
  /// Firestore: reads 5 cold, 6 for a moderator / 3 warm; writes 3 (memberships, the community, idempotency), 1 when
  /// not a member; deletes 1 (member doc) + 1 TTL later; replay 0 writes.
  Future<dzerothcommunitiesv1communities.LeaveCommunityResponse> leaveCommunity(
    dzerothcommunitiesv1communities.LeaveCommunityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.leaveCommunity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

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
  /// VALIDATION "page_token", 0 reads).
  /// Firestore: reads 43 cold at page 20 / 103 at page 50 (interceptor, community, query <= page, profiles <= page via
  /// identity.Directory, caller graph) / 21 / 51 warm, planning 30; writes 0.
  Future<dzerothcommunitiesv1communities.ListCommunityMembersResponse> listCommunityMembers(
    dzerothcommunitiesv1communities.ListCommunityMembersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.listCommunityMembers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Hide a post from this community's view, or a reply from its conversations.
  /// Owner or moderator, else FORBIDDEN "not_moderator"; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// post_id must be a root post created into this community (Post.community.id == community_id) or a reply at any
  /// depth of a conversation whose root was. Anything else (a reply in another community's conversation or in one with
  /// no community, a REPOST, a missing post) and a post or reply the platform removed (taken down, or hidden with its
  /// suspended author) => NOT_FOUND "post not found", 0 writes; so a hide and restore can never erase a platform
  /// removal (L-2). A moderator who is not the owner cannot act on a post or reply whose author is the owner or
  /// another moderator now => FORBIDDEN "not_owner", 0 writes; the owner acts on every one, a moderator on their own and
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
  /// Firestore: reads 5 cold (interceptor, idempotency, community, actor memberships, post) / 4 warm; writes 3 (post,
  /// community, idempotency), +1 for the actor's first log entry in this community (memberships modlogged), 1 when
  /// already hidden, + 1 TTL delete later; replay 0 writes; refused 0 writes.
  Future<dzerothcommunitiesv1communities.HideCommunityPostResponse> hideCommunityPost(
    dzerothcommunitiesv1communities.HideCommunityPostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.hideCommunityPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Restore a post or reply a moderator hid in this community: the reverse of HideCommunityPost, with the same roles,
  /// rules (the F16 "not_owner" and the platform-removal NOT_FOUND included), errors and budget. A root re-enters the
  /// community's feed and gets its label back; its recentRemovals entry is deleted, so it is never listed in
  /// removed_ids (a device that dropped it gets it back at its next cold open). A reply returns to GetThread for every
  /// caller. A post that is not hidden => success, the idempotency doc only. A RESTORE log entry is appended.
  /// Firestore: reads 5 cold / 4 warm; writes 3 (+1 for the actor's first log entry in this community), 1 when not
  /// hidden, + 1 TTL delete later; replay 0 writes; refused 0 writes.
  Future<dzerothcommunitiesv1communities.RestoreCommunityPostResponse> restoreCommunityPost(
    dzerothcommunitiesv1communities.RestoreCommunityPostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.restoreCommunityPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

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
  /// Firestore: reads 7 cold (interceptor, idempotency, community, target member doc, target memberships, actor
  /// memberships, target profile) / 6 warm; writes BAN 4, UNBAN 3 (+1 delete), MAKE_MODERATOR or REMOVE_MODERATOR 2-3,
  /// +1 for the actor's first log entry in this community, worst 5; 1 when nothing changes; deletes <= 1 + 1 TTL later;
  /// replay 0 writes; refused 0 writes.
  Future<dzerothcommunitiesv1communities.SetMemberRoleResponse> setMemberRole(
    dzerothcommunitiesv1communities.SetMemberRoleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.setMemberRole,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The community's moderation log, newest first: what the owner and moderators did. Owner and moderators
  /// only, else FORBIDDEN "not_moderator". The community keeps its newest COMMUNITY_MODLOG_MAX (100) entries, so older
  /// ones are gone. Entries never name a post's author; a user who deleted the account reads as actor_deleted or
  /// target_deleted (the action and time stay); an entry written by the platform has no actor and actor_deleted false
  /// (ModerationLogEntry.actor).
  /// Paging: page_size 0 => 25, max 25 (clamped); page_token is sealed, bound to the caller and the community, carries
  /// the last seq returned, and expires after 24 h (expired, foreign or tampered => VALIDATION "page_token", 0 reads).
  /// Firestore: reads 52 cold (interceptor, community, <= 50 actor and target profiles via identity.Directory) / 0 warm;
  /// writes 0.
  Future<dzerothcommunitiesv1communities.ListModerationLogResponse> listModerationLog(
    dzerothcommunitiesv1communities.ListModerationLogRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.CommunityService.listModerationLog,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
