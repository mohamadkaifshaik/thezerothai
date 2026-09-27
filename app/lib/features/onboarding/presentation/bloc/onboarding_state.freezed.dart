// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'onboarding_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$OnboardingState {

 OnboardingStatus get status; identity.Profile? get profile; String get handle; String get displayName; HandleCheckStatus get handleCheckStatus; String get handleCheckMessage; bool get isSubmitting; AppException? get error;
/// Create a copy of OnboardingState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OnboardingStateCopyWith<OnboardingState> get copyWith => _$OnboardingStateCopyWithImpl<OnboardingState>(this as OnboardingState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as OnboardingState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OnboardingState&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.profile, _this.profile) || other.profile == _this.profile)&&(identical(other.handle, _this.handle) || other.handle == _this.handle)&&(identical(other.displayName, _this.displayName) || other.displayName == _this.displayName)&&(identical(other.handleCheckStatus, _this.handleCheckStatus) || other.handleCheckStatus == _this.handleCheckStatus)&&(identical(other.handleCheckMessage, _this.handleCheckMessage) || other.handleCheckMessage == _this.handleCheckMessage)&&(identical(other.isSubmitting, _this.isSubmitting) || other.isSubmitting == _this.isSubmitting)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as OnboardingState;
  return Object.hash(runtimeType,_this.status,_this.profile,_this.handle,_this.displayName,_this.handleCheckStatus,_this.handleCheckMessage,_this.isSubmitting,_this.error);
}

