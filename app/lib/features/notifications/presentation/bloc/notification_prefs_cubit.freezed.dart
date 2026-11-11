// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'notification_prefs_cubit.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$NotificationPrefsState {

 NotificationPrefsStatus get status; NotificationPushPrefs? get prefs; NotificationPrefsGroup? get saving; AppException? get loadError; AppException? get error; int get serial;
/// Create a copy of NotificationPrefsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NotificationPrefsStateCopyWith<NotificationPrefsState> get copyWith => _$NotificationPrefsStateCopyWithImpl<NotificationPrefsState>(this as NotificationPrefsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as NotificationPrefsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NotificationPrefsState&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.prefs, _this.prefs) || other.prefs == _this.prefs)&&(identical(other.saving, _this.saving) || other.saving == _this.saving)&&(identical(other.loadError, _this.loadError) || other.loadError == _this.loadError)&&(identical(other.error, _this.error) || other.error == _this.error)&&(identical(other.serial, _this.serial) || other.serial == _this.serial));
}


@override
int get hashCode {
  final _this = this as NotificationPrefsState;
  return Object.hash(runtimeType,_this.status,_this.prefs,_this.saving,_this.loadError,_this.error,_this.serial);
}

@override
String toString() {
  final _this = this as NotificationPrefsState;
  return 'NotificationPrefsState(status: ${_this.status}, prefs: ${_this.prefs}, saving: ${_this.saving}, loadError: ${_this.loadError}, error: ${_this.error}, serial: ${_this.serial})';
}


}

/// @nodoc
abstract mixin class $NotificationPrefsStateCopyWith<$Res>  {
  factory $NotificationPrefsStateCopyWith(NotificationPrefsState value, $Res Function(NotificationPrefsState) _then) = _$NotificationPrefsStateCopyWithImpl;
@useResult
$Res call({
 NotificationPrefsStatus status, NotificationPushPrefs? prefs, NotificationPrefsGroup? saving, AppException? loadError, AppException? error, int serial
});




}
/// @nodoc
class _$NotificationPrefsStateCopyWithImpl<$Res>
    implements $NotificationPrefsStateCopyWith<$Res> {
  _$NotificationPrefsStateCopyWithImpl(this._self, this._then);

  final NotificationPrefsState _self;
  final $Res Function(NotificationPrefsState) _then;

/// Create a copy of NotificationPrefsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? prefs = freezed,Object? saving = freezed,Object? loadError = freezed,Object? error = freezed,Object? serial = null,}) {
  return _then(NotificationPrefsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as NotificationPrefsStatus,prefs: freezed == prefs ? _self.prefs : prefs // ignore: cast_nullable_to_non_nullable
as NotificationPushPrefs?,saving: freezed == saving ? _self.saving : saving // ignore: cast_nullable_to_non_nullable
as NotificationPrefsGroup?,loadError: freezed == loadError ? _self.loadError : loadError // ignore: cast_nullable_to_non_nullable
as AppException?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [NotificationPrefsState].
extension NotificationPrefsStatePatterns on NotificationPrefsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _NotificationPrefsState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _NotificationPrefsState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _NotificationPrefsState value)  $default,){
final _that = this;
switch (_that) {
case _NotificationPrefsState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _NotificationPrefsState value)?  $default,){
final _that = this;
switch (_that) {
case _NotificationPrefsState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( NotificationPrefsStatus status,  NotificationPushPrefs? prefs,  NotificationPrefsGroup? saving,  AppException? loadError,  AppException? error,  int serial)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _NotificationPrefsState() when $default != null:
return $default(_that.status,_that.prefs,_that.saving,_that.loadError,_that.error,_that.serial);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( NotificationPrefsStatus status,  NotificationPushPrefs? prefs,  NotificationPrefsGroup? saving,  AppException? loadError,  AppException? error,  int serial)  $default,) {final _that = this;
switch (_that) {
case _NotificationPrefsState():
return $default(_that.status,_that.prefs,_that.saving,_that.loadError,_that.error,_that.serial);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( NotificationPrefsStatus status,  NotificationPushPrefs? prefs,  NotificationPrefsGroup? saving,  AppException? loadError,  AppException? error,  int serial)?  $default,) {final _that = this;
switch (_that) {
case _NotificationPrefsState() when $default != null:
return $default(_that.status,_that.prefs,_that.saving,_that.loadError,_that.error,_that.serial);case _:
  return null;

}
}

}

/// @nodoc


class _NotificationPrefsState implements NotificationPrefsState {
  const _NotificationPrefsState({this.status = NotificationPrefsStatus.loading, this.prefs, this.saving, this.loadError, this.error, this.serial = 0});
  

@override@JsonKey() final  NotificationPrefsStatus status;
@override final  NotificationPushPrefs? prefs;
@override final  NotificationPrefsGroup? saving;
@override final  AppException? loadError;
@override final  AppException? error;
@override@JsonKey() final  int serial;

/// Create a copy of NotificationPrefsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$NotificationPrefsStateCopyWith<_NotificationPrefsState> get copyWith => __$NotificationPrefsStateCopyWithImpl<_NotificationPrefsState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _NotificationPrefsState&&(identical(other.status, status) || other.status == status)&&(identical(other.prefs, prefs) || other.prefs == prefs)&&(identical(other.saving, saving) || other.saving == saving)&&(identical(other.loadError, loadError) || other.loadError == loadError)&&(identical(other.error, error) || other.error == error)&&(identical(other.serial, serial) || other.serial == serial));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,prefs,saving,loadError,error,serial);
}

@override
String toString() {
    return 'NotificationPrefsState(status: $status, prefs: $prefs, saving: $saving, loadError: $loadError, error: $error, serial: $serial)';
}


}

/// @nodoc
abstract mixin class _$NotificationPrefsStateCopyWith<$Res> implements $NotificationPrefsStateCopyWith<$Res> {
  factory _$NotificationPrefsStateCopyWith(_NotificationPrefsState value, $Res Function(_NotificationPrefsState) _then) = __$NotificationPrefsStateCopyWithImpl;
@override @useResult
$Res call({
 NotificationPrefsStatus status, NotificationPushPrefs? prefs, NotificationPrefsGroup? saving, AppException? loadError, AppException? error, int serial
});




}
/// @nodoc
class __$NotificationPrefsStateCopyWithImpl<$Res>
    implements _$NotificationPrefsStateCopyWith<$Res> {
  __$NotificationPrefsStateCopyWithImpl(this._self, this._then);

  final _NotificationPrefsState _self;
  final $Res Function(_NotificationPrefsState) _then;

/// Create a copy of NotificationPrefsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? prefs = freezed,Object? saving = freezed,Object? loadError = freezed,Object? error = freezed,Object? serial = null,}) {
  return _then(_NotificationPrefsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as NotificationPrefsStatus,prefs: freezed == prefs ? _self.prefs : prefs // ignore: cast_nullable_to_non_nullable
as NotificationPushPrefs?,saving: freezed == saving ? _self.saving : saving // ignore: cast_nullable_to_non_nullable
as NotificationPrefsGroup?,loadError: freezed == loadError ? _self.loadError : loadError // ignore: cast_nullable_to_non_nullable
as AppException?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
