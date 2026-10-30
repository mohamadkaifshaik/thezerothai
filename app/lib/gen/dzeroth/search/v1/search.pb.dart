// This is a generated file - do not edit.
//
// Generated from dzeroth/search/v1/search.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $2;

import '../../graph/v1/graph.pb.dart' as $0;
import '../../posts/v1/posts.pb.dart' as $1;
import 'search.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'search.pbenum.dart';

class SearchPeopleRequest extends $pb.GeneratedMessage {
  factory SearchPeopleRequest({
    $core.String? query,
    $core.int? limit,
  }) {
    final result = SearchPeopleRequest._();
    if (query != null) result.query = query;
    if (limit != null) result.limit = limit;
    return result;
  }

  SearchPeopleRequest._();

  factory SearchPeopleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPeopleRequest()..mergeFromBuffer(data, registry);
  factory SearchPeopleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPeopleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchPeopleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchPeopleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'query')
    ..aI(2, _omitFieldNames ? '' : 'limit')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPeopleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPeopleRequest copyWith(void Function(SearchPeopleRequest) updates) =>
      super.copyWith((message) => updates(message as SearchPeopleRequest))
          as SearchPeopleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SearchPeopleRequest() / SearchPeopleRequest.new instead')
  static SearchPeopleRequest create() => SearchPeopleRequest._();
  static $pb.GeneratedMessage $_createMessage() => SearchPeopleRequest._();
  @$core.override
  SearchPeopleRequest createEmptyInstance() => SearchPeopleRequest._();
  @$core.pragma('dart2js:noInline')
  static SearchPeopleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchPeopleRequest>(
          SearchPeopleRequest.$_createMessage);
  static SearchPeopleRequest? _defaultInstance;

  /// A handle prefix, with or without '@' (grammar in the file comment).
  @$pb.TagNumber(1)
  $core.String get query => $_getSZ(0);
  @$pb.TagNumber(1)
  set query($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearQuery() => $_clearField(1);

  /// 0 => 10; max 20 (clamped); negative => VALIDATION "limit".
  @$pb.TagNumber(2)
  $core.int get limit => $_getIZ(1);
  @$pb.TagNumber(2)
  set limit($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLimit() => $_has(1);
  @$pb.TagNumber(2)
  void clearLimit() => $_clearField(2);
}

class SearchPeopleResponse extends $pb.GeneratedMessage {
  factory SearchPeopleResponse({
    $core.Iterable<$0.UserListItem>? users,
    $core.bool? unsupportedQuery,
  }) {
    final result = SearchPeopleResponse._();
    if (users != null) result.users.addAll(users);
    if (unsupportedQuery != null) result.unsupportedQuery = unsupportedQuery;
    return result;
  }

  SearchPeopleResponse._();

  factory SearchPeopleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPeopleResponse()..mergeFromBuffer(data, registry);
  factory SearchPeopleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPeopleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchPeopleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchPeopleResponse.$_createMessage)
    ..pPM<$0.UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: $0.UserListItem.$_createMessage)
    ..aOB(2, _omitFieldNames ? '' : 'unsupportedQuery')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPeopleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPeopleResponse copyWith(void Function(SearchPeopleResponse) updates) =>
      super.copyWith((message) => updates(message as SearchPeopleResponse))
          as SearchPeopleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SearchPeopleResponse() / SearchPeopleResponse.new instead')
  static SearchPeopleResponse create() => SearchPeopleResponse._();
  static $pb.GeneratedMessage $_createMessage() => SearchPeopleResponse._();
  @$core.override
  SearchPeopleResponse createEmptyInstance() => SearchPeopleResponse._();
  @$core.pragma('dart2js:noInline')
  static SearchPeopleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchPeopleResponse>(
          SearchPeopleResponse.$_createMessage);
  static SearchPeopleResponse? _defaultInstance;

  /// Handle order; at most limit. Each row has user (a live row: is_private is set) and relationship; since is unset.
  @$pb.TagNumber(1)
  $pb.PbList<$0.UserListItem> get users => $_getList(0);

  /// True when the query is not a handle prefix (users is then empty and nothing was read). Not an error.
  @$pb.TagNumber(2)
  $core.bool get unsupportedQuery => $_getBF(1);
  @$pb.TagNumber(2)
  set unsupportedQuery($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUnsupportedQuery() => $_has(1);
  @$pb.TagNumber(2)
  void clearUnsupportedQuery() => $_clearField(2);
}

