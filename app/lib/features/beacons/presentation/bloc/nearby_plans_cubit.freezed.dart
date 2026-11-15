// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'nearby_plans_cubit.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$NearbyPlansState {

 NearbyLoad get load; List<pb.NearbyBeacon> get items; String get nextPageToken; bool get loadingMore; AreaRef? get area; pb.NearbyCount? get count; pb.NearbyScope get scope; AppException? get error;
/// Create a copy of NearbyPlansState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NearbyPlansStateCopyWith<NearbyPlansState> get copyWith => _$NearbyPlansStateCopyWithImpl<NearbyPlansState>(this as NearbyPlansState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as NearbyPlansState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NearbyPlansState&&(identical(other.load, _this.load) || other.load == _this.load)&&const DeepCollectionEquality().equals(other.items, _this.items)&&(identical(other.nextPageToken, _this.nextPageToken) || other.nextPageToken == _this.nextPageToken)&&(identical(other.loadingMore, _this.loadingMore) || other.loadingMore == _this.loadingMore)&&(identical(other.area, _this.area) || other.area == _this.area)&&(identical(other.count, _this.count) || other.count == _this.count)&&(identical(other.scope, _this.scope) || other.scope == _this.scope)&&(identical(other.error, _this.error) || other.error == _this.error));
}


@override
int get hashCode {
  final _this = this as NearbyPlansState;
  return Object.hash(runtimeType,_this.load,const DeepCollectionEquality().hash(_this.items),_this.nextPageToken,_this.loadingMore,_this.area,_this.count,_this.scope,_this.error);
}

@override
String toString() {
  final _this = this as NearbyPlansState;
  return 'NearbyPlansState(load: ${_this.load}, items: ${_this.items}, nextPageToken: ${_this.nextPageToken}, loadingMore: ${_this.loadingMore}, area: ${_this.area}, count: ${_this.count}, scope: ${_this.scope}, error: ${_this.error})';
}


}

/// @nodoc
abstract mixin class $NearbyPlansStateCopyWith<$Res>  {
  factory $NearbyPlansStateCopyWith(NearbyPlansState value, $Res Function(NearbyPlansState) _then) = _$NearbyPlansStateCopyWithImpl;
@useResult
$Res call({
 NearbyLoad load, List<pb.NearbyBeacon> items, String nextPageToken, bool loadingMore, AreaRef? area, pb.NearbyCount? count, pb.NearbyScope scope, AppException? error
});




}
/// @nodoc
class _$NearbyPlansStateCopyWithImpl<$Res>
    implements $NearbyPlansStateCopyWith<$Res> {
  _$NearbyPlansStateCopyWithImpl(this._self, this._then);

  final NearbyPlansState _self;
  final $Res Function(NearbyPlansState) _then;

/// Create a copy of NearbyPlansState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? load = null,Object? items = null,Object? nextPageToken = null,Object? loadingMore = null,Object? area = freezed,Object? count = freezed,Object? scope = null,Object? error = freezed,}) {
  return _then(NearbyPlansState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as NearbyLoad,items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<pb.NearbyBeacon>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,area: freezed == area ? _self.area : area // ignore: cast_nullable_to_non_nullable
as AreaRef?,count: freezed == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as pb.NearbyCount?,scope: null == scope ? _self.scope : scope // ignore: cast_nullable_to_non_nullable
as pb.NearbyScope,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}

}


