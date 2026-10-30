// This is a generated file - do not edit.
//
// Generated from dzeroth/messaging/v1/messaging.proto.

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
    as $1;

import '../../common/v1/common.pb.dart' as $0;
import 'messaging.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'messaging.pbenum.dart';

class Conversation extends $pb.GeneratedMessage {
  factory Conversation({
    $core.String? id,
    ConversationKind? kind,
    $0.AuthorSnapshot? peer,
    ConversationState? state,
    Folder? folder,
    MessagePreview? lastMessage,
    $fixnum.Int64? unreadCount,
    $core.bool? canReply,
    $core.bool? silent,
    $1.Timestamp? updatedAt,
  }) {
    final result = Conversation._();
    if (id != null) result.id = id;
    if (kind != null) result.kind = kind;
    if (peer != null) result.peer = peer;
    if (state != null) result.state = state;
    if (folder != null) result.folder = folder;
    if (lastMessage != null) result.lastMessage = lastMessage;
    if (unreadCount != null) result.unreadCount = unreadCount;
    if (canReply != null) result.canReply = canReply;
    if (silent != null) result.silent = silent;
    if (updatedAt != null) result.updatedAt = updatedAt;
    return result;
  }

  Conversation._();

  factory Conversation.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Conversation()..mergeFromBuffer(data, registry);
  factory Conversation.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Conversation()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Conversation',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: Conversation.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aE<ConversationKind>(2, _omitFieldNames ? '' : 'kind',
        enumValues: ConversationKind.values)
    ..aOM<$0.AuthorSnapshot>(3, _omitFieldNames ? '' : 'peer',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aE<ConversationState>(4, _omitFieldNames ? '' : 'state',
        enumValues: ConversationState.values)
    ..aE<Folder>(5, _omitFieldNames ? '' : 'folder', enumValues: Folder.values)
    ..aOM<MessagePreview>(6, _omitFieldNames ? '' : 'lastMessage',
        subBuilder: MessagePreview.$_createMessage)
    ..aInt64(7, _omitFieldNames ? '' : 'unreadCount')
    ..aOB(8, _omitFieldNames ? '' : 'canReply')
    ..aOB(9, _omitFieldNames ? '' : 'silent')
    ..aOM<$1.Timestamp>(10, _omitFieldNames ? '' : 'updatedAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Conversation clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Conversation copyWith(void Function(Conversation) updates) =>
      super.copyWith((message) => updates(message as Conversation))
          as Conversation;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Conversation() / Conversation.new instead')
  static Conversation create() => Conversation._();
  static $pb.GeneratedMessage $_createMessage() => Conversation._();
  @$core.override
  Conversation createEmptyInstance() => Conversation._();
  @$core.pragma('dart2js:noInline')
  static Conversation getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Conversation>(
          Conversation.$_createMessage);
  static Conversation? _defaultInstance;

  /// 32 lower-case hex, opaque.
  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  ConversationKind get kind => $_getN(1);
  @$pb.TagNumber(2)
  set kind(ConversationKind value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasKind() => $_has(1);
  @$pb.TagNumber(2)
  void clearKind() => $_clearField(2);

  /// The other participant. From the caller's entry (refreshed on every message either way) in ListConversations, and
  /// live from the identity directory (60 s) in ListMessages, except that a peer who blocked the caller is the entry's
  /// frozen snapshot there. A peer who deleted the account reads "Deleted account".
  @$pb.TagNumber(3)
  $0.AuthorSnapshot get peer => $_getN(2);
  @$pb.TagNumber(3)
  set peer($0.AuthorSnapshot value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasPeer() => $_has(2);
  @$pb.TagNumber(3)
  void clearPeer() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.AuthorSnapshot ensurePeer() => $_ensure(2);

  @$pb.TagNumber(4)
  ConversationState get state => $_getN(3);
  @$pb.TagNumber(4)
  set state(ConversationState value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasState() => $_has(3);
  @$pb.TagNumber(4)
  void clearState() => $_clearField(4);

  /// The folder of the caller's entry.
  @$pb.TagNumber(5)
  Folder get folder => $_getN(4);
  @$pb.TagNumber(5)
  set folder(Folder value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasFolder() => $_has(4);
  @$pb.TagNumber(5)
  void clearFolder() => $_clearField(5);

  @$pb.TagNumber(6)
  MessagePreview get lastMessage => $_getN(5);
  @$pb.TagNumber(6)
  set lastMessage(MessagePreview value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasLastMessage() => $_has(5);
  @$pb.TagNumber(6)
  void clearLastMessage() => $_clearField(6);
  @$pb.TagNumber(6)
  MessagePreview ensureLastMessage() => $_ensure(5);

  /// Unread messages for the caller. Does not grow while silent. In ListMessages it is filled on the first page only
  /// (not on a since or older page), from the caller's own entry; 0 is authoritative there (read elsewhere, or no entry),
  /// except for up to 60 s after a request was accepted on another server instance: its cached copy of the conversation
  /// can still point at the Requests entry, the read misses and answers 0.
  @$pb.TagNumber(7)
  $fixnum.Int64 get unreadCount => $_getI64(6);
  @$pb.TagNumber(7)
  set unreadCount($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasUnreadCount() => $_has(6);
  @$pb.TagNumber(7)
  void clearUnreadCount() => $_clearField(7);

  /// False when either side blocks the other or the peer deleted the account: the thread is read-only but can still be
  /// reported. Show no composer.
  @$pb.TagNumber(8)
  $core.bool get canReply => $_getBF(7);
  @$pb.TagNumber(8)
  set canReply($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasCanReply() => $_has(7);
  @$pb.TagNumber(8)
  void clearCanReply() => $_clearField(8);

  /// True when the caller muted the peer: messages arrive without a push or an unread increment (F9). In ListMessages
  /// it is filled on the first page only, from the caller's own entry.
  @$pb.TagNumber(9)
  $core.bool get silent => $_getBF(8);
  @$pb.TagNumber(9)
  set silent($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasSilent() => $_has(8);
  @$pb.TagNumber(9)
  void clearSilent() => $_clearField(9);

  /// Last activity on the caller's entry; the ListConversations sort key.
  @$pb.TagNumber(10)
  $1.Timestamp get updatedAt => $_getN(9);
  @$pb.TagNumber(10)
  set updatedAt($1.Timestamp value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasUpdatedAt() => $_has(9);
  @$pb.TagNumber(10)
  void clearUpdatedAt() => $_clearField(10);
  @$pb.TagNumber(10)
  $1.Timestamp ensureUpdatedAt() => $_ensure(9);
}

/// The last message of a conversation as shown in the list.
class MessagePreview extends $pb.GeneratedMessage {
  factory MessagePreview({
    $core.String? snippet,
    $core.bool? fromSelf,
    MessageState? state,
    $1.Timestamp? createdAt,
  }) {
    final result = MessagePreview._();
    if (snippet != null) result.snippet = snippet;
    if (fromSelf != null) result.fromSelf = fromSelf;
    if (state != null) result.state = state;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  MessagePreview._();

  factory MessagePreview.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessagePreview()..mergeFromBuffer(data, registry);
  factory MessagePreview.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessagePreview()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MessagePreview',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MessagePreview.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'snippet')
    ..aOB(2, _omitFieldNames ? '' : 'fromSelf')
    ..aE<MessageState>(3, _omitFieldNames ? '' : 'state',
        enumValues: MessageState.values)
    ..aOM<$1.Timestamp>(4, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessagePreview clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessagePreview copyWith(void Function(MessagePreview) updates) =>
      super.copyWith((message) => updates(message as MessagePreview))
          as MessagePreview;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MessagePreview() / MessagePreview.new instead')
  static MessagePreview create() => MessagePreview._();
  static $pb.GeneratedMessage $_createMessage() => MessagePreview._();
  @$core.override
  MessagePreview createEmptyInstance() => MessagePreview._();
  @$core.pragma('dart2js:noInline')
  static MessagePreview getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MessagePreview>(
          MessagePreview.$_createMessage);
  static MessagePreview? _defaultInstance;

  /// At most 100 code points of the text; empty for a tombstone.
  @$pb.TagNumber(1)
  $core.String get snippet => $_getSZ(0);
  @$pb.TagNumber(1)
  set snippet($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSnippet() => $_has(0);
  @$pb.TagNumber(1)
  void clearSnippet() => $_clearField(1);

  /// True when the caller sent it (render "You: ").
  @$pb.TagNumber(2)
  $core.bool get fromSelf => $_getBF(1);
  @$pb.TagNumber(2)
  set fromSelf($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFromSelf() => $_has(1);
  @$pb.TagNumber(2)
  void clearFromSelf() => $_clearField(2);

  @$pb.TagNumber(3)
  MessageState get state => $_getN(2);
  @$pb.TagNumber(3)
  set state(MessageState value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasState() => $_has(2);
  @$pb.TagNumber(3)
  void clearState() => $_clearField(3);

  @$pb.TagNumber(4)
  $1.Timestamp get createdAt => $_getN(3);
  @$pb.TagNumber(4)
  set createdAt($1.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasCreatedAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearCreatedAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $1.Timestamp ensureCreatedAt() => $_ensure(3);
}

class Message extends $pb.GeneratedMessage {
  factory Message({
    $core.String? id,
    $core.String? conversationId,
    $core.bool? fromSelf,
    $core.String? text,
    MessageState? state,
    $1.Timestamp? createdAt,
  }) {
    final result = Message._();
    if (id != null) result.id = id;
    if (conversationId != null) result.conversationId = conversationId;
    if (fromSelf != null) result.fromSelf = fromSelf;
    if (text != null) result.text = text;
    if (state != null) result.state = state;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Message._();

  factory Message.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Message()..mergeFromBuffer(data, registry);
  factory Message.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Message()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Message',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: Message.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..aOB(3, _omitFieldNames ? '' : 'fromSelf')
    ..aOS(4, _omitFieldNames ? '' : 'text')
    ..aE<MessageState>(5, _omitFieldNames ? '' : 'state',
        enumValues: MessageState.values)
    ..aOM<$1.Timestamp>(6, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Message clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Message copyWith(void Function(Message) updates) =>
      super.copyWith((message) => updates(message as Message)) as Message;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Message() / Message.new instead')
  static Message create() => Message._();
  static $pb.GeneratedMessage $_createMessage() => Message._();
  @$core.override
  Message createEmptyInstance() => Message._();
  @$core.pragma('dart2js:noInline')
  static Message getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Message>(Message.$_createMessage);
  static Message? _defaultInstance;

  /// 32 lower-case hex, opaque; derived from the sender and the idempotency_key. Dedupe by it.
  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);

  /// True when the caller sent it. There is deliberately no sender uid: the peer is Conversation.peer.
  @$pb.TagNumber(3)
  $core.bool get fromSelf => $_getBF(2);
  @$pb.TagNumber(3)
  set fromSelf($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFromSelf() => $_has(2);
  @$pb.TagNumber(3)
  void clearFromSelf() => $_clearField(3);

  /// NFC, the post grammar. Empty unless state is VISIBLE.
  @$pb.TagNumber(4)
  $core.String get text => $_getSZ(3);
  @$pb.TagNumber(4)
  set text($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasText() => $_has(3);
  @$pb.TagNumber(4)
  void clearText() => $_clearField(4);

  @$pb.TagNumber(5)
  MessageState get state => $_getN(4);
  @$pb.TagNumber(5)
  set state(MessageState value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasState() => $_has(4);
  @$pb.TagNumber(5)
  void clearState() => $_clearField(5);

  /// Server time of the send; the sort key (newest first).
  @$pb.TagNumber(6)
  $1.Timestamp get createdAt => $_getN(5);
  @$pb.TagNumber(6)
  set createdAt($1.Timestamp value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasCreatedAt() => $_has(5);
  @$pb.TagNumber(6)
  void clearCreatedAt() => $_clearField(6);
  @$pb.TagNumber(6)
  $1.Timestamp ensureCreatedAt() => $_ensure(5);
}

enum SendMessageRequest_Target { conversationId, recipientUserId, notSet }

class SendMessageRequest extends $pb.GeneratedMessage {
  factory SendMessageRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
    $core.String? recipientUserId,
    $core.String? text,
  }) {
    final result = SendMessageRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    if (recipientUserId != null) result.recipientUserId = recipientUserId;
    if (text != null) result.text = text;
    return result;
  }

  SendMessageRequest._();

  factory SendMessageRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SendMessageRequest()..mergeFromBuffer(data, registry);
  factory SendMessageRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SendMessageRequest()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, SendMessageRequest_Target>
      _SendMessageRequest_TargetByTag = {
    2: SendMessageRequest_Target.conversationId,
    3: SendMessageRequest_Target.recipientUserId,
    0: SendMessageRequest_Target.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SendMessageRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: SendMessageRequest.$_createMessage)
    ..oo(0, [2, 3])
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..aOS(3, _omitFieldNames ? '' : 'recipientUserId')
    ..aOS(4, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendMessageRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendMessageRequest copyWith(void Function(SendMessageRequest) updates) =>
      super.copyWith((message) => updates(message as SendMessageRequest))
          as SendMessageRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SendMessageRequest() / SendMessageRequest.new instead')
  static SendMessageRequest create() => SendMessageRequest._();
  static $pb.GeneratedMessage $_createMessage() => SendMessageRequest._();
  @$core.override
  SendMessageRequest createEmptyInstance() => SendMessageRequest._();
  @$core.pragma('dart2js:noInline')
  static SendMessageRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SendMessageRequest>(
          SendMessageRequest.$_createMessage);
  static SendMessageRequest? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  SendMessageRequest_Target whichTarget() =>
      _SendMessageRequest_TargetByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearTarget() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// An existing conversation (32 lower-case hex) the caller is a participant of.
  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);

  /// Open or continue the 1:1 conversation with this user. [A-Za-z0-9-]{1,128}; not the caller.
  @$pb.TagNumber(3)
  $core.String get recipientUserId => $_getSZ(2);
  @$pb.TagNumber(3)
  set recipientUserId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRecipientUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearRecipientUserId() => $_clearField(3);

  /// NFC, <= 280 code points, <= 10 lines (the post grammar).
  @$pb.TagNumber(4)
  $core.String get text => $_getSZ(3);
  @$pb.TagNumber(4)
  set text($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasText() => $_has(3);
  @$pb.TagNumber(4)
  void clearText() => $_clearField(4);
}

class SendMessageResponse extends $pb.GeneratedMessage {
  factory SendMessageResponse({
    Message? message,
    Conversation? conversation,
  }) {
    final result = SendMessageResponse._();
    if (message != null) result.message = message;
    if (conversation != null) result.conversation = conversation;
    return result;
  }

  SendMessageResponse._();

  factory SendMessageResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SendMessageResponse()..mergeFromBuffer(data, registry);
  factory SendMessageResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SendMessageResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SendMessageResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: SendMessageResponse.$_createMessage)
    ..aOM<Message>(1, _omitFieldNames ? '' : 'message',
        subBuilder: Message.$_createMessage)
    ..aOM<Conversation>(2, _omitFieldNames ? '' : 'conversation',
        subBuilder: Conversation.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendMessageResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendMessageResponse copyWith(void Function(SendMessageResponse) updates) =>
      super.copyWith((message) => updates(message as SendMessageResponse))
          as SendMessageResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SendMessageResponse() / SendMessageResponse.new instead')
  static SendMessageResponse create() => SendMessageResponse._();
  static $pb.GeneratedMessage $_createMessage() => SendMessageResponse._();
  @$core.override
  SendMessageResponse createEmptyInstance() => SendMessageResponse._();
  @$core.pragma('dart2js:noInline')
  static SendMessageResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SendMessageResponse>(
          SendMessageResponse.$_createMessage);
  static SendMessageResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Message get message => $_getN(0);
  @$pb.TagNumber(1)
  set message(Message value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasMessage() => $_has(0);
  @$pb.TagNumber(1)
  void clearMessage() => $_clearField(1);
  @$pb.TagNumber(1)
  Message ensureMessage() => $_ensure(0);

  @$pb.TagNumber(2)
  Conversation get conversation => $_getN(1);
  @$pb.TagNumber(2)
  set conversation(Conversation value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasConversation() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversation() => $_clearField(2);
  @$pb.TagNumber(2)
  Conversation ensureConversation() => $_ensure(1);
}

class ListConversationsRequest extends $pb.GeneratedMessage {
  factory ListConversationsRequest({
    Folder? folder,
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = ListConversationsRequest._();
    if (folder != null) result.folder = folder;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    return result;
  }

  ListConversationsRequest._();

  factory ListConversationsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationsRequest()..mergeFromBuffer(data, registry);
  factory ListConversationsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListConversationsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListConversationsRequest.$_createMessage)
    ..aE<Folder>(1, _omitFieldNames ? '' : 'folder', enumValues: Folder.values)
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..aOS(4, _omitFieldNames ? '' : 'sinceToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationsRequest copyWith(
          void Function(ListConversationsRequest) updates) =>
      super.copyWith((message) => updates(message as ListConversationsRequest))
          as ListConversationsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListConversationsRequest() / ListConversationsRequest.new instead')
  static ListConversationsRequest create() => ListConversationsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListConversationsRequest._();
  @$core.override
  ListConversationsRequest createEmptyInstance() =>
      ListConversationsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListConversationsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListConversationsRequest>(
          ListConversationsRequest.$_createMessage);
  static ListConversationsRequest? _defaultInstance;

  /// INBOX or REQUESTS.
  @$pb.TagNumber(1)
  Folder get folder => $_getN(0);
  @$pb.TagNumber(1)
  set folder(Folder value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasFolder() => $_has(0);
  @$pb.TagNumber(1)
  void clearFolder() => $_clearField(1);

  /// 0 => 20; max 50 (clamped).
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

  @$pb.TagNumber(4)
  $core.String get sinceToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set sinceToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSinceToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearSinceToken() => $_clearField(4);
}

class ListConversationsResponse extends $pb.GeneratedMessage {
  factory ListConversationsResponse({
    $core.Iterable<Conversation>? conversations,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $fixnum.Int64? requestCount,
  }) {
    final result = ListConversationsResponse._();
    if (conversations != null) result.conversations.addAll(conversations);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (requestCount != null) result.requestCount = requestCount;
    return result;
  }

  ListConversationsResponse._();

  factory ListConversationsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationsResponse()..mergeFromBuffer(data, registry);
  factory ListConversationsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListConversationsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListConversationsResponse.$_createMessage)
    ..pPM<Conversation>(1, _omitFieldNames ? '' : 'conversations',
        subBuilder: Conversation.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..aInt64(4, _omitFieldNames ? '' : 'requestCount')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationsResponse copyWith(
          void Function(ListConversationsResponse) updates) =>
      super.copyWith((message) => updates(message as ListConversationsResponse))
          as ListConversationsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListConversationsResponse() / ListConversationsResponse.new instead')
  static ListConversationsResponse create() => ListConversationsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListConversationsResponse._();
  @$core.override
  ListConversationsResponse createEmptyInstance() =>
      ListConversationsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListConversationsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListConversationsResponse>(
          ListConversationsResponse.$_createMessage);
  static ListConversationsResponse? _defaultInstance;

  /// Most recent activity first.
  @$pb.TagNumber(1)
  $pb.PbList<Conversation> get conversations => $_getList(0);

  /// "" => no older conversations.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// Persist with the cached list; send on the next refresh.
  @$pb.TagNumber(3)
  $core.String get sinceToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set sinceToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSinceToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearSinceToken() => $_clearField(3);

  /// Pending message requests ("Message requests (N)"): set on every INBOX first page and since refresh; 0 on an older
  /// page and on REQUESTS. Authoritative on an INBOX response, including 0.
  @$pb.TagNumber(4)
  $fixnum.Int64 get requestCount => $_getI64(3);
  @$pb.TagNumber(4)
  set requestCount($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRequestCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearRequestCount() => $_clearField(4);
}

class ListMessagesRequest extends $pb.GeneratedMessage {
  factory ListMessagesRequest({
    $core.String? conversationId,
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = ListMessagesRequest._();
    if (conversationId != null) result.conversationId = conversationId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    return result;
  }

  ListMessagesRequest._();

  factory ListMessagesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessagesRequest()..mergeFromBuffer(data, registry);
  factory ListMessagesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessagesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMessagesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListMessagesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'conversationId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..aOS(4, _omitFieldNames ? '' : 'sinceToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessagesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessagesRequest copyWith(void Function(ListMessagesRequest) updates) =>
      super.copyWith((message) => updates(message as ListMessagesRequest))
          as ListMessagesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use ListMessagesRequest() / ListMessagesRequest.new instead')
  static ListMessagesRequest create() => ListMessagesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListMessagesRequest._();
  @$core.override
  ListMessagesRequest createEmptyInstance() => ListMessagesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMessagesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMessagesRequest>(
          ListMessagesRequest.$_createMessage);
  static ListMessagesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get conversationId => $_getSZ(0);
  @$pb.TagNumber(1)
  set conversationId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  /// 0 => 20; max 50 (clamped).
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

  @$pb.TagNumber(4)
  $core.String get sinceToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set sinceToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSinceToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearSinceToken() => $_clearField(4);
}

class ListMessagesResponse extends $pb.GeneratedMessage {
  factory ListMessagesResponse({
    $core.Iterable<Message>? messages,
    Conversation? conversation,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
  }) {
    final result = ListMessagesResponse._();
    if (messages != null) result.messages.addAll(messages);
    if (conversation != null) result.conversation = conversation;
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
    return result;
  }

  ListMessagesResponse._();

  factory ListMessagesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessagesResponse()..mergeFromBuffer(data, registry);
  factory ListMessagesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessagesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMessagesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListMessagesResponse.$_createMessage)
    ..pPM<Message>(1, _omitFieldNames ? '' : 'messages',
        subBuilder: Message.$_createMessage)
    ..aOM<Conversation>(2, _omitFieldNames ? '' : 'conversation',
        subBuilder: Conversation.$_createMessage)
    ..aOS(3, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(4, _omitFieldNames ? '' : 'sinceToken')
    ..aOS(5, _omitFieldNames ? '' : 'gapPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessagesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessagesResponse copyWith(void Function(ListMessagesResponse) updates) =>
      super.copyWith((message) => updates(message as ListMessagesResponse))
          as ListMessagesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMessagesResponse() / ListMessagesResponse.new instead')
  static ListMessagesResponse create() => ListMessagesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListMessagesResponse._();
  @$core.override
  ListMessagesResponse createEmptyInstance() => ListMessagesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMessagesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMessagesResponse>(
          ListMessagesResponse.$_createMessage);
  static ListMessagesResponse? _defaultInstance;

  /// Newest first.
  @$pb.TagNumber(1)
  $pb.PbList<Message> get messages => $_getList(0);

  /// Set on a first or older page; UNSET on a since response (keep the cached one).
  @$pb.TagNumber(2)
  Conversation get conversation => $_getN(1);
  @$pb.TagNumber(2)
  set conversation(Conversation value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasConversation() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversation() => $_clearField(2);
  @$pb.TagNumber(2)
  Conversation ensureConversation() => $_ensure(1);

  /// "" => no older messages.
  @$pb.TagNumber(3)
  $core.String get nextPageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set nextPageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNextPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearNextPageToken() => $_clearField(3);

  /// Persist with the cached messages; send on the next poll.
  @$pb.TagNumber(4)
  $core.String get sinceToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set sinceToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSinceToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearSinceToken() => $_clearField(4);

  /// Non-empty => a refresh gap exists below the returned messages (see the token contract).
  @$pb.TagNumber(5)
  $core.String get gapPageToken => $_getSZ(4);
  @$pb.TagNumber(5)
  set gapPageToken($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasGapPageToken() => $_has(4);
  @$pb.TagNumber(5)
  void clearGapPageToken() => $_clearField(5);
}

class MarkConversationReadRequest extends $pb.GeneratedMessage {
  factory MarkConversationReadRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
  }) {
    final result = MarkConversationReadRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    return result;
  }

  MarkConversationReadRequest._();

  factory MarkConversationReadRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkConversationReadRequest()..mergeFromBuffer(data, registry);
  factory MarkConversationReadRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkConversationReadRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MarkConversationReadRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MarkConversationReadRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkConversationReadRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkConversationReadRequest copyWith(
          void Function(MarkConversationReadRequest) updates) =>
      super.copyWith(
              (message) => updates(message as MarkConversationReadRequest))
          as MarkConversationReadRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use MarkConversationReadRequest() / MarkConversationReadRequest.new instead')
  static MarkConversationReadRequest create() =>
      MarkConversationReadRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      MarkConversationReadRequest._();
  @$core.override
  MarkConversationReadRequest createEmptyInstance() =>
      MarkConversationReadRequest._();
  @$core.pragma('dart2js:noInline')
  static MarkConversationReadRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MarkConversationReadRequest>(
          MarkConversationReadRequest.$_createMessage);
  static MarkConversationReadRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);
}

class MarkConversationReadResponse extends $pb.GeneratedMessage {
  factory MarkConversationReadResponse() => MarkConversationReadResponse._();

  MarkConversationReadResponse._();

  factory MarkConversationReadResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkConversationReadResponse()..mergeFromBuffer(data, registry);
  factory MarkConversationReadResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkConversationReadResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MarkConversationReadResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MarkConversationReadResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkConversationReadResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkConversationReadResponse copyWith(
          void Function(MarkConversationReadResponse) updates) =>
      super.copyWith(
              (message) => updates(message as MarkConversationReadResponse))
          as MarkConversationReadResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use MarkConversationReadResponse() / MarkConversationReadResponse.new instead')
  static MarkConversationReadResponse create() =>
      MarkConversationReadResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      MarkConversationReadResponse._();
  @$core.override
  MarkConversationReadResponse createEmptyInstance() =>
      MarkConversationReadResponse._();
  @$core.pragma('dart2js:noInline')
  static MarkConversationReadResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MarkConversationReadResponse>(
          MarkConversationReadResponse.$_createMessage);
  static MarkConversationReadResponse? _defaultInstance;
}

class AcceptMessageRequestRequest extends $pb.GeneratedMessage {
  factory AcceptMessageRequestRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
  }) {
    final result = AcceptMessageRequestRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    return result;
  }

  AcceptMessageRequestRequest._();

  factory AcceptMessageRequestRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AcceptMessageRequestRequest()..mergeFromBuffer(data, registry);
  factory AcceptMessageRequestRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AcceptMessageRequestRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AcceptMessageRequestRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: AcceptMessageRequestRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AcceptMessageRequestRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AcceptMessageRequestRequest copyWith(
          void Function(AcceptMessageRequestRequest) updates) =>
      super.copyWith(
              (message) => updates(message as AcceptMessageRequestRequest))
          as AcceptMessageRequestRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use AcceptMessageRequestRequest() / AcceptMessageRequestRequest.new instead')
  static AcceptMessageRequestRequest create() =>
      AcceptMessageRequestRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      AcceptMessageRequestRequest._();
  @$core.override
  AcceptMessageRequestRequest createEmptyInstance() =>
      AcceptMessageRequestRequest._();
  @$core.pragma('dart2js:noInline')
  static AcceptMessageRequestRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AcceptMessageRequestRequest>(
          AcceptMessageRequestRequest.$_createMessage);
  static AcceptMessageRequestRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);
}

class AcceptMessageRequestResponse extends $pb.GeneratedMessage {
  factory AcceptMessageRequestResponse() => AcceptMessageRequestResponse._();

  AcceptMessageRequestResponse._();

  factory AcceptMessageRequestResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AcceptMessageRequestResponse()..mergeFromBuffer(data, registry);
  factory AcceptMessageRequestResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AcceptMessageRequestResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AcceptMessageRequestResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: AcceptMessageRequestResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AcceptMessageRequestResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AcceptMessageRequestResponse copyWith(
          void Function(AcceptMessageRequestResponse) updates) =>
      super.copyWith(
              (message) => updates(message as AcceptMessageRequestResponse))
          as AcceptMessageRequestResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use AcceptMessageRequestResponse() / AcceptMessageRequestResponse.new instead')
  static AcceptMessageRequestResponse create() =>
      AcceptMessageRequestResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      AcceptMessageRequestResponse._();
  @$core.override
  AcceptMessageRequestResponse createEmptyInstance() =>
      AcceptMessageRequestResponse._();
  @$core.pragma('dart2js:noInline')
  static AcceptMessageRequestResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AcceptMessageRequestResponse>(
          AcceptMessageRequestResponse.$_createMessage);
  static AcceptMessageRequestResponse? _defaultInstance;
}

class DeleteConversationRequest extends $pb.GeneratedMessage {
  factory DeleteConversationRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
  }) {
    final result = DeleteConversationRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    return result;
  }

  DeleteConversationRequest._();

  factory DeleteConversationRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteConversationRequest()..mergeFromBuffer(data, registry);
  factory DeleteConversationRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteConversationRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteConversationRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: DeleteConversationRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteConversationRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteConversationRequest copyWith(
          void Function(DeleteConversationRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteConversationRequest))
          as DeleteConversationRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteConversationRequest() / DeleteConversationRequest.new instead')
  static DeleteConversationRequest create() => DeleteConversationRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      DeleteConversationRequest._();
  @$core.override
  DeleteConversationRequest createEmptyInstance() =>
      DeleteConversationRequest._();
  @$core.pragma('dart2js:noInline')
  static DeleteConversationRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteConversationRequest>(
          DeleteConversationRequest.$_createMessage);
  static DeleteConversationRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);
}

class DeleteConversationResponse extends $pb.GeneratedMessage {
  factory DeleteConversationResponse() => DeleteConversationResponse._();

  DeleteConversationResponse._();

  factory DeleteConversationResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteConversationResponse()..mergeFromBuffer(data, registry);
  factory DeleteConversationResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteConversationResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteConversationResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: DeleteConversationResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteConversationResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteConversationResponse copyWith(
          void Function(DeleteConversationResponse) updates) =>
      super.copyWith(
              (message) => updates(message as DeleteConversationResponse))
          as DeleteConversationResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteConversationResponse() / DeleteConversationResponse.new instead')
  static DeleteConversationResponse create() => DeleteConversationResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      DeleteConversationResponse._();
  @$core.override
  DeleteConversationResponse createEmptyInstance() =>
      DeleteConversationResponse._();
  @$core.pragma('dart2js:noInline')
  static DeleteConversationResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteConversationResponse>(
          DeleteConversationResponse.$_createMessage);
  static DeleteConversationResponse? _defaultInstance;
}

class MessagingServiceApi {
  final $pb.RpcClient _client;

  MessagingServiceApi(this._client);

  /// Send a text message, opening the conversation if needed. Target: recipient_user_id (opens or continues the 1:1
  /// conversation with that user; self => VALIDATION "recipient_user_id"; [A-Za-z0-9-]{1,128}) or conversation_id (an
  /// existing conversation the caller is a participant of, else NOT_FOUND).
  /// text: the post grammar (NFC, <= 280 code points, <= 10 lines; testdata fixtures), validated before any read
  /// (VALIDATION "text", 0 reads).
  /// Flag: per caller AND per recipient. Caller off => FEATURE_DISABLED; recipient off => CANNOT_MESSAGE.
  /// Refusals, all CANNOT_MESSAGE with identical bytes: either side blocks the other (the caller and recipient graph
  /// snapshots, cached 60 s, so a new Block applies at once on its instance and within 60 s elsewhere; ADR-0027 A8),
  /// the recipient is not ACTIVE or has messaging off, the conversation is gone (the peer deleted the account).
  /// Routing: a new conversation is ACCEPTED when the two follow each other, else REQUEST (the recipient's entry goes
  /// to REQUESTS). While REQUEST, the requester may send MESSAGES_REQUEST_MAX_UNANSWERED (3) messages, then
  /// LIMIT_REACHED "request_unanswered"; a message from the recipient of the request accepts it (as on X). The
  /// recipient muted the caller => delivered silently (no unread increment, no push).
  /// Idempotency (ADR-0027 D2, the ADR-0021 bend of rules 1 and 4): the message id is derived from (caller,
  /// idempotency_key) and Created in the send transaction, so a retry returns the stored message with 0 writes; the
  /// same key with a different body => VALIDATION "idempotency_key". Clients dedupe by message id.
  /// Caps (ADR-0027 D13): RATE_LIMIT_MESSAGES_SEND_PER_MIN 20/min/uid per instance (60/min at 3 instances);
  /// MESSAGES_SENDS_PER_DAY 300 (50 for new accounts) per instance (<= 900/day at 3) => RATE_LIMITED metadata["limit"]
  /// = "messages_daily"; QUOTA_DM_NEW_CONVERSATIONS_PER_DAY 20 new conversations per IST day (5 for new accounts),
  /// exact (quotas/{uid}.dmNew, in the transaction) => LIMIT_REACHED "dm_new_daily"; MESSAGES_REQUEST_MAX_UNANSWERED 3,
  /// exact (conversations.requestCount, in the transaction).
  /// Push: after the commit one `message` event through notifications.Emitter (one Pub/Sub publish, 0 Firestore on
  /// this path), only when the recipient's side is accepted and not silent; a request never pushes. The push is
  /// generic ("New message") and carries only the conversation id (NOTIFICATION_TYPE_MESSAGE).
  /// Firestore (ADR-0027 Cost impact): accepted conversation reads 5 worst cold (interceptor, caller graph, recipient
  /// graph, recipient users via the directory, conversation doc in the transaction), planning 2.5; writes 3 (message,
  /// 2 entries), 4 while REQUEST (+ requestCount). New conversation reads 7 worst (+ fresh recipient status, quotas),
  /// writes 5 (message, conversation, 2 entries, quotas.dmNew). Replay +1 read (the stored message), 0 writes.
  /// Refused <= 5 reads, 0 writes; a validation rejection 0 reads. Deletes 0.
  $async.Future<SendMessageResponse> sendMessage(
          $pb.ClientContext? ctx, SendMessageRequest request) =>
      _client.invoke<SendMessageResponse>(ctx, 'MessagingService',
          'SendMessage', request, SendMessageResponse());

  /// The caller's conversations in one folder, most recent activity first. The path comes from the caller's token;
  /// there is no user id parameter. folder must be INBOX or REQUESTS, else VALIDATION "folder".
  /// Read-time rules (caller graph, cached 60 s): REQUESTS drops entries whose peer the caller blocks or mutes, or who
  /// blocks the caller; INBOX keeps every entry, with can_reply = false when either side blocks. Filtering runs after
  /// the page query, so a page may be short or empty while next_page_token is non-empty: keep following it.
  /// request_count is set on every INBOX first page and since refresh (an empty refresh included); 0 on an older page and
  /// on REQUESTS. Clients treat the INBOX value as authoritative, 0 included (W7-37).
  /// There is no gap_page_token here (plan W7-2): a since refresh returns at most page_size entries.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListMessages.
  /// Firestore: first INBOX page 20: reads 23 worst cold (interceptor, query 20, caller graph, requests count()),
  /// planning 9; REQUESTS the same without the count(). INBOX since refresh reads 4 worst (interceptor, query min 1, caller
  /// graph, requests count()), planning 3; an empty one 3. Writes 0.
  $async.Future<ListConversationsResponse> listConversations(
          $pb.ClientContext? ctx, ListConversationsRequest request) =>
      _client.invoke<ListConversationsResponse>(ctx, 'MessagingService',
          'ListConversations', request, ListConversationsResponse());

  /// Messages of one conversation, newest first. Messages at or before the caller's own DeleteConversation time are
  /// not returned. Tombstones (state DELETED_ACCOUNT or REMOVED) are returned with empty text.
  /// conversation is set on a first or older page (live peer snapshot from the identity directory, 60 s; can_reply
  /// from the caller graph, 60 s) and UNSET on a since response, so a poll reads no peer profile or graph.
  /// On the first page only, conversation.unread_count and conversation.silent come from the caller's own entry (0 and
  /// false when it is gone); on an older page they are unset. When the peer blocked the caller, conversation.peer is the
  /// snapshot frozen on the caller's entry, not the live profile ("Deleted account" on an older page or when the entry is
  /// gone), and can_reply is false.
  /// A since refresh whose page was full returns gap_page_token: keep the cache and fill the gap with page_token =
  /// gap_page_token (bounded below by the old since_token).
  /// Client polling (ADR-0027 D7): only on a visible thread; web 15 s while hot, Android 30 s while hot, 45 s while
  /// quiet, stopped after 5 min idle or when hidden; a push for the conversation triggers an immediate pull; a
  /// RATE_LIMITED answer pauses polling.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListConversations.
  /// Firestore: first page 20 / 50: reads 25 / 55 worst cold (interceptor, conversation, query, peer users, caller
  /// graph for can_reply, the caller's entry), planning 16; older page 24 / 54 (no entry), planning 15. since poll:
  /// reads 3 cold (interceptor, conversation, query min 1) + 1 per new message returned, planning 1.2. NOT_FOUND after <= 2 reads. Writes 0.
  $async.Future<ListMessagesResponse> listMessages(
          $pb.ClientContext? ctx, ListMessagesRequest request) =>
      _client.invoke<ListMessagesResponse>(ctx, 'MessagingService',
          'ListMessages', request, ListMessagesResponse());

  /// Marks the conversation read for the caller: unread count 0 and the read time on the caller's own entry (a field
  /// update with an Exists precondition). The read time is never shown to the peer (no read receipts, F4). A missing
  /// entry (unknown id, non-participant, deleted for the caller) => success, 0 writes. Evicts the caller's
  /// unread_conversation_count cache on this instance. Call only when the client holds unread_count > 0.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  /// Firestore: reads 1 (interceptor), planning 0.3; writes 1 (0 when the entry is missing); deletes 0.
  $async.Future<MarkConversationReadResponse> markConversationRead(
          $pb.ClientContext? ctx, MarkConversationReadRequest request) =>
      _client.invoke<MarkConversationReadResponse>(ctx, 'MessagingService',
          'MarkConversationRead', request, MarkConversationReadResponse());

  /// Accepts a message request: the conversation becomes ACCEPTED and the caller's entry moves from REQUESTS to INBOX
  /// (unread count kept). Only the recipient of the request may accept; the requester (or a non-participant) gets
  /// NOT_FOUND. Already accepted => success, 0 writes. Emits nothing.
  /// Flag: per caller AND per recipient (the peer); peer off => CANNOT_MESSAGE. Refused under DEGRADED_MODE=readonly.
  /// Firestore: reads 3 worst (interceptor, conversation, request entry), planning 2.5; writes 2 (conversation state,
  /// dmInbox entry); deletes 1 (dmRequests entry).
  $async.Future<AcceptMessageRequestResponse> acceptMessageRequest(
          $pb.ClientContext? ctx, AcceptMessageRequestRequest request) =>
      _client.invoke<AcceptMessageRequestResponse>(ctx, 'MessagingService',
          'AcceptMessageRequest', request, AcceptMessageRequestResponse());

  /// Deletes the conversation for the caller only (also "delete request"): removes the caller's entry from either
  /// folder and hides every message up to now from the caller. The peer keeps the conversation. A deleted request stays
  /// a REQUEST for the sender, whose cap still applies; a later message recreates the caller's entry showing only newer
  /// messages. Blocking from a thread uses GraphService.Block and does not delete the conversation.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  /// Firestore: reads 3 worst, planning 2.5; writes 1 (clearedAt on the conversation); deletes 1 (the caller's entry).
  $async.Future<DeleteConversationResponse> deleteConversation(
          $pb.ClientContext? ctx, DeleteConversationRequest request) =>
      _client.invoke<DeleteConversationResponse>(ctx, 'MessagingService',
          'DeleteConversation', request, DeleteConversationResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