class SearchPostsRequest extends $pb.GeneratedMessage {
  factory SearchPostsRequest({
    $core.String? query,
    SearchTab? tab,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = SearchPostsRequest._();
    if (query != null) result.query = query;
    if (tab != null) result.tab = tab;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  SearchPostsRequest._();

  factory SearchPostsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPostsRequest()..mergeFromBuffer(data, registry);
  factory SearchPostsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPostsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchPostsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchPostsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'query')
    ..aE<SearchTab>(2, _omitFieldNames ? '' : 'tab',
        enumValues: SearchTab.values)
    ..aI(3, _omitFieldNames ? '' : 'pageSize')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPostsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPostsRequest copyWith(void Function(SearchPostsRequest) updates) =>
      super.copyWith((message) => updates(message as SearchPostsRequest))
          as SearchPostsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SearchPostsRequest() / SearchPostsRequest.new instead')
  static SearchPostsRequest create() => SearchPostsRequest._();
  static $pb.GeneratedMessage $_createMessage() => SearchPostsRequest._();
  @$core.override
  SearchPostsRequest createEmptyInstance() => SearchPostsRequest._();
  @$core.pragma('dart2js:noInline')
  static SearchPostsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchPostsRequest>(
          SearchPostsRequest.$_createMessage);
  static SearchPostsRequest? _defaultInstance;

  /// One hashtag, with or without '#' (grammar in the file comment).
  @$pb.TagNumber(1)
  $core.String get query => $_getSZ(0);
  @$pb.TagNumber(1)
  set query($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearQuery() => $_clearField(1);

  /// UNSPECIFIED => TOP.
  @$pb.TagNumber(2)
  SearchTab get tab => $_getN(1);
  @$pb.TagNumber(2)
  set tab(SearchTab value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasTab() => $_has(1);
  @$pb.TagNumber(2)
  void clearTab() => $_clearField(2);

  /// 0 => 20; max 50 (clamped); negative => VALIDATION "page_size". TOP returns at most 20.
  @$pb.TagNumber(3)
  $core.int get pageSize => $_getIZ(2);
  @$pb.TagNumber(3)
  set pageSize($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageSize() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageSize() => $_clearField(3);

  /// next_page_token of the previous page for the same query and tab.
  @$pb.TagNumber(4)
  $core.String get pageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set pageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageToken() => $_clearField(4);
}

class SearchPostsResponse extends $pb.GeneratedMessage {
  factory SearchPostsResponse({
    $core.Iterable<$1.PostView>? posts,
    $core.String? nextPageToken,
    $core.String? normalizedTag,
    $core.bool? unsupportedQuery,
  }) {
    final result = SearchPostsResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (normalizedTag != null) result.normalizedTag = normalizedTag;
    if (unsupportedQuery != null) result.unsupportedQuery = unsupportedQuery;
    return result;
  }

  SearchPostsResponse._();

  factory SearchPostsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPostsResponse()..mergeFromBuffer(data, registry);
  factory SearchPostsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchPostsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchPostsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchPostsResponse.$_createMessage)
    ..pPM<$1.PostView>(1, _omitFieldNames ? '' : 'posts',
        subBuilder: $1.PostView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'normalizedTag')
    ..aOB(4, _omitFieldNames ? '' : 'unsupportedQuery')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPostsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchPostsResponse copyWith(void Function(SearchPostsResponse) updates) =>
      super.copyWith((message) => updates(message as SearchPostsResponse))
          as SearchPostsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SearchPostsResponse() / SearchPostsResponse.new instead')
  static SearchPostsResponse create() => SearchPostsResponse._();
  static $pb.GeneratedMessage $_createMessage() => SearchPostsResponse._();
  @$core.override
  SearchPostsResponse createEmptyInstance() => SearchPostsResponse._();
  @$core.pragma('dart2js:noInline')
  static SearchPostsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchPostsResponse>(
          SearchPostsResponse.$_createMessage);
  static SearchPostsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$1.PostView> get posts => $_getList(0);

  /// "" => no more. Always "" for TOP and for an unsupported query.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// The tag searched, as posts store it (lower-case, NFC, no '#'), e.g. "#Go" and "go" both give "go". Empty when
  /// unsupported_query is true.
  @$pb.TagNumber(3)
  $core.String get normalizedTag => $_getSZ(2);
  @$pb.TagNumber(3)
  set normalizedTag($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNormalizedTag() => $_has(2);
  @$pb.TagNumber(3)
  void clearNormalizedTag() => $_clearField(3);

  /// True when the query is not a single hashtag (posts is then empty and nothing was read). Not an error.
  @$pb.TagNumber(4)
  $core.bool get unsupportedQuery => $_getBF(3);
  @$pb.TagNumber(4)
  set unsupportedQuery($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasUnsupportedQuery() => $_has(3);
  @$pb.TagNumber(4)
  void clearUnsupportedQuery() => $_clearField(4);
}

class GetTrendsRequest extends $pb.GeneratedMessage {
  factory GetTrendsRequest({
    $core.int? limit,
    $core.String? prefix,
  }) {
    final result = GetTrendsRequest._();
    if (limit != null) result.limit = limit;
    if (prefix != null) result.prefix = prefix;
    return result;
  }

  GetTrendsRequest._();

  factory GetTrendsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetTrendsRequest()..mergeFromBuffer(data, registry);
  factory GetTrendsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetTrendsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetTrendsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: GetTrendsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'limit')
    ..aOS(2, _omitFieldNames ? '' : 'prefix')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetTrendsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetTrendsRequest copyWith(void Function(GetTrendsRequest) updates) =>
      super.copyWith((message) => updates(message as GetTrendsRequest))
          as GetTrendsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetTrendsRequest() / GetTrendsRequest.new instead')
  static GetTrendsRequest create() => GetTrendsRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetTrendsRequest._();
  @$core.override
  GetTrendsRequest createEmptyInstance() => GetTrendsRequest._();
  @$core.pragma('dart2js:noInline')
  static GetTrendsRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetTrendsRequest>(
          GetTrendsRequest.$_createMessage);
  static GetTrendsRequest? _defaultInstance;

  /// 0 => 10; max 30 (clamped); negative => VALIDATION "limit".
  @$pb.TagNumber(1)
  $core.int get limit => $_getIZ(0);
  @$pb.TagNumber(1)
  set limit($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLimit() => $_has(0);
  @$pb.TagNumber(1)
  void clearLimit() => $_clearField(1);

  /// Optional tag prefix for suggestions (see GetTrends).
  @$pb.TagNumber(2)
  $core.String get prefix => $_getSZ(1);
  @$pb.TagNumber(2)
  set prefix($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPrefix() => $_has(1);
  @$pb.TagNumber(2)
  void clearPrefix() => $_clearField(2);
}

/// One trending hashtag.
class Trend extends $pb.GeneratedMessage {
  factory Trend({
    $core.String? tag,
    $fixnum.Int64? postCount,
    $core.int? rank,
  }) {
    final result = Trend._();
    if (tag != null) result.tag = tag;
    if (postCount != null) result.postCount = postCount;
    if (rank != null) result.rank = rank;
    return result;
  }

  Trend._();

  factory Trend.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Trend()..mergeFromBuffer(data, registry);
  factory Trend.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Trend()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Trend',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: Trend.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'tag')
    ..aInt64(2, _omitFieldNames ? '' : 'postCount')
    ..aI(3, _omitFieldNames ? '' : 'rank')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Trend clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Trend copyWith(void Function(Trend) updates) =>
      super.copyWith((message) => updates(message as Trend)) as Trend;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Trend() / Trend.new instead')
  static Trend create() => Trend._();
  static $pb.GeneratedMessage $_createMessage() => Trend._();
  @$core.override
  Trend createEmptyInstance() => Trend._();
  @$core.pragma('dart2js:noInline')
  static Trend getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Trend>(Trend.$_createMessage);
  static Trend? _defaultInstance;

  /// Lower-case, NFC, without '#'.
  @$pb.TagNumber(1)
  $core.String get tag => $_getSZ(0);
  @$pb.TagNumber(1)
  set tag($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTag() => $_has(0);
  @$pb.TagNumber(1)
  void clearTag() => $_clearField(1);

  /// Posts that carried the tag in the window (hidden posts, reposts and protected accounts' posts excluded).
  @$pb.TagNumber(2)
  $fixnum.Int64 get postCount => $_getI64(1);
  @$pb.TagNumber(2)
  set postCount($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostCount() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostCount() => $_clearField(2);

  /// 1-based rank in the whole list; with a prefix the ranks keep their gaps.
  @$pb.TagNumber(3)
  $core.int get rank => $_getIZ(2);
  @$pb.TagNumber(3)
  set rank($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRank() => $_has(2);
  @$pb.TagNumber(3)
  void clearRank() => $_clearField(3);
}

class GetTrendsResponse extends $pb.GeneratedMessage {
  factory GetTrendsResponse({
    $core.Iterable<Trend>? trends,
    $2.Timestamp? computedAt,
  }) {
    final result = GetTrendsResponse._();
    if (trends != null) result.trends.addAll(trends);
    if (computedAt != null) result.computedAt = computedAt;
    return result;
  }

  GetTrendsResponse._();

  factory GetTrendsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetTrendsResponse()..mergeFromBuffer(data, registry);
  factory GetTrendsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetTrendsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetTrendsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: GetTrendsResponse.$_createMessage)
    ..pPM<Trend>(1, _omitFieldNames ? '' : 'trends',
        subBuilder: Trend.$_createMessage)
    ..aOM<$2.Timestamp>(2, _omitFieldNames ? '' : 'computedAt',
        subBuilder: $2.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetTrendsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetTrendsResponse copyWith(void Function(GetTrendsResponse) updates) =>
      super.copyWith((message) => updates(message as GetTrendsResponse))
          as GetTrendsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetTrendsResponse() / GetTrendsResponse.new instead')
  static GetTrendsResponse create() => GetTrendsResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetTrendsResponse._();
  @$core.override
  GetTrendsResponse createEmptyInstance() => GetTrendsResponse._();
  @$core.pragma('dart2js:noInline')
  static GetTrendsResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetTrendsResponse>(
          GetTrendsResponse.$_createMessage);
  static GetTrendsResponse? _defaultInstance;

  /// Best first; at most limit.
  @$pb.TagNumber(1)
  $pb.PbList<Trend> get trends => $_getList(0);

  /// When the list was computed. Unset when there is no list yet.
  @$pb.TagNumber(2)
  $2.Timestamp get computedAt => $_getN(1);
  @$pb.TagNumber(2)
  set computedAt($2.Timestamp value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasComputedAt() => $_has(1);
  @$pb.TagNumber(2)
  void clearComputedAt() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.Timestamp ensureComputedAt() => $_ensure(1);
}

class SearchServiceApi {
  final $pb.RpcClient _client;

  SearchServiceApi(this._client);

  /// People whose handle starts with the query (ADR-0028 D2), in handle order. At most limit rows (0 => 10, max 20)
  /// and NO PAGINATION: there is no page token, by design (handle enumeration costs one call per 20 handles).
  /// Rows: accounts that are not ACTIVE and accounts that block the caller are left out (the answer is then the same
  /// as for a handle nobody has); accounts the caller blocks or mutes stay, with relationship.blocking / muting set.
  /// Protected accounts are listed, with user.is_private set. Each row carries the caller's relationship (follow
  /// state incl. REQUESTED, from the caller's graph, 0 extra reads); since is unset. The caller appears when matched.
  /// A caller whose blocked-by list overflowed (ADR-0008 D2) sees only accounts they follow and themselves.
  /// Staleness: matches are cached per instance for 60 s and shared across callers, so a new handle or a rename shows
  /// within 60 s; block and relationship filtering is per caller, from the 60 s graph snapshot.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_PEOPLE_PER_MIN 30/min/uid per instance (90/min at 3 instances);
  /// SEARCH_CALLS_PER_DAY 300 calls/uid/IST day per instance shared with SearchPosts (<= 900 at 3) => RATE_LIMITED,
  /// metadata["limit"] = "search_daily".
  /// Firestore: reads 7 cold at limit 5 / 22 at limit 20 (interceptor 1, caller graph 1, query <= limit, min 1),
  /// 0-2 warm (the prefix entry is cached); a grammar rejection or an unsupported query reads nothing beyond the
  /// interceptor. Writes 0.
  $async.Future<SearchPeopleResponse> searchPeople(
          $pb.ClientContext? ctx, SearchPeopleRequest request) =>
      _client.invoke<SearchPeopleResponse>(ctx, 'SearchService', 'SearchPeople',
          request, SearchPeopleResponse());

  /// Posts carrying one hashtag (ADR-0028 D3). The tab picks the order:
  /// - TOP (also UNSPECIFIED): the newest 30 tagged posts, those from the last 7 days ranked by likes + 2 x reposts +
  ///   2 x quotes + replies, ties newest first. One page of at most 20; next_page_token is always "" (show "See
  ///   latest").
  /// - LATEST: newest first, paged with next_page_token.
  /// - MEDIA: posts with their own images (a quote's embedded images do not count), newest first. Each older call scans
  ///   30 older tagged posts and returns the ones with images, so a page may be short or EMPTY while next_page_token is
  ///   non-empty: keep following it until it is "".
  /// Filtering (every tab, per caller): hidden posts (moderation) are dropped; posts by accounts the caller blocks,
  /// who block the caller, or whom the caller mutes are dropped, including a quote whose embedded author is one of
  /// them (ADR-0010 D6). Protected accounts (ADR-0025): a post by a protected account the caller is not and does not
  /// follow is dropped; a QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped. A
  /// caller whose blocked-by list overflowed sees only their own posts and posts by accounts they follow. A page may
  /// therefore be short: next_page_token follows the query, not the number of rows returned.
  /// Viewer flags (liked, reposted, bookmarked) follow FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS as on timelines.
  /// page_size 0 => 20, max 50 (clamped); TOP returns at most 20 whatever page_size says.
  /// page_token: opaque, sealed, bound to the caller, the tag and the tab, 24 h TTL. Expired, foreign, tampered, or
  /// sent with another query or tab => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", 0 reads: drop it
  /// and search again with no token.
  /// Staleness: the newest 30 posts per tag are cached per instance for 60 s and shared across callers (a new tagged
  /// post shows on Top, Latest page 1 and Media page 1 within 60 s); every filter above is applied per caller after the
  /// cache, so a takedown or a new block applies at once on that instance.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_POSTS_PER_MIN 20/min/uid per instance (60/min at 3 instances) and
  /// the shared "search_daily" cap (see SearchPeople).
  /// Firestore: TOP, LATEST first page and MEDIA first page (page_size <= 30): reads 33 cold (interceptor 1, caller
  /// graph 1, userLikes 1, the tag entry 30), 0-3 warm; LATEST first page at page_size 50: 53; LATEST older page 23 / 53
  /// at page_size 20 / 50; MEDIA older call 33 (scan cap 30). An unsupported query or a grammar rejection reads nothing
  /// beyond the interceptor. Writes 0.
  $async.Future<SearchPostsResponse> searchPosts(
          $pb.ClientContext? ctx, SearchPostsRequest request) =>
      _client.invoke<SearchPostsResponse>(
          ctx, 'SearchService', 'SearchPosts', request, SearchPostsResponse());

  /// Trending hashtags (ADR-0028 D6, founder defaults F1 and F6). A tag trends when at least TRENDS_MIN_AUTHORS (3)
  /// distinct accounts used it in the window; tags are ranked by distinct accounts, then posts, then tag. Hidden posts,
  /// reposts and posts by protected accounts are not counted; an operator denylist and the trends flag remove tags.
  /// The list is computed by a scheduled sweep (daily at Stage 0: "Trending today"); computed_at says when.
  /// limit 0 => 10, max 30 (clamped). prefix (optional; one leading '#' ignored; at most 50 code points after it; a control or
  /// bidi formatting character => VALIDATION "prefix") keeps only tags that start with it, in rank order, for typeahead
  /// hashtag suggestions at 0 extra reads. No list yet => an empty answer and computed_at unset.
  /// Staleness: the list is cached per instance for 10 min; a tag can be up to one sweep interval plus 10 min old.
  /// Flag: "trends". Rate limit: the 60/min/uid default bucket per instance (180/min at 3 instances).
  /// Firestore: reads 2 cold (interceptor 1, trends/current 1), 0-1 warm; at most one doc read per instance per 10 min
  /// (<= 432 a day at 3 instances, whatever the number of callers). Writes 0.
  $async.Future<GetTrendsResponse> getTrends(
          $pb.ClientContext? ctx, GetTrendsRequest request) =>
      _client.invoke<GetTrendsResponse>(
          ctx, 'SearchService', 'GetTrends', request, GetTrendsResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