/// Adds pattern-matching-related methods to [NearbyPlansState].
extension NearbyPlansStatePatterns on NearbyPlansState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _NearbyPlansState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _NearbyPlansState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _NearbyPlansState value)  $default,){
final _that = this;
switch (_that) {
case _NearbyPlansState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _NearbyPlansState value)?  $default,){
final _that = this;
switch (_that) {
case _NearbyPlansState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( NearbyLoad load,  List<pb.NearbyBeacon> items,  String nextPageToken,  bool loadingMore,  AreaRef? area,  pb.NearbyCount? count,  pb.NearbyScope scope,  AppException? error)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _NearbyPlansState() when $default != null:
return $default(_that.load,_that.items,_that.nextPageToken,_that.loadingMore,_that.area,_that.count,_that.scope,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( NearbyLoad load,  List<pb.NearbyBeacon> items,  String nextPageToken,  bool loadingMore,  AreaRef? area,  pb.NearbyCount? count,  pb.NearbyScope scope,  AppException? error)  $default,) {final _that = this;
switch (_that) {
case _NearbyPlansState():
return $default(_that.load,_that.items,_that.nextPageToken,_that.loadingMore,_that.area,_that.count,_that.scope,_that.error);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( NearbyLoad load,  List<pb.NearbyBeacon> items,  String nextPageToken,  bool loadingMore,  AreaRef? area,  pb.NearbyCount? count,  pb.NearbyScope scope,  AppException? error)?  $default,) {final _that = this;
switch (_that) {
case _NearbyPlansState() when $default != null:
return $default(_that.load,_that.items,_that.nextPageToken,_that.loadingMore,_that.area,_that.count,_that.scope,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _NearbyPlansState extends NearbyPlansState {
  const _NearbyPlansState({this.load = NearbyLoad.loading,  List<pb.NearbyBeacon> items = const <pb.NearbyBeacon>[], this.nextPageToken = '', this.loadingMore = false, this.area, this.count, this.scope = pb.NearbyScope.NEARBY_SCOPE_AREA, this.error}): _items = items,super._();
  

@override@JsonKey() final  NearbyLoad load;
 final  List<pb.NearbyBeacon> _items;
@override@JsonKey() List<pb.NearbyBeacon> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override@JsonKey() final  String nextPageToken;
@override@JsonKey() final  bool loadingMore;
@override final  AreaRef? area;
@override final  pb.NearbyCount? count;
@override@JsonKey() final  pb.NearbyScope scope;
@override final  AppException? error;

/// Create a copy of NearbyPlansState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$NearbyPlansStateCopyWith<_NearbyPlansState> get copyWith => __$NearbyPlansStateCopyWithImpl<_NearbyPlansState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _NearbyPlansState&&(identical(other.load, load) || other.load == load)&&const DeepCollectionEquality().equals(other.items, _items)&&(identical(other.nextPageToken, nextPageToken) || other.nextPageToken == nextPageToken)&&(identical(other.loadingMore, loadingMore) || other.loadingMore == loadingMore)&&(identical(other.area, area) || other.area == area)&&(identical(other.count, count) || other.count == count)&&(identical(other.scope, scope) || other.scope == scope)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,load,const DeepCollectionEquality().hash(_items),nextPageToken,loadingMore,area,count,scope,error);
}

@override
String toString() {
    return 'NearbyPlansState(load: $load, items: $items, nextPageToken: $nextPageToken, loadingMore: $loadingMore, area: $area, count: $count, scope: $scope, error: $error)';
}


}

/// @nodoc
abstract mixin class _$NearbyPlansStateCopyWith<$Res> implements $NearbyPlansStateCopyWith<$Res> {
  factory _$NearbyPlansStateCopyWith(_NearbyPlansState value, $Res Function(_NearbyPlansState) _then) = __$NearbyPlansStateCopyWithImpl;
@override @useResult
$Res call({
 NearbyLoad load, List<pb.NearbyBeacon> items, String nextPageToken, bool loadingMore, AreaRef? area, pb.NearbyCount? count, pb.NearbyScope scope, AppException? error
});




}
/// @nodoc
class __$NearbyPlansStateCopyWithImpl<$Res>
    implements _$NearbyPlansStateCopyWith<$Res> {
  __$NearbyPlansStateCopyWithImpl(this._self, this._then);

  final _NearbyPlansState _self;
  final $Res Function(_NearbyPlansState) _then;

/// Create a copy of NearbyPlansState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? load = null,Object? items = null,Object? nextPageToken = null,Object? loadingMore = null,Object? area = freezed,Object? count = freezed,Object? scope = null,Object? error = freezed,}) {
  return _then(_NearbyPlansState(
load: null == load ? _self.load : load // ignore: cast_nullable_to_non_nullable
as NearbyLoad,items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<pb.NearbyBeacon>,nextPageToken: null == nextPageToken ? _self.nextPageToken : nextPageToken // ignore: cast_nullable_to_non_nullable
as String,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,area: freezed == area ? _self.area : area // ignore: cast_nullable_to_non_nullable
as AreaRef?,count: freezed == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as pb.NearbyCount?,scope: null == scope ? _self.scope : scope // ignore: cast_nullable_to_non_nullable
as pb.NearbyScope,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as AppException?,
  ));
}


}

// dart format on
