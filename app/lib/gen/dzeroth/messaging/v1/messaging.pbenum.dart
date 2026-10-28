// This is a generated file - do not edit.
//
// Generated from dzeroth/messaging/v1/messaging.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// Additive: a group conversation would be a new value (ADR-0027 stage ladder).
class ConversationKind extends $pb.ProtobufEnum {
  static const ConversationKind CONVERSATION_KIND_UNSPECIFIED =
      ConversationKind._(
          0, _omitEnumNames ? '' : 'CONVERSATION_KIND_UNSPECIFIED');

  /// 1:1 between the caller and Conversation.peer.
  static const ConversationKind CONVERSATION_KIND_DIRECT =
      ConversationKind._(1, _omitEnumNames ? '' : 'CONVERSATION_KIND_DIRECT');

  static const $core.List<ConversationKind> values = <ConversationKind>[
    CONVERSATION_KIND_UNSPECIFIED,
    CONVERSATION_KIND_DIRECT,
  ];

  static final $core.List<ConversationKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static ConversationKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ConversationKind._(super.value, super.name);
}

class ConversationState extends $pb.ProtobufEnum {
  static const ConversationState CONVERSATION_STATE_UNSPECIFIED =
      ConversationState._(
          0, _omitEnumNames ? '' : 'CONVERSATION_STATE_UNSPECIFIED');

  /// A request from a non-mutual that the recipient has not accepted yet (capped at 3 messages from the requester).
  static const ConversationState CONVERSATION_STATE_REQUEST =
      ConversationState._(
          1, _omitEnumNames ? '' : 'CONVERSATION_STATE_REQUEST');
  static const ConversationState CONVERSATION_STATE_ACCEPTED =
      ConversationState._(
          2, _omitEnumNames ? '' : 'CONVERSATION_STATE_ACCEPTED');

  static const $core.List<ConversationState> values = <ConversationState>[
    CONVERSATION_STATE_UNSPECIFIED,
    CONVERSATION_STATE_REQUEST,
    CONVERSATION_STATE_ACCEPTED,
  ];

  static final $core.List<ConversationState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ConversationState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ConversationState._(super.value, super.name);
}

/// Where the caller's entry for a conversation lives. Additive (an archived folder would be a new value).
class Folder extends $pb.ProtobufEnum {
  static const Folder FOLDER_UNSPECIFIED =
      Folder._(0, _omitEnumNames ? '' : 'FOLDER_UNSPECIFIED');

  /// Accepted conversations, and requests the caller sent.
  static const Folder FOLDER_INBOX =
      Folder._(1, _omitEnumNames ? '' : 'FOLDER_INBOX');

  /// Message requests the caller received and has not accepted.
  static const Folder FOLDER_REQUESTS =
      Folder._(2, _omitEnumNames ? '' : 'FOLDER_REQUESTS');

  static const $core.List<Folder> values = <Folder>[
    FOLDER_UNSPECIFIED,
    FOLDER_INBOX,
    FOLDER_REQUESTS,
  ];

  static final $core.List<Folder?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static Folder? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Folder._(super.value, super.name);
}

class MessageState extends $pb.ProtobufEnum {
  static const MessageState MESSAGE_STATE_UNSPECIFIED =
      MessageState._(0, _omitEnumNames ? '' : 'MESSAGE_STATE_UNSPECIFIED');
  static const MessageState MESSAGE_STATE_VISIBLE =
      MessageState._(1, _omitEnumNames ? '' : 'MESSAGE_STATE_VISIBLE');

  /// The sender deleted the account; text is empty. Render "Message deleted".
  static const MessageState MESSAGE_STATE_DELETED_ACCOUNT =
      MessageState._(2, _omitEnumNames ? '' : 'MESSAGE_STATE_DELETED_ACCOUNT');

  /// Taken down by a moderator; text is empty.
  static const MessageState MESSAGE_STATE_REMOVED =
      MessageState._(3, _omitEnumNames ? '' : 'MESSAGE_STATE_REMOVED');

  static const $core.List<MessageState> values = <MessageState>[
    MESSAGE_STATE_UNSPECIFIED,
    MESSAGE_STATE_VISIBLE,
    MESSAGE_STATE_DELETED_ACCOUNT,
    MESSAGE_STATE_REMOVED,
  ];

  static final $core.List<MessageState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static MessageState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MessageState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
