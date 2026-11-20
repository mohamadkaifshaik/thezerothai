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

import '../../beacons/v1/beacons.pbenum.dart' as $3;
import '../../common/v1/common.pb.dart' as $0;
import '../../posts/v1/posts.pb.dart' as $2;
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
    $1.Timestamp? peerReadAt,
    ConversationEncryption? encryption,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
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
    if (peerReadAt != null) result.peerReadAt = peerReadAt;
    if (encryption != null) result.encryption = encryption;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
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
    ..aOM<$1.Timestamp>(11, _omitFieldNames ? '' : 'peerReadAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aE<ConversationEncryption>(12, _omitFieldNames ? '' : 'encryption',
        enumValues: ConversationEncryption.values)
    ..a<$fixnum.Int64>(
        13, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        14, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
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

  /// ListConversations: from the caller's entry. A REQUESTS row is REQUEST; an INBOX row is REQUEST for a request the caller sent
  /// that the peer has not accepted yet, else ACCEPTED. SendMessage and ListMessages: from the
  /// conversation (ListMessages through the 60 s instance copy, so up to 60 s behind an accept made on another instance).
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

  /// When the peer last marked this conversation read, if both of you have read receipts on (F3); unset otherwise.
  /// Messages with created_at at or before it are seen. ListMessages first page only (one extra read of the peer's own
  /// entry; a since or older page and every ListConversations row leave it unset, so polls stay free): re-open or
  /// refresh the thread to update it. Unset when FEATURE_READ_RECEIPTS is off for the caller, when either side has the
  /// setting off (reciprocal: your own off hides it at once on the serving instance, the peer's within the 60 s profile
  /// cache), when the peer never read with receipts on, when either side blocks the other, and when the peer is gone.
  @$pb.TagNumber(11)
  $1.Timestamp get peerReadAt => $_getN(10);
  @$pb.TagNumber(11)
  set peerReadAt($1.Timestamp value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasPeerReadAt() => $_has(10);
  @$pb.TagNumber(11)
  void clearPeerReadAt() => $_clearField(11);
  @$pb.TagNumber(11)
  $1.Timestamp ensurePeerReadAt() => $_ensure(10);

  /// NONE for a plaintext conversation, MLS for an encrypted one: on every SendMessage response (a plaintext send
  /// included) and on a ListMessages first or older page (from the conversation; ListMessages through the 60 s instance
  /// copy). UNSPECIFIED where the conversation's own value is not read: every ListConversations row and a ListMessages
  /// since response (conversation unset there). MLS => send only ciphertext.
  @$pb.TagNumber(12)
  ConversationEncryption get encryption => $_getN(11);
  @$pb.TagNumber(12)
  set encryption(ConversationEncryption value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasEncryption() => $_has(11);
  @$pb.TagNumber(12)
  void clearEncryption() => $_clearField(12);

  /// MLS only (0 otherwise), set where encryption is set: the current pair as of this response. It can be up to 60 s
  /// behind on ListMessages; the authoritative current pair is ListConversationCommits (or a STALE_EPOCH answer).
  @$pb.TagNumber(13)
  $fixnum.Int64 get mlsGeneration => $_getI64(12);
  @$pb.TagNumber(13)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(12, value);
  @$pb.TagNumber(13)
  $core.bool hasMlsGeneration() => $_has(12);
  @$pb.TagNumber(13)
  void clearMlsGeneration() => $_clearField(13);

  @$pb.TagNumber(14)
  $fixnum.Int64 get mlsEpoch => $_getI64(13);
  @$pb.TagNumber(14)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(13, value);
  @$pb.TagNumber(14)
  $core.bool hasMlsEpoch() => $_has(13);
  @$pb.TagNumber(14)
  void clearMlsEpoch() => $_clearField(14);
}

/// The last message of a conversation as shown in the list.
class MessagePreview extends $pb.GeneratedMessage {
  factory MessagePreview({
    $core.String? snippet,
    $core.bool? fromSelf,
    MessageState? state,
    $1.Timestamp? createdAt,
    $core.bool? sharedPost,
    $core.bool? encrypted,
  }) {
    final result = MessagePreview._();
    if (snippet != null) result.snippet = snippet;
    if (fromSelf != null) result.fromSelf = fromSelf;
    if (state != null) result.state = state;
    if (createdAt != null) result.createdAt = createdAt;
    if (sharedPost != null) result.sharedPost = sharedPost;
    if (encrypted != null) result.encrypted = encrypted;
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
    ..aOB(5, _omitFieldNames ? '' : 'sharedPost')
    ..aOB(6, _omitFieldNames ? '' : 'encrypted')
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

  /// True when the message shares a post. The snippet is then the sender's text (the caption or the post URL), never
  /// the post's own text: the preview is frozen on the entry and must not outlive a delete, a takedown or a protect.
  /// Render "Shared a post" when the snippet is the post URL.
  @$pb.TagNumber(5)
  $core.bool get sharedPost => $_getBF(4);
  @$pb.TagNumber(5)
  set sharedPost($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSharedPost() => $_has(4);
  @$pb.TagNumber(5)
  void clearSharedPost() => $_clearField(5);

  /// True when the message is end-to-end encrypted: the snippet is then empty (the server cannot read it) and
  /// shared_post is false. Build the preview from the device's own copy; for a message request the device has not
  /// opened yet, show a generic preview.
  @$pb.TagNumber(6)
  $core.bool get encrypted => $_getBF(5);
  @$pb.TagNumber(6)
  set encrypted($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasEncrypted() => $_has(5);
  @$pb.TagNumber(6)
  void clearEncrypted() => $_clearField(6);
}

class Message extends $pb.GeneratedMessage {
  factory Message({
    $core.String? id,
    $core.String? conversationId,
    $core.bool? fromSelf,
    $core.String? text,
    MessageState? state,
    $1.Timestamp? createdAt,
    $2.EmbeddedPost? sharedPost,
    $core.List<$core.int>? ciphertext,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.List<$core.int>? reportCommitment,
    $core.bool? ciphertextRemoved,
  }) {
    final result = Message._();
    if (id != null) result.id = id;
    if (conversationId != null) result.conversationId = conversationId;
    if (fromSelf != null) result.fromSelf = fromSelf;
    if (text != null) result.text = text;
    if (state != null) result.state = state;
    if (createdAt != null) result.createdAt = createdAt;
    if (sharedPost != null) result.sharedPost = sharedPost;
    if (ciphertext != null) result.ciphertext = ciphertext;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (reportCommitment != null) result.reportCommitment = reportCommitment;
    if (ciphertextRemoved != null) result.ciphertextRemoved = ciphertextRemoved;
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
    ..aOM<$2.EmbeddedPost>(8, _omitFieldNames ? '' : 'sharedPost',
        subBuilder: $2.EmbeddedPost.$_createMessage)
    ..a<$core.List<$core.int>>(
        9, _omitFieldNames ? '' : 'ciphertext', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        10, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        11, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        12, _omitFieldNames ? '' : 'reportCommitment', $pb.PbFieldType.OY)
    ..aOB(13, _omitFieldNames ? '' : 'ciphertextRemoved')
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

  /// 32 lower-case hex. The first 32 hex characters of SHA-256(sender auth uid || "|SendMessage|" || idempotency_key)
  /// (ASCII, lower-case hex). Idempotency keys must carry at least 128 random bits. Dedupe by it.
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

  /// The post this message shares (SendMessageRequest.shared_post_id), decided for the reader of THIS response, live
  /// (never a copy frozen at send time). When the reader may see the post by the GetPost rules every field is its
  /// current value; otherwise only post_id and unavailable = true are set ("Post unavailable"), one form for every
  /// cause: deleted, hidden by a moderator, author suspended or deleting, a block in either direction between the
  /// reader and the author (or a QUOTE's embedded author), a protected author the reader does not follow. A mute is not
  /// a block: the card is shown. Unset when the message shares no post and on a tombstone (state DELETED_ACCOUNT or
  /// REMOVED). EmbeddedPost.author is a frozen-copy AuthorSnapshot (is_private false). A tap opens /post/:id
  /// (PostService.GetPost decides again).
  @$pb.TagNumber(8)
  $2.EmbeddedPost get sharedPost => $_getN(6);
  @$pb.TagNumber(8)
  set sharedPost($2.EmbeddedPost value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasSharedPost() => $_has(6);
  @$pb.TagNumber(8)
  void clearSharedPost() => $_clearField(8);
  @$pb.TagNumber(8)
  $2.EmbeddedPost ensureSharedPost() => $_ensure(6);

  /// Encrypted messages only: an MLS application message whose plaintext is a serialized MessageContent. Opaque to the
  /// server. Empty for a plaintext message, a tombstone (DELETED_ACCOUNT, REMOVED) and once removed
  /// (ciphertext_removed). text is empty and shared_post unset whenever the message is encrypted.
  @$pb.TagNumber(9)
  $core.List<$core.int> get ciphertext => $_getN(7);
  @$pb.TagNumber(9)
  set ciphertext($core.List<$core.int> value) => $_setBytes(7, value);
  @$pb.TagNumber(9)
  $core.bool hasCiphertext() => $_has(7);
  @$pb.TagNumber(9)
  void clearCiphertext() => $_clearField(9);

  /// The (generation, epoch) the message was encrypted in; 0 for a plaintext message. Kept after the ciphertext is
  /// removed.
  @$pb.TagNumber(10)
  $fixnum.Int64 get mlsGeneration => $_getI64(8);
  @$pb.TagNumber(10)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(8, value);
  @$pb.TagNumber(10)
  $core.bool hasMlsGeneration() => $_has(8);
  @$pb.TagNumber(10)
  void clearMlsGeneration() => $_clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get mlsEpoch => $_getI64(9);
  @$pb.TagNumber(11)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(9, value);
  @$pb.TagNumber(11)
  $core.bool hasMlsEpoch() => $_has(9);
  @$pb.TagNumber(11)
  void clearMlsEpoch() => $_clearField(11);

  /// 32 bytes while the ciphertext is present, empty otherwise: SHA-256 over the ASCII bytes "dz-report-v1" followed by
  /// the exact MessageContent bytes inside the ciphertext. The receiving device MUST verify it against the decrypted
  /// MessageContent before showing the message: on a mismatch, or when report_key is not 32 bytes, it shows a "This
  /// message couldn't be verified" placeholder instead of the content and still offers Report (such a report is marked
  /// unverified). A report sends the content and the server recomputes it (moderation.v1
  /// ReportContentRequest.message_payload).
  @$pb.TagNumber(12)
  $core.List<$core.int> get reportCommitment => $_getN(10);
  @$pb.TagNumber(12)
  set reportCommitment($core.List<$core.int> value) => $_setBytes(10, value);
  @$pb.TagNumber(12)
  $core.bool hasReportCommitment() => $_has(10);
  @$pb.TagNumber(12)
  void clearReportCommitment() => $_clearField(12);

  /// True once the ciphertext was removed: by the 30-day sweep (state stays VISIBLE; the device's own copy is the only
  /// one left, else show "Couldn't decrypt this message"), by a takedown (state REMOVED) or by the sender's account
  /// deletion (state DELETED_ACCOUNT). ciphertext and report_commitment are then empty.
  @$pb.TagNumber(13)
  $core.bool get ciphertextRemoved => $_getBF(11);
  @$pb.TagNumber(13)
  set ciphertextRemoved($core.bool value) => $_setBool(11, value);
  @$pb.TagNumber(13)
  $core.bool hasCiphertextRemoved() => $_has(11);
  @$pb.TagNumber(13)
  void clearCiphertextRemoved() => $_clearField(13);
}

/// What a device encrypts as the plaintext of one encrypted message (Message.ciphertext). Never sent to the server in
/// the clear, except by a reporter: ModerationService.ReportContent message_payload carries these exact bytes. Any
/// padding is added by the encryption layer, outside these bytes. The report commitment is
/// SHA-256(ASCII "dz-report-v1" || the serialized MessageContent), computed by the sender over the very bytes it
/// encrypts; a receiver keeps the decrypted bytes as received (protobuf encoding is not canonical) so a report can
/// reproduce them.
class MessageContent extends $pb.GeneratedMessage {
  factory MessageContent({
    $core.String? text,
    $core.String? sharedPostId,
    $core.List<$core.int>? reportKey,
  }) {
    final result = MessageContent._();
    if (text != null) result.text = text;
    if (sharedPostId != null) result.sharedPostId = sharedPostId;
    if (reportKey != null) result.reportKey = reportKey;
    return result;
  }

  MessageContent._();

  factory MessageContent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessageContent()..mergeFromBuffer(data, registry);
  factory MessageContent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessageContent()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MessageContent',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MessageContent.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..aOS(2, _omitFieldNames ? '' : 'sharedPostId')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'reportKey', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageContent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageContent copyWith(void Function(MessageContent) updates) =>
      super.copyWith((message) => updates(message as MessageContent))
          as MessageContent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MessageContent() / MessageContent.new instead')
  static MessageContent create() => MessageContent._();
  static $pb.GeneratedMessage $_createMessage() => MessageContent._();
  @$core.override
  MessageContent createEmptyInstance() => MessageContent._();
  @$core.pragma('dart2js:noInline')
  static MessageContent getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MessageContent>(
          MessageContent.$_createMessage);
  static MessageContent? _defaultInstance;

  /// The message text: the post grammar (NFC, <= 280 code points, <= 10 lines), enforced by the sending app. Required;
  /// for a post share without a caption, the canonical post URL (as for plaintext).
  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);

  /// Optional: a shared post (19-digit id, the original for a REPOST), or empty. The reader's app loads it through
  /// PostService.GetPost, which applies every visibility rule for the reader.
  @$pb.TagNumber(2)
  $core.String get sharedPostId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sharedPostId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSharedPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSharedPostId() => $_clearField(2);

  /// 32 fresh random bytes per message. They make the commitment hiding (the server cannot confirm a guessed text
  /// against it). Never stored by the server, also not from a report.
  @$pb.TagNumber(3)
  $core.List<$core.int> get reportKey => $_getN(2);
  @$pb.TagNumber(3)
  set reportKey($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasReportKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearReportKey() => $_clearField(3);
}

enum SendMessageRequest_Target { conversationId, recipientUserId, notSet }

class SendMessageRequest extends $pb.GeneratedMessage {
  factory SendMessageRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
    $core.String? recipientUserId,
    $core.String? text,
    $core.String? sharedPostId,
    $core.List<$core.int>? ciphertext,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.List<$core.int>? reportCommitment,
    MlsInit? mlsInit,
  }) {
    final result = SendMessageRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    if (recipientUserId != null) result.recipientUserId = recipientUserId;
    if (text != null) result.text = text;
    if (sharedPostId != null) result.sharedPostId = sharedPostId;
    if (ciphertext != null) result.ciphertext = ciphertext;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (reportCommitment != null) result.reportCommitment = reportCommitment;
    if (mlsInit != null) result.mlsInit = mlsInit;
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
    ..aOS(5, _omitFieldNames ? '' : 'sharedPostId')
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'ciphertext', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        8, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        9, _omitFieldNames ? '' : 'reportCommitment', $pb.PbFieldType.OY)
    ..aOM<MlsInit>(10, _omitFieldNames ? '' : 'mlsInit',
        subBuilder: MlsInit.$_createMessage)
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

  /// NFC, <= 280 code points, <= 10 lines (the post grammar). Required for a plaintext message, also when
  /// shared_post_id is set: the caption, or the canonical post URL when the user typed none. Empty for an encrypted
  /// message (the text is MessageContent.text inside the ciphertext).
  @$pb.TagNumber(4)
  $core.String get text => $_getSZ(3);
  @$pb.TagNumber(4)
  set text($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasText() => $_has(3);
  @$pb.TagNumber(4)
  void clearText() => $_clearField(4);

  /// Optional: share this post in the message (FEATURE_DM_POST_SHARE). 19-digit post id; a REPOST id shares its
  /// original. Rules in the SendMessage comment. Empty for an encrypted message (MessageContent.shared_post_id).
  @$pb.TagNumber(5)
  $core.String get sharedPostId => $_getSZ(4);
  @$pb.TagNumber(5)
  set sharedPostId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSharedPostId() => $_has(4);
  @$pb.TagNumber(5)
  void clearSharedPostId() => $_clearField(5);

  /// Encrypted messages (SendMessage comment): the MLS application message, 1-8192 bytes. Setting it (or any field
  /// below) makes the request encrypted: text and shared_post_id must then be empty.
  @$pb.TagNumber(6)
  $core.List<$core.int> get ciphertext => $_getN(5);
  @$pb.TagNumber(6)
  set ciphertext($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasCiphertext() => $_has(5);
  @$pb.TagNumber(6)
  void clearCiphertext() => $_clearField(6);

  /// The (generation, epoch) the ciphertext was built in: the conversation's current pair, or (1, 1) with mls_init.
  @$pb.TagNumber(7)
  $fixnum.Int64 get mlsGeneration => $_getI64(6);
  @$pb.TagNumber(7)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMlsGeneration() => $_has(6);
  @$pb.TagNumber(7)
  void clearMlsGeneration() => $_clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get mlsEpoch => $_getI64(7);
  @$pb.TagNumber(8)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(7, value);
  @$pb.TagNumber(8)
  $core.bool hasMlsEpoch() => $_has(7);
  @$pb.TagNumber(8)
  void clearMlsEpoch() => $_clearField(8);

  /// Exactly 32 bytes: SHA-256(ASCII "dz-report-v1" || the MessageContent bytes inside the ciphertext). Stored; the
  /// server cannot check it on send.
  @$pb.TagNumber(9)
  $core.List<$core.int> get reportCommitment => $_getN(8);
  @$pb.TagNumber(9)
  set reportCommitment($core.List<$core.int> value) => $_setBytes(8, value);
  @$pb.TagNumber(9)
  $core.bool hasReportCommitment() => $_has(8);
  @$pb.TagNumber(9)
  void clearReportCommitment() => $_clearField(9);

  /// Only to start encryption: a new conversation, or the first encrypted send of a plaintext one. Needs e2ee_dm on
  /// for the caller and the recipient.
  @$pb.TagNumber(10)
  MlsInit get mlsInit => $_getN(9);
  @$pb.TagNumber(10)
  set mlsInit(MlsInit value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasMlsInit() => $_has(9);
  @$pb.TagNumber(10)
  void clearMlsInit() => $_clearField(10);
  @$pb.TagNumber(10)
  MlsInit ensureMlsInit() => $_ensure(9);
}

/// The group creation that starts encryption, sent with the conversation's first encrypted message. Its commit is the
/// commit built on generation 1, epoch 0; the conversation then stands at (1, 1), the pair of the accompanying message.
class MlsInit extends $pb.GeneratedMessage {
  factory MlsInit({
    $core.List<$core.int>? commit,
    $core.List<$core.int>? welcome,
    $core.Iterable<$core.String>? welcomeDeviceIds,
  }) {
    final result = MlsInit._();
    if (commit != null) result.commit = commit;
    if (welcome != null) result.welcome = welcome;
    if (welcomeDeviceIds != null)
      result.welcomeDeviceIds.addAll(welcomeDeviceIds);
    return result;
  }

  MlsInit._();

  factory MlsInit.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MlsInit()..mergeFromBuffer(data, registry);
  factory MlsInit.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MlsInit()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MlsInit',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MlsInit.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'commit', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'welcome', $pb.PbFieldType.OY)
    ..pPS(3, _omitFieldNames ? '' : 'welcomeDeviceIds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MlsInit clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MlsInit copyWith(void Function(MlsInit) updates) =>
      super.copyWith((message) => updates(message as MlsInit)) as MlsInit;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MlsInit() / MlsInit.new instead')
  static MlsInit create() => MlsInit._();
  static $pb.GeneratedMessage $_createMessage() => MlsInit._();
  @$core.override
  MlsInit createEmptyInstance() => MlsInit._();
  @$core.pragma('dart2js:noInline')
  static MlsInit getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MlsInit>(MlsInit.$_createMessage);
  static MlsInit? _defaultInstance;

  /// The MLS commit that creates the group, 1-16384 bytes (VALIDATION "commit"). Stored as the commit record (1, 0).
  @$pb.TagNumber(1)
  $core.List<$core.int> get commit => $_getN(0);
  @$pb.TagNumber(1)
  set commit($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommit() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommit() => $_clearField(1);

  /// The MLS Welcome for the members, 1-65536 bytes (VALIDATION "welcome"). Stored once per welcome_device_ids entry,
  /// replacing that device's earlier welcome for this conversation if any (at most one per conversation per device).
  @$pb.TagNumber(2)
  $core.List<$core.int> get welcome => $_getN(1);
  @$pb.TagNumber(2)
  set welcome($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasWelcome() => $_has(1);
  @$pb.TagNumber(2)
  void clearWelcome() => $_clearField(2);

  /// Format, checked before any lookup: 1-10 distinct device ids, each [A-Za-z0-9_-]{16,64}, else VALIDATION
  /// "welcome_device_ids". Active-device check, answered only after every NOT_FOUND and CANNOT_MESSAGE refusal: each
  /// id is an active registered device of the caller or the recipient, at least one of them the recipient's, else the
  /// same VALIDATION "welcome_device_ids" without saying which id failed. The sending device itself needs no welcome.
  /// Device ids, not user references.
  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get welcomeDeviceIds => $_getList(2);
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

/// The post a share would carry. No idempotency_key: the RPC is read-only (NO_SIDE_EFFECTS), the convention covers
/// mutations, and a retry is the same question.
class CheckPostShareRequest extends $pb.GeneratedMessage {
  factory CheckPostShareRequest({
    $core.String? postId,
  }) {
    final result = CheckPostShareRequest._();
    if (postId != null) result.postId = postId;
    return result;
  }

  CheckPostShareRequest._();

  factory CheckPostShareRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckPostShareRequest()..mergeFromBuffer(data, registry);
  factory CheckPostShareRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckPostShareRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckPostShareRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: CheckPostShareRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckPostShareRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckPostShareRequest copyWith(
          void Function(CheckPostShareRequest) updates) =>
      super.copyWith((message) => updates(message as CheckPostShareRequest))
          as CheckPostShareRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CheckPostShareRequest() / CheckPostShareRequest.new instead')
  static CheckPostShareRequest create() => CheckPostShareRequest._();
  static $pb.GeneratedMessage $_createMessage() => CheckPostShareRequest._();
  @$core.override
  CheckPostShareRequest createEmptyInstance() => CheckPostShareRequest._();
  @$core.pragma('dart2js:noInline')
  static CheckPostShareRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckPostShareRequest>(
          CheckPostShareRequest.$_createMessage);
  static CheckPostShareRequest? _defaultInstance;

  /// 19-digit post id; a REPOST id is checked on itself and on its original.
  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);
}

/// Present only when the share is allowed; every refusal is an error (the SendMessage bytes).
class CheckPostShareResponse extends $pb.GeneratedMessage {
  factory CheckPostShareResponse({
    $core.String? sharedPostId,
  }) {
    final result = CheckPostShareResponse._();
    if (sharedPostId != null) result.sharedPostId = sharedPostId;
    return result;
  }

  CheckPostShareResponse._();

  factory CheckPostShareResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckPostShareResponse()..mergeFromBuffer(data, registry);
  factory CheckPostShareResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckPostShareResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckPostShareResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: CheckPostShareResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'sharedPostId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckPostShareResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckPostShareResponse copyWith(
          void Function(CheckPostShareResponse) updates) =>
      super.copyWith((message) => updates(message as CheckPostShareResponse))
          as CheckPostShareResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CheckPostShareResponse() / CheckPostShareResponse.new instead')
  static CheckPostShareResponse create() => CheckPostShareResponse._();
  static $pb.GeneratedMessage $_createMessage() => CheckPostShareResponse._();
  @$core.override
  CheckPostShareResponse createEmptyInstance() => CheckPostShareResponse._();
  @$core.pragma('dart2js:noInline')
  static CheckPostShareResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckPostShareResponse>(
          CheckPostShareResponse.$_createMessage);
  static CheckPostShareResponse? _defaultInstance;

  /// The id SendMessage would store: the original's for a REPOST id, else post_id. Put this in MessageContent.
  @$pb.TagNumber(1)
  $core.String get sharedPostId => $_getSZ(0);
  @$pb.TagNumber(1)
  set sharedPostId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSharedPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearSharedPostId() => $_clearField(1);
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

class ListMessageSuggestionsRequest extends $pb.GeneratedMessage {
  factory ListMessageSuggestionsRequest({
    $core.int? limit,
  }) {
    final result = ListMessageSuggestionsRequest._();
    if (limit != null) result.limit = limit;
    return result;
  }

  ListMessageSuggestionsRequest._();

  factory ListMessageSuggestionsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessageSuggestionsRequest()..mergeFromBuffer(data, registry);
  factory ListMessageSuggestionsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessageSuggestionsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMessageSuggestionsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListMessageSuggestionsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'limit')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessageSuggestionsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessageSuggestionsRequest copyWith(
          void Function(ListMessageSuggestionsRequest) updates) =>
      super.copyWith(
              (message) => updates(message as ListMessageSuggestionsRequest))
          as ListMessageSuggestionsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMessageSuggestionsRequest() / ListMessageSuggestionsRequest.new instead')
  static ListMessageSuggestionsRequest create() =>
      ListMessageSuggestionsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListMessageSuggestionsRequest._();
  @$core.override
  ListMessageSuggestionsRequest createEmptyInstance() =>
      ListMessageSuggestionsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMessageSuggestionsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMessageSuggestionsRequest>(
          ListMessageSuggestionsRequest.$_createMessage);
  static ListMessageSuggestionsRequest? _defaultInstance;

  /// 0 => 10; max 20 (clamped); negative => VALIDATION "limit".
  @$pb.TagNumber(1)
  $core.int get limit => $_getIZ(0);
  @$pb.TagNumber(1)
  set limit($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLimit() => $_has(0);
  @$pb.TagNumber(1)
  void clearLimit() => $_clearField(1);
}

class MessageSuggestion extends $pb.GeneratedMessage {
  factory MessageSuggestion({
    $0.AuthorSnapshot? user,
    MessageSuggestionReason? reason,
    $3.BeaconActivity? planActivity,
    $core.String? communityId,
    $core.String? communityName,
  }) {
    final result = MessageSuggestion._();
    if (user != null) result.user = user;
    if (reason != null) result.reason = reason;
    if (planActivity != null) result.planActivity = planActivity;
    if (communityId != null) result.communityId = communityId;
    if (communityName != null) result.communityName = communityName;
    return result;
  }

  MessageSuggestion._();

  factory MessageSuggestion.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessageSuggestion()..mergeFromBuffer(data, registry);
  factory MessageSuggestion.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MessageSuggestion()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MessageSuggestion',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: MessageSuggestion.$_createMessage)
    ..aOM<$0.AuthorSnapshot>(1, _omitFieldNames ? '' : 'user',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aE<MessageSuggestionReason>(2, _omitFieldNames ? '' : 'reason',
        enumValues: MessageSuggestionReason.values)
    ..aE<$3.BeaconActivity>(3, _omitFieldNames ? '' : 'planActivity',
        enumValues: $3.BeaconActivity.values)
    ..aOS(4, _omitFieldNames ? '' : 'communityId')
    ..aOS(5, _omitFieldNames ? '' : 'communityName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageSuggestion clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageSuggestion copyWith(void Function(MessageSuggestion) updates) =>
      super.copyWith((message) => updates(message as MessageSuggestion))
          as MessageSuggestion;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MessageSuggestion() / MessageSuggestion.new instead')
  static MessageSuggestion create() => MessageSuggestion._();
  static $pb.GeneratedMessage $_createMessage() => MessageSuggestion._();
  @$core.override
  MessageSuggestion createEmptyInstance() => MessageSuggestion._();
  @$core.pragma('dart2js:noInline')
  static MessageSuggestion getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MessageSuggestion>(
          MessageSuggestion.$_createMessage);
  static MessageSuggestion? _defaultInstance;

  /// Live row from identity (up to 60 s stale); is_private is set as on other live rows.
  @$pb.TagNumber(1)
  $0.AuthorSnapshot get user => $_getN(0);
  @$pb.TagNumber(1)
  set user($0.AuthorSnapshot value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.AuthorSnapshot ensureUser() => $_ensure(0);

  @$pb.TagNumber(2)
  MessageSuggestionReason get reason => $_getN(1);
  @$pb.TagNumber(2)
  set reason(MessageSuggestionReason value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasReason() => $_has(1);
  @$pb.TagNumber(2)
  void clearReason() => $_clearField(2);

  /// MET_ON_PLAN only: the plan's activity.
  @$pb.TagNumber(3)
  $3.BeaconActivity get planActivity => $_getN(2);
  @$pb.TagNumber(3)
  set planActivity($3.BeaconActivity value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasPlanActivity() => $_has(2);
  @$pb.TagNumber(3)
  void clearPlanActivity() => $_clearField(3);

  /// COMMUNITY_MEMBER only: the community (19-digit Snowflake) and its current name.
  @$pb.TagNumber(4)
  $core.String get communityId => $_getSZ(3);
  @$pb.TagNumber(4)
  set communityId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCommunityId() => $_has(3);
  @$pb.TagNumber(4)
  void clearCommunityId() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get communityName => $_getSZ(4);
  @$pb.TagNumber(5)
  set communityName($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCommunityName() => $_has(4);
  @$pb.TagNumber(5)
  void clearCommunityName() => $_clearField(5);
}

class ListMessageSuggestionsResponse extends $pb.GeneratedMessage {
  factory ListMessageSuggestionsResponse({
    $core.Iterable<MessageSuggestion>? suggestions,
  }) {
    final result = ListMessageSuggestionsResponse._();
    if (suggestions != null) result.suggestions.addAll(suggestions);
    return result;
  }

  ListMessageSuggestionsResponse._();

  factory ListMessageSuggestionsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessageSuggestionsResponse()..mergeFromBuffer(data, registry);
  factory ListMessageSuggestionsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMessageSuggestionsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMessageSuggestionsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListMessageSuggestionsResponse.$_createMessage)
    ..pPM<MessageSuggestion>(1, _omitFieldNames ? '' : 'suggestions',
        subBuilder: MessageSuggestion.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessageSuggestionsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMessageSuggestionsResponse copyWith(
          void Function(ListMessageSuggestionsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as ListMessageSuggestionsResponse))
          as ListMessageSuggestionsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMessageSuggestionsResponse() / ListMessageSuggestionsResponse.new instead')
  static ListMessageSuggestionsResponse create() =>
      ListMessageSuggestionsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListMessageSuggestionsResponse._();
  @$core.override
  ListMessageSuggestionsResponse createEmptyInstance() =>
      ListMessageSuggestionsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMessageSuggestionsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMessageSuggestionsResponse>(
          ListMessageSuggestionsResponse.$_createMessage);
  static ListMessageSuggestionsResponse? _defaultInstance;

  /// Source order (see ListMessageSuggestions); at most limit.
  @$pb.TagNumber(1)
  $pb.PbList<MessageSuggestion> get suggestions => $_getList(0);
}

class CommitConversationRequest extends $pb.GeneratedMessage {
  factory CommitConversationRequest({
    $core.String? idempotencyKey,
    $core.String? conversationId,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.List<$core.int>? commit,
    $core.List<$core.int>? welcome,
    $core.Iterable<$core.String>? welcomeDeviceIds,
    $core.bool? reset,
  }) {
    final result = CommitConversationRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (conversationId != null) result.conversationId = conversationId;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (commit != null) result.commit = commit;
    if (welcome != null) result.welcome = welcome;
    if (welcomeDeviceIds != null)
      result.welcomeDeviceIds.addAll(welcomeDeviceIds);
    if (reset != null) result.reset = reset;
    return result;
  }

  CommitConversationRequest._();

  factory CommitConversationRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommitConversationRequest()..mergeFromBuffer(data, registry);
  factory CommitConversationRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommitConversationRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommitConversationRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: CommitConversationRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'commit', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'welcome', $pb.PbFieldType.OY)
    ..pPS(7, _omitFieldNames ? '' : 'welcomeDeviceIds')
    ..aOB(8, _omitFieldNames ? '' : 'reset')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommitConversationRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommitConversationRequest copyWith(
          void Function(CommitConversationRequest) updates) =>
      super.copyWith((message) => updates(message as CommitConversationRequest))
          as CommitConversationRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CommitConversationRequest() / CommitConversationRequest.new instead')
  static CommitConversationRequest create() => CommitConversationRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      CommitConversationRequest._();
  @$core.override
  CommitConversationRequest createEmptyInstance() =>
      CommitConversationRequest._();
  @$core.pragma('dart2js:noInline')
  static CommitConversationRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CommitConversationRequest>(
          CommitConversationRequest.$_createMessage);
  static CommitConversationRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// An MLS conversation the caller is a participant of (32 lower-case hex).
  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);

  /// Normal commit: the pair the commit is built on (the current pair). Reset: mls_generation is the generation being
  /// replaced (the current one; else STALE_EPOCH) and mls_epoch is ignored.
  @$pb.TagNumber(3)
  $fixnum.Int64 get mlsGeneration => $_getI64(2);
  @$pb.TagNumber(3)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMlsGeneration() => $_has(2);
  @$pb.TagNumber(3)
  void clearMlsGeneration() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get mlsEpoch => $_getI64(3);
  @$pb.TagNumber(4)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMlsEpoch() => $_has(3);
  @$pb.TagNumber(4)
  void clearMlsEpoch() => $_clearField(4);

  /// The MLS commit, 1-16384 bytes. For a reset: the commit that creates the fresh group.
  @$pb.TagNumber(5)
  $core.List<$core.int> get commit => $_getN(4);
  @$pb.TagNumber(5)
  set commit($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCommit() => $_has(4);
  @$pb.TagNumber(5)
  void clearCommit() => $_clearField(5);

  /// The MLS Welcome for the devices the commit adds, 1-65536 bytes; empty when it adds none. Required with reset.
  @$pb.TagNumber(6)
  $core.List<$core.int> get welcome => $_getN(5);
  @$pb.TagNumber(6)
  set welcome($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasWelcome() => $_has(5);
  @$pb.TagNumber(6)
  void clearWelcome() => $_clearField(6);

  /// The devices the welcome is for: 1-10 distinct device ids, each an active registered device of a participant, set
  /// exactly when welcome is set. A reset must address at least one device of the PEER; the caller's other devices are
  /// optional (the sending device creates the group and needs no welcome). Each stored welcome replaces that device's
  /// earlier welcome for this conversation (at most one per conversation per device). Device ids, not user references.
  @$pb.TagNumber(7)
  $pb.PbList<$core.String> get welcomeDeviceIds => $_getList(6);

  /// Replace generation mls_generation (the current one) with generation + 1 at epoch 1 and a fresh group (a device
  /// that cannot recover). Conditional like a commit: a stale mls_generation is STALE_EPOCH. Limited per day.
  @$pb.TagNumber(8)
  $core.bool get reset => $_getBF(7);
  @$pb.TagNumber(8)
  set reset($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasReset() => $_has(7);
  @$pb.TagNumber(8)
  void clearReset() => $_clearField(8);
}

class CommitConversationResponse extends $pb.GeneratedMessage {
  factory CommitConversationResponse({
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
  }) {
    final result = CommitConversationResponse._();
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    return result;
  }

  CommitConversationResponse._();

  factory CommitConversationResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommitConversationResponse()..mergeFromBuffer(data, registry);
  factory CommitConversationResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommitConversationResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommitConversationResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: CommitConversationResponse.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommitConversationResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommitConversationResponse copyWith(
          void Function(CommitConversationResponse) updates) =>
      super.copyWith(
              (message) => updates(message as CommitConversationResponse))
          as CommitConversationResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CommitConversationResponse() / CommitConversationResponse.new instead')
  static CommitConversationResponse create() => CommitConversationResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      CommitConversationResponse._();
  @$core.override
  CommitConversationResponse createEmptyInstance() =>
      CommitConversationResponse._();
  @$core.pragma('dart2js:noInline')
  static CommitConversationResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CommitConversationResponse>(
          CommitConversationResponse.$_createMessage);
  static CommitConversationResponse? _defaultInstance;

  /// The new current pair: (generation, epoch + 1) after a commit, (generation + 1, 1) after a reset. On a replay, the
  /// current pair at the time of the retry, which may be later.
  @$pb.TagNumber(1)
  $fixnum.Int64 get mlsGeneration => $_getI64(0);
  @$pb.TagNumber(1)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMlsGeneration() => $_has(0);
  @$pb.TagNumber(1)
  void clearMlsGeneration() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get mlsEpoch => $_getI64(1);
  @$pb.TagNumber(2)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMlsEpoch() => $_has(1);
  @$pb.TagNumber(2)
  void clearMlsEpoch() => $_clearField(2);
}

/// One stored commit. Apply in the order returned.
class ConversationCommit extends $pb.GeneratedMessage {
  factory ConversationCommit({
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.List<$core.int>? commit,
    $core.bool? fromSelf,
    $1.Timestamp? createdAt,
  }) {
    final result = ConversationCommit._();
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (commit != null) result.commit = commit;
    if (fromSelf != null) result.fromSelf = fromSelf;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  ConversationCommit._();

  factory ConversationCommit.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConversationCommit()..mergeFromBuffer(data, registry);
  factory ConversationCommit.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConversationCommit()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConversationCommit',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ConversationCommit.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'commit', $pb.PbFieldType.OY)
    ..aOB(4, _omitFieldNames ? '' : 'fromSelf')
    ..aOM<$1.Timestamp>(5, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConversationCommit clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConversationCommit copyWith(void Function(ConversationCommit) updates) =>
      super.copyWith((message) => updates(message as ConversationCommit))
          as ConversationCommit;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ConversationCommit() / ConversationCommit.new instead')
  static ConversationCommit create() => ConversationCommit._();
  static $pb.GeneratedMessage $_createMessage() => ConversationCommit._();
  @$core.override
  ConversationCommit createEmptyInstance() => ConversationCommit._();
  @$core.pragma('dart2js:noInline')
  static ConversationCommit getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ConversationCommit>(
          ConversationCommit.$_createMessage);
  static ConversationCommit? _defaultInstance;

  /// The pair the commit was built on; applying it moves the group to (mls_generation, mls_epoch + 1). Epoch 0 marks
  /// the commit that created a generation's group (mls_init for generation 1, a reset after that): a device that is not
  /// in that group joins through its Welcome instead of applying it.
  @$pb.TagNumber(1)
  $fixnum.Int64 get mlsGeneration => $_getI64(0);
  @$pb.TagNumber(1)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMlsGeneration() => $_has(0);
  @$pb.TagNumber(1)
  void clearMlsGeneration() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get mlsEpoch => $_getI64(1);
  @$pb.TagNumber(2)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMlsEpoch() => $_has(1);
  @$pb.TagNumber(2)
  void clearMlsEpoch() => $_clearField(2);

  /// The MLS commit bytes, opaque to the server.
  @$pb.TagNumber(3)
  $core.List<$core.int> get commit => $_getN(2);
  @$pb.TagNumber(3)
  set commit($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCommit() => $_has(2);
  @$pb.TagNumber(3)
  void clearCommit() => $_clearField(3);

  /// True when the calling USER sent it, from any of their devices (not only the calling device): a device still
  /// applies its own user's commits made on other devices. A device recognises its OWN accepted commit by comparing
  /// the bytes with its pending commit: it merges that pending commit and never processes the record. There is
  /// deliberately no sender uid.
  @$pb.TagNumber(4)
  $core.bool get fromSelf => $_getBF(3);
  @$pb.TagNumber(4)
  set fromSelf($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFromSelf() => $_has(3);
  @$pb.TagNumber(4)
  void clearFromSelf() => $_clearField(4);

  /// Server time the commit was stored.
  @$pb.TagNumber(5)
  $1.Timestamp get createdAt => $_getN(4);
  @$pb.TagNumber(5)
  set createdAt($1.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasCreatedAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearCreatedAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $1.Timestamp ensureCreatedAt() => $_ensure(4);
}

class ListConversationCommitsRequest extends $pb.GeneratedMessage {
  factory ListConversationCommitsRequest({
    $core.String? conversationId,
    $fixnum.Int64? afterGeneration,
    $fixnum.Int64? afterEpoch,
    $core.int? pageSize,
  }) {
    final result = ListConversationCommitsRequest._();
    if (conversationId != null) result.conversationId = conversationId;
    if (afterGeneration != null) result.afterGeneration = afterGeneration;
    if (afterEpoch != null) result.afterEpoch = afterEpoch;
    if (pageSize != null) result.pageSize = pageSize;
    return result;
  }

  ListConversationCommitsRequest._();

  factory ListConversationCommitsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationCommitsRequest()..mergeFromBuffer(data, registry);
  factory ListConversationCommitsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationCommitsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListConversationCommitsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListConversationCommitsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'conversationId')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'afterGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'afterEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aI(4, _omitFieldNames ? '' : 'pageSize')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationCommitsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationCommitsRequest copyWith(
          void Function(ListConversationCommitsRequest) updates) =>
      super.copyWith(
              (message) => updates(message as ListConversationCommitsRequest))
          as ListConversationCommitsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListConversationCommitsRequest() / ListConversationCommitsRequest.new instead')
  static ListConversationCommitsRequest create() =>
      ListConversationCommitsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListConversationCommitsRequest._();
  @$core.override
  ListConversationCommitsRequest createEmptyInstance() =>
      ListConversationCommitsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListConversationCommitsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListConversationCommitsRequest>(
          ListConversationCommitsRequest.$_createMessage);
  static ListConversationCommitsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get conversationId => $_getSZ(0);
  @$pb.TagNumber(1)
  set conversationId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  /// Exclusive lower bound: the pair of the last commit the device applied ((0, 0) for everything still stored).
  @$pb.TagNumber(2)
  $fixnum.Int64 get afterGeneration => $_getI64(1);
  @$pb.TagNumber(2)
  set afterGeneration($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAfterGeneration() => $_has(1);
  @$pb.TagNumber(2)
  void clearAfterGeneration() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get afterEpoch => $_getI64(2);
  @$pb.TagNumber(3)
  set afterEpoch($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasAfterEpoch() => $_has(2);
  @$pb.TagNumber(3)
  void clearAfterEpoch() => $_clearField(3);

  /// 0 => 20; max 50 (clamped).
  @$pb.TagNumber(4)
  $core.int get pageSize => $_getIZ(3);
  @$pb.TagNumber(4)
  set pageSize($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageSize() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageSize() => $_clearField(4);
}

class ListConversationCommitsResponse extends $pb.GeneratedMessage {
  factory ListConversationCommitsResponse({
    $core.Iterable<ConversationCommit>? commits,
    $core.bool? more,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
  }) {
    final result = ListConversationCommitsResponse._();
    if (commits != null) result.commits.addAll(commits);
    if (more != null) result.more = more;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    return result;
  }

  ListConversationCommitsResponse._();

  factory ListConversationCommitsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationCommitsResponse()..mergeFromBuffer(data, registry);
  factory ListConversationCommitsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListConversationCommitsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListConversationCommitsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListConversationCommitsResponse.$_createMessage)
    ..pPM<ConversationCommit>(1, _omitFieldNames ? '' : 'commits',
        subBuilder: ConversationCommit.$_createMessage)
    ..aOB(2, _omitFieldNames ? '' : 'more')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationCommitsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListConversationCommitsResponse copyWith(
          void Function(ListConversationCommitsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as ListConversationCommitsResponse))
          as ListConversationCommitsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListConversationCommitsResponse() / ListConversationCommitsResponse.new instead')
  static ListConversationCommitsResponse create() =>
      ListConversationCommitsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListConversationCommitsResponse._();
  @$core.override
  ListConversationCommitsResponse createEmptyInstance() =>
      ListConversationCommitsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListConversationCommitsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListConversationCommitsResponse>(
          ListConversationCommitsResponse.$_createMessage);
  static ListConversationCommitsResponse? _defaultInstance;

  /// Ascending by (generation, epoch).
  @$pb.TagNumber(1)
  $pb.PbList<ConversationCommit> get commits => $_getList(0);

  /// True when a full page was read and at least one commit is returned: call again after the last returned commit's
  /// pair.
  @$pb.TagNumber(2)
  $core.bool get more => $_getBF(1);
  @$pb.TagNumber(2)
  set more($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMore() => $_has(1);
  @$pb.TagNumber(2)
  void clearMore() => $_clearField(2);

  /// The conversation's current pair, read fresh; (0, 0) for a NONE conversation.
  @$pb.TagNumber(3)
  $fixnum.Int64 get mlsGeneration => $_getI64(2);
  @$pb.TagNumber(3)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMlsGeneration() => $_has(2);
  @$pb.TagNumber(3)
  void clearMlsGeneration() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get mlsEpoch => $_getI64(3);
  @$pb.TagNumber(4)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMlsEpoch() => $_has(3);
  @$pb.TagNumber(4)
  void clearMlsEpoch() => $_clearField(4);
}

class ListEpochMessagesRequest extends $pb.GeneratedMessage {
  factory ListEpochMessagesRequest({
    $core.String? conversationId,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListEpochMessagesRequest._();
    if (conversationId != null) result.conversationId = conversationId;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListEpochMessagesRequest._();

  factory ListEpochMessagesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListEpochMessagesRequest()..mergeFromBuffer(data, registry);
  factory ListEpochMessagesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListEpochMessagesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListEpochMessagesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListEpochMessagesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'conversationId')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aI(4, _omitFieldNames ? '' : 'pageSize')
    ..aOS(5, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListEpochMessagesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListEpochMessagesRequest copyWith(
          void Function(ListEpochMessagesRequest) updates) =>
      super.copyWith((message) => updates(message as ListEpochMessagesRequest))
          as ListEpochMessagesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListEpochMessagesRequest() / ListEpochMessagesRequest.new instead')
  static ListEpochMessagesRequest create() => ListEpochMessagesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListEpochMessagesRequest._();
  @$core.override
  ListEpochMessagesRequest createEmptyInstance() =>
      ListEpochMessagesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListEpochMessagesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListEpochMessagesRequest>(
          ListEpochMessagesRequest.$_createMessage);
  static ListEpochMessagesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get conversationId => $_getSZ(0);
  @$pb.TagNumber(1)
  set conversationId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  /// The epoch to list, both >= 1.
  @$pb.TagNumber(2)
  $fixnum.Int64 get mlsGeneration => $_getI64(1);
  @$pb.TagNumber(2)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMlsGeneration() => $_has(1);
  @$pb.TagNumber(2)
  void clearMlsGeneration() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get mlsEpoch => $_getI64(2);
  @$pb.TagNumber(3)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMlsEpoch() => $_has(2);
  @$pb.TagNumber(3)
  void clearMlsEpoch() => $_clearField(3);

  /// 0 => 20; max 50 (clamped).
  @$pb.TagNumber(4)
  $core.int get pageSize => $_getIZ(3);
  @$pb.TagNumber(4)
  set pageSize($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageSize() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageSize() => $_clearField(4);

  /// next_page_token of the previous page; bound to the caller, the conversation and the pair.
  @$pb.TagNumber(5)
  $core.String get pageToken => $_getSZ(4);
  @$pb.TagNumber(5)
  set pageToken($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPageToken() => $_has(4);
  @$pb.TagNumber(5)
  void clearPageToken() => $_clearField(5);
}

class ListEpochMessagesResponse extends $pb.GeneratedMessage {
  factory ListEpochMessagesResponse({
    $core.Iterable<Message>? messages,
    $core.String? nextPageToken,
    $1.Timestamp? clearedAt,
  }) {
    final result = ListEpochMessagesResponse._();
    if (messages != null) result.messages.addAll(messages);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (clearedAt != null) result.clearedAt = clearedAt;
    return result;
  }

  ListEpochMessagesResponse._();

  factory ListEpochMessagesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListEpochMessagesResponse()..mergeFromBuffer(data, registry);
  factory ListEpochMessagesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListEpochMessagesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListEpochMessagesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListEpochMessagesResponse.$_createMessage)
    ..pPM<Message>(1, _omitFieldNames ? '' : 'messages',
        subBuilder: Message.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOM<$1.Timestamp>(3, _omitFieldNames ? '' : 'clearedAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListEpochMessagesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListEpochMessagesResponse copyWith(
          void Function(ListEpochMessagesResponse) updates) =>
      super.copyWith((message) => updates(message as ListEpochMessagesResponse))
          as ListEpochMessagesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListEpochMessagesResponse() / ListEpochMessagesResponse.new instead')
  static ListEpochMessagesResponse create() => ListEpochMessagesResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListEpochMessagesResponse._();
  @$core.override
  ListEpochMessagesResponse createEmptyInstance() =>
      ListEpochMessagesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListEpochMessagesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListEpochMessagesResponse>(
          ListEpochMessagesResponse.$_createMessage);
  static ListEpochMessagesResponse? _defaultInstance;

  /// Every message of that epoch, by message id (not time order); complete once the epoch is closed (it has a commit,
  /// or a later generation exists).
  @$pb.TagNumber(1)
  $pb.PbList<Message> get messages => $_getList(0);

  /// "" => no more messages of this epoch (as of now).
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// The caller's own DeleteConversation time for this conversation; unset when the caller never deleted it. A message
  /// with created_at at or before it is returned for completeness only: never show or store it (ListMessages hides the
  /// same messages). From the conversation's 60 s instance copy, like ListMessages' own filter.
  @$pb.TagNumber(3)
  $1.Timestamp get clearedAt => $_getN(2);
  @$pb.TagNumber(3)
  set clearedAt($1.Timestamp value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasClearedAt() => $_has(2);
  @$pb.TagNumber(3)
  void clearClearedAt() => $_clearField(3);
  @$pb.TagNumber(3)
  $1.Timestamp ensureClearedAt() => $_ensure(2);
}

/// A pending Welcome for one of the caller's devices.
class Welcome extends $pb.GeneratedMessage {
  factory Welcome({
    $core.String? id,
    $core.String? conversationId,
    $fixnum.Int64? mlsGeneration,
    $fixnum.Int64? mlsEpoch,
    $core.List<$core.int>? welcome,
    $1.Timestamp? createdAt,
  }) {
    final result = Welcome._();
    if (id != null) result.id = id;
    if (conversationId != null) result.conversationId = conversationId;
    if (mlsGeneration != null) result.mlsGeneration = mlsGeneration;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (welcome != null) result.welcome = welcome;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Welcome._();

  factory Welcome.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Welcome()..mergeFromBuffer(data, registry);
  factory Welcome.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Welcome()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Welcome',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: Welcome.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'conversationId')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'mlsGeneration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'welcome', $pb.PbFieldType.OY)
    ..aOM<$1.Timestamp>(6, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Welcome clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Welcome copyWith(void Function(Welcome) updates) =>
      super.copyWith((message) => updates(message as Welcome)) as Welcome;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Welcome() / Welcome.new instead')
  static Welcome create() => Welcome._();
  static $pb.GeneratedMessage $_createMessage() => Welcome._();
  @$core.override
  Welcome createEmptyInstance() => Welcome._();
  @$core.pragma('dart2js:noInline')
  static Welcome getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Welcome>(Welcome.$_createMessage);
  static Welcome? _defaultInstance;

  /// 32 lower-case hex; acknowledge with AckWelcomes.
  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  /// The conversation the welcome joins (32 lower-case hex).
  @$pb.TagNumber(2)
  $core.String get conversationId => $_getSZ(1);
  @$pb.TagNumber(2)
  set conversationId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConversationId() => $_has(1);
  @$pb.TagNumber(2)
  void clearConversationId() => $_clearField(2);

  /// The pair the accompanying commit was BUILT ON, not the pair the device joins at: (1, 0) for an mls_init,
  /// (g + 1, 0) for a reset of generation g, (g, e) for a commit built on (g, e). The device joins at
  /// (mls_generation, mls_epoch + 1) and passes this pair as its after-pair to ListConversationCommits.
  @$pb.TagNumber(3)
  $fixnum.Int64 get mlsGeneration => $_getI64(2);
  @$pb.TagNumber(3)
  set mlsGeneration($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMlsGeneration() => $_has(2);
  @$pb.TagNumber(3)
  void clearMlsGeneration() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get mlsEpoch => $_getI64(3);
  @$pb.TagNumber(4)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMlsEpoch() => $_has(3);
  @$pb.TagNumber(4)
  void clearMlsEpoch() => $_clearField(4);

  /// The MLS Welcome bytes, opaque to the server.
  @$pb.TagNumber(5)
  $core.List<$core.int> get welcome => $_getN(4);
  @$pb.TagNumber(5)
  set welcome($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasWelcome() => $_has(4);
  @$pb.TagNumber(5)
  void clearWelcome() => $_clearField(5);

  /// Server time the welcome was stored. It is kept at least 30 days after it and may be deleted at any time after
  /// that (deletion is not immediate).
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

class ListWelcomesRequest extends $pb.GeneratedMessage {
  factory ListWelcomesRequest({
    $core.String? deviceId,
    $core.int? pageSize,
  }) {
    final result = ListWelcomesRequest._();
    if (deviceId != null) result.deviceId = deviceId;
    if (pageSize != null) result.pageSize = pageSize;
    return result;
  }

  ListWelcomesRequest._();

  factory ListWelcomesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListWelcomesRequest()..mergeFromBuffer(data, registry);
  factory ListWelcomesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListWelcomesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListWelcomesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListWelcomesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'deviceId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListWelcomesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListWelcomesRequest copyWith(void Function(ListWelcomesRequest) updates) =>
      super.copyWith((message) => updates(message as ListWelcomesRequest))
          as ListWelcomesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use ListWelcomesRequest() / ListWelcomesRequest.new instead')
  static ListWelcomesRequest create() => ListWelcomesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListWelcomesRequest._();
  @$core.override
  ListWelcomesRequest createEmptyInstance() => ListWelcomesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListWelcomesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListWelcomesRequest>(
          ListWelcomesRequest.$_createMessage);
  static ListWelcomesRequest? _defaultInstance;

  /// One of the caller's own registered devices.
  @$pb.TagNumber(1)
  $core.String get deviceId => $_getSZ(0);
  @$pb.TagNumber(1)
  set deviceId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDeviceId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDeviceId() => $_clearField(1);

  /// 0 or negative => 10; max 10 (clamped).
  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);
}

class ListWelcomesResponse extends $pb.GeneratedMessage {
  factory ListWelcomesResponse({
    $core.Iterable<Welcome>? welcomes,
    $core.bool? more,
  }) {
    final result = ListWelcomesResponse._();
    if (welcomes != null) result.welcomes.addAll(welcomes);
    if (more != null) result.more = more;
    return result;
  }

  ListWelcomesResponse._();

  factory ListWelcomesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListWelcomesResponse()..mergeFromBuffer(data, registry);
  factory ListWelcomesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListWelcomesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListWelcomesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: ListWelcomesResponse.$_createMessage)
    ..pPM<Welcome>(1, _omitFieldNames ? '' : 'welcomes',
        subBuilder: Welcome.$_createMessage)
    ..aOB(2, _omitFieldNames ? '' : 'more')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListWelcomesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListWelcomesResponse copyWith(void Function(ListWelcomesResponse) updates) =>
      super.copyWith((message) => updates(message as ListWelcomesResponse))
          as ListWelcomesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListWelcomesResponse() / ListWelcomesResponse.new instead')
  static ListWelcomesResponse create() => ListWelcomesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListWelcomesResponse._();
  @$core.override
  ListWelcomesResponse createEmptyInstance() => ListWelcomesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListWelcomesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListWelcomesResponse>(
          ListWelcomesResponse.$_createMessage);
  static ListWelcomesResponse? _defaultInstance;

  /// By welcome id (ids are hashes, so not time order). At most one per conversation: the server keeps only the newest
  /// welcome per conversation per device.
  @$pb.TagNumber(1)
  $pb.PbList<Welcome> get welcomes => $_getList(0);

  /// True when a full page was returned: acknowledge, then call again.
  @$pb.TagNumber(2)
  $core.bool get more => $_getBF(1);
  @$pb.TagNumber(2)
  set more($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMore() => $_has(1);
  @$pb.TagNumber(2)
  void clearMore() => $_clearField(2);
}

class AckWelcomesRequest extends $pb.GeneratedMessage {
  factory AckWelcomesRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
    $core.Iterable<$core.String>? ids,
  }) {
    final result = AckWelcomesRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    if (ids != null) result.ids.addAll(ids);
    return result;
  }

  AckWelcomesRequest._();

  factory AckWelcomesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AckWelcomesRequest()..mergeFromBuffer(data, registry);
  factory AckWelcomesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AckWelcomesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AckWelcomesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: AckWelcomesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..pPS(3, _omitFieldNames ? '' : 'ids')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckWelcomesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckWelcomesRequest copyWith(void Function(AckWelcomesRequest) updates) =>
      super.copyWith((message) => updates(message as AckWelcomesRequest))
          as AckWelcomesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AckWelcomesRequest() / AckWelcomesRequest.new instead')
  static AckWelcomesRequest create() => AckWelcomesRequest._();
  static $pb.GeneratedMessage $_createMessage() => AckWelcomesRequest._();
  @$core.override
  AckWelcomesRequest createEmptyInstance() => AckWelcomesRequest._();
  @$core.pragma('dart2js:noInline')
  static AckWelcomesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AckWelcomesRequest>(
          AckWelcomesRequest.$_createMessage);
  static AckWelcomesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// One of the caller's own registered devices.
  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);

  /// 1-50 welcome ids (Welcome.id).
  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get ids => $_getList(2);
}

class AckWelcomesResponse extends $pb.GeneratedMessage {
  factory AckWelcomesResponse() => AckWelcomesResponse._();

  AckWelcomesResponse._();

  factory AckWelcomesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AckWelcomesResponse()..mergeFromBuffer(data, registry);
  factory AckWelcomesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AckWelcomesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AckWelcomesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.messaging.v1'),
      createEmptyInstance: AckWelcomesResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckWelcomesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckWelcomesResponse copyWith(void Function(AckWelcomesResponse) updates) =>
      super.copyWith((message) => updates(message as AckWelcomesResponse))
          as AckWelcomesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use AckWelcomesResponse() / AckWelcomesResponse.new instead')
  static AckWelcomesResponse create() => AckWelcomesResponse._();
  static $pb.GeneratedMessage $_createMessage() => AckWelcomesResponse._();
  @$core.override
  AckWelcomesResponse createEmptyInstance() => AckWelcomesResponse._();
  @$core.pragma('dart2js:noInline')
  static AckWelcomesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AckWelcomesResponse>(
          AckWelcomesResponse.$_createMessage);
  static AckWelcomesResponse? _defaultInstance;
}

class MessagingServiceApi {
  final $pb.RpcClient _client;

  MessagingServiceApi(this._client);

  /// Send a text message, opening the conversation if needed. Target: recipient_user_id (opens or continues the 1:1
  /// conversation with that user; self => VALIDATION "recipient_user_id"; [A-Za-z0-9-]{1,128}) or conversation_id (an
  /// existing conversation the caller is a participant of, else NOT_FOUND).
  /// text: the post grammar (NFC, <= 280 code points, <= 10 lines; testdata fixtures), validated before any read
  /// (VALIDATION "text").
  /// Flag: per caller AND per recipient. Caller off => FEATURE_DISABLED; recipient off => CANNOT_MESSAGE.
  /// The caller needs a verified email (FAILED_PRECONDITION EMAIL_NOT_VERIFIED, before any lookup), as for posts.
  /// Refusals, all CANNOT_MESSAGE with identical bytes: either side blocks the other (the caller's graph
  /// snapshot, cached 60 s, and the recipient's graph read inside the send transaction, so the recipient's Block applies
  /// at once on every instance),
  /// the recipient is not ACTIVE or has messaging off, the conversation is gone (the peer deleted the account).
  /// Routing: a new conversation is ACCEPTED when the two follow each other, else REQUEST (the recipient's entry goes
  /// to REQUESTS). While REQUEST, the requester may send MESSAGES_REQUEST_MAX_UNANSWERED (3) messages, then
  /// LIMIT_REACHED "request_unanswered"; a message from the recipient of the request accepts it (as on X). The
  /// recipient muted the caller => delivered silently (no unread increment, no push).
  /// Idempotency (the bend of rules 1 and 4): the message id is the first 32 hex characters
  /// of SHA-256(sender auth uid || "|SendMessage|" || idempotency_key) (ASCII, lower-case hex), and Created in the send
  /// transaction, so a retry returns the stored message and writes nothing; the same key with a different body =>
  /// VALIDATION "idempotency_key". Idempotency keys must carry at least 128 random bits. Clients dedupe by message id.
  /// Caps: RATE_LIMIT_MESSAGES_SEND_PER_MIN 20/min/uid per instance (60/min at 3 instances);
  /// MESSAGES_SENDS_PER_DAY 300 (50 for new accounts) per instance (<= 900/day at 3) => RATE_LIMITED metadata["limit"]
  /// = "messages_daily"; QUOTA_DM_NEW_CONVERSATIONS_PER_DAY 20 new conversations per IST day (5 for new accounts),
  /// exact (quotas/{uid}.dmNew, in the transaction, the one persisted daily counter left besides reports) => LIMIT_REACHED "dm_new_daily"; MESSAGES_REQUEST_MAX_UNANSWERED 3,
  /// exact (conversations.requestCount, in the transaction).
  /// Push: after the commit one `message` event through notifications.Emitter (one Pub/Sub publish, 0 Firestore on
  /// this path), only when the recipient's side is accepted and not silent; a request never pushes. The push is
  /// generic ("New message") and carries only the conversation id (NOTIFICATION_TYPE_MESSAGE).
  /// A refused send writes nothing.
  /// Sharing a post (shared_post_id set): every rule above applies unchanged (blocks, DM policy, requests, caps, push).
  /// In addition, before the send transaction and after the recipient checks:
  /// - Flag FEATURE_DM_POST_SHARE (wire name "dm_post_share"): on for the caller (else FAILED_PRECONDITION +
  ///   FEATURE_DISABLED, metadata["feature"] = "dm_post_share", before any lookup); FEATURE_POSTS must be on.
  /// - shared_post_id: 19 digits (else VALIDATION "shared_post_id", before any lookup). A REPOST id shares its original;
  ///   the stored and returned id is the original's.
  /// - The post must be visible to the caller by the GetPost rules (missing, deleted, hidden, suspended or deleting
  ///   author, an author who blocks the caller, a QUOTE or REPOST whose embedded author blocks the caller), and by the
  ///   card's rule: no block in either direction, so a caller who blocked the author (or a QUOTE's embedded author) may
  ///   not send it either. Every case => NOT_FOUND "post not found", byte-identical to GetPost, writing nothing.
  /// - Protected authors: a post by a protected account may be sent only by that account (the RepostPost rule); any
  ///   other caller who can see it => FAILED_PRECONDITION + PROTECTED_ACCOUNT, writing nothing.
  /// - The client sends a text even without a caption: the canonical post URL (so a client that predates the card shows a
  ///   link that opens through GetPost). A client that renders shared_post hides a text equal to that URL.
  /// - Idempotency: shared_post_id is part of the request body, so the same key with a different post => VALIDATION
  ///   "idempotency_key", like a different text.
  /// - The message document stores the post id only, never a copy of the post: Message.shared_post is decided for each
  ///   reader at read time (ListMessages). The inbox preview never carries post text (MessagePreview.shared_post).
  /// - After the commit (never for a replay or a refusal, and never inside the send transaction, so a hot post cannot
  ///   abort a DM) the share is recorded once per (caller, post) for Post.share_count when FEATURE_SHARE_COUNT is not
  ///   globally off and the caller is not the post's author: best effort, a failure is logged and never fails the send.
  /// Worst case added by a share: the post visibility check (cache-first: the post, its author's status, the caller's
  /// graph already read, the protected set; 0-3 reads), then on a first share by this caller of this post 1 read
  /// (postShares marker) + 2 writes (marker Create, posts.shareCount Increment); 1 read and 0 writes otherwise.
  /// Encrypted messages (file comment, "End-to-end encryption"). A request with any of ciphertext, report_commitment,
  /// mls_generation, mls_epoch or mls_init set is an encrypted request:
  /// - Validation of the FORMAT of the encrypted fields, before any lookup: text and shared_post_id must be empty
  ///   (VALIDATION "text" / "shared_post_id"; the text and any shared post id travel inside the ciphertext as
  ///   MessageContent); ciphertext 1-8192 bytes (VALIDATION "ciphertext"); report_commitment exactly 32 bytes
  ///   (VALIDATION "report_commitment"); mls_generation and mls_epoch 1 to 2^63 - 1, and exactly (1, 1) with mls_init
  ///   (VALIDATION "mls_generation" / "mls_epoch"); with mls_init the MlsInit format rules (VALIDATION "commit",
  ///   "welcome" or "welcome_device_ids").
  /// - Order of answers: every existing refusal (verified email, NOT_FOUND, CANNOT_MESSAGE for gone, blocks, policy or
  ///   flag, LIMIT_REACHED, rate limits) keeps its order and bytes and comes first. Then, in this order and before any
  ///   write: the welcome-device (active) check (VALIDATION "welcome_device_ids"); ENCRYPTION_REQUIRED or VALIDATION
  ///   "ciphertext" (an encrypted send without mls_init into a NONE or new conversation), which cannot both apply;
  ///   STALE_EPOCH. Only the device check and STALE_EPOCH can both apply (on mls_init); the device check answers first.
  ///   A replay (the message of this idempotency_key already stored with the same request) wins over all of them.
  /// - Into an MLS conversation without mls_init: the pair must equal the conversation's current pair, compared inside
  ///   the send transaction, else STALE_EPOCH (current pair in metadata), storing nothing.
  /// - Into a NONE conversation, or opening a new one, without mls_init => VALIDATION "ciphertext".
  /// - A plaintext request (none of those fields) into an MLS conversation, by conversation_id or by recipient_user_id
  ///   => FAILED_PRECONDITION + ENCRYPTION_REQUIRED, storing nothing (entries and unread counts untouched).
  /// - STALE_EPOCH and ENCRYPTION_REQUIRED for a request that addressed recipient_user_id also carry
  ///   metadata["conversation_id"] (the caller is then a participant of that existing conversation), so the client can
  ///   continue by conversation id.
  /// - mls_init starts encryption: it creates the conversation as MLS (no conversation yet) or converts a NONE one (the
  ///   caller must be a participant; else the one NOT_FOUND). Flag e2ee_dm on for the caller (FEATURE_DISABLED
  ///   "e2ee_dm", before any lookup) and the recipient (CANNOT_MESSAGE). All existing send rules (blocks, DM policy,
  ///   requests and their cap, verified email, rate limits, dm_new_daily) apply unchanged and their refusals stay
  ///   byte-identical. In the transaction: a retried mls_init whose message already exists (same idempotency_key, same
  ///   request) is a replay and returns the stored message; any other mls_init that finds the conversation already MLS
  ///   => STALE_EPOCH with its pair (another device started first: join through ListWelcomes); else the conversation
  ///   becomes MLS at generation 1, epoch 1, the commit record (1, 0) is created with mls_init.commit, the welcomes are
  ///   stored (MlsInit), and the message is stored at (1, 1); all in the one send transaction, or none of it.
  ///   The retry is recognised inside the transaction, so the refusals before it still answer first: FEATURE_DISABLED
  ///   "e2ee_dm" if the caller has since lost the flag, CANNOT_MESSAGE if the recipient has (or blocked the caller),
  ///   although the message is stored. The client treats the init as possibly stored and checks ListMessages.
  /// - Stored and returned: text empty, ciphertext, report_commitment, the pair; no shared post id. The server cannot
  ///   check a shared post's visibility or the protected-author rule for an encrypted message: the sending app applies
  ///   them through CheckPostShare (and FEATURE_DM_POST_SHARE), the reader's app opens the card through
  ///   PostService.GetPost, which decides for the reader; Post.share_count does not count encrypted shares. Previews:
  ///   snippet empty, encrypted = true, shared_post false. Unread, silent, request routing and push are unchanged (the push carries no content).
  /// - Idempotency: unchanged rule, the message id derives from (caller, idempotency_key); the request identity of an
  ///   encrypted send covers the conversation, the pair, the ciphertext and the report commitment. A lost response is
  ///   retried with the SAME key and the IDENTICAL saved ciphertext, commitment and pair, and returns the stored message
  ///   even if the epoch has moved on since (a replay wins over STALE_EPOCH). The same key with a request differing in
  ///   any of them => VALIDATION "idempotency_key" as for a different text, except that a message a moderator took down
  ///   replays as its REMOVED tombstone (ciphertext_removed = true) whatever the request, as for plaintext. A
  ///   STALE_EPOCH refusal stores nothing, so the key is not consumed; the
  ///   message re-encrypted after it is a new request: send it with a NEW idempotency key (the client saves the new
  ///   bytes and key together before calling).
  /// - Cost: an encrypted send in an MLS conversation reads and writes exactly what a plaintext send does. "No
  ///   conversation write" holds only in an ACCEPTED conversation: in a REQUEST conversation the send still writes
  ///   requestCount, and a reply by the recipient that accepts the request still writes state, as for plaintext. A
  ///   refusal on an existing conversation (ENCRYPTION_REQUIRED, VALIDATION "ciphertext", STALE_EPOCH) adds 1 read,
  ///   the replay check of the message id. mls_init adds the device checks (at most 2 queries of at most 5 device
  ///   documents) and, in the transaction, at most 11 reads (the earlier welcome of each addressed device, to replace
  ///   it, and the (1, 0) commit record) and at most 2 + 20 = 22 more writes (the conversation's encryption fields, 0 when the send already creates
  ///   or updates the conversation; the commit record; per device one welcome and the delete of the earlier one).
  $async.Future<SendMessageResponse> sendMessage(
          $pb.ClientContext? ctx, SendMessageRequest request) =>
      _client.invoke<SendMessageResponse>(ctx, 'MessagingService',
          'SendMessage', request, SendMessageResponse());

  /// Answers whether the caller may share a post in a direct message, by the very rules SendMessage applies to
  /// shared_post_id (same function, same order, same bytes), without a recipient or a conversation and writing
  /// nothing. For an ENCRYPTED share the post id travels inside the ciphertext, so the sending app calls this once per
  /// share action before encrypting, and sends only on success. A plaintext share does not need it (SendMessage checks).
  /// Gates, in SendMessage's order, all before any lookup: "messaging" on for the caller; FEATURE_DM_SHARE_CHECK
  /// ("dm_share_check") on for the caller; a verified email (EMAIL_NOT_VERIFIED); "posts" and "dm_post_share" on for the
  /// caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = the off flag); post_id 19 digits (VALIDATION
  /// "post_id").
  /// Answers, byte-identical to SendMessage with shared_post_id except one: a raw read failure (a timeout or contention
  /// reading the post or the directory) is INTERNAL here (SendMessage: UNAVAILABLE "busy, please retry"), so the client's
  /// automatic retry of NO_SIDE_EFFECTS calls on UNAVAILABLE does not fire on it. NOT_FOUND "post not found" when the caller may not see
  /// the post by the GetPost rules or a block stands either way between the caller and its author (or a QUOTE's or the
  /// REPOST original's embedded author); FAILED_PRECONDITION + PROTECTED_ACCOUNT for a protected author's post shared by
  /// anyone else; UNAVAILABLE "temporarily busy, please retry" when the protected set cannot be read. A REPOST id is
  /// checked on itself and on its original, and shared_post_id names the original.
  /// Success is not a promise: the post or the graph can change before the send; the reader's app decides the card again.
  /// Rate limit: RATE_LIMIT_MESSAGES_SHARE_CHECK_PER_MIN 10/min/uid per instance; MESSAGES_SHARE_CHECKS_PER_DAY 300 per
  /// instance (RATE_LIMITED metadata["limit"] = "messages_share_checks_daily"). Answers under DEGRADED_MODE=readonly.
  /// Cost: SendMessage's share check, cache-first: 0-3 reads (the post and, for a REPOST, its original; author status
  /// through the directory, 60 s; caller graph, 60 s; the protected set). Writes nothing; never records a share.
  $async.Future<CheckPostShareResponse> checkPostShare(
          $pb.ClientContext? ctx, CheckPostShareRequest request) =>
      _client.invoke<CheckPostShareResponse>(ctx, 'MessagingService',
          'CheckPostShare', request, CheckPostShareResponse());

  /// The caller's conversations in one folder, most recent activity first. The path comes from the caller's token;
  /// there is no user id parameter. folder must be INBOX or REQUESTS, else VALIDATION "folder".
  /// Read-time rules (caller graph, cached 60 s): REQUESTS drops entries whose peer the caller blocks or mutes, or who
  /// blocks the caller (a caller past the blockedBy cap also checks each REQUESTS peer's graph, cached 60 s); INBOX
  /// keeps every entry, with can_reply = false when either side blocks. Filtering runs after
  /// the page query, so a page may be short or empty while next_page_token is non-empty: keep following it.
  /// request_count is set on every INBOX first page and since refresh (an empty refresh included); 0 on an older page and
  /// on REQUESTS. Clients treat the INBOX value as authoritative, 0 included.
  /// There is no gap_page_token here: a since refresh returns at most page_size entries.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListMessages.
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
  /// Client polling: only on a visible thread; web 15 s while hot, Android 30 s while hot, 45 s while
  /// quiet, stopped after 5 min idle or when hidden; a push for the conversation triggers an immediate pull; a
  /// RATE_LIMITED answer pauses polling.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListConversations.
  /// Shared posts: every returned VISIBLE message that carries a post gets Message.shared_post, decided for the CALLER
  /// (the reader, sender or recipient alike) by the GetPost rules at read time, on every page kind including a since
  /// poll. Only the page's shared post ids are hydrated, in one batched cache-first read (posts.GetMany: at most one
  /// read per distinct post not in the instance cache, plus its author's status through the identity directory, 60 s);
  /// the caller's graph snapshot (60 s) is read only when the page carries a shared post; a caller past the blockedBy
  /// cap also consults each card author's graph (60 s, at most one per distinct author), as GetPost does. A since poll with no new
  /// shared post therefore still reads no post, profile or graph. While FEATURE_DM_POST_SHARE is globally off every
  /// card is the unavailable form.
  $async.Future<ListMessagesResponse> listMessages(
          $pb.ClientContext? ctx, ListMessagesRequest request) =>
      _client.invoke<ListMessagesResponse>(ctx, 'MessagingService',
          'ListMessages', request, ListMessagesResponse());

  /// Marks the conversation read for the caller: unread count 0 and the read time on the caller's own entry (a field
  /// update with an Exists precondition). The read time (last_read_at) is never shown to the peer. When the caller's "Read
  /// receipts" setting is on (identity Profile.read_receipts, FEATURE_READ_RECEIPTS on for the caller; read from the 60 s
  /// profile cache, no extra Firestore read) the same update also stores read_receipt_at on the caller's entry, which the
  /// peer can see as Conversation.peer_read_at only while both sides have receipts on (F3: opt-in, reciprocal, never
  /// retroactive: a read made while the setting was off stores no receipt). A missing
  /// entry (unknown id, non-participant, deleted for the caller) => success, writing nothing. Evicts the caller's
  /// unread_conversation_count cache on this instance. Call only when the client holds unread_count > 0.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  $async.Future<MarkConversationReadResponse> markConversationRead(
          $pb.ClientContext? ctx, MarkConversationReadRequest request) =>
      _client.invoke<MarkConversationReadResponse>(ctx, 'MessagingService',
          'MarkConversationRead', request, MarkConversationReadResponse());

  /// Accepts a message request: the conversation becomes ACCEPTED and the caller's entry moves from REQUESTS to INBOX
  /// (unread count kept). Only the recipient of the request may accept; the requester (or a non-participant) gets
  /// NOT_FOUND. Already accepted => success, writing nothing. Emits nothing.
  /// Flag: per caller AND per recipient (the peer); peer off => CANNOT_MESSAGE. Refused under DEGRADED_MODE=readonly.
  /// The caller needs a verified email (FAILED_PRECONDITION EMAIL_NOT_VERIFIED, before any lookup), as for posts.
  /// Accepting updates the conversation state, the dmInbox entry and the requester's entry (request flag cleared,
  /// changedAt moved; skipped when the requester deleted that entry), and deletes the dmRequests entry.
  $async.Future<AcceptMessageRequestResponse> acceptMessageRequest(
          $pb.ClientContext? ctx, AcceptMessageRequestRequest request) =>
      _client.invoke<AcceptMessageRequestResponse>(ctx, 'MessagingService',
          'AcceptMessageRequest', request, AcceptMessageRequestResponse());

  /// Deletes the conversation for the caller only (also "delete request"): removes the caller's entry from either
  /// folder and hides every message up to now from the caller. The peer keeps the conversation. A deleted request stays
  /// a REQUEST for the sender, whose cap still applies; a later message recreates the caller's entry showing only newer
  /// messages. Blocking from a thread uses GraphService.Block and does not delete the conversation.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  /// Sets clearedAt on the conversation and deletes the caller's entry.
  $async.Future<DeleteConversationResponse> deleteConversation(
          $pb.ClientContext? ctx, DeleteConversationRequest request) =>
      _client.invoke<DeleteConversationResponse>(ctx, 'MessagingService',
          'DeleteConversation', request, DeleteConversationResponse());

  /// People the caller is likely to message (F30), for the new-message screen. Computed on every call; nothing is stored.
  /// Sources, in this order (a person appears once, with the first reason that found them):
  /// 1. RECENT_CONVERSATION: the peers of the caller's newest 8 INBOX entries.
  /// 2. MET_ON_PLAN: the organiser and ACCEPTED participants of the caller's 2 most recent ended plans (FEATURE_BEACONS on
  ///    for the caller; the caller was the organiser or ACCEPTED; not hidden; ended within the last 30 days, the
  ///    beacons TTL), at most 4 rows read per plan. plan_activity is that plan's activity.
  /// 3. MUTUAL_FOLLOW: among the caller's 10 newest followees, those who follow the caller back.
  /// 4. COMMUNITY_MEMBER: the 6 newest JOINED members of the community the caller joined most recently (FEATURE_COMMUNITIES
  ///    on for the caller; an ACTIVE community). community_id and community_name name it.
  /// Every row is someone SendMessage would not refuse with CANNOT_MESSAGE at the time of the call, by the same rules:
  /// never the caller; not ACTIVE, messaging off for them, either side blocks the other (the caller's 60 s graph snapshot),
  /// or their "who can message me" policy is FOLLOWING_ONLY (with FEATURE_DM_POLICY on for them) and they do not follow
  /// the caller (an existing ACCEPTED conversation is exempt, as on send) => left out. Accounts the caller mutes are left
  /// out too. A caller past the blockedBy cap gets an empty list (fail closed). The reason chip is computed, never stored.
  /// limit 0 => 10, max 20 (clamped); negative => VALIDATION "limit". No pagination, by design (the ListSuggestedUsers
  /// precedent): one bounded call, no page token.
  /// Flags: "messaging" and "dm_suggestions" on for the caller (file comment). Rate limit: RATE_LIMIT_DM_SUGGESTIONS_PER_MIN
  /// 10/min/uid per instance; no daily cap. Answers under DEGRADED_MODE=readonly.
  /// Cost: at most 8 + 2 + 2 + 8 + 1 + 6 = 27 documents from the sources (inbox entries, plan memberships, plans,
  /// participant rows, community memberships, community members; the community doc is cached 60 s), then cache-first
  /// profile and follow-edge reads for at most 20 candidates (60 s caches). Writes nothing.
  $async.Future<ListMessageSuggestionsResponse> listMessageSuggestions(
          $pb.ClientContext? ctx, ListMessageSuggestionsRequest request) =>
      _client.invoke<ListMessageSuggestionsResponse>(ctx, 'MessagingService',
          'ListMessageSuggestions', request, ListMessageSuggestionsResponse());

  /// Store an MLS commit for an encrypted conversation and advance its epoch, or reset the group (file comment,
  /// "Ordering"). A commit changes the group (adds or removes devices, renews keys); it is a record, not a message.
  /// Flag: "messaging" on for the caller (per caller, as SendMessage's caller check; the peer's flag is not checked;
  /// FEATURE_DISABLED before any lookup); e2ee_dm is not needed.
  /// The caller needs a verified email (EMAIL_NOT_VERIFIED, before any lookup). Refused under DEGRADED_MODE=readonly.
  /// Answers, in this order (nothing is written on any refusal):
  /// 0. The per-minute bucket and the per-user daily call cap "messages_commits_daily" (below) are applied by the
  ///    interceptor before the service runs, before the flag, so a retry counts against them like any call.
  /// 1. After the flag and the verified email, before any lookup: idempotency_key format and conversation_id (32
  ///    lower-case hex), VALIDATION; the pair's form: mls_generation 1 to 2^63 - 2, and mls_epoch 1 to 2^63 - 1 unless
  ///    reset (VALIDATION "mls_generation" / "mls_epoch"). Then, still before any lookup, the per-(caller, conversation)
  ///    cap "messages_commits_per_conversation_daily" (every call, a reset included), then for a reset the reset cap
  ///    "messages_resets_daily": a malformed call burns neither; a retry and a call later refused count against both;
  ///    the per-conversation cap is keyed by the conversation id as sent, so it answers the same for an unknown
  ///    conversation, one the caller is not in and a real one.
  /// 2. Existing refusals: an unknown conversation or a non-participant => the one NOT_FOUND; a NONE conversation =>
  ///    VALIDATION "conversation_id" (start encryption with SendMessage mls_init); a conversation whose peer is gone, or
  ///    a block in either direction (the recipient's graph read in the transaction, as a send) => CANNOT_MESSAGE,
  ///    byte-identical to SendMessage's. Only these refuse: unlike SendMessage, a commit or reset is NOT refused because
  ///    the peer is not ACTIVE or has messaging off, by the peer's who-can-message policy, or because the conversation is
  ///    still a REQUEST (the request cap counts messages, not commits). The CANNOT_MESSAGE bytes are SendMessage's. What
  ///    bounds a commit into such a conversation is the per-conversation cap (20 a day per caller, above).
  /// 3. Retry recognition: a commit whose record for its pair (for a reset: (mls_generation + 1, 0)) already exists from
  ///    the same user with identical commit bytes is a retry: it returns the current pair (possibly later than
  ///    (generation, epoch + 1) by then) and writes nothing, before every check below. A record for that pair with other
  ///    bytes or from the other user is not a retry: the request goes on to 4 and 5 (at the latest STALE_EPOCH).
  /// 4. Field validation: commit 1-16384 bytes (VALIDATION "commit"); welcome at most 65536 bytes (VALIDATION
  ///    "welcome"); welcome and welcome_device_ids go together and the ids are 1-10, distinct, well-formed (VALIDATION
  ///    "welcome_device_ids"); a reset requires both (VALIDATION "welcome_device_ids"). Then the welcome-device
  ///    (active) check, which runs during the transaction, after the conversation read that names the peer (its
  ///    key-directory reads are not transactional): each device must be an
  ///    active registered device of the caller or the peer, and a reset must address at least one device of the PEER
  ///    (the caller's other devices are optional; the sending device creates the group and needs no welcome), else
  ///    VALIDATION "welcome_device_ids" without saying which.
  /// 5. The pair: STALE_EPOCH with the current pair.
  /// Normal commit: (mls_generation, mls_epoch) is the pair it is built on and must be the current pair; the commit
  /// record for that pair is created (the first accepted wins: a second commit on the same pair is STALE_EPOCH) and the
  /// conversation moves to (generation, epoch + 1).
  /// Reset (reset = true): used when a device cannot recover (see the file comment, "Catch-up"). mls_generation names
  /// the generation being REPLACED and mls_epoch is ignored; it must be the current generation, else STALE_EPOCH with
  /// the current pair (a device that knows nothing reads it from ListConversationCommits). The server creates the
  /// commit record (generation + 1, 0) and the welcomes of the fresh group, and the conversation moves to
  /// (generation + 1, 1). Two resets of the same generation: the first wins, the other is STALE_EPOCH. A reset SHOULD
  /// address every active key device of both users the resetter can obtain a key package for (its own other devices
  /// included). Every device shows "Encryption was reset". Limited per day (below).
  /// Welcomes: one per welcome_device_ids entry, stored for that device with the commit's pair, replacing that device's
  /// earlier welcome for this conversation (file comment, "Welcomes"), delivered by ListWelcomes, kept at least 30 days
  /// after creation and may be deleted at any time after that (deletion is not immediate; a client must not rely on an
  /// old welcome or commit having disappeared).
  /// Neither a commit nor a reset changes rev or any message, and no since_token is retired by them.
  /// Idempotency: the commit record's pair is the natural key (3. above); idempotency_key is format-checked only.
  /// Caps: RATE_LIMIT_MESSAGES_COMMIT_PER_MIN 20/min/uid per instance; daily caps per instance MESSAGES_COMMITS_PER_DAY
  /// 500 per user (metadata["limit"] = "messages_commits_daily"), MESSAGES_COMMITS_PER_CONVERSATION_PER_DAY 20 per
  /// caller and conversation ("messages_commits_per_conversation_daily") and MESSAGES_RESETS_PER_DAY 10 per user
  /// ("messages_resets_daily"); a reset counts against all three. Order in step 0 and 1 above. RATE_LIMITED, honour
  /// retry_after (the next IST day for a daily cap).
  /// Cost: one transaction reads the conversation (which names the peer for the device check), the recipient graph,
  /// the commit record (retry recognition) and at most 10 earlier welcomes = at most 13 reads; the device check runs
  /// during the transaction, after the conversation read, and adds at most 2 queries of at most 5 device documents
  /// through the key directory, whose reads are not transactional; at most 2 + 20 writes (the conversation's pair, the
  /// commit record, per device one welcome and the delete of the earlier one). Emits nothing; no push.
  $async.Future<CommitConversationResponse> commitConversation(
          $pb.ClientContext? ctx, CommitConversationRequest request) =>
      _client.invoke<CommitConversationResponse>(ctx, 'MessagingService',
          'CommitConversation', request, CommitConversationResponse());

  /// Commits of an encrypted conversation after a given pair, ascending by (generation, epoch), plus the conversation's
  /// current pair read fresh (never the instance cache). This is how a device catches up after STALE_EPOCH, on app
  /// open, and after joining through a welcome.
  /// The commits and the current pair are read in ONE consistent snapshot (a read-only transaction), so "no commit
  /// returned while the current pair is ahead" is a real gap, never a race between two reads.
  /// after_generation, after_epoch: the device's after-pair (file comment, "Catch-up"): the pair of the last commit it
  /// applied (a commit's pair is the one it was built on), exclusive. A device that joined through a Welcome passes the
  /// welcome's pair; the creator of the mls_init passes (1, 0), the creator of a reset of generation g passes
  /// (g + 1, 0). (0, 0) lists everything still stored.
  /// Follows on, for a device whose after-pair is (g, e), so whose own epoch is (g, e + 1): the next commit must be
  /// (g, e + 1) (built on the device's epoch), or (g + 1, 0) when generation g was ended by a reset (the device then
  /// joins generation g + 1 through its welcome, it never applies an epoch-0 record). A gap is: the first commit
  /// returned is anything else (the needed one was deleted: commits are kept at least 30 days, then may be deleted at any time), or no commit is returned
  /// while the returned current pair is not (g, e + 1). What the device does then (join from a welcome, wait to be
  /// added, or reset) is in the file comment, "Catch-up".
  /// more = true when a full page was read and at least one commit is returned: call again with the last returned
  /// commit's pair. The current pair can be ahead of the last commit returned while more is true.
  /// Flag: "messaging" not globally off (a user dropped from an allowlist can still read). Participant check and the one
  /// NOT_FOUND as ListMessages; a NONE conversation answers an empty list with the pair (0, 0). Validation:
  /// conversation_id; page_size as the file comment. Rate limit: RATE_LIMIT_MESSAGES_SYNC_PER_MIN 60/min/uid per
  /// instance, shared with ListEpochMessages, ListWelcomes and AckWelcomes.
  /// Cost: one read-only transaction: 1 conversation read + 1 query of at most page_size (max 50) commit records.
  /// Writes nothing.
  $async.Future<ListConversationCommitsResponse> listConversationCommits(
          $pb.ClientContext? ctx, ListConversationCommitsRequest request) =>
      _client.invoke<ListConversationCommitsResponse>(
          ctx,
          'MessagingService',
          'ListConversationCommits',
          request,
          ListConversationCommitsResponse());

  /// Every message of one (generation, epoch) of an encrypted conversation, in message id order (not time order),
  /// paged with an opaque page_token. Once the epoch is closed (it has a commit, or a later generation exists after a
  /// reset; ListConversationCommits) no message can join it, so the full list is complete: a device calls this before
  /// applying the commit that ends an epoch, to prove it holds every message of the epoch (MLS deletes the epoch's
  /// keys on commit). It is a completeness set, not a decryption order: collect every page, then decrypt in created_at
  /// order, then by id (file comment, "Processing order"). Skip ids already processed.
  /// Messages at or before the caller's own DeleteConversation time (cleared_at in the response) ARE returned, unlike
  /// ListMessages, for completeness counting only: the client does not show or store them (it may decrypt and discard
  /// them; skipping their decryption would spend the forward limit). The tombstone rules are the same (DELETED_ACCOUNT
  /// and REMOVED carry no ciphertext), and a message whose ciphertext the retention sweep has removed has
  /// ciphertext_removed = true (30 days after created_at, possibly later: the sweep can lag).
  /// shared_post is never set (the post id is inside the ciphertext).
  /// page_token: sealed, bound to the caller, the conversation and the pair, expires after 30 days; an expired, foreign
  /// or tampered token, or one for another pair => VALIDATION "page_token": call again without it. next_page_token "" =>
  /// the end of the epoch's messages as of now.
  /// Flag: "messaging" not globally off. Participant check and the one NOT_FOUND as ListMessages (the conversation
  /// through the 60 s instance copy). Validation: conversation_id; mls_generation >= 1 and mls_epoch >= 1 (VALIDATION
  /// "mls_generation" / "mls_epoch"); page_size as the file comment. A NONE conversation or a pair with no messages is
  /// an empty list. Rate limit: RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: at most 1 conversation read (cache-first) + 1 query of at most page_size (max 50) messages. Writes nothing.
  $async.Future<ListEpochMessagesResponse> listEpochMessages(
          $pb.ClientContext? ctx, ListEpochMessagesRequest request) =>
      _client.invoke<ListEpochMessagesResponse>(ctx, 'MessagingService',
          'ListEpochMessages', request, ListEpochMessagesResponse());

  /// Welcomes waiting for one of the caller's devices: how a device joins an encrypted conversation's group (after
  /// mls_init, a commit that adds it, or a reset). Process each, then AckWelcomes it; a welcome stays listed until
  /// acknowledged, replaced by a later welcome for the same conversation and device, or deleted after its retention: it
  /// is kept at least 30 days after creation and may be deleted at any time after that (deletion is not immediate; a
  /// client must not rely on an old welcome having disappeared). At most one per conversation per device (file comment,
  /// "Welcomes").
  /// There is no cursor: acknowledging is how the list advances. more = true when a full page was returned:
  /// acknowledge, then call again. Acknowledge also a welcome the device cannot use (it will not become usable), else
  /// it keeps its place on the page until it is deleted. A welcome whose mls_generation is below the conversation's
  /// current generation (ListConversationCommits) is useless: acknowledge it and wait for one of the current
  /// generation. Old-generation welcomes remain for devices a reset did not address. A welcome the device cannot process
  /// is acknowledged too and counts as no welcome (file comment, "Catch-up").
  /// Order: by welcome id (ids are hashes, so not time order). The server keeps at most one welcome per conversation
  /// per device, so a page holds at most one per conversation.
  /// device_id: [A-Za-z0-9_-]{16,64} and one of the caller's own registered devices (an inactive one included), else
  /// VALIDATION "device_id" (one answer for both). It is a filter, not an authentication (file comment, "Devices").
  /// Flag: "messaging" not globally off. Validation: device_id; page_size as the file comment. Rate limit:
  /// RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: the device check (1 query of at most 5 device documents) + 1 query of at most page_size (max 10) welcomes.
  /// Writes nothing.
  $async.Future<ListWelcomesResponse> listWelcomes(
          $pb.ClientContext? ctx, ListWelcomesRequest request) =>
      _client.invoke<ListWelcomesResponse>(ctx, 'MessagingService',
          'ListWelcomes', request, ListWelcomesResponse());

  /// Delete welcomes the caller's device has processed. device_id as ListWelcomes (VALIDATION "device_id"); ids: 1-50
  /// welcome ids, each 32 lower-case hex, else VALIDATION "ids". Deletes by id among the caller's own welcomes:
  /// device_id does not further scope it (any of the caller's welcome ids is deleted), and ids that do not belong to
  /// the caller or are missing (already acknowledged, replaced, deleted after its retention, never existed) are ignored silently, so a
  /// replay is a success writing nothing new. Naturally idempotent; idempotency_key is format-checked only.
  /// Flag: "messaging" not globally off. Refused under DEGRADED_MODE=readonly. Rate limit:
  /// RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: the device check (1 query of at most 5 device documents) + at most 50 deletes, no other read.
  $async.Future<AckWelcomesResponse> ackWelcomes(
          $pb.ClientContext? ctx, AckWelcomesRequest request) =>
      _client.invoke<AckWelcomesResponse>(ctx, 'MessagingService',
          'AckWelcomes', request, AckWelcomesResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
