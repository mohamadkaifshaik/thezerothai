// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'message_search_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$MessageSearchState {

 String get query; MessageSearchStatus get status; List<ConversationHits> get groups;/// True when older pages of the one searched conversation can be fetched.
 bool get canLoadOlder; bool get loadingOlder;/// Older pages fetched so far in this search (held in memory only).
 int get olderPages; AppException? get olderError;
/// Create a copy of MessageSearchState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessageSearchStateCopyWith<MessageSearchState> get copyWith => _$MessageSearchStateCopyWithImpl<MessageSearchState>(this as MessageSearchState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as MessageSearchState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessageSearchState&&(identical(other.query, _this.query) || other.query == _this.query)&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.groups, _this.groups)&&(identical(other.canLoadOlder, _this.canLoadOlder) || other.canLoadOlder == _this.canLoadOlder)&&(identical(other.loadingOlder, _this.loadingOlder) || other.loadingOlder == _this.loadingOlder)&&(identical(other.olderPages, _this.olderPages) || other.olderPages == _this.olderPages)&&(identical(other.olderError, _this.olderError) || other.olderError == _this.olderError));
}


@override
int get hashCode {
  final _this = this as MessageSearchState;
  return Object.hash(runtimeType,_this.query,_this.status,const DeepCollectionEquality().hash(_this.groups),_this.canLoadOlder,_this.loadingOlder,_this.olderPages,_this.olderError);
}

@override
String toString() {
  final _this = this as MessageSearchState;
  return 'MessageSearchState(query: ${_this.query}, status: ${_this.status}, groups: ${_this.groups}, canLoadOlder: ${_this.canLoadOlder}, loadingOlder: ${_this.loadingOlder}, olderPages: ${_this.olderPages}, olderError: ${_this.olderError})';
}


}

/// @nodoc
abstract mixin class $MessageSearchStateCopyWith<$Res>  {
  factory $MessageSearchStateCopyWith(MessageSearchState value, $Res Function(MessageSearchState) _then) = _$MessageSearchStateCopyWithImpl;
@useResult
$Res call({
 String query, MessageSearchStatus status, List<ConversationHits> groups, bool canLoadOlder, bool loadingOlder, int olderPages, AppException? olderError
});




}
/// @nodoc
class _$MessageSearchStateCopyWithImpl<$Res>
    implements $MessageSearchStateCopyWith<$Res> {
  _$MessageSearchStateCopyWithImpl(this._self, this._then);

  final MessageSearchState _self;
  final $Res Function(MessageSearchState) _then;

/// Create a copy of MessageSearchState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? query = null,Object? status = null,Object? groups = null,Object? canLoadOlder = null,Object? loadingOlder = null,Object? olderPages = null,Object? olderError = freezed,}) {
  return _then(MessageSearchState(
query: null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as MessageSearchStatus,groups: null == groups ? _self.groups : groups // ignore: cast_nullable_to_non_nullable
as List<ConversationHits>,canLoadOlder: null == canLoadOlder ? _self.canLoadOlder : canLoadOlder // ignore: cast_nullable_to_non_nullable
as bool,loadingOlder: null == loadingOlder ? _self.loadingOlder : loadingOlder // ignore: cast_nullable_to_non_nullable
as bool,olderPages: null == olderPages ? _self.olderPages : olderPages // ignore: cast_nullable_to_non_nullable
as int,olderError: freezed == olderError ? _self.olderError : olderError // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [MessageSearchState].
extension MessageSearchStatePatterns on MessageSearchState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MessageSearchState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MessageSearchState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MessageSearchState value)  $default,){
final _that = this;
switch (_that) {
case _MessageSearchState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MessageSearchState value)?  $default,){
final _that = this;
switch (_that) {
case _MessageSearchState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String query,  MessageSearchStatus status,  List<ConversationHits> groups,  bool canLoadOlder,  bool loadingOlder,  int olderPages,  AppException? olderError)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MessageSearchState() when $default != null:
return $default(_that.query,_that.status,_that.groups,_that.canLoadOlder,_that.loadingOlder,_that.olderPages,_that.olderError);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String query,  MessageSearchStatus status,  List<ConversationHits> groups,  bool canLoadOlder,  bool loadingOlder,  int olderPages,  AppException? olderError)  $default,) {final _that = this;
switch (_that) {
case _MessageSearchState():
return $default(_that.query,_that.status,_that.groups,_that.canLoadOlder,_that.loadingOlder,_that.olderPages,_that.olderError);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String query,  MessageSearchStatus status,  List<ConversationHits> groups,  bool canLoadOlder,  bool loadingOlder,  int olderPages,  AppException? olderError)?  $default,) {final _that = this;
switch (_that) {
case _MessageSearchState() when $default != null:
return $default(_that.query,_that.status,_that.groups,_that.canLoadOlder,_that.loadingOlder,_that.olderPages,_that.olderError);case _:
  return null;

}
}

}

