// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'creator_insights_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$CreatorInsightsState {

 int get windowDays;
/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreatorInsightsStateCopyWith<CreatorInsightsState> get copyWith => _$CreatorInsightsStateCopyWithImpl<CreatorInsightsState>(this as CreatorInsightsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as CreatorInsightsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CreatorInsightsState&&(identical(other.windowDays, _this.windowDays) || other.windowDays == _this.windowDays));
}


@override
int get hashCode {
  final _this = this as CreatorInsightsState;
  return Object.hash(runtimeType,_this.windowDays);
}

@override
String toString() {
  final _this = this as CreatorInsightsState;
  return 'CreatorInsightsState(windowDays: ${_this.windowDays})';
}


}

/// @nodoc
abstract mixin class $CreatorInsightsStateCopyWith<$Res>  {
  factory $CreatorInsightsStateCopyWith(CreatorInsightsState value, $Res Function(CreatorInsightsState) _then) = _$CreatorInsightsStateCopyWithImpl;
@useResult
$Res call({
 int windowDays
});




}
/// @nodoc
class _$CreatorInsightsStateCopyWithImpl<$Res>
    implements $CreatorInsightsStateCopyWith<$Res> {
  _$CreatorInsightsStateCopyWithImpl(this._self, this._then);

  final CreatorInsightsState _self;
  final $Res Function(CreatorInsightsState) _then;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? windowDays = null,}) {
  return _then(_self.copyWith(
windowDays: null == windowDays ? _self.windowDays : windowDays // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [CreatorInsightsState].
extension CreatorInsightsStatePatterns on CreatorInsightsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CreatorInsightsLoading value)?  loading,TResult Function( CreatorInsightsEmpty value)?  empty,TResult Function( CreatorInsightsReady value)?  ready,TResult Function( CreatorInsightsError value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CreatorInsightsLoading() when loading != null:
return loading(_that);case CreatorInsightsEmpty() when empty != null:
return empty(_that);case CreatorInsightsReady() when ready != null:
return ready(_that);case CreatorInsightsError() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CreatorInsightsLoading value)  loading,required TResult Function( CreatorInsightsEmpty value)  empty,required TResult Function( CreatorInsightsReady value)  ready,required TResult Function( CreatorInsightsError value)  error,}){
final _that = this;
switch (_that) {
case CreatorInsightsLoading():
return loading(_that);case CreatorInsightsEmpty():
return empty(_that);case CreatorInsightsReady():
return ready(_that);case CreatorInsightsError():
return error(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CreatorInsightsLoading value)?  loading,TResult? Function( CreatorInsightsEmpty value)?  empty,TResult? Function( CreatorInsightsReady value)?  ready,TResult? Function( CreatorInsightsError value)?  error,}){
final _that = this;
switch (_that) {
case CreatorInsightsLoading() when loading != null:
return loading(_that);case CreatorInsightsEmpty() when empty != null:
return empty(_that);case CreatorInsightsReady() when ready != null:
return ready(_that);case CreatorInsightsError() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( int windowDays)?  loading,TResult Function( int windowDays)?  empty,TResult Function( int windowDays,  pb.GetCreatorInsightsResponse data)?  ready,TResult Function( int windowDays,  AppException error)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CreatorInsightsLoading() when loading != null:
return loading(_that.windowDays);case CreatorInsightsEmpty() when empty != null:
return empty(_that.windowDays);case CreatorInsightsReady() when ready != null:
return ready(_that.windowDays,_that.data);case CreatorInsightsError() when error != null:
return error(_that.windowDays,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( int windowDays)  loading,required TResult Function( int windowDays)  empty,required TResult Function( int windowDays,  pb.GetCreatorInsightsResponse data)  ready,required TResult Function( int windowDays,  AppException error)  error,}) {final _that = this;
switch (_that) {
case CreatorInsightsLoading():
return loading(_that.windowDays);case CreatorInsightsEmpty():
return empty(_that.windowDays);case CreatorInsightsReady():
return ready(_that.windowDays,_that.data);case CreatorInsightsError():
return error(_that.windowDays,_that.error);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( int windowDays)?  loading,TResult? Function( int windowDays)?  empty,TResult? Function( int windowDays,  pb.GetCreatorInsightsResponse data)?  ready,TResult? Function( int windowDays,  AppException error)?  error,}) {final _that = this;
switch (_that) {
case CreatorInsightsLoading() when loading != null:
return loading(_that.windowDays);case CreatorInsightsEmpty() when empty != null:
return empty(_that.windowDays);case CreatorInsightsReady() when ready != null:
return ready(_that.windowDays,_that.data);case CreatorInsightsError() when error != null:
return error(_that.windowDays,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class CreatorInsightsLoading implements CreatorInsightsState {
  const CreatorInsightsLoading({this.windowDays = 28});
  

@override@JsonKey() final  int windowDays;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreatorInsightsLoadingCopyWith<CreatorInsightsLoading> get copyWith => _$CreatorInsightsLoadingCopyWithImpl<CreatorInsightsLoading>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CreatorInsightsLoading&&(identical(other.windowDays, windowDays) || other.windowDays == windowDays));
}


@override
int get hashCode {
    return Object.hash(runtimeType,windowDays);
}

@override
String toString() {
    return 'CreatorInsightsState.loading(windowDays: $windowDays)';
}


}

/// @nodoc
abstract mixin class $CreatorInsightsLoadingCopyWith<$Res> implements $CreatorInsightsStateCopyWith<$Res> {
  factory $CreatorInsightsLoadingCopyWith(CreatorInsightsLoading value, $Res Function(CreatorInsightsLoading) _then) = _$CreatorInsightsLoadingCopyWithImpl;
@override @useResult
$Res call({
 int windowDays
});




}
/// @nodoc
class _$CreatorInsightsLoadingCopyWithImpl<$Res>
    implements $CreatorInsightsLoadingCopyWith<$Res> {
  _$CreatorInsightsLoadingCopyWithImpl(this._self, this._then);

  final CreatorInsightsLoading _self;
  final $Res Function(CreatorInsightsLoading) _then;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? windowDays = null,}) {
  return _then(CreatorInsightsLoading(
windowDays: null == windowDays ? _self.windowDays : windowDays // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class CreatorInsightsEmpty implements CreatorInsightsState {
  const CreatorInsightsEmpty({this.windowDays = 28});
  

@override@JsonKey() final  int windowDays;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreatorInsightsEmptyCopyWith<CreatorInsightsEmpty> get copyWith => _$CreatorInsightsEmptyCopyWithImpl<CreatorInsightsEmpty>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CreatorInsightsEmpty&&(identical(other.windowDays, windowDays) || other.windowDays == windowDays));
}


@override
int get hashCode {
    return Object.hash(runtimeType,windowDays);
}

@override
String toString() {
    return 'CreatorInsightsState.empty(windowDays: $windowDays)';
}


}

/// @nodoc
abstract mixin class $CreatorInsightsEmptyCopyWith<$Res> implements $CreatorInsightsStateCopyWith<$Res> {
  factory $CreatorInsightsEmptyCopyWith(CreatorInsightsEmpty value, $Res Function(CreatorInsightsEmpty) _then) = _$CreatorInsightsEmptyCopyWithImpl;
@override @useResult
$Res call({
 int windowDays
});




}
/// @nodoc
class _$CreatorInsightsEmptyCopyWithImpl<$Res>
    implements $CreatorInsightsEmptyCopyWith<$Res> {
  _$CreatorInsightsEmptyCopyWithImpl(this._self, this._then);

  final CreatorInsightsEmpty _self;
  final $Res Function(CreatorInsightsEmpty) _then;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? windowDays = null,}) {
  return _then(CreatorInsightsEmpty(
windowDays: null == windowDays ? _self.windowDays : windowDays // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class CreatorInsightsReady implements CreatorInsightsState {
  const CreatorInsightsReady({required this.windowDays, required this.data});
  

@override final  int windowDays;
 final  pb.GetCreatorInsightsResponse data;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreatorInsightsReadyCopyWith<CreatorInsightsReady> get copyWith => _$CreatorInsightsReadyCopyWithImpl<CreatorInsightsReady>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CreatorInsightsReady&&(identical(other.windowDays, windowDays) || other.windowDays == windowDays)&&(identical(other.data, data) || other.data == data));
}


@override
int get hashCode {
    return Object.hash(runtimeType,windowDays,data);
}

@override
String toString() {
    return 'CreatorInsightsState.ready(windowDays: $windowDays, data: $data)';
}


}

