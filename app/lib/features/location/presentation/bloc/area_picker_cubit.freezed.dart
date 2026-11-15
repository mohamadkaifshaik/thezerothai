// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'area_picker_cubit.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AreaPickerState {

 AreaPickerLoad get load; List<AreaEntry> get areas; String get query; AppException? get error;
/// Create a copy of AreaPickerState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AreaPickerStateCopyWith<AreaPickerState> get copyWith => _$AreaPickerStateCopyWithImpl<AreaPickerState>(this as AreaPickerState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as AreaPickerState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AreaPickerState&&(identical(other.load, _this.load) || other.load == _this.load)&&const DeepCollectionEquality().equals(other.areas, _this.areas)&&(identical(other.query, _this.query) || other.query == _this.query)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as AreaPickerState;
  return Object.hash(runtimeType,_this.load,const DeepCollectionEquality().hash(_this.areas),_this.query,_this.error);
}

@override
String toString() {
  final _this = this as AreaPickerState;
  return 'AreaPickerState(load: ${_this.load}, areas: ${_this.areas}, query: ${_this.query}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $AreaPickerStateCopyWith<$Res>  {
  factory $AreaPickerStateCopyWith(AreaPickerState value, $Res Function(AreaPickerState) _then) = _$AreaPickerStateCopyWithImpl;
@useResult
$Res call({
 AreaPickerLoad load, List<AreaEntry> areas, String query, AppException? error
});




}
/// @nodoc
class _$AreaPickerStateCopyWithImpl<$Res>
    implements $AreaPickerStateCopyWith<$Res> {
  _$AreaPickerStateCopyWithImpl(this._self, this._then);

  final AreaPickerState _self;
  final $Res Function(AreaPickerState) _then;

/// Create a copy of AreaPickerState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? load = null,Object? areas = null,Object? query = null,Object? error = freezed,}) {
  return _then(AreaPickerState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as AreaPickerLoad,areas: null == areas ? _self.areas : areas // ignore: cast_nullable_to_non_nullable
as List<AreaEntry>,query: null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [AreaPickerState].
extension AreaPickerStatePatterns on AreaPickerState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AreaPickerState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AreaPickerState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AreaPickerState value)  $default,){
final _that = this;
switch (_that) {
case _AreaPickerState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AreaPickerState value)?  $default,){
final _that = this;
switch (_that) {
case _AreaPickerState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( AreaPickerLoad load,  List<AreaEntry> areas,  String query,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AreaPickerState() when $default != null:
return $default(_that.load,_that.areas,_that.query,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( AreaPickerLoad load,  List<AreaEntry> areas,  String query,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _AreaPickerState():
return $default(_that.load,_that.areas,_that.query,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( AreaPickerLoad load,  List<AreaEntry> areas,  String query,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _AreaPickerState() when $default != null:
return $default(_that.load,_that.areas,_that.query,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _AreaPickerState extends AreaPickerState {
  const _AreaPickerState({this.load = AreaPickerLoad.loading,  List<AreaEntry> areas = const <AreaEntry>[], this.query = '', this.error}): _areas = areas,super._();
  

@override@JsonKey() final  AreaPickerLoad load;
 final  List<AreaEntry> _areas;
@override@JsonKey() List<AreaEntry> get areas {
  if (_areas is EqualUnmodifiableListView) return _areas;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_areas);
}

@override@JsonKey() final  String query;
@override final  AppException? error;

/// Create a copy of AreaPickerState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AreaPickerStateCopyWith<_AreaPickerState> get copyWith => __$AreaPickerStateCopyWithImpl<_AreaPickerState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _AreaPickerState&&(identical(other.load, load) || other.load == load)&&const DeepCollectionEquality().equals(other.areas, _areas)&&(identical(other.query, query) || other.query == query)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,load,const DeepCollectionEquality().hash(_areas),query,error);
}

@override
String toString() {
    return 'AreaPickerState(load: $load, areas: $areas, query: $query, error: $error)';
}


}

/// @nodoc
abstract mixin class _$AreaPickerStateCopyWith<$Res> implements $AreaPickerStateCopyWith<$Res> {
  factory _$AreaPickerStateCopyWith(_AreaPickerState value, $Res Function(_AreaPickerState) _then) = __$AreaPickerStateCopyWithImpl;
@override @useResult
$Res call({
 AreaPickerLoad load, List<AreaEntry> areas, String query, AppException? error
});




}
/// @nodoc
class __$AreaPickerStateCopyWithImpl<$Res>
    implements _$AreaPickerStateCopyWith<$Res> {
  __$AreaPickerStateCopyWithImpl(this._self, this._then);

  final _AreaPickerState _self;
  final $Res Function(_AreaPickerState) _then;

/// Create a copy of AreaPickerState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? load = null,Object? areas = null,Object? query = null,Object? error = freezed,}) {
  return _then(_AreaPickerState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as AreaPickerLoad,areas: null == areas ? _self._areas : areas // ignore: cast_nullable_to_non_nullable
as List<AreaEntry>,query: null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
