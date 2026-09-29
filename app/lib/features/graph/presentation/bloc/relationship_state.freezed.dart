// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'relationship_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RelationshipState {

 graph.Relationship get relationship; bool get isUpdating; AppException? get error;
/// Create a copy of RelationshipState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RelationshipStateCopyWith<RelationshipState> get copyWith => _$RelationshipStateCopyWithImpl<RelationshipState>(this as RelationshipState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as RelationshipState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RelationshipState&&(identical(other.relationship, _this.relationship) || other.relationship == _this.relationship)&&(identical(other.isUpdating, _this.isUpdating) || other.isUpdating == _this.isUpdating)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as RelationshipState;
  return Object.hash(runtimeType,_this.relationship,_this.isUpdating,_this.error);
}

@override
String toString() {
  final _this = this as RelationshipState;
  return 'RelationshipState(relationship: ${_this.relationship}, isUpdating: ${_this.isUpdating}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $RelationshipStateCopyWith<$Res>  {
  factory $RelationshipStateCopyWith(RelationshipState value, $Res Function(RelationshipState) _then) = _$RelationshipStateCopyWithImpl;
@useResult
$Res call({
 graph.Relationship relationship, bool isUpdating, AppException? error
});




}
/// @nodoc
class _$RelationshipStateCopyWithImpl<$Res>
    implements $RelationshipStateCopyWith<$Res> {
  _$RelationshipStateCopyWithImpl(this._self, this._then);

  final RelationshipState _self;
  final $Res Function(RelationshipState) _then;

/// Create a copy of RelationshipState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? relationship = null,Object? isUpdating = null,Object? error = freezed,}) {
  return _then(RelationshipState(
relationship: null == relationship ? _self.relationship : relationship // ignore: cast_nullable_to_non_nullable
as graph.Relationship,isUpdating: null == isUpdating ? _self.isUpdating : isUpdating // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [RelationshipState].
extension RelationshipStatePatterns on RelationshipState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RelationshipState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RelationshipState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RelationshipState value)  $default,){
final _that = this;
switch (_that) {
case _RelationshipState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RelationshipState value)?  $default,){
final _that = this;
switch (_that) {
case _RelationshipState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( graph.Relationship relationship,  bool isUpdating,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RelationshipState() when $default != null:
return $default(_that.relationship,_that.isUpdating,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( graph.Relationship relationship,  bool isUpdating,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _RelationshipState():
return $default(_that.relationship,_that.isUpdating,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( graph.Relationship relationship,  bool isUpdating,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _RelationshipState() when $default != null:
return $default(_that.relationship,_that.isUpdating,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _RelationshipState implements RelationshipState {
  const _RelationshipState({required this.relationship, this.isUpdating = false, this.error});
  

@override final  graph.Relationship relationship;
@override@JsonKey() final  bool isUpdating;
@override final  AppException? error;

/// Create a copy of RelationshipState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RelationshipStateCopyWith<_RelationshipState> get copyWith => __$RelationshipStateCopyWithImpl<_RelationshipState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _RelationshipState&&(identical(other.relationship, relationship) || other.relationship == relationship)&&(identical(other.isUpdating, isUpdating) || other.isUpdating == isUpdating)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,relationship,isUpdating,error);
}

@override
String toString() {
    return 'RelationshipState(relationship: $relationship, isUpdating: $isUpdating, error: $error)';
}


}

/// @nodoc
abstract mixin class _$RelationshipStateCopyWith<$Res> implements $RelationshipStateCopyWith<$Res> {
  factory _$RelationshipStateCopyWith(_RelationshipState value, $Res Function(_RelationshipState) _then) = __$RelationshipStateCopyWithImpl;
@override @useResult
$Res call({
 graph.Relationship relationship, bool isUpdating, AppException? error
});




}
/// @nodoc
class __$RelationshipStateCopyWithImpl<$Res>
    implements _$RelationshipStateCopyWith<$Res> {
  __$RelationshipStateCopyWithImpl(this._self, this._then);

  final _RelationshipState _self;
  final $Res Function(_RelationshipState) _then;

/// Create a copy of RelationshipState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? relationship = null,Object? isUpdating = null,Object? error = freezed,}) {
  return _then(_RelationshipState(
relationship: null == relationship ? _self.relationship : relationship // ignore: cast_nullable_to_non_nullable
as graph.Relationship,isUpdating: null == isUpdating ? _self.isUpdating : isUpdating // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
