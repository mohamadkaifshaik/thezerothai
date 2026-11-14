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

import 'package:protobuf/protobuf.dart' as $pb;

import 'messaging.pb.dart' as $3;
import 'messaging.pbjson.dart';

export 'messaging.pb.dart';

abstract class MessagingServiceBase extends $pb.GeneratedService {
  $async.Future<$3.SendMessageResponse> sendMessage(
      $pb.ServerContext ctx, $3.SendMessageRequest request);
  $async.Future<$3.ListConversationsResponse> listConversations(
      $pb.ServerContext ctx, $3.ListConversationsRequest request);
  $async.Future<$3.ListMessagesResponse> listMessages(
      $pb.ServerContext ctx, $3.ListMessagesRequest request);
  $async.Future<$3.MarkConversationReadResponse> markConversationRead(
      $pb.ServerContext ctx, $3.MarkConversationReadRequest request);
  $async.Future<$3.AcceptMessageRequestResponse> acceptMessageRequest(
      $pb.ServerContext ctx, $3.AcceptMessageRequestRequest request);
  $async.Future<$3.DeleteConversationResponse> deleteConversation(
      $pb.ServerContext ctx, $3.DeleteConversationRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'SendMessage':
        return $3.SendMessageRequest();
      case 'ListConversations':
        return $3.ListConversationsRequest();
      case 'ListMessages':
        return $3.ListMessagesRequest();
      case 'MarkConversationRead':
        return $3.MarkConversationReadRequest();
      case 'AcceptMessageRequest':
        return $3.AcceptMessageRequestRequest();
      case 'DeleteConversation':
        return $3.DeleteConversationRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'SendMessage':
        return sendMessage(ctx, request as $3.SendMessageRequest);
      case 'ListConversations':
        return listConversations(ctx, request as $3.ListConversationsRequest);
      case 'ListMessages':
        return listMessages(ctx, request as $3.ListMessagesRequest);
      case 'MarkConversationRead':
        return markConversationRead(
            ctx, request as $3.MarkConversationReadRequest);
      case 'AcceptMessageRequest':
        return acceptMessageRequest(
            ctx, request as $3.AcceptMessageRequestRequest);
      case 'DeleteConversation':
        return deleteConversation(ctx, request as $3.DeleteConversationRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => MessagingServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => MessagingServiceBase$messageJson;
}
