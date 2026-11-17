// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'trending_feed_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TrendingFeedState {

 PagedStatus get status; List<PostView> get rows;/// A pull to refresh is on its way (the rows stay).
 bool get refreshing;/// A further page is in flight.
 bool get loadingMore;/// The last page failed (the rows stay); [error] says why.
 bool get pagingFailed;/// A round found nothing on empty pages; only "Load more" asks again.
 bool get stalled;/// A next page exists.
 bool get hasMore;/// A failed refresh with the rows kept.
 Object? get notice; Object? get error;/// Changes when an expired token restarted the list from page one.
 int get resetSerial;
/// Create a copy of TrendingFeedState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TrendingFeedStateCopyWith<TrendingFeedState> get copyWith => _$TrendingFeedStateCopyWithImpl<TrendingFeedState>(this as TrendingFeedState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as TrendingFeedState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TrendingFeedState&&(identical(other.status, _this.status) || other.status == _this.status)&&const DeepCollectionEquality().equals(other.rows, _this.rows)&&(identical(other.refreshing, _this.refreshing) || other.refreshing == _this.refreshing)&&(identical(other.loadingMore, _this.loadingMore) || other.loadingMore == _this.loadingMore)&&(identical(other.pagingFailed, _this.pagingFailed) || other.pagingFailed == _this.pagingFailed)&&(identical(other.stalled, _this.stalled) || other.stalled == _this.stalled)&&(identical(other.hasMore, _this.hasMore) || other.hasMore == _this.hasMore)&&const DeepCollectionEquality().equals(other.notice, _this.notice)&&const DeepCollectionEquality().equals(other.error, _this.error)&&(identical(other.resetSerial, _this.resetSerial) || other.resetSerial == _this.resetSerial));
}


@override
int get hashCode {
  final _this = this as TrendingFeedState;
  return Object.hash(runtimeType,_this.status,const DeepCollectionEquality().hash(_this.rows),_this.refreshing,_this.loadingMore,_this.pagingFailed,_this.stalled,_this.hasMore,const DeepCollectionEquality().hash(_this.notice),const DeepCollectionEquality().hash(_this.error),_this.resetSerial);
}

@override
String toString() {
  final _this = this as TrendingFeedState;
  return 'TrendingFeedState(status: ${_this.status}, rows: ${_this.rows}, refreshing: ${_this.refreshing}, loadingMore: ${_this.loadingMore}, pagingFailed: ${_this.pagingFailed}, stalled: ${_this.stalled}, hasMore: ${_this.hasMore}, notice: ${_this.notice}, error: ${_this.error}, resetSerial: ${_this.resetSerial})';
}


}

