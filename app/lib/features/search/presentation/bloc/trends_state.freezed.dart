// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'trends_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TrendsState {

 TrendsStatus get status; List<Trend> get trends;/// When the server computed the list; null when there is no list yet.
 DateTime? get computedAt; Object? get error;
/// Create a copy of TrendsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TrendsStateCopyWith<TrendsState> get copyWith => _$TrendsStateCopyWithImpl<TrendsState>(this as TrendsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as TrendsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TrendsState&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.trends, _this.trends)&&(identical(other.computedAt, _this.computedAt) || other.computedAt == _this.computedAt)&&const DeepCollectionEquality().equals(other.error, _this.error));
}


@override
int get hashCode {
  final _this = this as TrendsState;
  return Object.hash(runtimeType,_this.status,const DeepCollectionEquality().hash(_this.trends),_this.computedAt,const DeepCollectionEquality().hash(_this.error));
}

@override
String toString() {
  final _this = this as TrendsState;
  return 'TrendsState(status: ${_this.status}, trends: ${_this.trends}, computedAt: ${_this.computedAt}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $TrendsStateCopyWith<$Res>  {
  factory $TrendsStateCopyWith(TrendsState value, $Res Function(TrendsState) _then) = _$TrendsStateCopyWithImpl;
@useResult
$Res call({
 TrendsStatus status, List<Trend> trends, DateTime? computedAt, Object? error
});




}
/// @nodoc
class _$TrendsStateCopyWithImpl<$Res>
    implements $TrendsStateCopyWith<$Res> {
  _$TrendsStateCopyWithImpl(this._self, this._then);

  final TrendsState _self;
  final $Res Function(TrendsState) _then;

/// Create a copy of TrendsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? trends = null,Object? computedAt = freezed,Object? error = freezed,}) {
  return _then(TrendsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TrendsStatus,trends: null == trends ? _self.trends : trends // ignore: cast_nullable_to_non_nullable
as List<Trend>,computedAt: freezed == computedAt ? _self.computedAt : computedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,error: freezed == error ? _self.error : error ,
  ));
}

}


/// Adds pattern-matching-related methods to [TrendsState].
extension TrendsStatePatterns on TrendsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TrendsState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TrendsState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TrendsState value)  $default,){
final _that = this;
switch (_that) {
case _TrendsState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TrendsState value)?  $default,){
final _that = this;
switch (_that) {
case _TrendsState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( TrendsStatus status,  List<Trend> trends,  DateTime? computedAt,  Object? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TrendsState() when $default != null:
return $default(_that.status,_that.trends,_that.computedAt,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( TrendsStatus status,  List<Trend> trends,  DateTime? computedAt,  Object? error)  $default,) {final _that = this;
switch (_that) {
case _TrendsState():
return $default(_that.status,_that.trends,_that.computedAt,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( TrendsStatus status,  List<Trend> trends,  DateTime? computedAt,  Object? error)?  $default,) {final _that = this;
switch (_that) {
case _TrendsState() when $default != null:
return $default(_that.status,_that.trends,_that.computedAt,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _TrendsState implements TrendsState {
  const _TrendsState({this.status = TrendsStatus.initial,  List<Trend> trends = const <Trend>[], this.computedAt, this.error}): _trends = trends;
  

@override@JsonKey() final  TrendsStatus status;
 final  List<Trend> _trends;
@override@JsonKey() List<Trend> get trends {
  if (_trends is EqualUnmodifiableListView) return _trends;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_trends);
}

/// When the server computed the list; null when there is no list yet.
@override final  DateTime? computedAt;
@override final  Object? error;

/// Create a copy of TrendsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TrendsStateCopyWith<_TrendsState> get copyWith => __$TrendsStateCopyWithImpl<_TrendsState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _TrendsState&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.trends, _trends)&&(identical(other.computedAt, computedAt) || other.computedAt == computedAt)&&const DeepCollectionEquality().equals(other.error, error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,const DeepCollectionEquality().hash(_trends),computedAt,const DeepCollectionEquality().hash(error));
}

@override
String toString() {
    return 'TrendsState(status: $status, trends: $trends, computedAt: $computedAt, error: $error)';
}


}

/// @nodoc
abstract mixin class _$TrendsStateCopyWith<$Res> implements $TrendsStateCopyWith<$Res> {
  factory _$TrendsStateCopyWith(_TrendsState value, $Res Function(_TrendsState) _then) = __$TrendsStateCopyWithImpl;
@override @useResult
$Res call({
 TrendsStatus status, List<Trend> trends, DateTime? computedAt, Object? error
});




}
/// @nodoc
class __$TrendsStateCopyWithImpl<$Res>
    implements _$TrendsStateCopyWith<$Res> {
  __$TrendsStateCopyWithImpl(this._self, this._then);

  final _TrendsState _self;
  final $Res Function(_TrendsState) _then;

/// Create a copy of TrendsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? trends = null,Object? computedAt = freezed,Object? error = freezed,}) {
  return _then(_TrendsState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TrendsStatus,trends: null == trends ? _self._trends : trends // ignore: cast_nullable_to_non_nullable
as List<Trend>,computedAt: freezed == computedAt ? _self.computedAt : computedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,error: freezed == error ? _self.error : error ,
  ));
}


}

// dart format on
