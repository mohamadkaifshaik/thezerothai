// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'profile_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ProfileState {

 ProfileStatus get status; identity.Profile? get profile; graph.Relationship? get relationship; bool get isOwnProfile; bool get graphEnabled; AppException? get error;
/// Create a copy of ProfileState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileStateCopyWith<ProfileState> get copyWith => _$ProfileStateCopyWithImpl<ProfileState>(this as ProfileState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ProfileState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileState&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.profile, _this.profile) || other.profile == _this.profile)&&(identical(other.relationship, _this.relationship) || other.relationship == _this.relationship)&&(identical(other.isOwnProfile, _this.isOwnProfile) || other.isOwnProfile == _this.isOwnProfile)&&(identical(other.graphEnabled, _this.graphEnabled) || other.graphEnabled == _this.graphEnabled)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as ProfileState;
  return Object.hash(runtimeType,_this.status,_this.profile,_this.relationship,_this.isOwnProfile,_this.graphEnabled,_this.error);
}

@override
String toString() {
  final _this = this as ProfileState;
  return 'ProfileState(status: ${_this.status}, profile: ${_this.profile}, relationship: ${_this.relationship}, isOwnProfile: ${_this.isOwnProfile}, graphEnabled: ${_this.graphEnabled}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $ProfileStateCopyWith<$Res>  {
  factory $ProfileStateCopyWith(ProfileState value, $Res Function(ProfileState) _then) = _$ProfileStateCopyWithImpl;
@useResult
$Res call({
 ProfileStatus status, identity.Profile? profile, graph.Relationship? relationship, bool isOwnProfile, bool graphEnabled, AppException? error
});




}
/// @nodoc
class _$ProfileStateCopyWithImpl<$Res>
    implements $ProfileStateCopyWith<$Res> {
  _$ProfileStateCopyWithImpl(this._self, this._then);

  final ProfileState _self;
  final $Res Function(ProfileState) _then;

/// Create a copy of ProfileState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? profile = freezed,Object? relationship = freezed,Object? isOwnProfile = null,Object? graphEnabled = null,Object? error = freezed,}) {
  return _then(ProfileState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ProfileStatus,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as identity.Profile?,relationship: freezed == relationship ? _self.relationship : relationship // ignore: cast_nullable_to_non_nullable
as graph.Relationship?,isOwnProfile: null == isOwnProfile ? _self.isOwnProfile : isOwnProfile // ignore: cast_nullable_to_non_nullable
as bool,graphEnabled: null == graphEnabled ? _self.graphEnabled : graphEnabled // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [ProfileState].
extension ProfileStatePatterns on ProfileState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProfileState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProfileState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProfileState value)  $default,){
final _that = this;
switch (_that) {
case _ProfileState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProfileState value)?  $default,){
final _that = this;
switch (_that) {
case _ProfileState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ProfileStatus status,  identity.Profile? profile,  graph.Relationship? relationship,  bool isOwnProfile,  bool graphEnabled,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProfileState() when $default != null:
return $default(_that.status,_that.profile,_that.relationship,_that.isOwnProfile,_that.graphEnabled,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ProfileStatus status,  identity.Profile? profile,  graph.Relationship? relationship,  bool isOwnProfile,  bool graphEnabled,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _ProfileState():
return $default(_that.status,_that.profile,_that.relationship,_that.isOwnProfile,_that.graphEnabled,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ProfileStatus status,  identity.Profile? profile,  graph.Relationship? relationship,  bool isOwnProfile,  bool graphEnabled,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _ProfileState() when $default != null:
return $default(_that.status,_that.profile,_that.relationship,_that.isOwnProfile,_that.graphEnabled,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _ProfileState implements ProfileState {
  const _ProfileState({this.status = ProfileStatus.loading, this.profile, this.relationship, this.isOwnProfile = false, this.graphEnabled = false, this.error});
  

@override@JsonKey() final  ProfileStatus status;
@override final  identity.Profile? profile;
@override final  graph.Relationship? relationship;
@override@JsonKey() final  bool isOwnProfile;
@override@JsonKey() final  bool graphEnabled;
@override final  AppException? error;

/// Create a copy of ProfileState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProfileStateCopyWith<_ProfileState> get copyWith => __$ProfileStateCopyWithImpl<_ProfileState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProfileState&&(identical(other.status, status) || other.status == status)&&(identical(other.profile, profile) || other.profile == profile)&&(identical(other.relationship, relationship) || other.relationship == relationship)&&(identical(other.isOwnProfile, isOwnProfile) || other.isOwnProfile == isOwnProfile)&&(identical(other.graphEnabled, graphEnabled) || other.graphEnabled == graphEnabled)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,profile,relationship,isOwnProfile,graphEnabled,error);
}

@override
String toString() {
    return 'ProfileState(status: $status, profile: $profile, relationship: $relationship, isOwnProfile: $isOwnProfile, graphEnabled: $graphEnabled, error: $error)';
}


}

/// @nodoc
abstract mixin class _$ProfileStateCopyWith<$Res> implements $ProfileStateCopyWith<$Res> {
  factory _$ProfileStateCopyWith(_ProfileState value, $Res Function(_ProfileState) _then) = __$ProfileStateCopyWithImpl;
@override @useResult
$Res call({
 ProfileStatus status, identity.Profile? profile, graph.Relationship? relationship, bool isOwnProfile, bool graphEnabled, AppException? error
});




}
/// @nodoc
class __$ProfileStateCopyWithImpl<$Res>
    implements _$ProfileStateCopyWith<$Res> {
  __$ProfileStateCopyWithImpl(this._self, this._then);

  final _ProfileState _self;
  final $Res Function(_ProfileState) _then;

/// Create a copy of ProfileState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? profile = freezed,Object? relationship = freezed,Object? isOwnProfile = null,Object? graphEnabled = null,Object? error = freezed,}) {
  return _then(_ProfileState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ProfileStatus,profile: freezed == profile ? _self.profile : profile // ignore: cast_nullable_to_non_nullable
as identity.Profile?,relationship: freezed == relationship ? _self.relationship : relationship // ignore: cast_nullable_to_non_nullable
as graph.Relationship?,isOwnProfile: null == isOwnProfile ? _self.isOwnProfile : isOwnProfile // ignore: cast_nullable_to_non_nullable
as bool,graphEnabled: null == graphEnabled ? _self.graphEnabled : graphEnabled // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
