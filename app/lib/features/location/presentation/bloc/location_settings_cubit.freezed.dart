// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'location_settings_cubit.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$LocationSettingsState {

 LocationLoad get load; LocationSettingsData? get data; bool get busy; AppException? get error; LocationNotice? get notice; int get serial;
/// Create a copy of LocationSettingsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LocationSettingsStateCopyWith<LocationSettingsState> get copyWith => _$LocationSettingsStateCopyWithImpl<LocationSettingsState>(this as LocationSettingsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as LocationSettingsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LocationSettingsState&&(identical(other.load, _this.load) || other.load == _this.load)&&(identical(other.data, _this.data) || other.data == _this.data)&&(identical(other.busy, _this.busy) || other.busy == _this.busy)&&(identical(other.error, _this.error) || other.error == _this.error)&&(identical(other.notice, _this.notice) || other.notice == _this.notice)&&(identical(other.serial, _this.serial) || other.serial == _this.serial));
}


@override
int get hashCode {
  final _this = this as LocationSettingsState;
  return Object.hash(runtimeType,_this.load,_this.data,_this.busy,_this.error,_this.notice,_this.serial);
}

@override
String toString() {
  final _this = this as LocationSettingsState;
  return 'LocationSettingsState(load: ${_this.load}, data: ${_this.data}, busy: ${_this.busy}, error: ${_this.error}, notice: ${_this.notice}, serial: ${_this.serial})';
}


}

/// @nodoc
abstract mixin class $LocationSettingsStateCopyWith<$Res>  {
  factory $LocationSettingsStateCopyWith(LocationSettingsState value, $Res Function(LocationSettingsState) _then) = _$LocationSettingsStateCopyWithImpl;
@useResult
$Res call({
 LocationLoad load, LocationSettingsData? data, bool busy, AppException? error, LocationNotice? notice, int serial
});




}
/// @nodoc
class _$LocationSettingsStateCopyWithImpl<$Res>
    implements $LocationSettingsStateCopyWith<$Res> {
  _$LocationSettingsStateCopyWithImpl(this._self, this._then);

  final LocationSettingsState _self;
  final $Res Function(LocationSettingsState) _then;

/// Create a copy of LocationSettingsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? load = null,Object? data = freezed,Object? busy = null,Object? error = freezed,Object? notice = freezed,Object? serial = null,}) {
  return _then(LocationSettingsState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as LocationLoad,data: freezed == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as LocationSettingsData?,busy: null == busy ? _self.busy : busy // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,notice: freezed == notice ? _self.notice : notice // ignore: cast_nullable_to_non_nullable
as LocationNotice?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [LocationSettingsState].
extension LocationSettingsStatePatterns on LocationSettingsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LocationSettingsState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LocationSettingsState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LocationSettingsState value)  $default,){
final _that = this;
switch (_that) {
case _LocationSettingsState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LocationSettingsState value)?  $default,){
final _that = this;
switch (_that) {
case _LocationSettingsState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( LocationLoad load,  LocationSettingsData? data,  bool busy,  AppException? error,  LocationNotice? notice,  int serial)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LocationSettingsState() when $default != null:
return $default(_that.load,_that.data,_that.busy,_that.error,_that.notice,_that.serial);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( LocationLoad load,  LocationSettingsData? data,  bool busy,  AppException? error,  LocationNotice? notice,  int serial)  $default,) {final _that = this;
switch (_that) {
case _LocationSettingsState():
return $default(_that.load,_that.data,_that.busy,_that.error,_that.notice,_that.serial);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( LocationLoad load,  LocationSettingsData? data,  bool busy,  AppException? error,  LocationNotice? notice,  int serial)?  $default,) {final _that = this;
switch (_that) {
case _LocationSettingsState() when $default != null:
return $default(_that.load,_that.data,_that.busy,_that.error,_that.notice,_that.serial);case _:
  return null;

}
}

}

/// @nodoc


class _LocationSettingsState extends LocationSettingsState {
  const _LocationSettingsState({this.load = LocationLoad.initial, this.data, this.busy = false, this.error, this.notice, this.serial = 0}): super._();
  

@override@JsonKey() final  LocationLoad load;
@override final  LocationSettingsData? data;
@override@JsonKey() final  bool busy;
@override final  AppException? error;
@override final  LocationNotice? notice;
@override@JsonKey() final  int serial;

/// Create a copy of LocationSettingsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LocationSettingsStateCopyWith<_LocationSettingsState> get copyWith => __$LocationSettingsStateCopyWithImpl<_LocationSettingsState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _LocationSettingsState&&(identical(other.load, load) || other.load == load)&&(identical(other.data, data) || other.data == data)&&(identical(other.busy, busy) || other.busy == busy)&&(identical(other.error, error) || other.error == error)&&(identical(other.notice, notice) || other.notice == notice)&&(identical(other.serial, serial) || other.serial == serial));
}


@override
int get hashCode {
    return Object.hash(runtimeType,load,data,busy,error,notice,serial);
}

@override
String toString() {
    return 'LocationSettingsState(load: $load, data: $data, busy: $busy, error: $error, notice: $notice, serial: $serial)';
}


}

/// @nodoc
abstract mixin class _$LocationSettingsStateCopyWith<$Res> implements $LocationSettingsStateCopyWith<$Res> {
  factory _$LocationSettingsStateCopyWith(_LocationSettingsState value, $Res Function(_LocationSettingsState) _then) = __$LocationSettingsStateCopyWithImpl;
@override @useResult
$Res call({
 LocationLoad load, LocationSettingsData? data, bool busy, AppException? error, LocationNotice? notice, int serial
});




}
/// @nodoc
class __$LocationSettingsStateCopyWithImpl<$Res>
    implements _$LocationSettingsStateCopyWith<$Res> {
  __$LocationSettingsStateCopyWithImpl(this._self, this._then);

  final _LocationSettingsState _self;
  final $Res Function(_LocationSettingsState) _then;

/// Create a copy of LocationSettingsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? load = null,Object? data = freezed,Object? busy = null,Object? error = freezed,Object? notice = freezed,Object? serial = null,}) {
  return _then(_LocationSettingsState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as LocationLoad,data: freezed == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as LocationSettingsData?,busy: null == busy ? _self.busy : busy // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,notice: freezed == notice ? _self.notice : notice // ignore: cast_nullable_to_non_nullable
as LocationNotice?,serial: null == serial ? _self.serial : serial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
