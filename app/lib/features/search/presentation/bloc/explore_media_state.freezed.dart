// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'explore_media_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ExploreMediaState {

 ExploreMediaStatus get status; List<ExploreMediaTile> get tiles;/// A further page is in flight.
 bool get loadingMore;/// Some hashtag still has a next page token.
 bool get hasMore;/// The last page request failed (the tiles stay); [error] says why.
 bool get pagingFailed; Object? get error;/// A pull to refresh is on its way (the tiles stay).
 bool get refreshing;/// A round found nothing on empty pages; only "Show more" asks again.
 bool get stalled;/// A failed refresh with the tiles kept.
 Object? get notice;/// Changes when an expired token restarted the list from page one.
 int get resetSerial;
/// Create a copy of ExploreMediaState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ExploreMediaStateCopyWith<ExploreMediaState> get copyWith => _$ExploreMediaStateCopyWithImpl<ExploreMediaState>(this as ExploreMediaState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ExploreMediaState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ExploreMediaState&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.tiles, _this.tiles)&&(identical(other.loadingMore, _this.loadingMore) || other.loadingMore == _this.loadingMore)&&(identical(other.hasMore, _this.hasMore) || other.hasMore == _this.hasMore)&&(identical(other.pagingFailed, _this.pagingFailed) || other.pagingFailed == _this.pagingFailed)&&const DeepCollectionEquality().equals(other.error, _this.error)&&(identical(other.refreshing, _this.refreshing) || other.refreshing == _this.refreshing)&&(identical(other.stalled, _this.stalled) || other.stalled == _this.stalled)&&const DeepCollectionEquality().equals(other.notice, _this.notice)&&(identical(other.resetSerial, _this.resetSerial) || other.resetSerial == _this.resetSerial));
}


@override
int get hashCode {
  final _this = this as ExploreMediaState;
  return Object.hash(runtimeType,_this.status,const DeepCollectionEquality().hash(_this.tiles),_this.loadingMore,_this.hasMore,_this.pagingFailed,const DeepCollectionEquality().hash(_this.error),_this.refreshing,_this.stalled,const DeepCollectionEquality().hash(_this.notice),_this.resetSerial);
}

@override
String toString() {
  final _this = this as ExploreMediaState;
  return 'ExploreMediaState(status: ${_this.status}, tiles: ${_this.tiles}, loadingMore: ${_this.loadingMore}, hasMore: ${_this.hasMore}, pagingFailed: ${_this.pagingFailed}, error: ${_this.error}, refreshing: ${_this.refreshing}, stalled: ${_this.stalled}, notice: ${_this.notice}, resetSerial: ${_this.resetSerial})';
}


}

/// @nodoc
abstract mixin class $ExploreMediaStateCopyWith<$Res>  {
  factory $ExploreMediaStateCopyWith(ExploreMediaState value, $Res Function(ExploreMediaState) _then) = _$ExploreMediaStateCopyWithImpl;
@useResult
$Res call({
 ExploreMediaStatus status, List<ExploreMediaTile> tiles, bool loadingMore, bool hasMore, bool pagingFailed, Object? error, bool refreshing, bool stalled, Object? notice, int resetSerial
});




}
/// @nodoc
class _$ExploreMediaStateCopyWithImpl<$Res>
    implements $ExploreMediaStateCopyWith<$Res> {
  _$ExploreMediaStateCopyWithImpl(this._self, this._then);

  final ExploreMediaState _self;
  final $Res Function(ExploreMediaState) _then;

/// Create a copy of ExploreMediaState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? tiles = null,Object? loadingMore = null,Object? hasMore = null,Object? pagingFailed = null,Object? error = freezed,Object? refreshing = null,Object? stalled = null,Object? notice = freezed,Object? resetSerial = null,}) {
  return _then(ExploreMediaState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ExploreMediaStatus,tiles: null == tiles ? _self.tiles : tiles // ignore: cast_nullable_to_non_nullable
as List<ExploreMediaTile>,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,pagingFailed: null == pagingFailed ? _self.pagingFailed : pagingFailed // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error ,refreshing: null == refreshing ? _self.refreshing : refreshing // ignore: cast_nullable_to_non_nullable
as bool,stalled: null == stalled ? _self.stalled : stalled // ignore: cast_nullable_to_non_nullable
as bool,notice: freezed == notice ? _self.notice : notice ,resetSerial: null == resetSerial ? _self.resetSerial : resetSerial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [ExploreMediaState].
extension ExploreMediaStatePatterns on ExploreMediaState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ExploreMediaState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ExploreMediaState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ExploreMediaState value)  $default,){
final _that = this;
switch (_that) {
case _ExploreMediaState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ExploreMediaState value)?  $default,){
final _that = this;
switch (_that) {
case _ExploreMediaState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ExploreMediaStatus status,  List<ExploreMediaTile> tiles,  bool loadingMore,  bool hasMore,  bool pagingFailed,  Object? error,  bool refreshing,  bool stalled,  Object? notice,  int resetSerial)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ExploreMediaState() when $default != null:
return $default(_that.status,_that.tiles,_that.loadingMore,_that.hasMore,_that.pagingFailed,_that.error,_that.refreshing,_that.stalled,_that.notice,_that.resetSerial);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ExploreMediaStatus status,  List<ExploreMediaTile> tiles,  bool loadingMore,  bool hasMore,  bool pagingFailed,  Object? error,  bool refreshing,  bool stalled,  Object? notice,  int resetSerial)  $default,) {final _that = this;
switch (_that) {
case _ExploreMediaState():
return $default(_that.status,_that.tiles,_that.loadingMore,_that.hasMore,_that.pagingFailed,_that.error,_that.refreshing,_that.stalled,_that.notice,_that.resetSerial);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ExploreMediaStatus status,  List<ExploreMediaTile> tiles,  bool loadingMore,  bool hasMore,  bool pagingFailed,  Object? error,  bool refreshing,  bool stalled,  Object? notice,  int resetSerial)?  $default,) {final _that = this;
switch (_that) {
case _ExploreMediaState() when $default != null:
return $default(_that.status,_that.tiles,_that.loadingMore,_that.hasMore,_that.pagingFailed,_that.error,_that.refreshing,_that.stalled,_that.notice,_that.resetSerial);case _:
  return null;

}
}

}

