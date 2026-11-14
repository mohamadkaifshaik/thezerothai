// This is a generated file - do not edit.
//
// Generated from dzeroth/articles/v1/articles.proto.

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
    as $0;

import '../../common/v1/common.pb.dart' as $1;
import '../../posts/v1/posts.pb.dart' as $2;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class Article extends $pb.GeneratedMessage {
  factory Article({
    $core.String? articleId,
    $core.String? authorId,
    $fixnum.Int64? revision,
    $core.String? title,
    $core.String? bodyJson,
    $core.String? coverMediaId,
    $core.String? postId,
    $0.Timestamp? updatedAt,
    $core.String? coverUrl,
    $core.bool? publicationPending,
    $core.String? publicationCaption,
    $2.ReplyPolicy? publicationReplyPolicy,
    $core.String? excerpt,
    $core.Iterable<$1.MediaRef>? images,
  }) {
    final result = Article._();
    if (articleId != null) result.articleId = articleId;
    if (authorId != null) result.authorId = authorId;
    if (revision != null) result.revision = revision;
    if (title != null) result.title = title;
    if (bodyJson != null) result.bodyJson = bodyJson;
    if (coverMediaId != null) result.coverMediaId = coverMediaId;
    if (postId != null) result.postId = postId;
    if (updatedAt != null) result.updatedAt = updatedAt;
    if (coverUrl != null) result.coverUrl = coverUrl;
    if (publicationPending != null)
      result.publicationPending = publicationPending;
    if (publicationCaption != null)
      result.publicationCaption = publicationCaption;
    if (publicationReplyPolicy != null)
      result.publicationReplyPolicy = publicationReplyPolicy;
    if (excerpt != null) result.excerpt = excerpt;
    if (images != null) result.images.addAll(images);
    return result;
  }

  Article._();

  factory Article.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Article()..mergeFromBuffer(data, registry);
  factory Article.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Article()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Article',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: Article.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'articleId')
    ..aOS(2, _omitFieldNames ? '' : 'authorId')
    ..aInt64(3, _omitFieldNames ? '' : 'revision')
    ..aOS(4, _omitFieldNames ? '' : 'title')
    ..aOS(5, _omitFieldNames ? '' : 'bodyJson')
    ..aOS(6, _omitFieldNames ? '' : 'coverMediaId')
    ..aOS(7, _omitFieldNames ? '' : 'postId')
    ..aOM<$0.Timestamp>(8, _omitFieldNames ? '' : 'updatedAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOS(9, _omitFieldNames ? '' : 'coverUrl')
    ..aOB(10, _omitFieldNames ? '' : 'publicationPending')
    ..aOS(11, _omitFieldNames ? '' : 'publicationCaption')
    ..aE<$2.ReplyPolicy>(12, _omitFieldNames ? '' : 'publicationReplyPolicy',
        enumValues: $2.ReplyPolicy.values)
    ..aOS(13, _omitFieldNames ? '' : 'excerpt')
    ..pPM<$1.MediaRef>(14, _omitFieldNames ? '' : 'images',
        subBuilder: $1.MediaRef.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Article clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Article copyWith(void Function(Article) updates) =>
      super.copyWith((message) => updates(message as Article)) as Article;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Article() / Article.new instead')
  static Article create() => Article._();
  static $pb.GeneratedMessage $_createMessage() => Article._();
  @$core.override
  Article createEmptyInstance() => Article._();
  @$core.pragma('dart2js:noInline')
  static Article getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Article>(Article.$_createMessage);
  static Article? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get articleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set articleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasArticleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get authorId => $_getSZ(1);
  @$pb.TagNumber(2)
  set authorId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAuthorId() => $_has(1);
  @$pb.TagNumber(2)
  void clearAuthorId() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get revision => $_getI64(2);
  @$pb.TagNumber(3)
  set revision($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRevision() => $_has(2);
  @$pb.TagNumber(3)
  void clearRevision() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get title => $_getSZ(3);
  @$pb.TagNumber(4)
  set title($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTitle() => $_has(3);
  @$pb.TagNumber(4)
  void clearTitle() => $_clearField(4);

  /// JSON array of validated structured blocks; never HTML. Empty in ListArticles responses: open an article
  /// with GetArticle to read its body.
  @$pb.TagNumber(5)
  $core.String get bodyJson => $_getSZ(4);
  @$pb.TagNumber(5)
  set bodyJson($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasBodyJson() => $_has(4);
  @$pb.TagNumber(5)
  void clearBodyJson() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get coverMediaId => $_getSZ(5);
  @$pb.TagNumber(6)
  set coverMediaId($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasCoverMediaId() => $_has(5);
  @$pb.TagNumber(6)
  void clearCoverMediaId() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get postId => $_getSZ(6);
  @$pb.TagNumber(7)
  set postId($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasPostId() => $_has(6);
  @$pb.TagNumber(7)
  void clearPostId() => $_clearField(7);

  @$pb.TagNumber(8)
  $0.Timestamp get updatedAt => $_getN(7);
  @$pb.TagNumber(8)
  set updatedAt($0.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasUpdatedAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearUpdatedAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $0.Timestamp ensureUpdatedAt() => $_ensure(7);

  @$pb.TagNumber(9)
  $core.String get coverUrl => $_getSZ(8);
  @$pb.TagNumber(9)
  set coverUrl($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasCoverUrl() => $_has(8);
  @$pb.TagNumber(9)
  void clearCoverUrl() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.bool get publicationPending => $_getBF(9);
  @$pb.TagNumber(10)
  set publicationPending($core.bool value) => $_setBool(9, value);
  @$pb.TagNumber(10)
  $core.bool hasPublicationPending() => $_has(9);
  @$pb.TagNumber(10)
  void clearPublicationPending() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.String get publicationCaption => $_getSZ(10);
  @$pb.TagNumber(11)
  set publicationCaption($core.String value) => $_setString(10, value);
  @$pb.TagNumber(11)
  $core.bool hasPublicationCaption() => $_has(10);
  @$pb.TagNumber(11)
  void clearPublicationCaption() => $_clearField(11);

  @$pb.TagNumber(12)
  $2.ReplyPolicy get publicationReplyPolicy => $_getN(11);
  @$pb.TagNumber(12)
  set publicationReplyPolicy($2.ReplyPolicy value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasPublicationReplyPolicy() => $_has(11);
  @$pb.TagNumber(12)
  void clearPublicationReplyPolicy() => $_clearField(12);

  /// Plain-text excerpt of the body (whitespace collapsed, at most 280 Unicode code points), computed by the
  /// server on read. Set on every response, including ListArticles where body_json is empty. Never HTML.
  @$pb.TagNumber(13)
  $core.String get excerpt => $_getSZ(12);
  @$pb.TagNumber(13)
  set excerpt($core.String value) => $_setString(12, value);
  @$pb.TagNumber(13)
  $core.bool hasExcerpt() => $_has(12);
  @$pb.TagNumber(13)
  void clearExcerpt() => $_clearField(13);

  /// Inline image blocks of body_json, resolved on read (GetArticle and PublishArticle; empty elsewhere). One entry per
  /// image the reader can show: a block whose media was deleted, withheld or is not usable is simply absent, and the
  /// client shows a placeholder for it. Match an entry to its block by media_id. The alt text and caption stay in
  /// body_json. Never sent by SaveArticle; the server ignores it on input.
  @$pb.TagNumber(14)
  $pb.PbList<$1.MediaRef> get images => $_getList(13);
}

class GetArticleRequest extends $pb.GeneratedMessage {
  factory GetArticleRequest({
    $core.String? articleId,
  }) {
    final result = GetArticleRequest._();
    if (articleId != null) result.articleId = articleId;
    return result;
  }

  GetArticleRequest._();

  factory GetArticleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetArticleRequest()..mergeFromBuffer(data, registry);
  factory GetArticleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetArticleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetArticleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: GetArticleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'articleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetArticleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetArticleRequest copyWith(void Function(GetArticleRequest) updates) =>
      super.copyWith((message) => updates(message as GetArticleRequest))
          as GetArticleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetArticleRequest() / GetArticleRequest.new instead')
  static GetArticleRequest create() => GetArticleRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetArticleRequest._();
  @$core.override
  GetArticleRequest createEmptyInstance() => GetArticleRequest._();
  @$core.pragma('dart2js:noInline')
  static GetArticleRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetArticleRequest>(
          GetArticleRequest.$_createMessage);
  static GetArticleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get articleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set articleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasArticleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticleId() => $_clearField(1);
}

class GetArticleResponse extends $pb.GeneratedMessage {
  factory GetArticleResponse({
    Article? article,
    $2.PostView? post,
  }) {
    final result = GetArticleResponse._();
    if (article != null) result.article = article;
    if (post != null) result.post = post;
    return result;
  }

  GetArticleResponse._();

  factory GetArticleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetArticleResponse()..mergeFromBuffer(data, registry);
  factory GetArticleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetArticleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetArticleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: GetArticleResponse.$_createMessage)
    ..aOM<Article>(1, _omitFieldNames ? '' : 'article',
        subBuilder: Article.$_createMessage)
    ..aOM<$2.PostView>(2, _omitFieldNames ? '' : 'post',
        subBuilder: $2.PostView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetArticleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetArticleResponse copyWith(void Function(GetArticleResponse) updates) =>
      super.copyWith((message) => updates(message as GetArticleResponse))
          as GetArticleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetArticleResponse() / GetArticleResponse.new instead')
  static GetArticleResponse create() => GetArticleResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetArticleResponse._();
  @$core.override
  GetArticleResponse createEmptyInstance() => GetArticleResponse._();
  @$core.pragma('dart2js:noInline')
  static GetArticleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetArticleResponse>(
          GetArticleResponse.$_createMessage);
  static GetArticleResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Article get article => $_getN(0);
  @$pb.TagNumber(1)
  set article(Article value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasArticle() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticle() => $_clearField(1);
  @$pb.TagNumber(1)
  Article ensureArticle() => $_ensure(0);

  @$pb.TagNumber(2)
  $2.PostView get post => $_getN(1);
  @$pb.TagNumber(2)
  set post($2.PostView value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPost() => $_has(1);
  @$pb.TagNumber(2)
  void clearPost() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.PostView ensurePost() => $_ensure(1);
}

class ListArticlesRequest extends $pb.GeneratedMessage {
  factory ListArticlesRequest({
    $core.bool? published,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListArticlesRequest._();
    if (published != null) result.published = published;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListArticlesRequest._();

  factory ListArticlesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListArticlesRequest()..mergeFromBuffer(data, registry);
  factory ListArticlesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListArticlesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListArticlesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: ListArticlesRequest.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'published')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListArticlesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListArticlesRequest copyWith(void Function(ListArticlesRequest) updates) =>
      super.copyWith((message) => updates(message as ListArticlesRequest))
          as ListArticlesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use ListArticlesRequest() / ListArticlesRequest.new instead')
  static ListArticlesRequest create() => ListArticlesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListArticlesRequest._();
  @$core.override
  ListArticlesRequest createEmptyInstance() => ListArticlesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListArticlesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListArticlesRequest>(
          ListArticlesRequest.$_createMessage);
  static ListArticlesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get published => $_getBF(0);
  @$pb.TagNumber(1)
  set published($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPublished() => $_has(0);
  @$pb.TagNumber(1)
  void clearPublished() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);
}

class ListArticlesResponse extends $pb.GeneratedMessage {
  factory ListArticlesResponse({
    $core.Iterable<Article>? articles,
    $core.String? nextPageToken,
  }) {
    final result = ListArticlesResponse._();
    if (articles != null) result.articles.addAll(articles);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListArticlesResponse._();

  factory ListArticlesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListArticlesResponse()..mergeFromBuffer(data, registry);
  factory ListArticlesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListArticlesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListArticlesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: ListArticlesResponse.$_createMessage)
    ..pPM<Article>(1, _omitFieldNames ? '' : 'articles',
        subBuilder: Article.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListArticlesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListArticlesResponse copyWith(void Function(ListArticlesResponse) updates) =>
      super.copyWith((message) => updates(message as ListArticlesResponse))
          as ListArticlesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListArticlesResponse() / ListArticlesResponse.new instead')
  static ListArticlesResponse create() => ListArticlesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListArticlesResponse._();
  @$core.override
  ListArticlesResponse createEmptyInstance() => ListArticlesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListArticlesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListArticlesResponse>(
          ListArticlesResponse.$_createMessage);
  static ListArticlesResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Article> get articles => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class SaveArticleRequest extends $pb.GeneratedMessage {
  factory SaveArticleRequest({
    Article? article,
    $fixnum.Int64? expectedRevision,
  }) {
    final result = SaveArticleRequest._();
    if (article != null) result.article = article;
    if (expectedRevision != null) result.expectedRevision = expectedRevision;
    return result;
  }

  SaveArticleRequest._();

  factory SaveArticleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SaveArticleRequest()..mergeFromBuffer(data, registry);
  factory SaveArticleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SaveArticleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SaveArticleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: SaveArticleRequest.$_createMessage)
    ..aOM<Article>(1, _omitFieldNames ? '' : 'article',
        subBuilder: Article.$_createMessage)
    ..aInt64(2, _omitFieldNames ? '' : 'expectedRevision')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SaveArticleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SaveArticleRequest copyWith(void Function(SaveArticleRequest) updates) =>
      super.copyWith((message) => updates(message as SaveArticleRequest))
          as SaveArticleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SaveArticleRequest() / SaveArticleRequest.new instead')
  static SaveArticleRequest create() => SaveArticleRequest._();
  static $pb.GeneratedMessage $_createMessage() => SaveArticleRequest._();
  @$core.override
  SaveArticleRequest createEmptyInstance() => SaveArticleRequest._();
  @$core.pragma('dart2js:noInline')
  static SaveArticleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SaveArticleRequest>(
          SaveArticleRequest.$_createMessage);
  static SaveArticleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Article get article => $_getN(0);
  @$pb.TagNumber(1)
  set article(Article value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasArticle() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticle() => $_clearField(1);
  @$pb.TagNumber(1)
  Article ensureArticle() => $_ensure(0);

  @$pb.TagNumber(2)
  $fixnum.Int64 get expectedRevision => $_getI64(1);
  @$pb.TagNumber(2)
  set expectedRevision($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExpectedRevision() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpectedRevision() => $_clearField(2);
}

class SaveArticleResponse extends $pb.GeneratedMessage {
  factory SaveArticleResponse({
    Article? article,
  }) {
    final result = SaveArticleResponse._();
    if (article != null) result.article = article;
    return result;
  }

  SaveArticleResponse._();

  factory SaveArticleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SaveArticleResponse()..mergeFromBuffer(data, registry);
  factory SaveArticleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SaveArticleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SaveArticleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: SaveArticleResponse.$_createMessage)
    ..aOM<Article>(1, _omitFieldNames ? '' : 'article',
        subBuilder: Article.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SaveArticleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SaveArticleResponse copyWith(void Function(SaveArticleResponse) updates) =>
      super.copyWith((message) => updates(message as SaveArticleResponse))
          as SaveArticleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SaveArticleResponse() / SaveArticleResponse.new instead')
  static SaveArticleResponse create() => SaveArticleResponse._();
  static $pb.GeneratedMessage $_createMessage() => SaveArticleResponse._();
  @$core.override
  SaveArticleResponse createEmptyInstance() => SaveArticleResponse._();
  @$core.pragma('dart2js:noInline')
  static SaveArticleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SaveArticleResponse>(
          SaveArticleResponse.$_createMessage);
  static SaveArticleResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Article get article => $_getN(0);
  @$pb.TagNumber(1)
  set article(Article value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasArticle() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticle() => $_clearField(1);
  @$pb.TagNumber(1)
  Article ensureArticle() => $_ensure(0);
}

class DeleteArticleRequest extends $pb.GeneratedMessage {
  factory DeleteArticleRequest({
    $core.String? articleId,
    $fixnum.Int64? expectedRevision,
  }) {
    final result = DeleteArticleRequest._();
    if (articleId != null) result.articleId = articleId;
    if (expectedRevision != null) result.expectedRevision = expectedRevision;
    return result;
  }

  DeleteArticleRequest._();

  factory DeleteArticleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteArticleRequest()..mergeFromBuffer(data, registry);
  factory DeleteArticleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteArticleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteArticleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: DeleteArticleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'articleId')
    ..aInt64(2, _omitFieldNames ? '' : 'expectedRevision')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteArticleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteArticleRequest copyWith(void Function(DeleteArticleRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteArticleRequest))
          as DeleteArticleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteArticleRequest() / DeleteArticleRequest.new instead')
  static DeleteArticleRequest create() => DeleteArticleRequest._();
  static $pb.GeneratedMessage $_createMessage() => DeleteArticleRequest._();
  @$core.override
  DeleteArticleRequest createEmptyInstance() => DeleteArticleRequest._();
  @$core.pragma('dart2js:noInline')
  static DeleteArticleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteArticleRequest>(
          DeleteArticleRequest.$_createMessage);
  static DeleteArticleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get articleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set articleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasArticleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get expectedRevision => $_getI64(1);
  @$pb.TagNumber(2)
  set expectedRevision($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExpectedRevision() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpectedRevision() => $_clearField(2);
}

class DeleteArticleResponse extends $pb.GeneratedMessage {
  factory DeleteArticleResponse() => DeleteArticleResponse._();

  DeleteArticleResponse._();

  factory DeleteArticleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteArticleResponse()..mergeFromBuffer(data, registry);
  factory DeleteArticleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteArticleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteArticleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: DeleteArticleResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteArticleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteArticleResponse copyWith(
          void Function(DeleteArticleResponse) updates) =>
      super.copyWith((message) => updates(message as DeleteArticleResponse))
          as DeleteArticleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteArticleResponse() / DeleteArticleResponse.new instead')
  static DeleteArticleResponse create() => DeleteArticleResponse._();
  static $pb.GeneratedMessage $_createMessage() => DeleteArticleResponse._();
  @$core.override
  DeleteArticleResponse createEmptyInstance() => DeleteArticleResponse._();
  @$core.pragma('dart2js:noInline')
  static DeleteArticleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteArticleResponse>(
          DeleteArticleResponse.$_createMessage);
  static DeleteArticleResponse? _defaultInstance;
}

class PublishArticleRequest extends $pb.GeneratedMessage {
  factory PublishArticleRequest({
    $core.String? articleId,
    $fixnum.Int64? expectedRevision,
    $core.String? idempotencyKey,
    $core.String? caption,
    $2.ReplyPolicy? replyPolicy,
  }) {
    final result = PublishArticleRequest._();
    if (articleId != null) result.articleId = articleId;
    if (expectedRevision != null) result.expectedRevision = expectedRevision;
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (caption != null) result.caption = caption;
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    return result;
  }

  PublishArticleRequest._();

  factory PublishArticleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishArticleRequest()..mergeFromBuffer(data, registry);
  factory PublishArticleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishArticleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PublishArticleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: PublishArticleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'articleId')
    ..aInt64(2, _omitFieldNames ? '' : 'expectedRevision')
    ..aOS(3, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(4, _omitFieldNames ? '' : 'caption')
    ..aE<$2.ReplyPolicy>(5, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: $2.ReplyPolicy.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishArticleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishArticleRequest copyWith(
          void Function(PublishArticleRequest) updates) =>
      super.copyWith((message) => updates(message as PublishArticleRequest))
          as PublishArticleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use PublishArticleRequest() / PublishArticleRequest.new instead')
  static PublishArticleRequest create() => PublishArticleRequest._();
  static $pb.GeneratedMessage $_createMessage() => PublishArticleRequest._();
  @$core.override
  PublishArticleRequest createEmptyInstance() => PublishArticleRequest._();
  @$core.pragma('dart2js:noInline')
  static PublishArticleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PublishArticleRequest>(
          PublishArticleRequest.$_createMessage);
  static PublishArticleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get articleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set articleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasArticleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get expectedRevision => $_getI64(1);
  @$pb.TagNumber(2)
  set expectedRevision($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExpectedRevision() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpectedRevision() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get idempotencyKey => $_getSZ(2);
  @$pb.TagNumber(3)
  set idempotencyKey($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasIdempotencyKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearIdempotencyKey() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get caption => $_getSZ(3);
  @$pb.TagNumber(4)
  set caption($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCaption() => $_has(3);
  @$pb.TagNumber(4)
  void clearCaption() => $_clearField(4);

  @$pb.TagNumber(5)
  $2.ReplyPolicy get replyPolicy => $_getN(4);
  @$pb.TagNumber(5)
  set replyPolicy($2.ReplyPolicy value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasReplyPolicy() => $_has(4);
  @$pb.TagNumber(5)
  void clearReplyPolicy() => $_clearField(5);
}

class PublishArticleResponse extends $pb.GeneratedMessage {
  factory PublishArticleResponse({
    Article? article,
    $2.PostView? post,
  }) {
    final result = PublishArticleResponse._();
    if (article != null) result.article = article;
    if (post != null) result.post = post;
    return result;
  }

  PublishArticleResponse._();

  factory PublishArticleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishArticleResponse()..mergeFromBuffer(data, registry);
  factory PublishArticleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishArticleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PublishArticleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.articles.v1'),
      createEmptyInstance: PublishArticleResponse.$_createMessage)
    ..aOM<Article>(1, _omitFieldNames ? '' : 'article',
        subBuilder: Article.$_createMessage)
    ..aOM<$2.PostView>(2, _omitFieldNames ? '' : 'post',
        subBuilder: $2.PostView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishArticleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishArticleResponse copyWith(
          void Function(PublishArticleResponse) updates) =>
      super.copyWith((message) => updates(message as PublishArticleResponse))
          as PublishArticleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use PublishArticleResponse() / PublishArticleResponse.new instead')
  static PublishArticleResponse create() => PublishArticleResponse._();
  static $pb.GeneratedMessage $_createMessage() => PublishArticleResponse._();
  @$core.override
  PublishArticleResponse createEmptyInstance() => PublishArticleResponse._();
  @$core.pragma('dart2js:noInline')
  static PublishArticleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PublishArticleResponse>(
          PublishArticleResponse.$_createMessage);
  static PublishArticleResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Article get article => $_getN(0);
  @$pb.TagNumber(1)
  set article(Article value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasArticle() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticle() => $_clearField(1);
  @$pb.TagNumber(1)
  Article ensureArticle() => $_ensure(0);

  @$pb.TagNumber(2)
  $2.PostView get post => $_getN(1);
  @$pb.TagNumber(2)
  set post($2.PostView value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPost() => $_has(1);
  @$pb.TagNumber(2)
  void clearPost() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.PostView ensurePost() => $_ensure(1);
}

/// Article bodies are read separately from bounded timeline previews.
class ArticleServiceApi {
  final $pb.RpcClient _client;

  ArticleServiceApi(this._client);

  $async.Future<GetArticleResponse> getArticle(
          $pb.ClientContext? ctx, GetArticleRequest request) =>
      _client.invoke<GetArticleResponse>(
          ctx, 'ArticleService', 'GetArticle', request, GetArticleResponse());
  $async.Future<ListArticlesResponse> listArticles(
          $pb.ClientContext? ctx, ListArticlesRequest request) =>
      _client.invoke<ListArticlesResponse>(ctx, 'ArticleService',
          'ListArticles', request, ListArticlesResponse());
  $async.Future<SaveArticleResponse> saveArticle(
          $pb.ClientContext? ctx, SaveArticleRequest request) =>
      _client.invoke<SaveArticleResponse>(
          ctx, 'ArticleService', 'SaveArticle', request, SaveArticleResponse());
  $async.Future<DeleteArticleResponse> deleteArticle(
          $pb.ClientContext? ctx, DeleteArticleRequest request) =>
      _client.invoke<DeleteArticleResponse>(ctx, 'ArticleService',
          'DeleteArticle', request, DeleteArticleResponse());
  $async.Future<PublishArticleResponse> publishArticle(
          $pb.ClientContext? ctx, PublishArticleRequest request) =>
      _client.invoke<PublishArticleResponse>(ctx, 'ArticleService',
          'PublishArticle', request, PublishArticleResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