/// @nodoc
abstract mixin class $TrendingFeedStateCopyWith<$Res>  {
  factory $TrendingFeedStateCopyWith(TrendingFeedState value, $Res Function(TrendingFeedState) _then) = _$TrendingFeedStateCopyWithImpl;
@useResult
$Res call({
 PagedStatus status, List<PostView> rows, bool refreshing, bool loadingMore, bool pagingFailed, bool stalled, bool hasMore, Object? notice, Object? error, int resetSerial
});




}
/// @nodoc
class _$TrendingFeedStateCopyWithImpl<$Res>
    implements $TrendingFeedStateCopyWith<$Res> {
  _$TrendingFeedStateCopyWithImpl(this._self, this._then);

  final TrendingFeedState _self;
  final $Res Function(TrendingFeedState) _then;

/// Create a copy of TrendingFeedState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? rows = null,Object? refreshing = null,Object? loadingMore = null,Object? pagingFailed = null,Object? stalled = null,Object? hasMore = null,Object? notice = freezed,Object? error = freezed,Object? resetSerial = null,}) {
  return _then(TrendingFeedState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as PagedStatus,rows: null == rows ? _self.rows : rows // ignore: cast_nullable_to_non_nullable
as List<PostView>,refreshing: null == refreshing ? _self.refreshing : refreshing // ignore: cast_nullable_to_non_nullable
as bool,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,pagingFailed: null == pagingFailed ? _self.pagingFailed : pagingFailed // ignore: cast_nullable_to_non_nullable
as bool,stalled: null == stalled ? _self.stalled : stalled // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,notice: freezed == notice ? _self.notice : notice ,error: freezed == error ? _self.error : error ,resetSerial: null == resetSerial ? _self.resetSerial : resetSerial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [TrendingFeedState].
extension TrendingFeedStatePatterns on TrendingFeedState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TrendingFeedState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TrendingFeedState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TrendingFeedState value)  $default,){
final _that = this;
switch (_that) {
case _TrendingFeedState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TrendingFeedState value)?  $default,){
final _that = this;
switch (_that) {
case _TrendingFeedState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( PagedStatus status,  List<PostView> rows,  bool refreshing,  bool loadingMore,  bool pagingFailed,  bool stalled,  bool hasMore,  Object? notice,  Object? error,  int resetSerial)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TrendingFeedState() when $default != null:
return $default(_that.status,_that.rows,_that.refreshing,_that.loadingMore,_that.pagingFailed,_that.stalled,_that.hasMore,_that.notice,_that.error,_that.resetSerial);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( PagedStatus status,  List<PostView> rows,  bool refreshing,  bool loadingMore,  bool pagingFailed,  bool stalled,  bool hasMore,  Object? notice,  Object? error,  int resetSerial)  $default,) {final _that = this;
switch (_that) {
case _TrendingFeedState():
return $default(_that.status,_that.rows,_that.refreshing,_that.loadingMore,_that.pagingFailed,_that.stalled,_that.hasMore,_that.notice,_that.error,_that.resetSerial);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( PagedStatus status,  List<PostView> rows,  bool refreshing,  bool loadingMore,  bool pagingFailed,  bool stalled,  bool hasMore,  Object? notice,  Object? error,  int resetSerial)?  $default,) {final _that = this;
switch (_that) {
case _TrendingFeedState() when $default != null:
return $default(_that.status,_that.rows,_that.refreshing,_that.loadingMore,_that.pagingFailed,_that.stalled,_that.hasMore,_that.notice,_that.error,_that.resetSerial);case _:
  return null;

}
}

}

/// @nodoc


class _TrendingFeedState implements TrendingFeedState {
  const _TrendingFeedState({this.status = PagedStatus.initial,  List<PostView> rows = const <PostView>[], this.refreshing = false, this.loadingMore = false, this.pagingFailed = false, this.stalled = false, this.hasMore = false, this.notice, this.error, this.resetSerial = 0}): _rows = rows;
  

@override@JsonKey() final  PagedStatus status;
 final  List<PostView> _rows;
@override@JsonKey() List<PostView> get rows {
  if (_rows is EqualUnmodifiableListView) return _rows;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_rows);
}

/// A pull to refresh is on its way (the rows stay).
@override@JsonKey() final  bool refreshing;
/// A further page is in flight.
@override@JsonKey() final  bool loadingMore;
/// The last page failed (the rows stay); [error] says why.
@override@JsonKey() final  bool pagingFailed;
/// A round found nothing on empty pages; only "Load more" asks again.
@override@JsonKey() final  bool stalled;
/// A next page exists.
@override@JsonKey() final  bool hasMore;
/// A failed refresh with the rows kept.
@override final  Object? notice;
@override final  Object? error;
/// Changes when an expired token restarted the list from page one.
@override@JsonKey() final  int resetSerial;

/// Create a copy of TrendingFeedState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TrendingFeedStateCopyWith<_TrendingFeedState> get copyWith => __$TrendingFeedStateCopyWithImpl<_TrendingFeedState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _TrendingFeedState&&(identical(other.status, status) || other.status == status)&&const DeepCollectionEquality().equals(other.rows, _rows)&&(identical(other.refreshing, refreshing) || other.refreshing == refreshing)&&(identical(other.loadingMore, loadingMore) || other.loadingMore == loadingMore)&&(identical(other.pagingFailed, pagingFailed) || other.pagingFailed == pagingFailed)&&(identical(other.stalled, stalled) || other.stalled == stalled)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&const DeepCollectionEquality().equals(other.notice, notice)&&const DeepCollectionEquality().equals(other.error, error)&&(identical(other.resetSerial, resetSerial) || other.resetSerial == resetSerial));
}


@override
int get hashCode {
    return Object.hash(runtimeType,status,const DeepCollectionEquality().hash(_rows),refreshing,loadingMore,pagingFailed,stalled,hasMore,const DeepCollectionEquality().hash(notice),const DeepCollectionEquality().hash(error),resetSerial);
}

@override
String toString() {
    return 'TrendingFeedState(status: $status, rows: $rows, refreshing: $refreshing, loadingMore: $loadingMore, pagingFailed: $pagingFailed, stalled: $stalled, hasMore: $hasMore, notice: $notice, error: $error, resetSerial: $resetSerial)';
}


}

/// @nodoc
abstract mixin class _$TrendingFeedStateCopyWith<$Res> implements $TrendingFeedStateCopyWith<$Res> {
  factory _$TrendingFeedStateCopyWith(_TrendingFeedState value, $Res Function(_TrendingFeedState) _then) = __$TrendingFeedStateCopyWithImpl;
@override @useResult
$Res call({
 PagedStatus status, List<PostView> rows, bool refreshing, bool loadingMore, bool pagingFailed, bool stalled, bool hasMore, Object? notice, Object? error, int resetSerial
});




}
/// @nodoc
class __$TrendingFeedStateCopyWithImpl<$Res>
    implements _$TrendingFeedStateCopyWith<$Res> {
  __$TrendingFeedStateCopyWithImpl(this._self, this._then);

  final _TrendingFeedState _self;
  final $Res Function(_TrendingFeedState) _then;

/// Create a copy of TrendingFeedState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? rows = null,Object? refreshing = null,Object? loadingMore = null,Object? pagingFailed = null,Object? stalled = null,Object? hasMore = null,Object? notice = freezed,Object? error = freezed,Object? resetSerial = null,}) {
  return _then(_TrendingFeedState(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as PagedStatus,rows: null == rows ? _self._rows : rows // ignore: cast_nullable_to_non_nullable
as List<PostView>,refreshing: null == refreshing ? _self.refreshing : refreshing // ignore: cast_nullable_to_non_nullable
as bool,loadingMore: null == loadingMore ? _self.loadingMore : loadingMore // ignore: cast_nullable_to_non_nullable
as bool,pagingFailed: null == pagingFailed ? _self.pagingFailed : pagingFailed // ignore: cast_nullable_to_non_nullable
as bool,stalled: null == stalled ? _self.stalled : stalled // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,notice: freezed == notice ? _self.notice : notice ,error: freezed == error ? _self.error : error ,resetSerial: null == resetSerial ? _self.resetSerial : resetSerial // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