@override
String toString() {
  final _this = this as OnboardingState;
  return 'OnboardingState(status: ${_this.status}, profile: ${_this.profile}, handle: ${_this.handle}, displayName: ${_this.displayName}, handleCheckStatus: ${_this.handleCheckStatus}, handleCheckMessage: ${_this.handleCheckMessage}, isSubmitting: ${_this.isSubmitting}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $OnboardingStateCopyWith<$Res>  {
  factory $OnboardingStateCopyWith(OnboardingState value, $Res Function(OnboardingState) _then) = _$OnboardingStateCopyWithImpl;
@useResult
$Res call({
 OnboardingStatus status, identity.Profile? profile, String handle, String displayName, HandleCheckStatus handleCheckStatus, String handleCheckMessage, bool isSubmitting, AppException? error
});




}
/// @nodoc
class _$OnboardingStateCopyWithImpl<$Res>
    implements $OnboardingStateCopyWith<$Res> {
  _$OnboardingStateCopyWithImpl(this._self, this._then);

  final OnboardingState _self;
  final $Res Function(OnboardingState) _then;

/// Create a copy of OnboardingState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? profile = freezed,Object? handle = null,Object? displayName = null,Object? handleCheckStatus = null,Object? handleCheckMessage = null,Object? isSubmitting = null,Object? error = freezed,}) {
  return _then(OnboardingState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as OnboardingStatus,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as identity.Profile?,handle: null == handle ? _self.handle : handle // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,handleCheckStatus: null == handleCheckStatus ? _self.handleCheckStatus : handleCheckStatus // ignore: cast_nullable_to_non_nullable
as HandleCheckStatus,handleCheckMessage: null == handleCheckMessage ? _self.handleCheckMessage : handleCheckMessage // ignore: cast_nullable_to_non_nullable
as String,isSubmitting: null == isSubmitting ? _self.isSubmitting : isSubmitting // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [OnboardingState].
extension OnboardingStatePatterns on OnboardingState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _OnboardingState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _OnboardingState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _OnboardingState value)  $default,){
final _that = this;
switch (_that) {
case _OnboardingState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _OnboardingState value)?  $default,){
final _that = this;
switch (_that) {
case _OnboardingState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( OnboardingStatus status,  identity.Profile? profile,  String handle,  String displayName,  HandleCheckStatus handleCheckStatus,  String handleCheckMessage,  bool isSubmitting,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _OnboardingState() when $default != null:
return $default(_that.status,_that.profile,_that.handle,_that.displayName,_that.handleCheckStatus,_that.handleCheckMessage,_that.isSubmitting,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( OnboardingStatus status,  identity.Profile? profile,  String handle,  String displayName,  HandleCheckStatus handleCheckStatus,  String handleCheckMessage,  bool isSubmitting,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _OnboardingState():
return $default(_that.status,_that.profile,_that.handle,_that.displayName,_that.handleCheckStatus,_that.handleCheckMessage,_that.isSubmitting,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( OnboardingStatus status,  identity.Profile? profile,  String handle,  String displayName,  HandleCheckStatus handleCheckStatus,  String handleCheckMessage,  bool isSubmitting,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _OnboardingState() when $default != null:
return $default(_that.status,_that.profile,_that.handle,_that.displayName,_that.handleCheckStatus,_that.handleCheckMessage,_that.isSubmitting,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _OnboardingState extends OnboardingState {
  const _OnboardingState({this.status = OnboardingStatus.unknown, this.profile, this.handle = '', this.displayName = '', this.handleCheckStatus = HandleCheckStatus.idle, this.handleCheckMessage = '', this.isSubmitting = false, this.error}): super._();
  

@override@JsonKey() final  OnboardingStatus status;
@override final  identity.Profile? profile;
@override@JsonKey() final  String handle;
@override@JsonKey() final  String displayName;
@override@JsonKey() final  HandleCheckStatus handleCheckStatus;
@override@JsonKey() final  String handleCheckMessage;
@override@JsonKey() final  bool isSubmitting;
@override final  AppException? error;

/// Create a copy of OnboardingState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OnboardingStateCopyWith<_OnboardingState> get copyWith => __$OnboardingStateCopyWithImpl<_OnboardingState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _OnboardingState&&(identical(other.status, status) || other.status == status)&&(identical(other.profile, profile) || other.profile == profile)&&(identical(other.handle, handle) || other.handle == handle)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.handleCheckStatus, handleCheckStatus) || other.handleCheckStatus == handleCheckStatus)&&(identical(other.handleCheckMessage, handleCheckMessage) || other.handleCheckMessage == handleCheckMessage)&&(identical(other.isSubmitting, isSubmitting) || other.isSubmitting == isSubmitting)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,profile,handle,displayName,handleCheckStatus,handleCheckMessage,isSubmitting,error);
}

@override
String toString() {
    return 'OnboardingState(status: $status, profile: $profile, handle: $handle, displayName: $displayName, handleCheckStatus: $handleCheckStatus, handleCheckMessage: $handleCheckMessage, isSubmitting: $isSubmitting, error: $error)';
}


}

/// @nodoc
abstract mixin class _$OnboardingStateCopyWith<$Res> implements $OnboardingStateCopyWith<$Res> {
  factory _$OnboardingStateCopyWith(_OnboardingState value, $Res Function(_OnboardingState) _then) = __$OnboardingStateCopyWithImpl;
@override @useResult
$Res call({
 OnboardingStatus status, identity.Profile? profile, String handle, String displayName, HandleCheckStatus handleCheckStatus, String handleCheckMessage, bool isSubmitting, AppException? error
});




}
/// @nodoc
class __$OnboardingStateCopyWithImpl<$Res>
    implements _$OnboardingStateCopyWith<$Res> {
  __$OnboardingStateCopyWithImpl(this._self, this._then);

  final _OnboardingState _self;
  final $Res Function(_OnboardingState) _then;

/// Create a copy of OnboardingState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? profile = freezed,Object? handle = null,Object? displayName = null,Object? handleCheckStatus = null,Object? handleCheckMessage = null,Object? isSubmitting = null,Object? error = freezed,}) {
  return _then(_OnboardingState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as OnboardingStatus,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as identity.Profile?,handle: null == handle ? _self.handle : handle // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,handleCheckStatus: null == handleCheckStatus ? _self.handleCheckStatus : handleCheckStatus // ignore: cast_nullable_to_non_nullable
as HandleCheckStatus,handleCheckMessage: null == handleCheckMessage ? _self.handleCheckMessage : handleCheckMessage // ignore: cast_nullable_to_non_nullable
as String,isSubmitting: null == isSubmitting ? _self.isSubmitting : isSubmitting // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