/// @nodoc
abstract mixin class $CreatorInsightsReadyCopyWith<$Res> implements $CreatorInsightsStateCopyWith<$Res> {
  factory $CreatorInsightsReadyCopyWith(CreatorInsightsReady value, $Res Function(CreatorInsightsReady) _then) = _$CreatorInsightsReadyCopyWithImpl;
@override @useResult
$Res call({
 int windowDays, pb.GetCreatorInsightsResponse data
});




}
/// @nodoc
class _$CreatorInsightsReadyCopyWithImpl<$Res>
    implements $CreatorInsightsReadyCopyWith<$Res> {
  _$CreatorInsightsReadyCopyWithImpl(this._self, this._then);

  final CreatorInsightsReady _self;
  final $Res Function(CreatorInsightsReady) _then;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? windowDays = null,Object? data = null,}) {
  return _then(CreatorInsightsReady(
windowDays: null == windowDays ? _self.windowDays : windowDays // ignore: cast_nullable_to_non_nullable
as int,data: null == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as pb.GetCreatorInsightsResponse,
  ));
}


}

/// @nodoc


class CreatorInsightsError implements CreatorInsightsState {
  const CreatorInsightsError({required this.windowDays, required this.error});
  

@override final  int windowDays;
 final  AppException error;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreatorInsightsErrorCopyWith<CreatorInsightsError> get copyWith => _$CreatorInsightsErrorCopyWithImpl<CreatorInsightsError>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CreatorInsightsError&&(identical(other.windowDays, windowDays) || other.windowDays == windowDays)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,windowDays,error);
}

@override
String toString() {
    return 'CreatorInsightsState.error(windowDays: $windowDays, error: $error)';
}


}

/// @nodoc
abstract mixin class $CreatorInsightsErrorCopyWith<$Res> implements $CreatorInsightsStateCopyWith<$Res> {
  factory $CreatorInsightsErrorCopyWith(CreatorInsightsError value, $Res Function(CreatorInsightsError) _then) = _$CreatorInsightsErrorCopyWithImpl;
@override @useResult
$Res call({
 int windowDays, AppException error
});




}
/// @nodoc
class _$CreatorInsightsErrorCopyWithImpl<$Res>
    implements $CreatorInsightsErrorCopyWith<$Res> {
  _$CreatorInsightsErrorCopyWithImpl(this._self, this._then);

  final CreatorInsightsError _self;
  final $Res Function(CreatorInsightsError) _then;

/// Create a copy of CreatorInsightsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? windowDays = null,Object? error = null,}) {
  return _then(CreatorInsightsError(
windowDays: null == windowDays ? _self.windowDays : windowDays // ignore: cast_nullable_to_non_nullable
as int,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException,
  ));
}


}

// dart format on
