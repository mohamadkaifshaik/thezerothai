// This is a generated file - do not edit.
//
// Generated from dzeroth/search/v1/search.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// The order a SearchPosts call returns (ADR-0028 D3). There is no PEOPLE value: the client's People tab calls
/// SearchPeople with the same query. A new tab is an additive value.
class SearchTab extends $pb.ProtobufEnum {
  /// Treated as TOP.
  static const SearchTab SEARCH_TAB_UNSPECIFIED =
      SearchTab._(0, _omitEnumNames ? '' : 'SEARCH_TAB_UNSPECIFIED');

  /// The newest 30 tagged posts re-ranked by engagement; one page, no token.
  static const SearchTab SEARCH_TAB_TOP =
      SearchTab._(1, _omitEnumNames ? '' : 'SEARCH_TAB_TOP');

  /// Newest first, paged.
  static const SearchTab SEARCH_TAB_LATEST =
      SearchTab._(2, _omitEnumNames ? '' : 'SEARCH_TAB_LATEST');

  /// Posts with their own images, newest first; pages may be short or empty while a token remains.
  static const SearchTab SEARCH_TAB_MEDIA =
      SearchTab._(3, _omitEnumNames ? '' : 'SEARCH_TAB_MEDIA');

  static const $core.List<SearchTab> values = <SearchTab>[
    SEARCH_TAB_UNSPECIFIED,
    SEARCH_TAB_TOP,
    SEARCH_TAB_LATEST,
    SEARCH_TAB_MEDIA,
  ];

  static final $core.List<SearchTab?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static SearchTab? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const SearchTab._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
