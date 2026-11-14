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

import '../../communities/v1/communities.pb.dart' as $4;
import '../../graph/v1/graph.pb.dart' as $0;
import '../../lists/v1/lists.pb.dart' as $3;
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
    $core.bool? fromFollowing,
  }) {
    final result = SearchPostsRequest._();
    if (query != null) result.query = query;
    if (tab != null) result.tab = tab;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (fromFollowing != null) result.fromFollowing = fromFollowing;
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
    ..aOB(5, _omitFieldNames ? '' : 'fromFollowing')
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

  /// "People you follow" (F22): keep only posts whose row author the caller follows (a REPOST row counts for the
  /// account that reposted). The caller's own posts are left out. Needs FEATURE_SEARCH_FILTERS (see the file comment).
  /// The following set is the caller's 60 s graph snapshot (at most 5,000 accounts). Every other filter still applies.
  /// Recall limit: TOP filters its one 30-post entry. LATEST and MEDIA scan at most 3 of the tab's query windows per
  /// call, stopping once page_size rows are kept, so a page may be SHORT or EMPTY while next_page_token is non-empty:
  /// keep following it. A page token is bound to this value too: a token from a call with the other value =>
  /// VALIDATION "page_token".
  @$pb.TagNumber(5)
  $core.bool get fromFollowing => $_getBF(4);
  @$pb.TagNumber(5)
  set fromFollowing($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasFromFollowing() => $_has(4);
  @$pb.TagNumber(5)
  void clearFromFollowing() => $_clearField(5);
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

  /// 1-based rank in the whole served list (denylisted and hidden tags are already removed, so a removal leaves no gap);
  /// with a prefix the ranks keep their gaps.
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

class SearchListsRequest extends $pb.GeneratedMessage {
  factory SearchListsRequest({
    $core.String? query,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = SearchListsRequest._();
    if (query != null) result.query = query;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  SearchListsRequest._();

  factory SearchListsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchListsRequest()..mergeFromBuffer(data, registry);
  factory SearchListsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchListsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchListsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchListsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'query')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchListsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchListsRequest copyWith(void Function(SearchListsRequest) updates) =>
      super.copyWith((message) => updates(message as SearchListsRequest))
          as SearchListsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SearchListsRequest() / SearchListsRequest.new instead')
  static SearchListsRequest create() => SearchListsRequest._();
  static $pb.GeneratedMessage $_createMessage() => SearchListsRequest._();
  @$core.override
  SearchListsRequest createEmptyInstance() => SearchListsRequest._();
  @$core.pragma('dart2js:noInline')
  static SearchListsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchListsRequest>(
          SearchListsRequest.$_createMessage);
  static SearchListsRequest? _defaultInstance;

  /// A name prefix (rules on SearchLists).
  @$pb.TagNumber(1)
  $core.String get query => $_getSZ(0);
  @$pb.TagNumber(1)
  set query($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearQuery() => $_clearField(1);

  /// 0 => 20; max 20 (clamped); negative => VALIDATION "page_size".
  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);

  /// next_page_token of the previous page for the same query.
  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);
}

class SearchListsResponse extends $pb.GeneratedMessage {
  factory SearchListsResponse({
    $core.Iterable<$3.ListInfo>? lists,
    $core.String? nextPageToken,
  }) {
    final result = SearchListsResponse._();
    if (lists != null) result.lists.addAll(lists);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  SearchListsResponse._();

  factory SearchListsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchListsResponse()..mergeFromBuffer(data, registry);
  factory SearchListsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchListsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchListsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchListsResponse.$_createMessage)
    ..pPM<$3.ListInfo>(1, _omitFieldNames ? '' : 'lists',
        subBuilder: $3.ListInfo.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchListsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchListsResponse copyWith(void Function(SearchListsResponse) updates) =>
      super.copyWith((message) => updates(message as SearchListsResponse))
          as SearchListsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SearchListsResponse() / SearchListsResponse.new instead')
  static SearchListsResponse create() => SearchListsResponse._();
  static $pb.GeneratedMessage $_createMessage() => SearchListsResponse._();
  @$core.override
  SearchListsResponse createEmptyInstance() => SearchListsResponse._();
  @$core.pragma('dart2js:noInline')
  static SearchListsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchListsResponse>(
          SearchListsResponse.$_createMessage);
  static SearchListsResponse? _defaultInstance;

  /// Folded-name order; at most page_size; may be short while next_page_token is set.
  @$pb.TagNumber(1)
  $pb.PbList<$3.ListInfo> get lists => $_getList(0);

  /// "" => no more.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class SearchCommunitiesRequest extends $pb.GeneratedMessage {
  factory SearchCommunitiesRequest({
    $core.String? query,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = SearchCommunitiesRequest._();
    if (query != null) result.query = query;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  SearchCommunitiesRequest._();

  factory SearchCommunitiesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchCommunitiesRequest()..mergeFromBuffer(data, registry);
  factory SearchCommunitiesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchCommunitiesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchCommunitiesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchCommunitiesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'query')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchCommunitiesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchCommunitiesRequest copyWith(
          void Function(SearchCommunitiesRequest) updates) =>
      super.copyWith((message) => updates(message as SearchCommunitiesRequest))
          as SearchCommunitiesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SearchCommunitiesRequest() / SearchCommunitiesRequest.new instead')
  static SearchCommunitiesRequest create() => SearchCommunitiesRequest._();
  static $pb.GeneratedMessage $_createMessage() => SearchCommunitiesRequest._();
  @$core.override
  SearchCommunitiesRequest createEmptyInstance() =>
      SearchCommunitiesRequest._();
  @$core.pragma('dart2js:noInline')
  static SearchCommunitiesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchCommunitiesRequest>(
          SearchCommunitiesRequest.$_createMessage);
  static SearchCommunitiesRequest? _defaultInstance;

  /// A name prefix (rules on SearchLists).
  @$pb.TagNumber(1)
  $core.String get query => $_getSZ(0);
  @$pb.TagNumber(1)
  set query($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasQuery() => $_has(0);
  @$pb.TagNumber(1)
  void clearQuery() => $_clearField(1);

  /// 0 => 20; max 20 (clamped); negative => VALIDATION "page_size".
  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);

  /// next_page_token of the previous page for the same query.
  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);
}

class SearchCommunitiesResponse extends $pb.GeneratedMessage {
  factory SearchCommunitiesResponse({
    $core.Iterable<$4.Community>? communities,
    $core.String? nextPageToken,
  }) {
    final result = SearchCommunitiesResponse._();
    if (communities != null) result.communities.addAll(communities);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  SearchCommunitiesResponse._();

  factory SearchCommunitiesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchCommunitiesResponse()..mergeFromBuffer(data, registry);
  factory SearchCommunitiesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SearchCommunitiesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SearchCommunitiesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.search.v1'),
      createEmptyInstance: SearchCommunitiesResponse.$_createMessage)
    ..pPM<$4.Community>(1, _omitFieldNames ? '' : 'communities',
        subBuilder: $4.Community.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchCommunitiesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SearchCommunitiesResponse copyWith(
          void Function(SearchCommunitiesResponse) updates) =>
      super.copyWith((message) => updates(message as SearchCommunitiesResponse))
          as SearchCommunitiesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SearchCommunitiesResponse() / SearchCommunitiesResponse.new instead')
  static SearchCommunitiesResponse create() => SearchCommunitiesResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      SearchCommunitiesResponse._();
  @$core.override
  SearchCommunitiesResponse createEmptyInstance() =>
      SearchCommunitiesResponse._();
  @$core.pragma('dart2js:noInline')
  static SearchCommunitiesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SearchCommunitiesResponse>(
          SearchCommunitiesResponse.$_createMessage);
  static SearchCommunitiesResponse? _defaultInstance;

  /// Folded-name order; at most page_size. Each row is the light header with the caller's viewer_role.
  @$pb.TagNumber(1)
  $pb.PbList<$4.Community> get communities => $_getList(0);

  /// "" => no more.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class SearchServiceApi {
  final $pb.RpcClient _client;

  SearchServiceApi(this._client);

  /// People whose handle starts with the query, in handle order. At most limit rows (0 => 10, max 20)
  /// and NO PAGINATION: there is no page token, by design (handle enumeration costs one call per 20 handles).
  /// Rows: accounts that are not ACTIVE and accounts that block the caller are left out (the answer is then the same
  /// as for a handle nobody has); accounts the caller blocks or mutes stay, with relationship.blocking / muting set.
  /// Protected accounts are listed, with user.is_private set. Each row carries the caller's relationship (follow
  /// state incl. REQUESTED, from the caller's graph); since is unset. The caller appears when matched.
  /// A caller whose blocked-by list overflowed sees only accounts they follow and themselves.
  /// Staleness: matches are cached per instance for 60 s and shared across callers, so a new handle or a rename shows
  /// within 60 s; block and relationship filtering is per caller, from the 60 s graph snapshot.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_PEOPLE_PER_MIN 30/min/uid per instance (90/min at 3 instances);
  /// SEARCH_PEOPLE_CALLS_PER_DAY calls/uid/IST day per instance (SearchPeople only) => RATE_LIMITED,
  /// metadata["limit"] = "search_people_daily".
  /// The prefix entry is cached. A grammar rejection or an unsupported query does no lookup. Writes nothing.
  $async.Future<SearchPeopleResponse> searchPeople(
          $pb.ClientContext? ctx, SearchPeopleRequest request) =>
      _client.invoke<SearchPeopleResponse>(ctx, 'SearchService', 'SearchPeople',
          request, SearchPeopleResponse());

  /// Posts carrying one hashtag. The tab picks the order:
  /// - TOP (also UNSPECIFIED): the newest 30 tagged posts, those from the last 7 days ranked by likes + 2 x reposts +
  ///   2 x quotes + replies, ties newest first. One page of at most 20; next_page_token is always "" (show "See
  ///   latest").
  /// - LATEST: newest first, paged with next_page_token. The query windows are fixed tiers, independent of page_size
  ///   (page 1: the 30-post entry, or 50 rows at page_size 31..50; an older page: 20 rows at page_size <= 20, else 50).
  ///   A window is filtered whole and then cut to page_size, so a page can be SHORT while next_page_token is non-empty.
  ///   A window that came back not full is the end of the tag; its token (only when the page was cut) is a tail token and
  ///   the next call reads the whole rest of the tag. The token position is the last returned row when the page was cut,
  ///   else the last row of the window.
  /// - MEDIA: posts with their own images (a quote's embedded images do not count), newest first. Each older call scans
  ///   30 older tagged posts and returns the ones with images, so a page may be short or EMPTY while next_page_token is
  ///   non-empty: keep following it until it is "".
  /// Filtering (every tab, per caller): hidden posts (moderation) are dropped; posts by accounts the caller blocks,
  /// who block the caller, or whom the caller mutes are dropped, including a quote whose embedded author is one of
  /// them. Protected accounts: a post by a protected account the caller is not and does not
  /// follow is dropped; a QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped. A
  /// caller whose blocked-by list overflowed sees only their own posts and posts by accounts they follow. A page may
  /// therefore be short. Whether next_page_token is set and how many rows come back depend only on the posts the caller
  /// can see and on whether the query window was full, never on how many were dropped (LATEST; MEDIA scans a fixed 30).
  /// Viewer flags (liked, reposted, bookmarked) follow FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS as on timelines.
  /// page_size 0 => 20, max 50 (clamped); TOP returns at most 20 whatever page_size says.
  /// page_token: opaque, sealed, bound to the caller, the tag and the tab, 24 h TTL. Expired, foreign, tampered, or
  /// sent with another query or tab => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", before any lookup: drop it
  /// and search again with no token.
  /// Staleness: the newest 30 posts per tag are cached per instance for 60 s and shared across callers (a new tagged
  /// post shows on Top, Latest page 1 and Media page 1 within 60 s); every filter above is applied per caller after the
  /// cache, so a takedown or a new block applies at once on that instance.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_POSTS_PER_MIN 20/min/uid per instance (60/min at 3 instances); no daily cap.
  /// LATEST pages use fixed windows of 20 rows (page_size <= 20) or 50 (21..50); MEDIA scans at most 30 rows. An
  /// unsupported query or a grammar rejection does no lookup. Writes nothing.
  $async.Future<SearchPostsResponse> searchPosts(
          $pb.ClientContext? ctx, SearchPostsRequest request) =>
      _client.invoke<SearchPostsResponse>(
          ctx, 'SearchService', 'SearchPosts', request, SearchPostsResponse());

  /// Trending hashtags (founder defaults F1 and F6). A tag trends when at least TRENDS_MIN_AUTHORS (3; 5 in prod)
  /// distinct established accounts (ACTIVE, at least TRENDS_MIN_ACCOUNT_AGE = 72 h old; at most TRENDS_MAX_AUTHOR_CHECKS = 500
  /// authors are checked per sweep, the rest are not counted) used it in the window; tags are ranked by distinct
  /// established accounts, then their posts, then tag. Hidden posts,
  /// reposts and posts by protected accounts are not counted; tags on the operator denylist (TRENDS_DENYLIST) or the
  /// operator hide list (opsctl trends hide) and the trends flag remove tags. Tags are matched by a folded key (NFKC,
  /// lower-case, U+200C, U+200D and '_' removed), so a spelling variant of a removed tag goes with it.
  /// The list is computed by a scheduled sweep (daily at Stage 0: "Trending today"); computed_at says when.
  /// limit 0 => 10, max 30 (clamped). prefix (optional; one leading '#' ignored; at most 50 code points after it; a control or
  /// bidi formatting character => VALIDATION "prefix") keeps only tags that start with it, in rank order, for typeahead
  /// hashtag suggestions without an extra lookup. No list yet => an empty answer and computed_at unset.
  /// Staleness: the list is cached per instance for 10 min; a tag can be up to one sweep interval plus 10 min old. A tag
  /// hidden by an operator leaves every server within 10 min (the client copy lives 5 more).
  /// Flag: "trends". Rate limit: the 60/min/uid default bucket per instance (180/min at 3 instances); no daily cap.
  /// The list is loaded at most once per instance per 10 min, whatever the number of callers. Writes nothing.
  $async.Future<GetTrendsResponse> getTrends(
          $pb.ClientContext? ctx, GetTrendsRequest request) =>
      _client.invoke<GetTrendsResponse>(
          ctx, 'SearchService', 'GetTrends', request, GetTrendsResponse());

  /// Public lists whose folded name starts with the folded query (F20), in folded-name order, then list id.
  /// query: NFC, trimmed, lower-cased; 1 to 30 code points after that, no control or bidi formatting character, else
  /// VALIDATION "query" before any lookup. No sigil is stripped.
  /// Rows: public lists only (a private list is never read: the query has isPrivate == false). Then the GetList rules for
  /// the caller drop a list hidden by an operator, a list whose owner is not ACTIVE, a list whose owner blocks the caller
  /// or that the caller blocks, a protected owner's list the caller does not follow, an owner past the blockedBy cap, and
  /// the caller's own lists (they are on the Lists tab), exactly as DiscoverLists does. A dropped row is never
  /// replaced, so a page may be SHORT or EMPTY while next_page_token is non-empty: keep following it until it is "".
  /// follower_count and followed_by_viewer are set only when FEATURE_LIST_FOLLOWS is on for the caller (as on GetList).
  /// page_size 0 => 20, max 20 (clamped); negative => VALIDATION "page_size". page_token: opaque, sealed, bound to the
  /// caller and the folded query, 24 h TTL; expired, foreign, tampered or sent with another query => VALIDATION
  /// "page_token", before any lookup.
  /// Staleness: the query reads Firestore on every call; the per-row rules use the 60 s caches GetList uses.
  /// Flags: "search", "search_lists", "lists". Rate limit: RATE_LIMIT_SEARCH_DIRECTORY_PER_MIN 20/min/uid per instance,
  /// shared with SearchCommunities; no daily cap. Cost: one query of at most page_size documents, then per row the
  /// owner's profile and graph (cache-first) and one batched follow-marker read when list_follows is on. Writes nothing.
  $async.Future<SearchListsResponse> searchLists(
          $pb.ClientContext? ctx, SearchListsRequest request) =>
      _client.invoke<SearchListsResponse>(
          ctx, 'SearchService', 'SearchLists', request, SearchListsResponse());

  /// ACTIVE communities whose folded name starts with the folded query (F21), in folded-name order, then community id.
  /// query: the SearchLists rules. A SUSPENDED (taken offline by an operator) or ARCHIVED community is never returned (the
  /// query has status == ACTIVE, the directory rule). As in ListCommunities there is no block filtering (D7); viewer_role
  /// is the caller's role (memberships cached 60 s). page_size and page_token: the SearchLists rules (the token is bound
  /// to this RPC). A page is short only at the end.
  /// Flags: "search", "search_lists", "communities". Rate limit: the SearchLists bucket. Cost: one query of at most
  /// page_size documents and the caller's memberships (cached 60 s). Writes nothing.
  $async.Future<SearchCommunitiesResponse> searchCommunities(
          $pb.ClientContext? ctx, SearchCommunitiesRequest request) =>
      _client.invoke<SearchCommunitiesResponse>(ctx, 'SearchService',
          'SearchCommunities', request, SearchCommunitiesResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
