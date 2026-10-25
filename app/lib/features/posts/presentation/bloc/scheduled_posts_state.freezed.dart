// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'scheduled_posts_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ScheduledPostsState {

 ScheduledPostsStatus get status; List<pb.ScheduledPost> get items; String get nextPageToken;/// Why the first page failed ([ScheduledPostsStatus.error]).
 AppException? get error;/// A refresh or a next page failed while rows are on screen: they stay,
/// under a banner.
 AppException? get notice;
/// Create a copy of ScheduledPostsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ScheduledPostsStateCopyWith<ScheduledPostsState> get copyWith => _$ScheduledPostsStateCopyWithImpl<ScheduledPostsState>(this as ScheduledPostsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ScheduledPostsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ScheduledPostsState&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.items, _this.items)&&(identical(other.nextPageToken, _this.nextPageToken) || other.nextPageToken == _this.nextPageToken)&&(identical(other.error, _this.error) || other.error == _this.error)&&(identical(other.notice, _this.notice) || other.notice == _this.notice));
}


@override
int get hashCode {
  final _this = this as ScheduledPostsState;
  return Object.hash(runtimeType,_this.status,const DeepCollectionEquality().hash(_this.items),_this.nextPageToken,_this.error,_this.notice);
}

@override
String toString() {
  final _this = this as ScheduledPostsState;
  return 'ScheduledPostsState(status: ${_this.status}, items: ${_this.items}, nextPageToken: ${_this.nextPageToken}, error: ${_this.error}, notice: ${_this.notice})';
}


}

/// @nodoc
abstract mixin class $ScheduledPostsStateCopyWith<$Res>  {
  factory $ScheduledPostsStateCopyWith(ScheduledPostsState value, $Res Function(ScheduledPostsState) _then) = _$ScheduledPostsStateCopyWithImpl;
@useResult
$Res call({
 ScheduledPostsStatus status, List<pb.ScheduledPost> items, String nextPageToken, AppException? error, AppException? notice
});




}
/// @nodoc
class _$ScheduledPostsStateCopyWithImpl<$Res>
    implements $ScheduledPostsStateCopyWith<$Res> {
  _$ScheduledPostsStateCopyWithImpl(this._self, this._then);

  final ScheduledPostsState _self;
  final $Res Function(ScheduledPostsState) _then;

/// Create a copy of ScheduledPostsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? items = null,Object? nextPageToken = null,Object? error = freezed,Object? notice = freezed,}) {
  return _then(ScheduledPostsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ScheduledPostsStatus,items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<pb.ScheduledPost>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,notice: freezed == notice ? _self.notice : notice // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [ScheduledPostsState].
extension ScheduledPostsStatePatterns on ScheduledPostsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ScheduledPostsState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ScheduledPostsState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ScheduledPostsState value)  $default,){
final _that = this;
switch (_that) {
case _ScheduledPostsState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ScheduledPostsState value)?  $default,){
final _that = this;
switch (_that) {
case _ScheduledPostsState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ScheduledPostsStatus status,  List<pb.ScheduledPost> items,  String nextPageToken,  AppException? error,  AppException? notice)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ScheduledPostsState() when $default != null:
return $default(_that.status,_that.items,_that.nextPageToken,_that.error,_that.notice);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ScheduledPostsStatus status,  List<pb.ScheduledPost> items,  String nextPageToken,  AppException? error,  AppException? notice)  $default,) {final _that = this;
switch (_that) {
case _ScheduledPostsState():
return $default(_that.status,_that.items,_that.nextPageToken,_that.error,_that.notice);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ScheduledPostsStatus status,  List<pb.ScheduledPost> items,  String nextPageToken,  AppException? error,  AppException? notice)?  $default,) {final _that = this;
switch (_that) {
case _ScheduledPostsState() when $default != null:
return $default(_that.status,_that.items,_that.nextPageToken,_that.error,_that.notice);case _:
  return null;

}
}

}

/// @nodoc


class _ScheduledPostsState extends ScheduledPostsState {
  const _ScheduledPostsState({this.status = ScheduledPostsStatus.loading,  List<pb.ScheduledPost> items = const <pb.ScheduledPost>[], this.nextPageToken = '', this.error, this.notice}): _items = items,super._();
  

@override@JsonKey() final  ScheduledPostsStatus status;
 final  List<pb.ScheduledPost> _items;
@override@JsonKey() List<pb.ScheduledPost> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override@JsonKey() final  String nextPageToken;
/// Why the first page failed ([ScheduledPostsStatus.error]).
@override final  AppException? error;
/// A refresh or a next page failed while rows are on screen: they stay,
/// under a banner.
@override final  AppException? notice;

/// Create a copy of ScheduledPostsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ScheduledPostsStateCopyWith<_ScheduledPostsState> get copyWith => __$ScheduledPostsStateCopyWithImpl<_ScheduledPostsState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ScheduledPostsState&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.items, _items)&&(identical(other.nextPageToken, nextPageToken) || other.nextPageToken == nextPageToken)&&(identical(other.error, error) || other.error == error)&&(identical(other.notice, notice) || other.notice == notice));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,const DeepCollectionEquality().hash(_items),nextPageToken,error,notice);
}

@override
String toString() {
    return 'ScheduledPostsState(status: $status, items: $items, nextPageToken: $nextPageToken, error: $error, notice: $notice)';
}


}

/// @nodoc
abstract mixin class _$ScheduledPostsStateCopyWith<$Res> implements $ScheduledPostsStateCopyWith<$Res> {
  factory _$ScheduledPostsStateCopyWith(_ScheduledPostsState value, $Res Function(_ScheduledPostsState) _then) = __$ScheduledPostsStateCopyWithImpl;
@override @useResult
$Res call({
 ScheduledPostsStatus status, List<pb.ScheduledPost> items, String nextPageToken, AppException? error, AppException? notice
});




}
/// @nodoc
class __$ScheduledPostsStateCopyWithImpl<$Res>
    implements _$ScheduledPostsStateCopyWith<$Res> {
  __$ScheduledPostsStateCopyWithImpl(this._self, this._then);

  final _ScheduledPostsState _self;
  final $Res Function(_ScheduledPostsState) _then;

/// Create a copy of ScheduledPostsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? items = null,Object? nextPageToken = null,Object? error = freezed,Object? notice = freezed,}) {
  return _then(_ScheduledPostsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ScheduledPostsStatus,items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<pb.ScheduledPost>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,notice: freezed == notice ? _self.notice : notice // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