/// @nodoc


class _ExploreMediaState implements ExploreMediaState {
  const _ExploreMediaState({this.status = ExploreMediaStatus.initial,  List<ExploreMediaTile> tiles = const <ExploreMediaTile>[], this.loadingMore = false, this.hasMore = false, this.pagingFailed = false, this.error, this.refreshing = false, this.stalled = false, this.notice, this.resetSerial = 0}): _tiles = tiles;
  

@override@JsonKey() final  ExploreMediaStatus status;
 final  List<ExploreMediaTile> _tiles;
@override@JsonKey() List<ExploreMediaTile> get tiles {
  if (_tiles is EqualUnmodifiableListView) return _tiles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tiles);
}

/// A further page is in flight.
@override@JsonKey() final  bool loadingMore;
/// Some hashtag still has a next page token.
@override@JsonKey() final  bool hasMore;
/// The last page request failed (the tiles stay); [error] says why.
@override@JsonKey() final  bool pagingFailed;
@override final  Object? error;
/// A pull to refresh is on its way (the tiles stay).
@override@JsonKey() final  bool refreshing;
/// A round found nothing on empty pages; only "Show more" asks again.
@override@JsonKey() final  bool stalled;
/// A failed refresh with the tiles kept.
@override final  Object? notice;
/// Changes when an expired token restarted the list from page one.
@override@JsonKey() final  int resetSerial;

/// Create a copy of ExploreMediaState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ExploreMediaStateCopyWith<_ExploreMediaState> get copyWith => __$ExploreMediaStateCopyWithImpl<_ExploreMediaState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ExploreMediaState&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.tiles, _tiles)&&(identical(other.loadingMore, loadingMore) || other.loadingMore == loadingMore)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.pagingFailed, pagingFailed) || other.pagingFailed == pagingFailed)&&const DeepCollectionEquality().equals(other.error, error)&&(identical(other.refreshing, refreshing) || other.refreshing == refreshing)&&(identical(other.stalled, stalled) || other.stalled == stalled)&&const DeepCollectionEquality().equals(other.notice, notice)&&(identical(other.resetSerial, resetSerial) || other.resetSerial == resetSerial));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,const DeepCollectionEquality().hash(_tiles),loadingMore,hasMore,pagingFailed,const DeepCollectionEquality().hash(error),refreshing,stalled,const DeepCollectionEquality().hash(notice),resetSerial);
}

@override
String toString() {
    return 'ExploreMediaState(status: $status, tiles: $tiles, loadingMore: $loadingMore, hasMore: $hasMore, pagingFailed: $pagingFailed, error: $error, refreshing: $refreshing, stalled: $stalled, notice: $notice, resetSerial: $resetSerial)';
}


}

/// @nodoc
abstract mixin class _$ExploreMediaStateCopyWith<$Res> implements $ExploreMediaStateCopyWith<$Res> {
  factory _$ExploreMediaStateCopyWith(_ExploreMediaState value, $Res Function(_ExploreMediaState) _then) = __$ExploreMediaStateCopyWithImpl;
@override @useResult
$Res call({
 ExploreMediaStatus status, List<ExploreMediaTile> tiles, bool loadingMore, bool hasMore, bool pagingFailed, Object? error, bool refreshing, bool stalled, Object? notice, int resetSerial
});




}
/// @nodoc
class __$ExploreMediaStateCopyWithImpl<$Res>
    implements _$ExploreMediaStateCopyWith<$Res> {
  __$ExploreMediaStateCopyWithImpl(this._self, this._then);

  final _ExploreMediaState _self;
  final $Res Function(_ExploreMediaState) _then;

/// Create a copy of ExploreMediaState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? tiles = null,Object? loadingMore = null,Object? hasMore = null,Object? pagingFailed = null,Object? error = freezed,Object? refreshing = null,Object? stalled = null,Object? notice = freezed,Object? resetSerial = null,}) {
  return _then(_ExploreMediaState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ExploreMediaStatus,tiles: null == tiles ? _self._tiles : tiles // ignore: cast_nullable_to_non_nullable
as List<ExploreMediaTile>,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,pagingFailed: null == pagingFailed ? _self.pagingFailed : pagingFailed // ignore: cast_nullable_to_non_nullable
as bool,error: freezed == error ? _self.error : error ,refreshing: null == refreshing ? _self.refreshing : refreshing // ignore: cast_nullable_to_non_nullable
as bool,stalled: null == stalled ? _self.stalled : stalled // ignore: cast_nullable_to_non_nullable
as bool,notice: freezed == notice ? _self.notice : notice ,resetSerial: null == resetSerial ? _self.resetSerial : resetSerial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