/// @nodoc


class _MessageSearchState implements MessageSearchState {
  const _MessageSearchState({this.query = '', this.status = MessageSearchStatus.idle,  List<ConversationHits> groups = const <ConversationHits>[], this.canLoadOlder = false, this.loadingOlder = false, this.olderPages = 0, this.olderError}): _groups = groups;
  

@override@JsonKey() final  String query;
@override@JsonKey() final  MessageSearchStatus status;
 final  List<ConversationHits> _groups;
@override@JsonKey() List<ConversationHits> get groups {
  if (_groups is EqualUnmodifiableListView) return _groups;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_groups);
}

/// True when older pages of the one searched conversation can be fetched.
@override@JsonKey() final  bool canLoadOlder;
@override@JsonKey() final  bool loadingOlder;
/// Older pages fetched so far in this search (held in memory only).
@override@JsonKey() final  int olderPages;
@override final  AppException? olderError;

/// Create a copy of MessageSearchState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MessageSearchStateCopyWith<_MessageSearchState> get copyWith => __$MessageSearchStateCopyWithImpl<_MessageSearchState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _MessageSearchState&&(identical(other.query, query) || other.query == query)&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.groups, _groups)&&(identical(other.canLoadOlder, canLoadOlder) || other.canLoadOlder == canLoadOlder)&&(identical(other.loadingOlder, loadingOlder) || other.loadingOlder == loadingOlder)&&(identical(other.olderPages, olderPages) || other.olderPages == olderPages)&&(identical(other.olderError, olderError) || other.olderError == olderError));
}


@override
int get hashCode {
    return Object.hash(runtimeType,query,status,const DeepCollectionEquality().hash(_groups),canLoadOlder,loadingOlder,olderPages,olderError);
}

@override
String toString() {
    return 'MessageSearchState(query: $query, status: $status, groups: $groups, canLoadOlder: $canLoadOlder, loadingOlder: $loadingOlder, olderPages: $olderPages, olderError: $olderError)';
}


}

/// @nodoc
abstract mixin class _$MessageSearchStateCopyWith<$Res> implements $MessageSearchStateCopyWith<$Res> {
  factory _$MessageSearchStateCopyWith(_MessageSearchState value, $Res Function(_MessageSearchState) _then) = __$MessageSearchStateCopyWithImpl;
@override @useResult
$Res call({
 String query, MessageSearchStatus status, List<ConversationHits> groups, bool canLoadOlder, bool loadingOlder, int olderPages, AppException? olderError
});




}
/// @nodoc
class __$MessageSearchStateCopyWithImpl<$Res>
    implements _$MessageSearchStateCopyWith<$Res> {
  __$MessageSearchStateCopyWithImpl(this._self, this._then);

  final _MessageSearchState _self;
  final $Res Function(_MessageSearchState) _then;

/// Create a copy of MessageSearchState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? query = null,Object? status = null,Object? groups = null,Object? canLoadOlder = null,Object? loadingOlder = null,Object? olderPages = null,Object? olderError = freezed,}) {
  return _then(_MessageSearchState(
query: null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as MessageSearchStatus,groups: null == groups ? _self._groups : groups // ignore: cast_nullable_to_non_nullable
as List<ConversationHits>,canLoadOlder: null == canLoadOlder ? _self.canLoadOlder : canLoadOlder // ignore: cast_nullable_to_non_nullable
as bool,loadingOlder: null == loadingOlder ? _self.loadingOlder : loadingOlder // ignore: cast_nullable_to_non_nullable
as bool,olderPages: null == olderPages ? _self.olderPages : olderPages // ignore: cast_nullable_to_non_nullable
as int,olderError: freezed == olderError ? _self.olderError : olderError // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
