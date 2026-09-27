// This is a generated file - do not edit.
//
// Generated from dzeroth/media/v1/media.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'media.pb.dart' as $2;
import 'media.pbjson.dart';

export 'media.pb.dart';

abstract class MediaServiceBase extends $pb.GeneratedService {
  $async.Future<$2.CreateUploadResponse> createUpload(
      $pb.ServerContext ctx, $2.CreateUploadRequest request);
  $async.Future<$2.FinalizeUploadResponse> finalizeUpload(
      $pb.ServerContext ctx, $2.FinalizeUploadRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateUpload':
        return $2.CreateUploadRequest();
      case 'FinalizeUpload':
        return $2.FinalizeUploadRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateUpload':
        return createUpload(ctx, request as $2.CreateUploadRequest);
      case 'FinalizeUpload':
        return finalizeUpload(ctx, request as $2.FinalizeUploadRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => MediaServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => MediaServiceBase$messageJson;
}
