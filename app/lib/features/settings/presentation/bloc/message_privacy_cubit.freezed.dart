// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'message_privacy_cubit.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$MessagePrivacyState {

 OwnPrivacy? get confirmed; bool? get savingReceipts; WhoCanMessage? get savingWho; AppException? get error; int get serial; bool get receiptsRefused; bool get followingRefused;
/// Create a copy of MessagePrivacyState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessagePrivacyStateCopyWith<MessagePrivacyState> get copyWith => _$MessagePrivacyStateCopyWithImpl<MessagePrivacyState>(this as MessagePrivacyState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as MessagePrivacyState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessagePrivacyState&&(identical(other.confirmed, _this.confirmed) || other.confirmed == _this.confirmed)&&(identical(other.savingReceipts, _this.savingReceipts) || other.savingReceipts == _this.savingReceipts)&&(identical(other.savingWho, _this.savingWho) || other.savingWho == _this.savingWho)&&(identical(other.error, _this.error) || other.error == _this.error)&&(identical(other.serial, _this.serial) || other.serial == _this.serial)&&(identical(other.receiptsRefused, _this.receiptsRefused) || other.receiptsRefused == _this.receiptsRefused)&&(identical(other.followingRefused, _this.followingRefused) || other.followingRefused == _this.followingRefused));
}


@override
int get hashCode {
  final _this = this as MessagePrivacyState;
  return Object.hash(runtimeType,_this.confirmed,_this.savingReceipts,_this.savingWho,_this.error,_this.serial,_this.receiptsRefused,_this.followingRefused);
}

@override
String toString() {
  final _this = this as MessagePrivacyState;
  return 'MessagePrivacyState(confirmed: ${_this.confirmed}, savingReceipts: ${_this.savingReceipts}, savingWho: ${_this.savingWho}, error: ${_this.error}, serial: ${_this.serial}, receiptsRefused: ${_this.receiptsRefused}, followingRefused: ${_this.followingRefused})';
}


}

