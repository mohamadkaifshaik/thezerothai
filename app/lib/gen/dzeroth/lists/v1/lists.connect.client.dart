//
//  Generated code. Do not modify.
//  source: dzeroth/lists/v1/lists.proto
//

import "package:connectrpc/connect.dart" as connect;
import "lists.pb.dart" as dzerothlistsv1lists;
import "lists.connect.spec.dart" as specs;

extension type ListServiceClient (connect.Transport _transport) {
  /// Create a list owned by the caller. The new list is private unless is_private is sent as false (F3).
  /// name: 1-25 code points after NFC and trim; description: 0-100 code points; both single line, no control or bidi
  /// formatting characters (the bio rules); else VALIDATION "name" / "description", before any lookup.
  /// One transaction: idempotency doc, quotas/{uid} (list_creates), a count() of the caller's lists (ownerId == caller,
  /// so the cap is exact), then Create lists/{id} with a fresh Snowflake id.
  /// At LISTS_MAX_PER_USER (20) => LIMIT_REACHED "lists"; over the daily quota => QUOTA_EXCEEDED "list_creates".
  /// A replay writes nothing, and neither does a refusal at the cap or the quota.
  Future<dzerothlistsv1lists.CreateListResponse> createList(
    dzerothlistsv1lists.CreateListRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.createList,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Change a list's name, description or visibility. Owner only: any other caller, a missing list or a deleted one
  /// => NOT_FOUND. Only the fields that are set change; the field rules are CreateList's. Making a list private stops
  /// it serving non-owners at once on this instance and within 60 s on the others (the list instance cache).
  /// One transaction: idempotency doc, the list (fresh). A request that changes nothing writes only the idempotency doc.
  /// A rename of a list the caller has pinned also refreshes that tab's title (users/{uid}.homeTabs, through identity).
  /// A request that changes nothing writes only the idempotency doc; a replay writes nothing.
  Future<dzerothlistsv1lists.UpdateListResponse> updateList(
    dzerothlistsv1lists.UpdateListRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.updateList,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Delete one of the caller's lists. Owner only; any other caller or a missing list => success with no effect
  /// (NOT_FOUND is not returned, so a retry after a lost response succeeds). Other users who pinned the list keep a
  /// dangling Home tab: GetListTimeline answers NOT_FOUND and the client offers Unpin. The caller's own pin of the list
  /// is removed in the same call (a field-level update of users/{uid}.homeTabs through identity, only when pinned).
  /// A replay writes nothing.
  Future<dzerothlistsv1lists.DeleteListResponse> deleteList(
    dzerothlistsv1lists.DeleteListRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.deleteList,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// One list's header. NOT_FOUND for every cause in the header comment. pinned_by_viewer comes from the caller's own
  /// users/{uid}.homeTabs, already read by the account-status interceptor.
  /// Cached: the list doc 60 s per instance (CACHE_LISTS_ENTRIES), the owner's profile through identity.Directory, the
  /// owner's graph snapshot 60 s (read for a non-owner caller only: blockedBy overflow, F4).
  Future<dzerothlistsv1lists.GetListResponse> getList(
    dzerothlistsv1lists.GetListRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.getList,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// An owner's lists, in creation order (oldest first). owner_id "" means the caller.
  /// The caller's own lists: all of them, private ones included. Another owner's: public, not hidden lists only; an
  /// owner who is missing, not ACTIVE or blocks the caller => NOT_FOUND (byte-identical to GetProfile's missing-user
  /// error), and an owner whose blockedBy overflowed returns no lists.
  /// contains_user_id (the "Add to Lists" sheet) is accepted only with the caller's own lists (owner_id "" or the
  /// caller), else VALIDATION "contains_user_id", before any lookup: on another owner's lists it would be
  /// a membership oracle. containing_list_ids lists the returned lists whose members include that user (the
  /// member ids are in the list docs already read).
  /// Paging: the caller's own lists page by page_size (0 => 20, max 50, clamped) with an opaque sealed next_page_token.
  /// Another owner's lists are never paged: every public list comes back in one response and next_page_token is "",
  /// whatever page_size is (a token or a short page would reveal the owner's private lists). The owner has at
  /// most LISTS_MAX_PER_USER (20) lists.
  /// Query: lists where ownerId == owner, Limit(page_size + 1) for the caller, Limit(LISTS_MAX_PER_USER) for another owner,
  /// the automatic single-field index (no composite index).
  /// Cached: the owner's list set 60 s per instance; a write by the owner updates this instance's copy.
  Future<dzerothlistsv1lists.ListUserListsResponse> listUserLists(
    dzerothlistsv1lists.ListUserListsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.listUserLists,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Add an account to one of the caller's lists. Owner only, else NOT_FOUND. user_id: [A-Za-z0-9-]{1,128}; self is
  /// allowed (your own posts in your own list). The target must be ACTIVE (identity.Directory, cached) and pass the
  /// member rules in the header comment (block either way => NOT_FOUND; a protected target the caller does not follow
  /// => PROTECTED_ACCOUNT); the caller's blockedBy overflow adds one read of the target's graph (fail closed).
  /// One transaction: idempotency doc, the list (fresh), quotas/{uid} (list_adds), then ArrayUnion into memberIds and
  /// updatedAt. The same write removes members who block the caller (F4 lazy drop, from the caller's graph snapshot).
  /// At LIST_MAX_MEMBERS (150) => LIMIT_REACHED "list_members"; over the quota => QUOTA_EXCEEDED "list_adds".
  /// Already a member => success, the idempotency doc only, no quota spent.
  /// A replay and a refusal write nothing.
  Future<dzerothlistsv1lists.AddListMemberResponse> addListMember(
    dzerothlistsv1lists.AddListMemberRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.addListMember,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Remove an account from one of the caller's lists. Owner only, else NOT_FOUND. Not a member => success, the
  /// idempotency doc only. No quota. The same write removes members who block the caller (F4).
  /// A replay writes nothing.
  Future<dzerothlistsv1lists.RemoveListMemberResponse> removeListMember(
    dzerothlistsv1lists.RemoveListMemberRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.removeListMember,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// A list's members, most recently added first, as user rows with the caller's relationship to each
  /// (from the caller's graph). NOT_FOUND for every cause in the header comment. Members who are not ACTIVE and the
  /// member drops in the header comment are left out, so a page may be short while next_page_token is set: keep
  /// following it. UserListItem.since is unset (memberIds carries no timestamps); user.is_private is set (live row).
  /// Paging: page_size 0 => 20, max 50 (clamped); page_token is sealed, bound to the caller and the list, and expires
  /// after 24 h (expired, foreign or tampered => VALIDATION "page_token", before any lookup).
  Future<dzerothlistsv1lists.ListListMembersResponse> listListMembers(
    dzerothlistsv1lists.ListListMembersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ListService.listListMembers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
