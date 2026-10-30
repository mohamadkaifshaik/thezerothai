// This is a generated file - do not edit.
//
// Generated from dzeroth/lists/v1/lists.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'lists.pb.dart' as $3;
import 'lists.pbjson.dart';

export 'lists.pb.dart';

abstract class ListServiceBase extends $pb.GeneratedService {
  $async.Future<$3.CreateListResponse> createList(
      $pb.ServerContext ctx, $3.CreateListRequest request);
  $async.Future<$3.UpdateListResponse> updateList(
      $pb.ServerContext ctx, $3.UpdateListRequest request);
  $async.Future<$3.DeleteListResponse> deleteList(
      $pb.ServerContext ctx, $3.DeleteListRequest request);
  $async.Future<$3.GetListResponse> getList(
      $pb.ServerContext ctx, $3.GetListRequest request);
  $async.Future<$3.ListUserListsResponse> listUserLists(
      $pb.ServerContext ctx, $3.ListUserListsRequest request);
  $async.Future<$3.AddListMemberResponse> addListMember(
      $pb.ServerContext ctx, $3.AddListMemberRequest request);
  $async.Future<$3.RemoveListMemberResponse> removeListMember(
      $pb.ServerContext ctx, $3.RemoveListMemberRequest request);
  $async.Future<$3.ListListMembersResponse> listListMembers(
      $pb.ServerContext ctx, $3.ListListMembersRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateList':
        return $3.CreateListRequest();
      case 'UpdateList':
        return $3.UpdateListRequest();
      case 'DeleteList':
        return $3.DeleteListRequest();
      case 'GetList':
        return $3.GetListRequest();
      case 'ListUserLists':
        return $3.ListUserListsRequest();
      case 'AddListMember':
        return $3.AddListMemberRequest();
      case 'RemoveListMember':
        return $3.RemoveListMemberRequest();
      case 'ListListMembers':
        return $3.ListListMembersRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateList':
        return createList(ctx, request as $3.CreateListRequest);
      case 'UpdateList':
        return updateList(ctx, request as $3.UpdateListRequest);
      case 'DeleteList':
        return deleteList(ctx, request as $3.DeleteListRequest);
      case 'GetList':
        return getList(ctx, request as $3.GetListRequest);
      case 'ListUserLists':
        return listUserLists(ctx, request as $3.ListUserListsRequest);
      case 'AddListMember':
        return addListMember(ctx, request as $3.AddListMemberRequest);
      case 'RemoveListMember':
        return removeListMember(ctx, request as $3.RemoveListMemberRequest);
      case 'ListListMembers':
        return listListMembers(ctx, request as $3.ListListMembersRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => ListServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => ListServiceBase$messageJson;
}