/// @nodoc
abstract mixin class $MessagePrivacyStateCopyWith<$Res>  {
  factory $MessagePrivacyStateCopyWith(MessagePrivacyState value, $Res Function(MessagePrivacyState) _then) = _$MessagePrivacyStateCopyWithImpl;
@useResult
$Res call({
 OwnPrivacy? confirmed, bool? savingReceipts, WhoCanMessage? savingWho, AppException? error, int serial, bool receiptsRefused, bool followingRefused
});




}
/// @nodoc
class _$MessagePrivacyStateCopyWithImpl<$Res>
    implements $MessagePrivacyStateCopyWith<$Res> {
  _$MessagePrivacyStateCopyWithImpl(this._self, this._then);

  final MessagePrivacyState _self;
  final $Res Function(MessagePrivacyState) _then;

/// Create a copy of MessagePrivacyState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? confirmed = freezed,Object? savingReceipts = freezed,Object? savingWho = freezed,Object? error = freezed,Object? serial = null,Object? receiptsRefused = null,Object? followingRefused = null,}) {
  return _then(MessagePrivacyState(
confirmed: freezed == confirmed ? _self.confirmed : confirmed // ignore: cast_nullable_to_non_nullable
as OwnPrivacy?,savingReceipts: freezed == savingReceipts ? _self.savingReceipts : savingReceipts // ignore: cast_nullable_to_non_nullable
as bool?,savingWho: freezed == savingWho ? _self.savingWho : savingWho // ignore: cast_nullable_to_non_nullable
as WhoCanMessage?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,receiptsRefused: null == receiptsRefused ? _self.receiptsRefused : receiptsRefused // ignore: cast_nullable_to_non_nullable
as bool,followingRefused: null == followingRefused ? _self.followingRefused : followingRefused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [MessagePrivacyState].
extension MessagePrivacyStatePatterns on MessagePrivacyState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MessagePrivacyState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MessagePrivacyState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MessagePrivacyState value)  $default,){
final _that = this;
switch (_that) {
case _MessagePrivacyState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MessagePrivacyState value)?  $default,){
final _that = this;
switch (_that) {
case _MessagePrivacyState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( OwnPrivacy? confirmed,  bool? savingReceipts,  WhoCanMessage? savingWho,  AppException? error,  int serial,  bool receiptsRefused,  bool followingRefused)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MessagePrivacyState() when $default != null:
return $default(_that.confirmed,_that.savingReceipts,_that.savingWho,_that.error,_that.serial,_that.receiptsRefused,_that.followingRefused);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( OwnPrivacy? confirmed,  bool? savingReceipts,  WhoCanMessage? savingWho,  AppException? error,  int serial,  bool receiptsRefused,  bool followingRefused)  $default,) {final _that = this;
switch (_that) {
case _MessagePrivacyState():
return $default(_that.confirmed,_that.savingReceipts,_that.savingWho,_that.error,_that.serial,_that.receiptsRefused,_that.followingRefused);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( OwnPrivacy? confirmed,  bool? savingReceipts,  WhoCanMessage? savingWho,  AppException? error,  int serial,  bool receiptsRefused,  bool followingRefused)?  $default,) {final _that = this;
switch (_that) {
case _MessagePrivacyState() when $default != null:
return $default(_that.confirmed,_that.savingReceipts,_that.savingWho,_that.error,_that.serial,_that.receiptsRefused,_that.followingRefused);case _:
  return null;

}
}

}

/// @nodoc


class _MessagePrivacyState extends MessagePrivacyState {
  const _MessagePrivacyState({this.confirmed, this.savingReceipts, this.savingWho, this.error, this.serial = 0, this.receiptsRefused = false, this.followingRefused = false}): super._();
  

@override final  OwnPrivacy? confirmed;
@override final  bool? savingReceipts;
@override final  WhoCanMessage? savingWho;
@override final  AppException? error;
@override@JsonKey() final  int serial;
@override@JsonKey() final  bool receiptsRefused;
@override@JsonKey() final  bool followingRefused;

/// Create a copy of MessagePrivacyState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MessagePrivacyStateCopyWith<_MessagePrivacyState> get copyWith => __$MessagePrivacyStateCopyWithImpl<_MessagePrivacyState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _MessagePrivacyState&&(identical(other.confirmed, confirmed) || other.confirmed == confirmed)&&(identical(other.savingReceipts, savingReceipts) || other.savingReceipts == savingReceipts)&&(identical(other.savingWho, savingWho) || other.savingWho == savingWho)&&(identical(other.error, error) || other.error == error)&&(identical(other.serial, serial) || other.serial == serial)&&(identical(other.receiptsRefused, receiptsRefused) || other.receiptsRefused == receiptsRefused)&&(identical(other.followingRefused, followingRefused) || other.followingRefused == followingRefused));
}


@override
int get hashCode {
    return Object.hash(runtimeType,confirmed,savingReceipts,savingWho,error,serial,receiptsRefused,followingRefused);
}

@override
String toString() {
    return 'MessagePrivacyState(confirmed: $confirmed, savingReceipts: $savingReceipts, savingWho: $savingWho, error: $error, serial: $serial, receiptsRefused: $receiptsRefused, followingRefused: $followingRefused)';
}


}

/// @nodoc
abstract mixin class _$MessagePrivacyStateCopyWith<$Res> implements $MessagePrivacyStateCopyWith<$Res> {
  factory _$MessagePrivacyStateCopyWith(_MessagePrivacyState value, $Res Function(_MessagePrivacyState) _then) = __$MessagePrivacyStateCopyWithImpl;
@override @useResult
$Res call({
 OwnPrivacy? confirmed, bool? savingReceipts, WhoCanMessage? savingWho, AppException? error, int serial, bool receiptsRefused, bool followingRefused
});




}
/// @nodoc
class __$MessagePrivacyStateCopyWithImpl<$Res>
    implements _$MessagePrivacyStateCopyWith<$Res> {
  __$MessagePrivacyStateCopyWithImpl(this._self, this._then);

  final _MessagePrivacyState _self;
  final $Res Function(_MessagePrivacyState) _then;

/// Create a copy of MessagePrivacyState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? confirmed = freezed,Object? savingReceipts = freezed,Object? savingWho = freezed,Object? error = freezed,Object? serial = null,Object? receiptsRefused = null,Object? followingRefused = null,}) {
  return _then(_MessagePrivacyState(
confirmed: freezed == confirmed ? _self.confirmed : confirmed // ignore: cast_nullable_to_non_nullable
as OwnPrivacy?,savingReceipts: freezed == savingReceipts ? _self.savingReceipts : savingReceipts // ignore: cast_nullable_to_non_nullable
as bool?,savingWho: freezed == savingWho ? _self.savingWho : savingWho // ignore: cast_nullable_to_non_nullable
as WhoCanMessage?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,receiptsRefused: null == receiptsRefused ? _self.receiptsRefused : receiptsRefused // ignore: cast_nullable_to_non_nullable
as bool,followingRefused: null == followingRefused ? _self.followingRefused : followingRefused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
