// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'suggestions_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SuggestionsState {

 List<graph.UserListItem> get items;
/// Create a copy of SuggestionsState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SuggestionsStateCopyWith<SuggestionsState> get copyWith => _$SuggestionsStateCopyWithImpl<SuggestionsState>(this as SuggestionsState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as SuggestionsState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SuggestionsState&&const DeepCollectionEquality().equals(other.items, _this.items));
}


@override
int get hashCode {
  final _this = this as SuggestionsState;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.items));
}

@override
String toString() {
  final _this = this as SuggestionsState;
  return 'SuggestionsState(items: ${_this.items})';
}


}

/// @nodoc
abstract mixin class $SuggestionsStateCopyWith<$Res>  {
  factory $SuggestionsStateCopyWith(SuggestionsState value, $Res Function(SuggestionsState) _then) = _$SuggestionsStateCopyWithImpl;
@useResult
$Res call({
 List<graph.UserListItem> items
});




}
/// @nodoc
class _$SuggestionsStateCopyWithImpl<$Res>
    implements $SuggestionsStateCopyWith<$Res> {
  _$SuggestionsStateCopyWithImpl(this._self, this._then);

  final SuggestionsState _self;
  final $Res Function(SuggestionsState) _then;

/// Create a copy of SuggestionsState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? items = null,}) {
  return _then(SuggestionsState(
items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<graph.UserListItem>,
  ));
}

}


/// Adds pattern-matching-related methods to [SuggestionsState].
extension SuggestionsStatePatterns on SuggestionsState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SuggestionsState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SuggestionsState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SuggestionsState value)  $default,){
final _that = this;
switch (_that) {
case _SuggestionsState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SuggestionsState value)?  $default,){
final _that = this;
switch (_that) {
case _SuggestionsState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<graph.UserListItem> items)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SuggestionsState() when $default != null:
return $default(_that.items);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<graph.UserListItem> items)  $default,) {final _that = this;
switch (_that) {
case _SuggestionsState():
return $default(_that.items);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<graph.UserListItem> items)?  $default,) {final _that = this;
switch (_that) {
case _SuggestionsState() when $default != null:
return $default(_that.items);case _:
  return null;

}
}

}

/// @nodoc


class _SuggestionsState implements SuggestionsState {
  const _SuggestionsState({ List<graph.UserListItem> items = const <graph.UserListItem>[]}): _items = items;
  

 final  List<graph.UserListItem> _items;
@override@JsonKey() List<graph.UserListItem> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}


/// Create a copy of SuggestionsState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SuggestionsStateCopyWith<_SuggestionsState> get copyWith => __$SuggestionsStateCopyWithImpl<_SuggestionsState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _SuggestionsState&&const DeepCollectionEquality().equals(other.items, _items));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_items));
}

@override
String toString() {
    return 'SuggestionsState(items: $items)';
}


}

/// @nodoc
abstract mixin class _$SuggestionsStateCopyWith<$Res> implements $SuggestionsStateCopyWith<$Res> {
  factory _$SuggestionsStateCopyWith(_SuggestionsState value, $Res Function(_SuggestionsState) _then) = __$SuggestionsStateCopyWithImpl;
@override @useResult
$Res call({
 List<graph.UserListItem> items
});




}
/// @nodoc
class __$SuggestionsStateCopyWithImpl<$Res>
    implements _$SuggestionsStateCopyWith<$Res> {
  __$SuggestionsStateCopyWithImpl(this._self, this._then);

  final _SuggestionsState _self;
  final $Res Function(_SuggestionsState) _then;

/// Create a copy of SuggestionsState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? items = null,}) {
  return _then(_SuggestionsState(
items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<graph.UserListItem>,
  ));
}


}

// dart format on
