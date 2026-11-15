// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'data_usage_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DataUsageState {

 bool get dataSaver; HighQualityImages get images; HighQualityUploads get uploads;/// The connection is metered (mobile data).
 bool get metered;/// The saved choices have been read.
 bool get loaded;
/// Create a copy of DataUsageState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DataUsageStateCopyWith<DataUsageState> get copyWith => _$DataUsageStateCopyWithImpl<DataUsageState>(this as DataUsageState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as DataUsageState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DataUsageState&&(identical(other.dataSaver, _this.dataSaver) || other.dataSaver == _this.dataSaver)&&(identical(other.images, _this.images) || other.images == _this.images)&&(identical(other.uploads, _this.uploads) || other.uploads == _this.uploads)&&(identical(other.metered, _this.metered) || other.metered == _this.metered)&&(identical(other.loaded, _this.loaded) || other.loaded == _this.loaded));
}


@override
int get hashCode {
  final _this = this as DataUsageState;
  return Object.hash(runtimeType,_this.dataSaver,_this.images,_this.uploads,_this.metered,_this.loaded);
}

@override
String toString() {
  final _this = this as DataUsageState;
  return 'DataUsageState(dataSaver: ${_this.dataSaver}, images: ${_this.images}, uploads: ${_this.uploads}, metered: ${_this.metered}, loaded: ${_this.loaded})';
}


}

/// @nodoc
abstract mixin class $DataUsageStateCopyWith<$Res>  {
  factory $DataUsageStateCopyWith(DataUsageState value, $Res Function(DataUsageState) _then) = _$DataUsageStateCopyWithImpl;
@useResult
$Res call({
 bool dataSaver, HighQualityImages images, HighQualityUploads uploads, bool metered, bool loaded
});




}
/// @nodoc
class _$DataUsageStateCopyWithImpl<$Res>
    implements $DataUsageStateCopyWith<$Res> {
  _$DataUsageStateCopyWithImpl(this._self, this._then);

  final DataUsageState _self;
  final $Res Function(DataUsageState) _then;

/// Create a copy of DataUsageState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? dataSaver = null,Object? images = null,Object? uploads = null,Object? metered = null,Object? loaded = null,}) {
  return _then(DataUsageState(
dataSaver: null == dataSaver ? _self.dataSaver : dataSaver // ignore: cast_nullable_to_non_nullable
as bool,images: null == images ? _self.images : images // ignore: cast_nullable_to_non_nullable
as HighQualityImages,uploads: null == uploads ? _self.uploads : uploads // ignore: cast_nullable_to_non_nullable
as HighQualityUploads,metered: null == metered ? _self.metered : metered // ignore: cast_nullable_to_non_nullable
as bool,loaded: null == loaded ? _self.loaded : loaded // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [DataUsageState].
extension DataUsageStatePatterns on DataUsageState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DataUsageState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DataUsageState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DataUsageState value)  $default,){
final _that = this;
switch (_that) {
case _DataUsageState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DataUsageState value)?  $default,){
final _that = this;
switch (_that) {
case _DataUsageState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool dataSaver,  HighQualityImages images,  HighQualityUploads uploads,  bool metered,  bool loaded)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DataUsageState() when $default != null:
return $default(_that.dataSaver,_that.images,_that.uploads,_that.metered,_that.loaded);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool dataSaver,  HighQualityImages images,  HighQualityUploads uploads,  bool metered,  bool loaded)  $default,) {final _that = this;
switch (_that) {
case _DataUsageState():
return $default(_that.dataSaver,_that.images,_that.uploads,_that.metered,_that.loaded);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool dataSaver,  HighQualityImages images,  HighQualityUploads uploads,  bool metered,  bool loaded)?  $default,) {final _that = this;
switch (_that) {
case _DataUsageState() when $default != null:
return $default(_that.dataSaver,_that.images,_that.uploads,_that.metered,_that.loaded);case _:
  return null;

}
}

}

/// @nodoc


class _DataUsageState extends DataUsageState {
  const _DataUsageState({this.dataSaver = false, this.images = HighQualityImages.mobileAndWifi, this.uploads = HighQualityUploads.mobileAndWifi, this.metered = false, this.loaded = false}): super._();
  

@override@JsonKey() final  bool dataSaver;
@override@JsonKey() final  HighQualityImages images;
@override@JsonKey() final  HighQualityUploads uploads;
/// The connection is metered (mobile data).
@override@JsonKey() final  bool metered;
/// The saved choices have been read.
@override@JsonKey() final  bool loaded;

/// Create a copy of DataUsageState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DataUsageStateCopyWith<_DataUsageState> get copyWith => __$DataUsageStateCopyWithImpl<_DataUsageState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DataUsageState&&(identical(other.dataSaver, dataSaver) || other.dataSaver == dataSaver)&&(identical(other.images, images) || other.images == images)&&(identical(other.uploads, uploads) || other.uploads == uploads)&&(identical(other.metered, metered) || other.metered == metered)&&(identical(other.loaded, loaded) || other.loaded == loaded));
}


@override
int get hashCode {
    return Object.hash(runtimeType,dataSaver,images,uploads,metered,loaded);
}

@override
String toString() {
    return 'DataUsageState(dataSaver: $dataSaver, images: $images, uploads: $uploads, metered: $metered, loaded: $loaded)';
}


}

/// @nodoc
abstract mixin class _$DataUsageStateCopyWith<$Res> implements $DataUsageStateCopyWith<$Res> {
  factory _$DataUsageStateCopyWith(_DataUsageState value, $Res Function(_DataUsageState) _then) = __$DataUsageStateCopyWithImpl;
@override @useResult
$Res call({
 bool dataSaver, HighQualityImages images, HighQualityUploads uploads, bool metered, bool loaded
});




}
/// @nodoc
class __$DataUsageStateCopyWithImpl<$Res>
    implements _$DataUsageStateCopyWith<$Res> {
  __$DataUsageStateCopyWithImpl(this._self, this._then);

  final _DataUsageState _self;
  final $Res Function(_DataUsageState) _then;

/// Create a copy of DataUsageState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? dataSaver = null,Object? images = null,Object? uploads = null,Object? metered = null,Object? loaded = null,}) {
  return _then(_DataUsageState(
dataSaver: null == dataSaver ? _self.dataSaver : dataSaver // ignore: cast_nullable_to_non_nullable
as bool,images: null == images ? _self.images : images // ignore: cast_nullable_to_non_nullable
as HighQualityImages,uploads: null == uploads ? _self.uploads : uploads // ignore: cast_nullable_to_non_nullable
as HighQualityUploads,metered: null == metered ? _self.metered : metered // ignore: cast_nullable_to_non_nullable
as bool,loaded: null == loaded ? _self.loaded : loaded // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
