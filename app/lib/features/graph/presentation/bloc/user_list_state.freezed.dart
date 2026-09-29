// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'user_list_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$UserListState {

 UserListStatus get status; List<graph.UserListItem> get items; String get nextPageToken; AppException? get error;
/// Create a copy of UserListState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserListStateCopyWith<UserListState> get copyWith => _$UserListStateCopyWithImpl<UserListState>(this as UserListState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as UserListState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UserListState&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.items, _this.items)&&(identical(other.nextPageToken, _this.nextPageToken) || other.nextPageToken == _this.nextPageToken)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as UserListState;
  return Object.hash(runtimeType,_this.status,const DeepCollectionEquality().hash(_this.items),_this.nextPageToken,_this.error);
}

@override
String toString() {
  final _this = this as UserListState;
  return 'UserListState(status: ${_this.status}, items: ${_this.items}, nextPageToken: ${_this.nextPageToken}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $UserListStateCopyWith<$Res>  {
  factory $UserListStateCopyWith(UserListState value, $Res Function(UserListState) _then) = _$UserListStateCopyWithImpl;
@useResult
$Res call({
 UserListStatus status, List<graph.UserListItem> items, String nextPageToken, AppException? error
});




}
/// @nodoc
class _$UserListStateCopyWithImpl<$Res>
    implements $UserListStateCopyWith<$Res> {
  _$UserListStateCopyWithImpl(this._self, this._then);

  final UserListState _self;
  final $Res Function(UserListState) _then;

/// Create a copy of UserListState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? items = null,Object? nextPageToken = null,Object? error = freezed,}) {
  return _then(UserListState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as UserListStatus,items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<graph.UserListItem>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [UserListState].
extension UserListStatePatterns on UserListState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _UserListState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _UserListState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _UserListState value)  $default,){
final _that = this;
switch (_that) {
case _UserListState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _UserListState value)?  $default,){
final _that = this;
switch (_that) {
case _UserListState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( UserListStatus status,  List<graph.UserListItem> items,  String nextPageToken,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _UserListState() when $default != null:
return $default(_that.status,_that.items,_that.nextPageToken,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( UserListStatus status,  List<graph.UserListItem> items,  String nextPageToken,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _UserListState():
return $default(_that.status,_that.items,_that.nextPageToken,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( UserListStatus status,  List<graph.UserListItem> items,  String nextPageToken,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _UserListState() when $default != null:
return $default(_that.status,_that.items,_that.nextPageToken,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _UserListState extends UserListState {
  const _UserListState({this.status = UserListStatus.loading,  List<graph.UserListItem> items = const <graph.UserListItem>[], this.nextPageToken = '', this.error}): _items = items,super._();
  

@override@JsonKey() final  UserListStatus status;
 final  List<graph.UserListItem> _items;
@override@JsonKey() List<graph.UserListItem> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override@JsonKey() final  String nextPageToken;
@override final  AppException? error;

/// Create a copy of UserListState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$UserListStateCopyWith<_UserListState> get copyWith => __$UserListStateCopyWithImpl<_UserListState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _UserListState&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.items, _items)&&(identical(other.nextPageToken, nextPageToken) || other.nextPageToken == nextPageToken)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,const DeepCollectionEquality().hash(_items),nextPageToken,error);
}

@override
String toString() {
    return 'UserListState(status: $status, items: $items, nextPageToken: $nextPageToken, error: $error)';
}


}

/// @nodoc
abstract mixin class _$UserListStateCopyWith<$Res> implements $UserListStateCopyWith<$Res> {
  factory _$UserListStateCopyWith(_UserListState value, $Res Function(_UserListState) _then) = __$UserListStateCopyWithImpl;
@override @useResult
$Res call({
 UserListStatus status, List<graph.UserListItem> items, String nextPageToken, AppException? error
});




}
/// @nodoc
class __$UserListStateCopyWithImpl<$Res>
    implements _$UserListStateCopyWith<$Res> {
  __$UserListStateCopyWithImpl(this._self, this._then);

  final _UserListState _self;
  final $Res Function(_UserListState) _then;

/// Create a copy of UserListState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? items = null,Object? nextPageToken = null,Object? error = freezed,}) {
  return _then(_UserListState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as UserListStatus,items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<graph.UserListItem>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
